$ErrorActionPreference = "Stop"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$K8Root = Resolve-Path (Join-Path $PSScriptRoot "..")
$AppRoot = if ($env:CSV_PROCESSOR_APP_PATH) {
  Resolve-Path $env:CSV_PROCESSOR_APP_PATH
} else {
  Resolve-Path (Join-Path $K8Root "../csv-processor-app")
}

function Ensure-KubeContext {
  minikube status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Starting minikube..."
    minikube start
  }
  minikube update-context 2>$null | Out-Null
  kubectl config use-context minikube 2>$null | Out-Null
  kubectl cluster-info 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw "kubectl cannot reach the cluster. Run: minikube start; kubectl config use-context minikube"
  }
  $ctx = kubectl config current-context 2>$null
  Write-Host "Kubernetes context: $ctx"
}

function Render-Values {
  param([string]$ValuesFile, [string]$RenderedDir)
  if ($env:USE_ANSIBLE -ne "1") {
    Write-Host "Skipping Ansible on Windows (set `$env:USE_ANSIBLE=1 on Linux/WSL to render values)."
    if (-not (Test-Path $ValuesFile)) { throw "Missing $ValuesFile." }
    Write-Host "Using $ValuesFile"
    return
  }
  $ansibleArgs = @(
    (Join-Path $K8Root "ansible/playbooks/deploy.yml"),
    "-i", (Join-Path $K8Root "ansible/inventory/dev/hosts.yml"),
    "-e", "deploy_with_helm=false",
    "-e", "environment=dev",
    "-e", "image_repository=csv-processor",
    "-e", "image_tag=local",
    "-e", "output_dir=$RenderedDir"
  )
  if (Get-Command ansible-playbook -ErrorAction SilentlyContinue) {
    ansible-playbook @ansibleArgs
    if ($LASTEXITCODE -eq 0) {
      Write-Host "Ansible rendered $ValuesFile"
      return
    }
  }
  Write-Host "Ansible unavailable; using committed $ValuesFile."
  if (-not (Test-Path $ValuesFile)) { throw "Missing $ValuesFile." }
}

Ensure-KubeContext

Write-Host "Building local image from $AppRoot..."
$built = $false
minikube image build -t csv-processor:local $AppRoot
if ($LASTEXITCODE -eq 0) {
  Write-Host "Image built inside minikube."
  $built = $true
}
if (-not $built) {
  Write-Host "minikube image build failed; falling back to docker build + image load..."
  docker build -t csv-processor:local $AppRoot
  minikube cache delete csv-processor:local 2>$null
  minikube image load csv-processor:local --overwrite=true
}

$Rendered = Join-Path $K8Root "rendered"
$ValuesFile = Join-Path $Rendered "values-dev.yaml"
New-Item -ItemType Directory -Force -Path $Rendered | Out-Null

Render-Values -ValuesFile $ValuesFile -RenderedDir $Rendered

helm upgrade --install csv-processor (Join-Path $K8Root "helm/csv-processor") `
  -f (Join-Path $K8Root "helm/csv-processor/values-minikube.yaml") `
  -f $ValuesFile `
  --set image.repository=csv-processor `
  --set image.tag=local `
  --set config.s3Bucket="" `
  --namespace csv-processor `
  --create-namespace

Write-Host ""
Write-Host "Deployed. Access the app:"
Write-Host "  kubectl port-forward -n csv-processor svc/csv-processor 8080:80"
Write-Host "  Then open http://localhost:8080"
