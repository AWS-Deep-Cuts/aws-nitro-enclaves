# AWS Deep Cuts - Nitro Enclaves ハンズオン: Enclave イメージの元になるコンテナイメージ
# nitro-cli build-enclave が、このコンテナイメージから Enclave イメージ（EIF）を作成します。

# 段階 1: NSM のライブラリ libnsm.so をソースからビルドする（AWS 公式の aws-nitro-enclaves-nsm-api。0.5.2、2026-10-08 のコミット）
FROM public.ecr.aws/amazonlinux/amazonlinux:2023 AS nsm-builder
RUN dnf install -y gcc git tar gzip && dnf clean all
RUN curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.92.0
WORKDIR /build
RUN git clone https://github.com/aws/aws-nitro-enclaves-nsm-api.git \
 && cd aws-nitro-enclaves-nsm-api \
 && git checkout 4bf743e17f9b4174cc16a4ed743086ca6e541405 \
 && /root/.cargo/bin/cargo build --release -p nsm-lib

# 段階 2: Enclave の中で動くアプリ
FROM public.ecr.aws/amazonlinux/amazonlinux:2023
RUN dnf install -y python3 python3-pip openssl iproute && dnf clean all
# boto3 1.42.97 は Python 3.9 に対応する最後の系列の版（PyPI の requires_python は >=3.9。2026-04-27 公開）
RUN pip3 install --no-cache-dir boto3==1.42.97
COPY --from=nsm-builder /build/aws-nitro-enclaves-nsm-api/target/release/libnsm.so /usr/lib64/libnsm.so
ENV KMS_REGION=ap-northeast-1
COPY run.sh app.py /app/
CMD ["/bin/sh", "/app/run.sh"]
