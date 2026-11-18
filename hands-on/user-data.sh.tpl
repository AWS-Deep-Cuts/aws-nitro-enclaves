#!/bin/bash
# AWS Deep Cuts - Nitro Enclaves ハンズオン: 親インスタンスのユーザーデータの元
# setup.sh が __BUCKET_NAME__ と __REGION__ を置き換えて user-data.sh を作成し、
# README の手順 2 の run-instances が --user-data で渡します。
# cloud-init は、このスクリプトをインスタンスの初回の起動でだけ、root として実行します。
set -euxo pipefail
# 費用の上限のため、初回の起動から 4 時間でインスタンスを停止する。
# シャットダウンの動作を terminate にしてあるため、停止はインスタンスの終了になる。
# shutdown の予約は再起動で消えるため、終了の時刻をファイルに保存し、起動のたびに予約し直す。
install -d -m 0755 /var/lib/aws-deepcuts
date -u -d '+240 minutes' +%s > /var/lib/aws-deepcuts/deadline
cat > /usr/local/sbin/aws-deepcuts-deadline.sh <<'EOS'
#!/bin/bash
set -euo pipefail
DEADLINE=$(cat /var/lib/aws-deepcuts/deadline)
NOW=$(date -u +%s)
MINUTES=$(( (DEADLINE - NOW + 59) / 60 ))
if (( MINUTES <= 0 )); then
  shutdown -h now "AWS Deep Cuts: 終了の時刻を過ぎたため、インスタンスを終了します"
else
  shutdown -h "+${MINUTES}" "AWS Deep Cuts: 初回の起動から 4 時間で、インスタンスを終了します"
fi
EOS
chmod 0755 /usr/local/sbin/aws-deepcuts-deadline.sh
cat > /etc/systemd/system/aws-deepcuts-deadline.service <<'EOS'
[Unit]
Description=AWS Deep Cuts: terminate this instance 4 hours after the first boot
After=systemd-logind.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/aws-deepcuts-deadline.sh

[Install]
WantedBy=multi-user.target
EOS
systemctl daemon-reload
systemctl enable --now aws-deepcuts-deadline.service

# nitro-cli と、Enclave イメージの作成に使う docker を入れる。
# アロケーターと vsock-proxy のサービスは、README の手順 3 で有効にする（ここでは有効にしない）。
dnf install -y aws-nitro-enclaves-cli aws-nitro-enclaves-cli-devel python3-pip
systemctl enable --now docker
pip3 install cbor2==5.9.0

# Enclave のアプリと補助のプログラムを、受け渡し用のバケットから取得する
mkdir -p /root/santa
aws s3 cp "s3://__BUCKET_NAME__/app/" /root/santa/ --recursive --region "__REGION__"
cat > /root/santa/santa.env <<EOF
REGION="__REGION__"
BUCKET_NAME="__BUCKET_NAME__"
ENCLAVE_CID=16
EOF
