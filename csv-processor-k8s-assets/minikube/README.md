# Minikube — deploy application locally

Deploy the CSV processor on a local Minikube cluster. **S3 is disabled** (`config.s3Bucket=""`).

## Layout

```
minikube/
├── deploy.sh                      # Git Bash / Linux
├── deploy.ps1                     # PowerShell
├── MINIKUBE_QUICK_REFERENCE.md    # deploy, validate, access, remove
└── README.md
```

`csv-processor-app` is at [`../../csv-processor-app`](../../csv-processor-app) in the monorepo. Set `CSV_PROCESSOR_APP_PATH` to override.

## Quick start

```powershell
cd csv-processor-k8s-assets\minikube
.\deploy.ps1
kubectl port-forward -n csv-processor svc/csv-processor 8080:80
```

**Full command list:** [MINIKUBE_QUICK_REFERENCE.md](MINIKUBE_QUICK_REFERENCE.md)

## What deploy does

| Step | Detail |
|------|--------|
| Cluster | Starts Minikube if needed; sets context to `minikube` |
| Image | Builds `csv-processor:local` via `minikube image build` |
| Helm | `values-minikube.yaml` + `rendered/values-dev.yaml` → release `csv-processor` |

Pods run **2/2** (app + nginx). Port-forward to **http://localhost:8080**.

## Remove application

```bash
helm uninstall csv-processor -n csv-processor
```

## Windows notes

- Prefer **port-forward** over `minikube service --url` on Docker driver.
- Ansible skipped by default; uses committed `rendered/values-dev.yaml`.
- Use **`minikube image build`** instead of `image load` on Docker Desktop.
