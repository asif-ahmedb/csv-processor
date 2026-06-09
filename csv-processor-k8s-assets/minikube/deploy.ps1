$ErrorActionPreference = "Stop"
Write-Host "==> CSV Processor - Minikube deploy"
$env:PYTHONUTF8 = "1"
$env:PYTHONIOENCODING = "utf-8"
$K8Root = Resolve-Path (Join-Path $PSScriptRoot "..")
if ($env:CSV_PROCESSOR_APP_PATH) {
  $AppRoot = Resolve-Path $env:CSV_PROCESSOR_APP_PATH
} elseif (Test-Path (Join-Path $K8Root "../csv-processor-app")) {
  $AppRoot = Resolve-Path (Join-Path $K8Root "../csv-processor-app")
} else {
  throw "csv-processor-app not found at $(Join-Path $K8Root '../csv-processor-app'). Set `$env:CSV_PROCESSOR_APP_PATH."
}
Write-Host "    k8s-assets: $K8Root"
Write-Host "    app:        $AppRoot"

function Invoke-External {
  param([string[]]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $null = & $Command[0] @($Command[1..($Command.Length - 1)]) 2>&1
  $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 0 }
  $ErrorActionPreference = $prev
  return $code
}

function Ensure-KubeContext {
  Write-Host "==> Checking Docker..."
  if ((Invoke-External @("docker", "version", "--format", "{{.Server.Version}}")) -ne 0) {
    throw "Docker is not running. Start Docker Desktop, then retry."
  }
  Write-Host "==> Checking Minikube..."
  $hostStatus = & {
    $ErrorActionPreference = "Continue"
    minikube status --format='{{.Host}}' 2>&1 | Out-String
  }
  if ($hostStatus -notmatch 'Running') {
    Write-Host "==> Starting Minikube..."
    if ((Invoke-External @("minikube", "start", "--driver=docker")) -ne 0) {
      throw "minikube start failed. Try: minikube delete; minikube start --driver=docker"
    }
  }
  Invoke-External @("minikube", "update-context") | Out-Null
  Invoke-External @("kubectl", "config", "use-context", "minikube") | Out-Null
  if ((Invoke-External @("kubectl", "get", "nodes")) -ne 0) {
    throw "kubectl cannot reach the cluster. Run: minikube update-context"
  }
  $ctx = kubectl config current-context 2>$null
  Write-Host "    context: $ctx"
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

foreach ($cmd in @("minikube", "kubectl", "helm", "docker")) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    throw "'$cmd' not found in PATH"
  }
}

Ensure-KubeContext

Write-Host "==> Building image csv-processor:local from $AppRoot..."
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

Invoke-External @("minikube", "update-context") | Out-Null

Write-Host "==> Helm install..."
helm upgrade --install csv-processor (Join-Path $K8Root "helm/csv-processor") `
  --kube-context minikube `
  -f (Join-Path $K8Root "helm/csv-processor/values-minikube.yaml") `
  -f $ValuesFile `
  --set image.repository=csv-processor `
  --set image.tag=local `
  --set config.s3Bucket="" `
  --namespace csv-processor `
  --create-namespace
if ($LASTEXITCODE -ne 0) {
  throw "Helm deploy failed. Run: minikube update-context; kubectl config use-context minikube; retry"
}

Write-Host ""
Write-Host "==> Deployed. Verify:"
Write-Host "    kubectl get pods -n csv-processor"
Write-Host ""
Write-Host "==> Access:"
Write-Host "    kubectl port-forward -n csv-processor svc/csv-processor 8080:80"
Write-Host "    http://localhost:8080"
