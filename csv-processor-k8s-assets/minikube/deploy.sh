#!/usr/bin/env bash
set -euo pipefail

echo "==> CSV Processor — Minikube deploy"

export PYTHONUTF8=1
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -n "${CSV_PROCESSOR_APP_PATH:-}" ]]; then
  APP_ROOT="$(cd "${CSV_PROCESSOR_APP_PATH}" && pwd)"
elif [[ -d "${K8_ROOT}/../csv-processor-app" ]]; then
  APP_ROOT="$(cd "${K8_ROOT}/../csv-processor-app" && pwd)"
else
  echo "ERROR: csv-processor-app not found at ${K8_ROOT}/../csv-processor-app" >&2
  echo "Set CSV_PROCESSOR_APP_PATH to the app directory." >&2
  exit 1
fi

VALUES_FILE="${K8_ROOT}/rendered/values-dev.yaml"

echo "    k8s-assets: ${K8_ROOT}"
echo "    app:        ${APP_ROOT}"

# Ansible crashes on Windows (os.get_blocking / WinError 1) when launched from Git Bash.
# Minikube deploy uses committed rendered/values-dev.yaml instead. Set USE_ANSIBLE=1 on Linux/WSL.
is_windows() {
  [[ -n "${MSYSTEM:-}" || -n "${WINDIR:-}" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]
}

render_values() {
  if is_windows && [[ "${USE_ANSIBLE:-}" != "1" ]]; then
    echo "==> Skipping Ansible on Windows (using ${VALUES_FILE})"
    if [[ ! -f "${VALUES_FILE}" ]]; then
      echo "ERROR: Missing ${VALUES_FILE}" >&2
      exit 1
    fi
    return 0
  fi

  if command -v ansible-playbook >/dev/null 2>&1 \
    && ansible-playbook "${K8_ROOT}/ansible/playbooks/deploy.yml" \
      -i "${K8_ROOT}/ansible/inventory/dev/hosts.yml" \
      -e deploy_with_helm=false \
      -e environment=dev \
      -e output_dir="${K8_ROOT}/rendered" \
      -e helm_chart_path="${K8_ROOT}/helm/csv-processor" \
      -e image_repository=csv-processor \
      -e image_tag=local; then
    echo "==> Ansible rendered ${VALUES_FILE}"
    return 0
  fi

  echo "==> Ansible unavailable; using ${VALUES_FILE}"
  if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "ERROR: Missing ${VALUES_FILE}" >&2
    exit 1
  fi
}

ensure_kube_context() {
  echo "==> Checking Docker..."
  if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running. Start Docker Desktop, then retry." >&2
    exit 1
  fi

  echo "==> Checking Minikube..."
  if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
    echo "==> Starting Minikube..."
    minikube start --driver=docker
  fi

  minikube update-context >/dev/null 2>&1 || true
  kubectl config use-context minikube >/dev/null 2>&1 || true

  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "ERROR: kubectl cannot reach Minikube." >&2
    echo "Try: minikube start && kubectl config use-context minikube" >&2
    exit 1
  fi

  echo "    context: $(kubectl config current-context)"
}

for cmd in minikube kubectl helm docker; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' not found in PATH" >&2
    exit 1
  fi
done

ensure_kube_context

echo "==> Building image csv-processor:local from ${APP_ROOT}..."
if minikube image build -t csv-processor:local "${APP_ROOT}"; then
  echo "    built inside Minikube"
else
  echo "    minikube image build failed; falling back to docker build + load..."
  docker build -t csv-processor:local "${APP_ROOT}"
  minikube cache delete csv-processor:local 2>/dev/null || true
  minikube image load csv-processor:local --overwrite=true
fi

render_values

echo "==> Helm install..."
helm upgrade --install csv-processor "${K8_ROOT}/helm/csv-processor" \
  -f "${K8_ROOT}/helm/csv-processor/values-minikube.yaml" \
  -f "${VALUES_FILE}" \
  --set image.repository=csv-processor \
  --set image.tag=local \
  --set config.s3Bucket="" \
  --namespace csv-processor \
  --create-namespace

echo ""
echo "==> Deployed. Verify:"
echo "    kubectl get pods -n csv-processor"
echo ""
echo "==> Access:"
echo "    kubectl port-forward -n csv-processor svc/csv-processor 8080:80"
echo "    http://localhost:8080"
