#!/usr/bin/env bash
# api.csv-processor.k8s.local does not resolve outside the VPC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "${ROOT}/settings.env" ]]; then
  # shellcheck source=/dev/null
  source "${ROOT}/settings.env"
fi

CLUSTER_NAME="${CLUSTER_NAME:-csv-processor.k8s.local}"

ELB_DNS="$(aws elb describe-load-balancers \
  --query "LoadBalancerDescriptions[?contains(LoadBalancerName,'csv-processor')].DNSName | [0]" \
  --output text 2>/dev/null || true)"

# kops 1.27+ may create an NLB instead of a Classic ELB; try elbv2 as fallback
if [[ -z "${ELB_DNS}" || "${ELB_DNS}" == "None" ]]; then
  ELB_DNS="$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName,'csv-processor')].DNSName | [0]" \
    --output text 2>/dev/null || true)"
fi

if [[ -z "${ELB_DNS}" || "${ELB_DNS}" == "None" ]]; then
  echo "Could not find kops API ELB (Classic or NLB). Wait for cluster update to finish and retry." >&2
  exit 1
fi

kubectl config set-cluster "${CLUSTER_NAME}" \
  --server="https://${ELB_DNS}" \
  --insecure-skip-tls-verify=true

# Newer kubectl/Helm reject certificate-authority-data + insecure-skip-tls-verify together
kubectl config unset "clusters.${CLUSTER_NAME}.certificate-authority-data" 2>/dev/null || true
kubectl config unset "clusters.${CLUSTER_NAME}.tls-server-name" 2>/dev/null || true
kubectl config use-context "${CLUSTER_NAME}" 2>/dev/null || true

echo "kubeconfig → https://${ELB_DNS}"

if [[ "${VERIFY_NODES:-0}" == "1" ]]; then
  kubectl get nodes
fi
