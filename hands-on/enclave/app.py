#!/usr/bin/env python3
"""AWS Deep Cuts - Nitro Enclaves ハンズオン: Enclave の中で動くシークレットサンタのアプリ

起動時の処理（この順。各段で 1 行のログを標準出力に出す）:
  1. 設定 SHOW_WISHES_TO_OPERATOR の値を表示する
  2. 127.0.0.1:443 の TCP を、vsock で親インスタンスの vsock-proxy（CID 3・ポート 8000）へ転送する
  3. NSM のライブラリ libnsm.so を読み込み、/dev/nsm を開く
  4. NSM の DescribePCR で、この Enclave の PCR0 を読む
  5. openssl で RSA 2048 の鍵の組を作成する。秘密鍵は Enclave の外に出さない
  6. vsock のポート 5000 で、親インスタンスからの要求を待ち受ける

要求は 1 行 1 つの JSON（改行で終わる。UTF-8）:
  {"type": "attest"}  … アテステーション文書を作成して返す
  {"type": "match", "credentials": {...}, "wishes": [...]}
                      … KMS に希望の復号を依頼し、組み合わせを決め、
                        各参加者の公開鍵で暗号化した結果を返す

ログには件数と成否だけを出し、希望と組み合わせは出さない。
ログは、デバッグモードの Enclave のときだけ、親インスタンスの nitro-cli console で読める。
Python 3.9（Amazon Linux 2023 の python3）で動くように書いている。
"""
import base64
import ctypes
import json
import os
import re
import secrets
import socket
import subprocess
import tempfile
import threading
from ctypes import POINTER, byref, c_bool, c_char_p, c_int32, c_uint8, c_uint16, c_uint32, c_void_p

import boto3
from botocore.exceptions import BotoCoreError, ClientError

# のぞき見 4 で、運営者がこの行を True に書き換える。True にすると、復号した希望を運営者への応答に含める
SHOW_WISHES_TO_OPERATOR = False

PARENT_CID = 3            # 親インスタンスの vsock の CID
PROXY_PORT = 8000         # 親インスタンスの vsock-proxy のポート
APP_PORT = 5000           # このアプリが要求を待ち受ける vsock のポート
KEY_PATH = "/tmp/enclave-key.pem"
PUB_PATH = "/tmp/enclave-pub.der"
MAX_RESULT_BYTES = 190    # RSA 2048・OAEP・SHA-256 で暗号化できる上限（256 - 2 × 32 - 2）
MIN_PARTICIPANTS = 3
NAME_PATTERN = re.compile(r"^[a-z0-9_-]{1,32}$")

NSM = None
NSM_FD = -1
PUBLIC_KEY_DER = b""


def log(message):
    print(message, flush=True)


# ─── 2. KMS への通信の転送 ─────────────────────────────────────

def pipe(source, destination):
    """source から読んだバイト列を、そのまま destination に書き込む"""
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            destination.sendall(data)
    except OSError:
        pass
    finally:
        try:
            destination.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def bridge(client, upstream):
    """1 つの接続について、両方向の転送が終わるまで待ち、2 つのソケットを閉じる"""
    outgoing = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    outgoing.start()
    pipe(upstream, client)
    outgoing.join()
    client.close()
    upstream.close()


def serve_kms_forwarder(listener):
    while True:
        client, _ = listener.accept()
        upstream = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        try:
            upstream.connect((PARENT_CID, PROXY_PORT))
        except OSError as e:
            log(f"親インスタンスの vsock-proxy に接続できません: {e}")
            client.close()
            upstream.close()
            continue
        threading.Thread(target=bridge, args=(client, upstream), daemon=True).start()


def start_kms_forwarder():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 443))
    listener.listen(16)
    threading.Thread(target=serve_kms_forwarder, args=(listener,), daemon=True).start()


# ─── 3・4. NSM（Nitro Secure Module） ─────────────────────────

def init_nsm():
    global NSM, NSM_FD
    NSM = ctypes.CDLL("/usr/lib64/libnsm.so")
    NSM.nsm_lib_init.argtypes = []
    NSM.nsm_lib_init.restype = c_int32
    NSM.nsm_describe_pcr.argtypes = [c_int32, c_uint16, POINTER(c_bool), POINTER(c_uint8), POINTER(c_uint32)]
    NSM.nsm_describe_pcr.restype = c_int32
    # 引数の順は aws-nitro-enclaves-nsm-api の nsm-lib/src/lib.rs の nsm_get_attestation_doc のとおり
    NSM.nsm_get_attestation_doc.argtypes = [c_int32, c_void_p, c_uint32, c_void_p, c_uint32,
                                            c_char_p, c_uint32, POINTER(c_uint8), POINTER(c_uint32)]
    NSM.nsm_get_attestation_doc.restype = c_int32
    NSM_FD = NSM.nsm_lib_init()
    if NSM_FD < 0:
        raise RuntimeError("/dev/nsm を開けません")


def describe_pcr0():
    lock = c_bool(False)
    buf = (c_uint8 * 64)()
    size = c_uint32(len(buf))
    rc = NSM.nsm_describe_pcr(NSM_FD, 0, byref(lock), buf, byref(size))
    if rc != 0:
        return f"（取得できませんでした。ErrorCode {rc}）"
    return bytes(buf[:size.value]).hex()


def log_pcr0():
    log(f"この Enclave の PCR0（NSM の DescribePCR）: {describe_pcr0()}")


def attestation_document():
    """NSM に公開鍵を渡し、アテステーション文書を受け取る"""
    buf = (c_uint8 * 16384)()
    size = c_uint32(len(buf))
    rc = NSM.nsm_get_attestation_doc(NSM_FD, None, 0, None, 0,
                                     PUBLIC_KEY_DER, len(PUBLIC_KEY_DER), buf, byref(size))
    # rc == 0 が成功（ErrorCode::Success）
    if rc != 0:
        raise RuntimeError(f"アテステーション文書を取得できません。ErrorCode {rc}")
    return bytes(buf[:size.value])


# ─── 5. Enclave の鍵の組 ──────────────────────────────────────

def create_key_pair():
    global PUBLIC_KEY_DER
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA",
                    "-pkeyopt", "rsa_keygen_bits:2048", "-out", KEY_PATH],
                   check=True, capture_output=True)
    os.chmod(KEY_PATH, 0o600)
    subprocess.run(["openssl", "pkey", "-in", KEY_PATH, "-pubout", "-outform", "DER", "-out", PUB_PATH],
                   check=True, capture_output=True)
    with open(PUB_PATH, "rb") as f:
        PUBLIC_KEY_DER = f.read()


# ─── 希望の復号と、結果の暗号化 ────────────────────────────────

def decrypt_wish(kms, blob, doc):
    """KMS に Decrypt を依頼し、返ってきた CiphertextForRecipient を Enclave の秘密鍵で復号する"""
    resp = kms.decrypt(
        CiphertextBlob=blob,
        Recipient={
            "KeyEncryptionAlgorithm": "RSAES_OAEP_SHA_256",
            "AttestationDocument": doc,  # NSM が発行した文書。PCR0 と Enclave の公開鍵が入っている
        },
    )
    # Plaintext は返らない。KMS は、復号した希望を文書の公開鍵で暗号化して返す
    envelope = resp["CiphertextForRecipient"]
    with tempfile.NamedTemporaryFile(dir="/tmp", suffix=".der") as f:
        f.write(envelope)
        f.flush()
        out = subprocess.run(
            ["openssl", "cms", "-decrypt", "-inform", "DER",
             "-inkey", "/tmp/enclave-key.pem", "-in", f.name],
            check=True, capture_output=True)
    return json.loads(out.stdout)


def encrypt_for_participant(public_key_pem, data):
    """参加者の公開鍵で、結果の本文を暗号化する。開けるのは、その参加者の秘密鍵だけ"""
    with tempfile.NamedTemporaryFile(dir="/tmp", suffix=".pub", mode="w") as f:
        f.write(public_key_pem)
        f.flush()
        out = subprocess.run(
            ["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", f.name,
             "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256"],
            input=data, check=True, capture_output=True)
    return out.stdout


def validate_participants(people):
    names = []
    for person in people:
        name = person.get("name", "")
        if not NAME_PATTERN.match(name) or not person.get("wish") or not person.get("public_key"):
            raise ValueError("参加者の JSON の形が正しくありません")
        names.append(name)
    # 運営者が同じ暗号文を 2 回入れる操作を拒否する
    if len(set(names)) != len(names):
        raise ValueError("同じ参加者の希望が 2 つ以上あります")
    if len(names) < MIN_PARTICIPANTS:
        raise ValueError(f"参加者が {MIN_PARTICIPANTS} 人未満です")


def handle_match(request):
    log_pcr0()
    wishes = request.get("wishes", [])
    log(f"組み合わせの要求を受け付けました。暗号化した希望: {len(wishes)} 件")
    creds = request["credentials"]
    doc = attestation_document()  # 同じ要求の中の Decrypt で共有する
    kms = boto3.client(
        "kms",
        region_name=os.environ["KMS_REGION"],
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["Token"],
    )
    people = []
    for item in wishes:
        blob = base64.b64decode(item["ciphertext"])
        try:
            people.append(decrypt_wish(kms, blob, doc))
        except ClientError as e:
            error = e.response.get("Error", {})
            code = error.get("Code", "ClientError")
            log(f"KMS が Decrypt を拒否しました: {code}")
            # 最初の失敗で止める（KMS の呼び出しの回数と CloudTrail の記録を少なくするため）
            return {"status": "error", "error_code": code, "message": error.get("Message", "")}
    log(f"KMS から {len(people)} 件の希望を受け取り、Enclave の秘密鍵で開きました")
    validate_participants(people)

    # 全員を並べ替え、各参加者は次の参加者に贈る。最後の参加者は最初の参加者に贈る。
    # 並べ替えた全員で 1 つの輪を作るため、自分に当たる人はいない。
    order = list(people)
    secrets.SystemRandom().shuffle(order)
    results = {}
    operator_view = []
    for i, giver in enumerate(order):
        receiver = order[(i + 1) % len(order)]
        text = f"{receiver['name']} さんに贈ります。{receiver['name']} さんの希望: {receiver['wish']}"
        data = text.encode("utf-8")
        if len(data) > MAX_RESULT_BYTES:
            raise ValueError(f"結果の本文が {MAX_RESULT_BYTES} バイトを超えます。希望を短くしてください")
        results[giver["name"]] = base64.b64encode(encrypt_for_participant(giver["public_key"], data)).decode()
        operator_view.append({"giver": giver["name"], "receiver": receiver["name"], "wish": receiver["wish"]})

    response = {"status": "ok", "results": results}
    if SHOW_WISHES_TO_OPERATOR:
        response["operator_view"] = operator_view
    log(f"組み合わせを決め、{len(results)} 件の結果を参加者の公開鍵で暗号化しました")
    return response


def handle_attest():
    log_pcr0()
    log("アテステーション文書の要求を受け付けました")
    doc = attestation_document()
    log(f"アテステーション文書を返します: {len(doc)} バイト")
    return {"status": "ok", "attestation_document": base64.b64encode(doc).decode()}


# ─── 6. 親インスタンスからの要求を待ち受ける ────────────────────

def read_line(conn, limit=4 * 1024 * 1024):
    chunks = []
    total = 0
    while True:
        data = conn.recv(65536)
        if not data:
            break
        chunks.append(data)
        total += len(data)
        if data.endswith(b"\n") or total > limit:
            break
    return b"".join(chunks)


def handle_connection(conn):
    try:
        request = json.loads(read_line(conn).decode("utf-8"))
        kind = request.get("type")
        if kind == "attest":
            response = handle_attest()
        elif kind == "match":
            response = handle_match(request)
        else:
            response = {"status": "error", "error_code": "BadRequest", "message": f"不明な要求です: {kind}"}
    except (ValueError, KeyError, TypeError, RuntimeError, BotoCoreError, subprocess.CalledProcessError) as e:
        log(f"要求を処理できませんでした: {type(e).__name__}")
        response = {"status": "error", "error_code": type(e).__name__, "message": str(e)}
    conn.sendall((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))


def main():
    log(f"[1/6] 設定 SHOW_WISHES_TO_OPERATOR = {SHOW_WISHES_TO_OPERATOR}")
    start_kms_forwarder()
    log(f"[2/6] 127.0.0.1:443 を vsock の CID {PARENT_CID}・ポート {PROXY_PORT} へ転送します")
    init_nsm()
    log("[3/6] NSM のライブラリを読み込み、/dev/nsm を開きました")
    log("[4/6] " + f"この Enclave の PCR0（NSM の DescribePCR）: {describe_pcr0()}")
    create_key_pair()
    log(f"[5/6] Enclave の鍵の組を作成しました。公開鍵: {len(PUBLIC_KEY_DER)} バイト")
    server = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    server.bind((socket.VMADDR_CID_ANY, APP_PORT))
    server.listen(4)
    log(f"[6/6] vsock のポート {APP_PORT} で要求を待ち受けます")
    while True:
        conn, _ = server.accept()
        try:
            handle_connection(conn)
        except OSError as e:
            log(f"接続の処理に失敗しました: {e}")
        finally:
            conn.close()


if __name__ == "__main__":
    main()
