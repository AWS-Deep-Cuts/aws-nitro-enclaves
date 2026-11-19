#!/usr/bin/env python3
"""AWS Deep Cuts - Nitro Enclaves ハンズオン: 親インスタンスで運営者が実行するクライアント

  python3 client.py attest --out <ファイル>
      Enclave にアテステーション文書を作成させ、バイナリのままファイルに保存する
  python3 client.py match --inbox <ディレクトリ> --out <ディレクトリ>
      暗号化した希望（<inbox>/*.enc）と、インスタンスロールの一時的な認証情報を Enclave に送り、
      Enclave が返した結果（参加者ごとの暗号文）を <out>/<参加者>.result.enc に保存する

Enclave の CID は santa.env の ENCLAVE_CID（既定 16）、ポートは 5000。
標準ライブラリだけで書いている（Amazon Linux 2023 の python3 は 3.9）。
"""
import argparse
import base64
import glob
import json
import os
import socket
import sys
import time
import urllib.request

APP_PORT = 5000
RETRY_SECONDS = 1
QUIET_RETRY_SECONDS = 15
RETRY_LIMIT_SECONDS = 60
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def enclave_cid():
    """santa.env の ENCLAVE_CID を読む。無ければ 16"""
    cid = os.environ.get("ENCLAVE_CID")
    env_path = os.path.join(SCRIPT_DIR, "santa.env")
    if not cid and os.path.exists(env_path):
        with open(env_path, encoding="utf-8") as f:
            for line in f:
                key, _, value = line.strip().partition("=")
                if key == "ENCLAVE_CID":
                    cid = value.strip('"')
    return int(cid or 16)


def instance_role_credentials():
    """IMDSv2 で、インスタンスロールの一時的な認証情報を取得する"""
    base = "http://169.254.169.254/latest"
    token_request = urllib.request.Request(
        base + "/api/token", method="PUT", headers={"X-aws-ec2-metadata-token-ttl-seconds": "300"})
    token = urllib.request.urlopen(token_request, timeout=5).read().decode()

    def get(path):
        request = urllib.request.Request(
            base + "/meta-data/iam/security-credentials/" + path, headers={"X-aws-ec2-metadata-token": token})
        return urllib.request.urlopen(request, timeout=5).read().decode()

    role_name = get("").splitlines()[0]
    creds = json.loads(get(role_name))
    return {"AccessKeyId": creds["AccessKeyId"], "SecretAccessKey": creds["SecretAccessKey"],
            "Token": creds["Token"]}


def connect(cid):
    """Enclave の起動直後は、アプリの待ち受けが始まっていないことがあるため、やり直す。
    起動直後の失敗は想定どおりのため、QUIET_RETRY_SECONDS までは表示せずにやり直す"""
    start = time.time()
    deadline = start + RETRY_LIMIT_SECONDS
    while True:
        sock = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        try:
            sock.connect((cid, APP_PORT))
            return sock
        except OSError as e:
            sock.close()
            if time.time() >= deadline:
                print(f"Enclave（CID {cid}）のポート {APP_PORT} に接続できません: {e}", file=sys.stderr)
                print("nitro-cli describe-enclaves で、Enclave が起動しているかを確かめてください。", file=sys.stderr)
                sys.exit(1)
            if time.time() - start >= QUIET_RETRY_SECONDS:
                print(f"  接続できないため、{RETRY_SECONDS} 秒後にやり直します（{e}）")
            time.sleep(RETRY_SECONDS)


def send_request(payload):
    cid = enclave_cid()
    print(f"Enclave（CID {cid}）のポート {APP_PORT} に接続します")
    sock = connect(cid)
    try:
        sock.sendall((json.dumps(payload) + "\n").encode("utf-8"))
        chunks = []
        while True:
            data = sock.recv(65536)
            if not data:
                break
            chunks.append(data)
            if data.endswith(b"\n"):
                break
    finally:
        sock.close()
    return json.loads(b"".join(chunks).decode("utf-8"))


def print_error(response):
    print(f"Enclave の応答: error（{response.get('error_code', '-')}）")
    if response.get("message"):
        print(f"  {response['message']}")


def cmd_attest(args):
    response = send_request({"type": "attest"})
    if response.get("status") != "ok":
        print_error(response)
        sys.exit(1)
    doc = base64.b64decode(response["attestation_document"])
    with open(args.out, "wb") as f:
        f.write(doc)
    print("Enclave の応答: ok")
    print(f"アテステーション文書を {args.out} に保存しました（{len(doc)} バイト）")


def cmd_match(args):
    files = sorted(glob.glob(os.path.join(args.inbox, "*.enc")))
    if not files:
        print(f"{args.inbox}/*.enc が見つかりません", file=sys.stderr)
        sys.exit(1)
    wishes = []
    for path in files:
        with open(path, "rb") as f:
            wishes.append({"file": os.path.basename(path), "ciphertext": base64.b64encode(f.read()).decode()})
    payload = {"type": "match", "credentials": instance_role_credentials(), "wishes": wishes}
    response = send_request(payload)
    print(f"送るもの: 暗号化した希望 {len(wishes)} 件（{args.inbox}/*.enc）と、"
          "インスタンスロールの一時的な認証情報（値は表示しません）")
    if response.get("status") != "ok":
        print_error(response)
        sys.exit(1)
    print("Enclave の応答: ok")
    os.makedirs(args.out, exist_ok=True)
    for name in sorted(response["results"]):
        data = base64.b64decode(response["results"][name])
        path = os.path.join(args.out, f"{name}.result.enc")
        with open(path, "wb") as f:
            f.write(data)
        print(f"  {name:<9} → {path}（{len(data)} バイト）")
    view = response.get("operator_view")
    if not view:
        print("運営者に見える希望: なし")
        return
    print("運営者に見える希望:")
    print(f"  {'贈る人':<9} {'受け取る人':<9} 希望")
    for row in view:
        print(f"  {row['giver']:<9} {row['receiver']:<9} {row['wish']}")


def main():
    parser = argparse.ArgumentParser(description="Enclave のシークレットサンタのアプリに要求を送る")
    sub = parser.add_subparsers(dest="command", required=True)
    attest = sub.add_parser("attest", help="アテステーション文書を取得する")
    attest.add_argument("--out", required=True, help="文書を保存するファイル")
    attest.set_defaults(func=cmd_attest)
    match = sub.add_parser("match", help="組み合わせを依頼する")
    match.add_argument("--inbox", required=True, help="暗号化した希望（*.enc）のディレクトリ")
    match.add_argument("--out", required=True, help="結果を保存するディレクトリ")
    match.set_defaults(func=cmd_match)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
