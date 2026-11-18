#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Nitro Enclaves ハンズオンの事前準備（AWS CloudShell で実行します）
# Enclave の起動・KMS キーの作成・暗号化と復号は、README の手順で 1 コマンドずつ実行します。
# このスクリプトは、その前提になる次のものだけを作成します。
#   1. 受け渡し用の S3 バケット … Enclave のアプリ・暗号化した希望・結果・測定値を受け渡す
#   2. インスタンスロールとインスタンスプロファイル … 親インスタンスに付ける IAM ロール。KMS の権限は付けない
#   3. セキュリティグループ … インバウンドのルールを持たない
#   4. user-data.sh … 親インスタンスのユーザーデータ（user-data.sh.tpl にバケット名とリージョンを埋める）

readonly PROJECT_TAG="aws-deepcuts-nitro-enclaves"
readonly REGION="ap-northeast-1"
readonly ROLE_NAME="aws-deepcuts-enclave-parent-role"
readonly PROFILE_NAME="aws-deepcuts-enclave-parent-role"
readonly INLINE_POLICY_NAME="aws-deepcuts-enclave-bucket"
readonly SG_NAME="aws-deepcuts-enclave-sg"
readonly KEY_ALIAS="alias/aws-deepcuts-santa"
readonly CANDIDATE_TYPES=("c6i.xlarge" "c5.xlarge" "c6a.xlarge")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

fail() {
  echo "❌ Error: $1" >&2
  shift
  for line in "$@"; do echo "   ${line}" >&2; done
  exit 1
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Nitro Enclaves 事前準備"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/6] 前提の確認 ─────────────────────────────────────────
echo "[1/6] 前提を確認..."
if [[ -f "${RESOURCE_FILE}" ]]; then
  fail "${RESOURCE_FILE} が既に存在します。前回の環境が残っています。" \
    "先に bash ./cleanup.sh を実行してください。"
fi
for cmd in jq openssl base64 sed; do
  command -v "${cmd}" >/dev/null || fail "${cmd} コマンドが見つかりません。"
done
for f in user-data.sh.tpl enclave/Dockerfile enclave/run.sh enclave/app.py instance/client.py instance/show-attestation.py; do
  [[ -f "${SCRIPT_DIR}/${f}" ]] || fail "${SCRIPT_DIR}/${f} が見つかりません。リポジトリの hands-on ディレクトリで実行してください。"
done
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null) \
  || fail "AWS の認証情報を取得できません。CloudShell で実行しているか確認してください。"
if [[ "${CALLER_ARN}" == *":root" ]]; then
  fail "ルートユーザーで実行しています。" \
    "IAM ユーザーか IAM ロール（IAM Identity Center のユーザーを含む）でサインインし直してください。"
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws ec2 describe-vpcs --region "${REGION}" --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
if [[ -z "${VPC_ID}" || "${VPC_ID}" == "None" ]]; then
  fail "東京リージョンに既定の VPC がありません。" \
    "VPC コンソールの「アクション」→「デフォルト VPC を作成」で作成してから、やり直してください。"
fi
echo "  呼び出し元: ${CALLER_ARN}"
echo "  アカウント: ${ACCOUNT_ID} / リージョン: ${REGION} / 既定の VPC: ${VPC_ID}"
# 同じ名前のリソースが既にある場合は、タグ Project=aws-deepcuts-nitro-enclaves が付いたものだけを使う。
# タグが無いものは、このハンズオンの外で作成されたリソースのため、使わずに止める（cleanup.sh も削除しない）
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  EXISTING_TAG=$(aws iam get-role --role-name "${ROLE_NAME}" \
    --query "Role.Tags[?Key=='Project'].Value | [0]" --output text)
  [[ "${EXISTING_TAG}" == "${PROJECT_TAG}" ]] || fail \
    "IAM ロール ${ROLE_NAME} が既にあり、タグ Project=${PROJECT_TAG} が付いていません。" \
    "このハンズオンの外で作成されたロールのため、変更しません。ハンズオン用の別のアカウントで実施してください。"
fi
if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  EXISTING_TAG=$(aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" \
    --query "InstanceProfile.Tags[?Key=='Project'].Value | [0]" --output text)
  [[ "${EXISTING_TAG}" == "${PROJECT_TAG}" ]] || fail \
    "インスタンスプロファイル ${PROFILE_NAME} が既にあり、タグ Project=${PROJECT_TAG} が付いていません。" \
    "このハンズオンの外で作成されたインスタンスプロファイルのため、変更しません。ハンズオン用の別のアカウントで実施してください。"
fi
EXISTING_SG=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ -n "${EXISTING_SG}" && "${EXISTING_SG}" != "None" ]]; then
  EXISTING_TAG=$(aws ec2 describe-security-groups --region "${REGION}" --group-ids "${EXISTING_SG}" \
    --query "SecurityGroups[0].Tags[?Key=='Project'].Value | [0]" --output text)
  [[ "${EXISTING_TAG}" == "${PROJECT_TAG}" ]] || fail \
    "セキュリティグループ ${SG_NAME}（${EXISTING_SG}）が既にあり、タグ Project=${PROJECT_TAG} が付いていません。" \
    "このハンズオンの外で作成されたセキュリティグループのため、使いません。ハンズオン用の別のアカウントで実施してください。"
fi
echo ""

# ─── [2/6] インスタンスタイプとサブネットの選択 ─────────────────
# Nitro Enclaves に対応し（NitroEnclavesSupport が supported）、
# パブリック IPv4 アドレスを自動で割り当てる既定のサブネットがある AZ で提供されているタイプを選ぶ
echo "[2/6] Nitro Enclaves に対応したインスタンスタイプとサブネットを選択..."
INSTANCE_TYPE=""
SUBNET_ID=""
AZ=""
for TYPE in "${CANDIDATE_TYPES[@]}"; do
  SUPPORT=$(aws ec2 describe-instance-types --region "${REGION}" --instance-types "${TYPE}" \
    --query 'InstanceTypes[0].NitroEnclavesSupport' --output text 2>/dev/null || true)
  if [[ "${SUPPORT}" != "supported" ]]; then
    echo "  ${TYPE}: Nitro Enclaves に対応していないか、このリージョンで使えません（${SUPPORT:-取得できません}）"
    continue
  fi
  OFFERED_AZS=$(aws ec2 describe-instance-type-offerings --region "${REGION}" \
    --location-type availability-zone --filters "Name=instance-type,Values=${TYPE}" \
    --query 'InstanceTypeOfferings[].Location' --output text | tr '\t' '\n' | sort)
  for CANDIDATE_AZ in ${OFFERED_AZS}; do
    CANDIDATE_SUBNET=$(aws ec2 describe-subnets --region "${REGION}" \
      --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
                "Name=availability-zone,Values=${CANDIDATE_AZ}" "Name=map-public-ip-on-launch,Values=true" \
      --query 'Subnets[0].SubnetId' --output text)
    if [[ -n "${CANDIDATE_SUBNET}" && "${CANDIDATE_SUBNET}" != "None" ]]; then
      INSTANCE_TYPE="${TYPE}"
      SUBNET_ID="${CANDIDATE_SUBNET}"
      AZ="${CANDIDATE_AZ}"
      break 2
    fi
  done
  echo "  ${TYPE}: 提供されている AZ に、パブリック IPv4 を自動で割り当てる既定のサブネットがありません"
done
if [[ -z "${INSTANCE_TYPE}" ]]; then
  fail "使えるインスタンスタイプとサブネットの組が見つかりませんでした。" \
    "候補: ${CANDIDATE_TYPES[*]}" \
    "既定の VPC のサブネットで「パブリック IPv4 アドレスを自動割り当て」が有効かを確認してください。"
fi
echo "  インスタンスタイプ: ${INSTANCE_TYPE} / AZ: ${AZ} / サブネット: ${SUBNET_ID}"

# 作成したリソースは、作成した直後に resource-ids.env へ書き足す。
# 途中で失敗しても、cleanup.sh がこのファイルを読んで、作成済みのリソースを削除できるようにするため。
cat > "${RESOURCE_FILE}" <<EOF
# AWS Deep Cuts Nitro Enclaves - リソース情報（setup.sh が作成。README の手順で行を追記します）
REGION="${REGION}"
ACCOUNT_ID="${ACCOUNT_ID}"
VPC_ID="${VPC_ID}"
SUBNET_ID="${SUBNET_ID}"
AZ="${AZ}"
INSTANCE_TYPE="${INSTANCE_TYPE}"
ROLE_NAME="${ROLE_NAME}"
PROFILE_NAME="${PROFILE_NAME}"
KEY_ALIAS="${KEY_ALIAS}"
EOF
echo "  リソース情報の保存先: ${RESOURCE_FILE}"
echo ""

# ─── [3/6] 受け渡し用のバケット ───────────────────────────────
echo "[3/6] 受け渡し用の S3 バケットを作成し、Enclave のアプリをアップロード..."
BUCKET_NAME="aws-deepcuts-enclave-${ACCOUNT_ID}-$(date +%Y%m%d-%H%M%S)"
aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
echo "BUCKET_NAME=\"${BUCKET_NAME}\"" >> "${RESOURCE_FILE}"
aws s3api put-public-access-block --bucket "${BUCKET_NAME}" --region "${REGION}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
for f in Dockerfile run.sh app.py; do
  aws s3 cp "${SCRIPT_DIR}/enclave/${f}" "s3://${BUCKET_NAME}/app/enclave/${f}" --region "${REGION}" --only-show-errors
done
for f in client.py show-attestation.py; do
  aws s3 cp "${SCRIPT_DIR}/instance/${f}" "s3://${BUCKET_NAME}/app/${f}" --region "${REGION}" --only-show-errors
done
echo "  作成: s3://${BUCKET_NAME}"
echo "  アップロード: app/enclave/Dockerfile・run.sh・app.py、app/client.py・show-attestation.py"
echo ""

# ─── [4/6] インスタンスロールとインスタンスプロファイル ─────────
echo "[4/6] 親インスタンスに付けるインスタンスロールを作成..."
TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  # [1/6] で、タグ Project が付いていることを確かめてある
  echo "  既に存在するため、そのまま使います: ${ROLE_NAME}"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "AWS Deep Cuts Nitro Enclaves hands-on: parent instance role (no KMS permissions)" \
    --tags "Key=Project,Value=${PROJECT_TAG}" \
    --assume-role-policy-document "${TRUST_POLICY}" >/dev/null
  echo "  作成: ${ROLE_NAME}"
fi
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query Role.Arn --output text)
echo "ROLE_ARN=\"${ROLE_ARN}\"" >> "${RESOURCE_FILE}"
# Session Manager で親インスタンスに接続するための AWS 管理ポリシー
aws iam attach-role-policy --role-name "${ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
# 受け渡し用のバケットの読み書きだけを許可する。KMS の権限は付けない（復号の許可は、手順 5 のキーポリシーで与える）
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name "${INLINE_POLICY_NAME}" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"ReadWriteHandoffObjects\",
        \"Effect\": \"Allow\",
        \"Action\": [\"s3:GetObject\", \"s3:PutObject\"],
        \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}/*\"
      },
      {
        \"Sid\": \"ListHandoffBucket\",
        \"Effect\": \"Allow\",
        \"Action\": \"s3:ListBucket\",
        \"Resource\": \"arn:aws:s3:::${BUCKET_NAME}\"
      }
    ]
  }"
if aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  echo "  既に存在するため、そのまま使います: インスタンスプロファイル ${PROFILE_NAME}"
else
  aws iam create-instance-profile --instance-profile-name "${PROFILE_NAME}" \
    --tags "Key=Project,Value=${PROJECT_TAG}" >/dev/null
  echo "  作成: インスタンスプロファイル ${PROFILE_NAME}"
fi
ROLES_IN_PROFILE=$(aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" \
  --query 'InstanceProfile.Roles[].RoleName' --output text)
if [[ " ${ROLES_IN_PROFILE} " != *" ${ROLE_NAME} "* ]]; then
  aws iam add-role-to-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}"
fi
echo "  インスタンスロール: ${ROLE_ARN}"
echo "  許可: AmazonSSMManagedInstanceCore と、受け渡し用のバケットの読み書き（KMS の権限は無し）"
echo ""

# ─── [5/6] セキュリティグループ ──────────────────────────────
echo "[5/6] セキュリティグループを作成..."
SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=${SG_NAME}" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [[ -n "${SG_ID}" && "${SG_ID}" != "None" ]]; then
  echo "  既に存在するため、そのまま使います: ${SG_NAME}（${SG_ID}）"
else
  # インバウンドのルールは追加しない。Session Manager の接続と KMS への通信は、どちらも親インスタンスから外へ向かう
  SG_ID=$(aws ec2 create-security-group --region "${REGION}" --vpc-id "${VPC_ID}" \
    --group-name "${SG_NAME}" --description "AWS Deep Cuts Nitro Enclaves hands-on (no inbound rules)" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${SG_NAME}},{Key=Project,Value=${PROJECT_TAG}}]" \
    --query GroupId --output text)
  echo "  作成: ${SG_NAME}（${SG_ID}）"
fi
echo "SG_ID=\"${SG_ID}\"" >> "${RESOURCE_FILE}"
echo ""

# ─── [6/6] ユーザーデータと待機 ──────────────────────────────
echo "[6/6] 親インスタンスのユーザーデータ user-data.sh を作成..."
sed -e "s/__BUCKET_NAME__/${BUCKET_NAME}/g" -e "s/__REGION__/${REGION}/g" \
  "${SCRIPT_DIR}/user-data.sh.tpl" > "${SCRIPT_DIR}/user-data.sh"
echo "  作成: ${SCRIPT_DIR}/user-data.sh"
# 作成した直後のインスタンスプロファイルは、run-instances で使えるようになるまで少し時間がかかる
echo "  インスタンスプロファイルの反映を待機（10 秒）..."
sleep 10
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ セットアップが完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "作成したリソースは、マネジメントコンソールの次の画面で確認できます。"
echo "  IAM ロール:   https://us-east-1.console.aws.amazon.com/iam/home#/roles/details/${ROLE_NAME}"
echo "  S3 バケット:  https://${REGION}.console.aws.amazon.com/s3/buckets/${BUCKET_NAME}?region=${REGION}"
echo ""
echo "次のステップ: README の手順 1 に戻り、作成したリソースを確認してから、次のコマンドで変数を読み込んでください。"
echo "  source ./resource-ids.env"
