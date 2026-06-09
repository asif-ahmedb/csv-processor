#!/usr/bin/env bash
# End-to-end kops bootstrap with IRSA enabled from cluster creation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS="${ROOT}/manifests"
cd "$ROOT"

if [[ ! -f settings.env ]]; then
  echo "Copy settings.env.example to settings.env and edit values first."
  exit 1
fi
# shellcheck source=/dev/null
source settings.env

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}
require aws
require kops
require kubectl
require envsubst

# Git Bash on Windows: native AWS CLI cannot read file:///tmp/... from mktemp.
aws_file_uri() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    printf 'file://%s' "$(cygpath -m "${path}")"
  else
    printf 'file://%s' "${path}"
  fi
}

bootstrap_tmp_file() {
  local name="$1"
  local dir="${ROOT}/.bootstrap-tmp"
  mkdir -p "${dir}"
  printf '%s/%s' "${dir}" "${name}"
}

export KOPS_STATE_STORE="s3://${KOPS_STATE_BUCKET}"
export NAME="${CLUSTER_NAME}"

CLUSTER_CONFIG="${MANIFESTS}/cluster-config.yaml"

echo "==> Creating S3 buckets"
aws s3api head-bucket --bucket "${KOPS_STATE_BUCKET}" 2>/dev/null || \
  aws s3 mb "s3://${KOPS_STATE_BUCKET}" --region "${AWS_REGION}"

aws s3api head-bucket --bucket "${PROCESSED_BUCKET}" 2>/dev/null || \
  aws s3 mb "s3://${PROCESSED_BUCKET}" --region "${AWS_REGION}"

echo "==> Applying S3 lifecycle policy to ${PROCESSED_BUCKET}"
LIFECYCLE_DOC="$(bootstrap_tmp_file lifecycle.json)"
cat > "${LIFECYCLE_DOC}" <<EOF
{
  "Rules": [
    {
      "ID": "processed-csv-lifecycle",
      "Status": "Enabled",
      "Filter": { "Prefix": "processed/" },
      "Transitions": [
        { "Days": ${GLACIER_TRANSITION_DAYS:-30},    "StorageClass": "GLACIER" },
        { "Days": ${GLACIER_DEEP_ARCHIVE_DAYS:-180}, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "NoncurrentVersionTransitions": [
        { "NoncurrentDays": 90, "StorageClass": "GLACIER" }
      ],
      "NoncurrentVersionExpiration": { "NoncurrentDays": 365 },
      "Expiration": { "Days": 365 }
    }
  ]
}
EOF
aws s3api put-bucket-lifecycle-configuration \
  --bucket "${PROCESSED_BUCKET}" \
  --lifecycle-configuration "$(aws_file_uri "${LIFECYCLE_DOC}")"
rm -f "${LIFECYCLE_DOC}"

echo "==> IRSA discovery bucket ${IRSA_DISCOVERY_BUCKET}"
if ! aws s3api head-bucket --bucket "${IRSA_DISCOVERY_BUCKET}" 2>/dev/null; then
  aws s3 mb "s3://${IRSA_DISCOVERY_BUCKET}" --region "${AWS_REGION}"
fi
OWNERSHIP_DOC="$(bootstrap_tmp_file irsa-ownership.json)"
cat > "${OWNERSHIP_DOC}" <<'EOF'
{
  "Rules": [
    {
      "ObjectOwnership": "BucketOwnerPreferred"
    }
  ]
}
EOF
aws s3api put-bucket-ownership-controls \
  --bucket "${IRSA_DISCOVERY_BUCKET}" \
  --ownership-controls "$(aws_file_uri "${OWNERSHIP_DOC}")"
rm -f "${OWNERSHIP_DOC}"

PUBLIC_ACCESS_DOC="$(bootstrap_tmp_file irsa-public-access.json)"
cat > "${PUBLIC_ACCESS_DOC}" <<'EOF'
{
  "BlockPublicAcls": false,
  "IgnorePublicAcls": false,
  "BlockPublicPolicy": false,
  "RestrictPublicBuckets": false
}
EOF
aws s3api put-public-access-block \
  --bucket "${IRSA_DISCOVERY_BUCKET}" \
  --public-access-block-configuration "$(aws_file_uri "${PUBLIC_ACCESS_DOC}")"
rm -f "${PUBLIC_ACCESS_DOC}"

echo "==> Creating IAM policy csv-processor-app-s3"
POLICY_DOC="$(bootstrap_tmp_file app-s3-policy.json)"
envsubst < iam/app-s3-policy.json.tmpl > "${POLICY_DOC}"
APP_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/csv-processor-app-s3"
if aws iam get-policy --policy-arn "${APP_POLICY_ARN}" >/dev/null 2>&1; then
  VERSIONS="$(aws iam list-policy-versions --policy-arn "${APP_POLICY_ARN}" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  for v in ${VERSIONS}; do
    aws iam delete-policy-version --policy-arn "${APP_POLICY_ARN}" --version-id "${v}" || true
  done
  aws iam create-policy-version \
    --policy-arn "${APP_POLICY_ARN}" \
    --policy-document "$(aws_file_uri "${POLICY_DOC}")" \
    --set-as-default
else
  aws iam create-policy \
    --policy-name csv-processor-app-s3 \
    --policy-document "$(aws_file_uri "${POLICY_DOC}")" \
    --description "CSV processor IRSA: list/upload/delete processed and history objects"
fi
rm -f "${POLICY_DOC}"

echo "==> Rendering cluster spec"
envsubst < "${MANIFESTS}/cluster-config.yaml.tmpl" > "${CLUSTER_CONFIG}"

echo "==> Registering cluster with kops"
IG_FILES=(
  "${MANIFESTS}/instancegroup-masters.yaml"
  "${MANIFESTS}/instancegroup-nodes-ondemand.yaml"
  "${MANIFESTS}/instancegroup-nodes-spot.yaml"
  "${MANIFESTS}/instancegroup-nodes-mixed.yaml"
)
if kops get cluster "${NAME}" >/dev/null 2>&1; then
  kops replace -f "${CLUSTER_CONFIG}"
  for f in "${IG_FILES[@]}"; do kops replace -f "${f}"; done
else
  kops create -f "${CLUSTER_CONFIG}"
  for f in "${IG_FILES[@]}"; do kops create -f "${f}"; done
fi

echo "==> Provisioning AWS + control plane (IRSA included from day one)"
kops update cluster --name "${NAME}" --yes --admin=2400h

# api.csv-processor.k8s.local does not resolve on a laptop; point kubectl at the API ELB first.
echo "==> Configuring local kubeconfig for API ELB access"
for i in $(seq 1 30); do
  if "${ROOT}/scripts/configure-kubeconfig.sh"; then
    break
  fi
  if [[ "${i}" -eq 30 ]]; then
    echo "ERROR: API ELB not found. Wait for kops update to finish, then run:"
    echo "  ${ROOT}/scripts/configure-kubeconfig.sh"
    exit 1
  fi
  echo "  waiting for API ELB... (${i}/30)"
  sleep 20
done

echo "==> Waiting for nodes to become Ready (up to 15m)"
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  ready_count="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)"
  if [[ "${ready_count}" -gt 0 ]]; then
    kubectl get nodes
    break
  fi
  sleep 15
done
if [[ "${ready_count:-0}" -eq 0 ]]; then
  echo "ERROR: no Ready nodes after 15m. Check: kubectl get nodes" >&2
  exit 1
fi

echo "==> Cluster autoscaler IAM (node role)"
NODE_ROLE="nodes.${CLUSTER_NAME}"
CA_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/csv-processor-cluster-autoscaler"
if ! aws iam get-policy --policy-arn "${CA_POLICY_ARN}" >/dev/null 2>&1; then
  aws iam create-policy \
    --policy-name csv-processor-cluster-autoscaler \
    --policy-document "$(aws_file_uri "${ROOT}/iam/cluster-autoscaler-policy.json")"
fi
aws iam attach-role-policy --role-name "${NODE_ROLE}" --policy-arn "${CA_POLICY_ARN}"

kubectl apply -f "${MANIFESTS}/cluster-autoscaler/rbac.yaml"
CA_DEPLOY="$(bootstrap_tmp_file ca-deployment.yaml)"
envsubst < "${MANIFESTS}/cluster-autoscaler/deployment.yaml" > "${CA_DEPLOY}"
kubectl apply -f "${CA_DEPLOY}"
rm -f "${CA_DEPLOY}"

echo "==> Waiting for IRSA role (created by kops during cluster provisioning)"
for i in $(seq 1 12); do
  if aws iam get-role --role-name "${APP_IRSA_ROLE_NAME}" >/dev/null 2>&1; then
    echo "  IRSA role ready: ${APP_IRSA_ROLE_NAME}"
    break
  fi
  if [[ "${i}" -eq 12 ]]; then
    echo "ERROR: IRSA role ${APP_IRSA_ROLE_NAME} not found after 2 minutes."
    echo "  Run: aws iam get-role --role-name '${APP_IRSA_ROLE_NAME}'"
    echo "  If the cluster is up but the role is missing, re-run: kops update cluster --name ${NAME} --yes"
    exit 1
  fi
  echo "  not ready yet, retrying in 10s... (${i}/12)"
  sleep 10
done

cat <<EOF

Bootstrap complete.

Deploy the app (from csv-processor-k8s-assets):
  helm upgrade --install ${APP_RELEASE} ./helm/csv-processor \\
    -f ./helm/csv-processor/values-kops.yaml \\
    --namespace ${APP_NAMESPACE} --create-namespace \\
    --set config.s3Bucket=${PROCESSED_BUCKET} \\
    --set-string aws.accountId=${AWS_ACCOUNT_ID}

Verify IRSA in pod:
  kubectl exec -n ${APP_NAMESPACE} deploy/${APP_RELEASE} -c app -- env | grep AWS_ROLE

EOF
