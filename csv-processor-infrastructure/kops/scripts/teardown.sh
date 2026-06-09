#!/usr/bin/env bash
# Remove kops cluster and leftover IAM / S3 resources from settings.env.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

YES=false
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=true ;;
    -h|--help)
      echo "Usage: $0 [--yes]"
      echo "  Deletes kops cluster, IAM policies, and S3 buckets defined in settings.env."
      exit 0
      ;;
  esac
done

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

export KOPS_STATE_STORE="s3://${KOPS_STATE_BUCKET}"
export NAME="${CLUSTER_NAME}"

APP_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/csv-processor-app-s3"
CA_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/csv-processor-cluster-autoscaler"
NODE_ROLE="nodes.${CLUSTER_NAME}"
OIDC_URL="${IRSA_DISCOVERY_BUCKET}.s3.${AWS_REGION}.amazonaws.com"

if [[ "${YES}" != true ]]; then
  cat <<EOF
This will permanently delete:

  Cluster:     ${CLUSTER_NAME}
  S3 buckets:  ${KOPS_STATE_BUCKET}
                 ${IRSA_DISCOVERY_BUCKET}
                 ${PROCESSED_BUCKET}
  IAM policies: csv-processor-app-s3
                  csv-processor-cluster-autoscaler (if unused elsewhere)

Re-run with --yes to proceed.
EOF
  exit 1
fi

purge_versioned_bucket() {
  local bucket="$1"
  if ! aws s3api head-bucket --bucket "${bucket}" 2>/dev/null; then
    echo "  skip (missing): s3://${bucket}"
    return 0
  fi

  echo "==> Emptying s3://${bucket}"
  aws s3 rm "s3://${bucket}/" --recursive 2>/dev/null || true

  while true; do
    local vcount dcount
    vcount="$(aws s3api list-object-versions --bucket "${bucket}" \
      --query 'length(Versions)' --output text 2>/dev/null || echo 0)"
    dcount="$(aws s3api list-object-versions --bucket "${bucket}" \
      --query 'length(DeleteMarkers)' --output text 2>/dev/null || echo 0)"
    if [[ "${vcount}" == "None" ]]; then vcount=0; fi
    if [[ "${dcount}" == "None" ]]; then dcount=0; fi
    if [[ "${vcount}" -eq 0 && "${dcount}" -eq 0 ]]; then
      break
    fi

    local tmp payload
    tmp="$(mktemp)"
    if [[ "${vcount}" -gt 0 ]]; then
      aws s3api list-object-versions --bucket "${bucket}" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId},Quiet:true}' \
        --output json > "${tmp}"
      payload="$(cat "${tmp}")"
      if [[ "${payload}" != *"VersionId"* ]]; then
        rm -f "${tmp}"
        break
      fi
      aws s3api delete-objects --bucket "${bucket}" --delete "${payload}" >/dev/null
    fi
    if [[ "${dcount}" -gt 0 ]]; then
      aws s3api list-object-versions --bucket "${bucket}" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId},Quiet:true}' \
        --output json > "${tmp}"
      payload="$(cat "${tmp}")"
      if [[ "${payload}" == *"VersionId"* ]]; then
        aws s3api delete-objects --bucket "${bucket}" --delete "${payload}" >/dev/null
      fi
    fi
    rm -f "${tmp}"
    echo "  removed another batch from ${bucket}"
  done

  aws s3 rb "s3://${bucket}"
  echo "  deleted: s3://${bucket}"
}

detach_policy_from_roles() {
  local policy_arn="$1"
  local roles
  roles="$(aws iam list-entities-for-policy --policy-arn "${policy_arn}" \
    --query 'PolicyRoles[].RoleName' --output text 2>/dev/null || true)"
  for role in ${roles}; do
    echo "  detach ${policy_arn} from ${role}"
    aws iam detach-role-policy --role-name "${role}" --policy-arn "${policy_arn}" 2>/dev/null || true
  done
}

delete_iam_policy() {
  local policy_arn="$1"
  local policy_name="${policy_arn##*/}"
  if ! aws iam get-policy --policy-arn "${policy_arn}" >/dev/null 2>&1; then
    echo "  skip (missing): ${policy_name}"
    return 0
  fi
  detach_policy_from_roles "${policy_arn}"
  local versions
  versions="$(aws iam list-policy-versions --policy-arn "${policy_arn}" \
    --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)"
  for v in ${versions}; do
    aws iam delete-policy-version --policy-arn "${policy_arn}" --version-id "${v}" || true
  done
  aws iam delete-policy --policy-arn "${policy_arn}"
  echo "  deleted: ${policy_name}"
}

delete_irsa_role() {
  local role_name="$1"
  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    echo "  skip (missing): ${role_name}"
    return 0
  fi
  local attached
  attached="$(aws iam list-attached-role-policies --role-name "${role_name}" \
    --query 'AttachedPolicies[].PolicyArn' --output text)"
  for arn in ${attached}; do
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${arn}" || true
  done
  aws iam delete-role --role-name "${role_name}"
  echo "  deleted role: ${role_name}"
}

delete_oidc_provider() {
  local arn="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL}"
  if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${arn}" >/dev/null 2>&1; then
    aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "${arn}"
    echo "  deleted OIDC provider: ${OIDC_URL}"
  else
    echo "  skip (missing): OIDC provider ${OIDC_URL}"
  fi
}

remove_kubeconfig_context() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl config delete-context "${CLUSTER_NAME}" 2>/dev/null || true
    kubectl config delete-cluster "${CLUSTER_NAME}" 2>/dev/null || true
    kubectl config delete-user "${CLUSTER_NAME}" 2>/dev/null || true
    echo "==> Removed kubectl context ${CLUSTER_NAME} (if present)"
  fi
}

echo "==> Uninstalling Helm release (best effort)"
if command -v helm >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  if kubectl get ns "${APP_NAMESPACE}" >/dev/null 2>&1; then
    helm uninstall "${APP_RELEASE}" -n "${APP_NAMESPACE}" 2>/dev/null || true
  fi
fi

echo "==> Deleting kops cluster ${NAME}"
if kops get cluster "${NAME}" >/dev/null 2>&1; then
  kops delete cluster --name "${NAME}" --yes
else
  echo "  cluster not in kops state; continuing with IAM/S3 cleanup"
fi

echo "==> Cleaning up IAM (leftovers after kops delete)"
delete_irsa_role "${APP_IRSA_ROLE_NAME}"
delete_oidc_provider
delete_iam_policy "${APP_POLICY_ARN}"
# Detach autoscaler policy from node role if kops left the role behind
aws iam detach-role-policy --role-name "${NODE_ROLE}" --policy-arn "${CA_POLICY_ARN}" 2>/dev/null || true
delete_iam_policy "${CA_POLICY_ARN}"

echo "==> Deleting S3 buckets"
purge_versioned_bucket "${KOPS_STATE_BUCKET}"
purge_versioned_bucket "${IRSA_DISCOVERY_BUCKET}"
purge_versioned_bucket "${PROCESSED_BUCKET}"

remove_kubeconfig_context

cat <<EOF

Teardown complete.

Verify nothing remains:
  aws s3 ls | grep csv-processor
  aws iam list-roles --query "Roles[?contains(RoleName,'csv-processor')].RoleName"
  aws iam list-policies --scope Local --query "Policies[?contains(PolicyName,'csv-processor')].PolicyName"

EOF
