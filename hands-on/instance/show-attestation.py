#!/usr/bin/env python3
"""AWS Deep Cuts - Nitro Enclaves ハンズオン: アテステーション文書の中身を表示する

  python3 show-attestation.py <client.py attest で保存したファイル>

アテステーション文書は、CBOR で表した COSE_Sign1（4 つの要素の配列）です。
3 つ目の要素 payload を CBOR として読み、主な項目を表示します。
署名と証明書の検証は行いません（KMS が Decrypt の要求を受け付けるときに検証します）。
cbor2 はユーザーデータが pip3 install cbor2==5.9.0 で入れています。
"""
import datetime
import hashlib
import sys

import cbor2

SHOWN_PCRS = (0, 1, 2, 3, 4, 8)


def load_payload(path):
    with open(path, "rb") as f:
        cose = cbor2.loads(f.read())
    # COSE_Sign1 は CBOR のタグ 18 が付く場合と、付かない場合がある
    if isinstance(cose, cbor2.CBORTag):
        cose = cose.value
    if not isinstance(cose, list) or len(cose) != 4:
        raise ValueError("COSE_Sign1 の形ではありません")
    return cbor2.loads(cose[2])


def main():
    if len(sys.argv) != 2:
        print("使い方: python3 show-attestation.py <アテステーション文書のファイル>", file=sys.stderr)
        sys.exit(2)
    doc = load_payload(sys.argv[1])
    timestamp = datetime.datetime.fromtimestamp(doc["timestamp"] / 1000, tz=datetime.timezone.utc)
    print(f"module_id : {doc['module_id']}")
    print(f"timestamp : {timestamp:%Y-%m-%d %H:%M:%S} UTC")
    print(f"digest    : {doc['digest']}")
    pcrs = doc.get("pcrs", {})
    for index in SHOWN_PCRS:
        value = pcrs.get(index)
        print(f"PCR{index:<7}: {value.hex() if value is not None else '-'}")
    public_key = doc.get("public_key")
    if public_key:
        fingerprint = hashlib.sha256(public_key).hexdigest()[:16]
        print(f"public_key: {len(public_key)} バイト（SHA-256 の先頭 16 桁: {fingerprint}）")
    else:
        print("public_key: なし")
    print(f"certificate: {len(doc.get('certificate', b''))} バイト、cabundle: {len(doc.get('cabundle', []))} 個")


if __name__ == "__main__":
    main()
