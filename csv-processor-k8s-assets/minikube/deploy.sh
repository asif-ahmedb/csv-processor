#!/usr/bin/env bash
set -euo pipefail
export PYTHONUTF8=1
export LC_ALL="${LC_ALL:-C.UTF-8}"
export LANG="${LANG:-C.UTF-8}"
K8_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_ROOT="${CSV_PROCESSOR_APP_PATH:-$(cd "$K8_ROOT/../csv-processor-app" && pwd)}"
VALUES_FILE="${K8_ROOT}/rendered/values-dev.yaml"

# Ansible crashes on Windows (os.get_blocking / WinError 1) when launched from Git Bash.
# Minikube deploy uses committed rendered/values-dev.yaml instead. Set USE_ANSIBLE=1 on Linux/WSL.
is_windows() {
  [[ -n "${MSYSTEM:-}" || -n "${WINDIR:-}" || "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]
}

render_values() {
  if is_windows && [[ "${USE_ANSIBLE:-}" != "1" ]]; then
    echo "Skipping Ansible on Windows (set USE_ANSIBLE=1 on Linux/WSL to render values)."
    if [[ ! -f "${VALUES_FILE}" ]]; then
      echo "Missing ${VALUES_FILE}." >&2
      exit 1
    fi
    echo "Using ${VALUES_FILE}"
    return 0
  fi

  local ansible_cmd=""
  if command -v ansible-playbook >/dev/null 2>&1; then
    ansible_cmd="ansible-playbook"
  fi

  if [[ -n "${ansible_cmd}" ]] && ansible-playbook "${K8_ROOT}/ansible/playbooks/deploy.yml" \
    -i "${K8_ROOT}/ansible/inventory/dev/hosts.yml" \
    -e deploy_with_helm=false \
    -e environment=dev \
    -e output_dir="${K8_ROOT}/rendered" \
    -e helm_chart_path="${K8_ROOT}/helm/csv-processor" \
    -e image_repository=csv-processor \
    -e image_tag=local; then
    echo "Ansible rendered ${VALUES_FILE}"
    return 0
  fi

  echo "Ansible unavailable; using committed ${VALUES_FILE}."
  if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "Missing ${VALUES_FILE}." >&2
    exit 1
  fi
}

ensure_kube_context() {
  if ! minikube status >/dev/null 2>&1; then
    echo "Starting minikube..."
    minikube start
  fi
  minikube update-context >/dev/null 2>&1 || true
  if command -v kubectl >/dev/null 2>&1; then
    kubectl config use-context minikube >/dev/null 2>&1 || true
    if ! kubectl cluster-info >/dev/null 2>&1; then
      echo "kubectl cannot reach the cluster. Try: minikube start && kubectl config use-context minikube" >&2
      exit 1
    fi
  fi
  echo "Kubernetes context: $(kubectl config current-context 2>/dev/null || echo minikube)"
}

ensure_kube_context

echo "Building local image from ${APP_ROOT}..."
# Build inside minikube's runtime — avoids "blob not found" errors from
# minikube image load on Windows + Docker Desktop.
if minikube image build -t csv-processor:local "${APP_ROOT}"; then
  echo "Image built inside minikube."
else
  echo "minikube image build failed; falling back to docker build + image load..."
  docker build -t csv-processor:local "${APP_ROOT}"
  minikube cache delete csv-processor:local 2>/dev/null || true
  minikube image load csv-processor:local --overwrite=true
fi

render_values

helm upgrade --install csv-processor "${K8_ROOT}/helm/csv-processor" \
  -f "${K8_ROOT}/helm/csv-processor/values-minikube.yaml" \
  -f "${VALUES_FILE}" \
  --set image.repository=csv-processor \
  --set image.tag=local \
  --set config.s3Bucket="" \
  --namespace csv-processor \
  --create-namespace

echo ""
echo "Deployed. Access the app:"
echo "  kubectl port-forward -n csv-processor svc/csv-processor 8080:80"
echo "  Then open http://localhost:8080"
echo "  (Or: minikube service csv-processor -n csv-processor --url)"
