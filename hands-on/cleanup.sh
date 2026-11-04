#!/bin/bash
set -euo pipefail
export AWS_PAGER=""

# AWS Deep Cuts - Nitro Enclaves ハンズオンの後片付け（AWS CloudShell で実行します）
# 手順の中で作成した親インスタンスと KMS キー、setup.sh が作成したリソースを、すべて削除します。
# KMS キー・IAM ロール・インスタンスプロファイル・セキュリティグループは、タグ Project=aws-deepcuts-nitro-enclaves が
# 付いたものだけを削除します。同じ名前でもタグの無いものは、このハンズオンの外で作成されたものとして残します。
# KMS キーはすぐには削除できないため、7 日後の削除を予約します。

readonly PROJECT_TAG="aws-deepcuts-nitro-enclaves"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly RESOURCE_FILE="${SCRIPT_DIR}/resource-ids.env"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  AWS Deep Cuts - Nitro Enclaves 後片付け"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ─── [1/7] resource-ids.env を読む ────────────────────────────
echo "[1/7] リソース情報を読み込み..."
if [[ ! -f "${RESOURCE_FILE}" ]]; then
  echo "❌ Error: ${RESOURCE_FILE} が見つかりません。" >&2
  echo "   setup.sh を実行したディレクトリ（hands-on）で実行してください。" >&2
  exit 1
fi
# shellcheck source=/dev/null
source "${RESOURCE_FILE}"
REGION="${REGION:-ap-northeast-1}"
ROLE_NAME="${ROLE_NAME:-aws-deepcuts-enclave-parent-role}"
PROFILE_NAME="${PROFILE_NAME:-aws-deepcuts-enclave-parent-role}"
KEY_ALIAS="${KEY_ALIAS:-alias/aws-deepcuts-santa}"
BUCKET_NAME="${BUCKET_NAME:-}"
SG_ID="${SG_ID:-}"
VPC_ID="${VPC_ID:-}"
# 手順をやり直して同じ変数を 2 回以上追記した場合に備え、すべての行の値を集める
env_values() {
  grep -E "^$1=" "${RESOURCE_FILE}" | sed -E "s/^$1=\"?([^\"]*)\"?$/\1/" | sort -u || true
}
# 削除の対象は、タグ Project=aws-deepcuts-nitro-enclaves が付いたリソースだけにする。
# 同じ名前でも、タグの無いリソースは、このハンズオンの外で作成されたものとして扱い、変更も削除もしない
key_is_ours() {
  [[ "$(aws kms list-resource-tags --region "${REGION}" --key-id "$1" \
        --query "Tags[?TagKey=='Project'].TagValue | [0]" --output text 2>/dev/null || true)" == "${PROJECT_TAG}" ]]
}
role_is_ours() {
  [[ "$(aws iam get-role --role-name "${ROLE_NAME}" \
        --query "Role.Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)" == "${PROJECT_TAG}" ]]
}
profile_is_ours() {
  [[ "$(aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" \
        --query "InstanceProfile.Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)" == "${PROJECT_TAG}" ]]
}
sg_is_ours() {
  [[ "$(aws ec2 describe-security-groups --region "${REGION}" --group-ids "$1" \
        --query "SecurityGroups[0].Tags[?Key=='Project'].Value | [0]" --output text 2>/dev/null || true)" == "${PROJECT_TAG}" ]]
}
echo "  リージョン: ${REGION}"
echo ""

# ─── [2/7] 親インスタンスを終了する ───────────────────────────
echo "[2/7] 親インスタンスを終了..."
INSTANCE_IDS=$(
  {
    aws ec2 describe-instances --region "${REGION}" \
      --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
                "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | tr '\t' '\n'
    env_values INSTANCE_ID
  } | grep -E '^i-' | sort -u || true
)
if [[ -z "${INSTANCE_IDS}" ]]; then
  echo "  対象なし"
else
  for ID in ${INSTANCE_IDS}; do
    if aws ec2 terminate-instances --region "${REGION}" --instance-ids "${ID}" >/dev/null 2>&1; then
      echo "  終了を依頼: ${ID}"
    else
      echo "  既に削除されているか、見つかりません: ${ID}"
    fi
  done
  echo "  終了を待機..."
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --region "${REGION}" --instance-ids ${INSTANCE_IDS} 2>/dev/null \
    || echo "  ⚠️  終了の完了を確認できませんでした。最後の確認で状態を表示します。"
fi
echo ""

# ─── [3/7] KMS キーの削除を予約する ───────────────────────────
echo "[3/7] KMS キーのエイリアスを削除し、キーの削除を予約..."
# 候補は次の 3 つの和集合。作成直後のキーがタグの検索に現れない場合も、(2)(3) で見つける
#   (1) タグ Project=aws-deepcuts-nitro-enclaves の付いたキー
#   (2) resource-ids.env の KEY_ID（複数行あれば、すべて）
#   (3) エイリアス alias/aws-deepcuts-santa が指すキー
# 候補のうち、キー自身にタグ Project=aws-deepcuts-nitro-enclaves が付いたものだけを、削除の予約の対象にする
ALIAS_TARGET=$(aws kms describe-key --region "${REGION}" --key-id "${KEY_ALIAS}" \
  --query KeyMetadata.KeyId --output text 2>/dev/null || true)
KEY_CANDIDATES=$(
  {
    aws resourcegroupstaggingapi get-resources --region "${REGION}" \
      --resource-type-filters kms:key --tag-filters "Key=Project,Values=${PROJECT_TAG}" \
      --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n'
    env_values KEY_ID
    echo "${ALIAS_TARGET}"
  } | grep -v -E '^(None)?$' | sort -u || true
)
if [[ -n "${ALIAS_TARGET}" && "${ALIAS_TARGET}" != "None" ]]; then
  if ! key_is_ours "${ALIAS_TARGET}"; then
    echo "  ⚠️  エイリアス ${KEY_ALIAS} は、タグ Project=${PROJECT_TAG} の無いキー ${ALIAS_TARGET} を指しています。"
    echo "     このハンズオンの外で作成されたキーのため、エイリアスもキーも削除しません。"
  elif aws kms delete-alias --region "${REGION}" --alias-name "${KEY_ALIAS}" 2>/dev/null; then
    echo "  削除: エイリアス ${KEY_ALIAS}"
  fi
fi
KEY_IDS=""
SKIPPED_KEYS=""
for CANDIDATE in ${KEY_CANDIDATES}; do
  KEY_INFO=$(aws kms describe-key --region "${REGION}" --key-id "${CANDIDATE}" \
    --query 'KeyMetadata.[KeyId,KeyState]' --output text 2>/dev/null || true)
  if [[ -z "${KEY_INFO}" ]]; then
    echo "  見つかりません: ${CANDIDATE}"
    continue
  fi
  read -r KID KSTATE <<< "${KEY_INFO}"
  [[ " ${KEY_IDS} ${SKIPPED_KEYS} " == *" ${KID} "* ]] && continue
  if ! key_is_ours "${KID}"; then
    SKIPPED_KEYS="${SKIPPED_KEYS} ${KID}"
    echo "  ⚠️  タグ Project=${PROJECT_TAG} が無いため、削除の対象から外しました: ${KID}"
    continue
  fi
  KEY_IDS="${KEY_IDS} ${KID}"
  if [[ "${KSTATE}" == "PendingDeletion" ]]; then
    echo "  既に削除を予約済み: ${KID}"
  elif aws kms schedule-key-deletion --region "${REGION}" --key-id "${KID}" \
         --pending-window-in-days 7 >/dev/null 2>&1; then
    echo "  削除を予約（7 日後）: ${KID}"
  else
    echo "  ⚠️  削除を予約できませんでした: ${KID}（状態 ${KSTATE}）"
  fi
done
[[ -z "${KEY_IDS}" ]] && echo "  対象なし"
echo ""

# ─── [4/7] セキュリティグループを削除する ──────────────────────
echo "[4/7] セキュリティグループを削除..."
if [[ -z "${SG_ID}" && -n "${VPC_ID}" ]]; then
  SG_ID=$(aws ec2 describe-security-groups --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=aws-deepcuts-enclave-sg" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
  [[ "${SG_ID}" == "None" ]] && SG_ID=""
fi
if [[ -n "${SG_ID}" ]] && aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG_ID}" >/dev/null 2>&1 \
   && ! sg_is_ours "${SG_ID}"; then
  echo "  ⚠️  タグ Project=${PROJECT_TAG} が無いため、削除しません: ${SG_ID}"
  SG_ID=""
elif [[ -n "${SG_ID}" ]]; then
  DELETED=""
  # インスタンスの終了直後は、ネットワークインターフェースの依存関係で失敗することがあるため、10 秒おきに最大 2 分試す
  for _ in $(seq 1 12); do
    if aws ec2 delete-security-group --region "${REGION}" --group-id "${SG_ID}" 2>/dev/null; then
      DELETED="yes"
      break
    fi
    if ! aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG_ID}" >/dev/null 2>&1; then
      DELETED="yes"
      break
    fi
    sleep 10
  done
  if [[ -n "${DELETED}" ]]; then
    echo "  削除: ${SG_ID}"
  else
    echo "  ⚠️  削除できませんでした: ${SG_ID}"
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [5/7] インスタンスロールとインスタンスプロファイルを削除する ─
echo "[5/7] インスタンスロールとインスタンスプロファイルを削除..."
if profile_is_ours; then
  aws iam remove-role-from-instance-profile --instance-profile-name "${PROFILE_NAME}" --role-name "${ROLE_NAME}" 2>/dev/null || true
  if aws iam delete-instance-profile --instance-profile-name "${PROFILE_NAME}" 2>/dev/null; then
    echo "  削除: インスタンスプロファイル ${PROFILE_NAME}"
  fi
elif aws iam get-instance-profile --instance-profile-name "${PROFILE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  タグ Project=${PROJECT_TAG} が無いため、削除しません: インスタンスプロファイル ${PROFILE_NAME}"
fi
if role_is_ours; then
  aws iam detach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" 2>/dev/null || true
  aws iam delete-role-policy --role-name "${ROLE_NAME}" --policy-name "aws-deepcuts-enclave-bucket" 2>/dev/null || true
  if aws iam delete-role --role-name "${ROLE_NAME}" 2>/dev/null; then
    echo "  削除: インスタンスロール ${ROLE_NAME}"
  fi
elif aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  echo "  ⚠️  タグ Project=${PROJECT_TAG} が無いため、削除しません: インスタンスロール ${ROLE_NAME}"
fi
echo ""

# ─── [6/7] 受け渡し用のバケットを削除する ──────────────────────
echo "[6/7] 受け渡し用のバケットを削除..."
if [[ -n "${BUCKET_NAME}" ]]; then
  aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "${REGION}" --only-show-errors 2>/dev/null || true
  if aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
    echo "  削除: s3://${BUCKET_NAME}"
  fi
else
  echo "  対象なし"
fi
echo ""

# ─── [7/7] ローカルのファイルを削除する ───────────────────────
echo "[7/7] CloudShell のローカルのファイルを削除..."
# participants/ には、参加者の秘密鍵が含まれる
rm -rf "${SCRIPT_DIR:?}/participants" "${SCRIPT_DIR:?}/outbox" "${SCRIPT_DIR:?}/results"
rm -f "${SCRIPT_DIR:?}/key-policy.json" "${SCRIPT_DIR:?}/user-data.sh"
echo "  削除: participants/、outbox/、results/、key-policy.json、user-data.sh"
echo ""

# ─── 残りの確認 ─────────────────────────────────────────────
echo "残っているリソースを確認..."
LEFT=0
REMAINING=$(aws ec2 describe-instances --region "${REGION}" \
  --filters "Name=tag:Project,Values=${PROJECT_TAG}" \
  --query "Reservations[].Instances[?State.Name!='terminated'].[InstanceId,State.Name]" --output text 2>/dev/null || true)
if [[ -n "${REMAINING}" ]]; then
  echo "  ⚠️  終了していない親インスタンスがあります: ${REMAINING//$'\n'/, }"; LEFT=1
fi
TAGGED_KEYS=$(aws resourcegroupstaggingapi get-resources --region "${REGION}" \
  --resource-type-filters kms:key --tag-filters "Key=Project,Values=${PROJECT_TAG}" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' || true)
for KID in ${KEY_IDS} ${TAGGED_KEYS}; do
  STATE=$(aws kms describe-key --region "${REGION}" --key-id "${KID}" \
    --query KeyMetadata.KeyState --output text 2>/dev/null || echo "不明")
  if [[ "${STATE}" != "PendingDeletion" ]]; then
    echo "  ⚠️  削除が予約されていない KMS キーがあります: ${KID}（状態 ${STATE}）"; LEFT=1
  fi
done
if role_is_ours; then
  echo "  ⚠️  インスタンスロールが残っています: ${ROLE_NAME}"; LEFT=1
fi
if profile_is_ours; then
  echo "  ⚠️  インスタンスプロファイルが残っています: ${PROFILE_NAME}"; LEFT=1
fi
if [[ -n "${SG_ID}" ]] && aws ec2 describe-security-groups --region "${REGION}" --group-ids "${SG_ID}" >/dev/null 2>&1; then
  echo "  ⚠️  セキュリティグループが残っています: ${SG_ID}"; LEFT=1
fi
if [[ -n "${BUCKET_NAME}" ]] && aws s3api head-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" 2>/dev/null; then
  echo "  ⚠️  受け渡し用のバケットが残っています: ${BUCKET_NAME}"; LEFT=1
fi
if [[ "${LEFT}" == "1" ]]; then
  echo ""
  echo "❌ 削除できなかったリソースがあります。数分待ってから、もう一度 bash ./cleanup.sh を実行してください。" >&2
  exit 1
fi
echo "  なし（KMS キーは、7 日後の削除を予約した状態です）"
rm -f "${RESOURCE_FILE}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ すべてのリソースの削除が完了しました！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
