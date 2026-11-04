#!/bin/sh
# Enclave にはネットワークが無い。ループバックを有効にし、KMS のホスト名を 127.0.0.1 に向ける。
# 127.0.0.1:443 への通信は、app.py が vsock で親インスタンスの vsock-proxy（CID 3・ポート 8000）へ転送する。
ip addr add 127.0.0.1/32 dev lo
ip link set dev lo up
echo "127.0.0.1 kms.${KMS_REGION}.amazonaws.com" >> /etc/hosts
exec python3 -u /app/app.py
