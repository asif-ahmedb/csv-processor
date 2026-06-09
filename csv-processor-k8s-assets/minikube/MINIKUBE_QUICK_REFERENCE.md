# Minikube — Deploy Application (Command Reference)

End-to-end: **deploy app → validate → access → remove app**.

Local cluster must be running (`minikube start` — `deploy.sh` starts it if needed). S3 is disabled (`config.s3Bucket=""`).

| Module | Role |
|--------|------|
| `csv-processor-k8s-assets/minikube` | Deploy scripts (`deploy.sh` / `deploy.ps1`) |
| `csv-processor-k8s-assets` | Helm chart + `values-minikube.yaml` |
| `csv-processor-app` | Source built as `csv-processor:local` |

---

## Phase 0 — Prerequisites

```bash
minikube version
kubectl version --client
helm version
docker version          # typical Windows driver
```

`csv-processor-app` is at `../../csv-processor-app` in the monorepo. Set `CSV_PROCESSOR_APP_PATH` to override.

```bash
minikube start          # optional — deploy.sh starts if needed
kubectl config use-context minikube
kubectl get nodes       # Ready
```

---

## Phase 1 — Deploy

**Git Bash / Linux:**

```bash
cd csv-processor-k8s-assets/minikube
chmod +x deploy.sh
./deploy.sh
```

**PowerShell:**

```powershell
cd csv-processor-k8s-assets\minikube
.\deploy.ps1
```

### What deploy creates

| Resource | Value |
|----------|--------|
| Local image | `csv-processor:local` |
| Helm release | `csv-processor` in namespace `csv-processor` |
| Service | NodePort `30080` |
| S3 | Disabled |

### Manual Helm (without script)

```bash
cd csv-processor-k8s-assets
minikube image build -t csv-processor:local ../csv-processor-app

helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-minikube.yaml \
  -f ./rendered/values-dev.yaml \
  --set image.repository=csv-processor \
  --set image.tag=local \
  --set config.s3Bucket="" \
  --namespace csv-processor \
  --create-namespace
```

---

## Phase 2 — Validate deployment

```bash
kubectl get pods -n csv-processor -w    # 2/2 Running (app + nginx)
kubectl get svc -n csv-processor
kubectl get pvc -n csv-processor
kubectl get hpa -n csv-processor
```

```bash
kubectl rollout restart deployment/csv-processor -n csv-processor   # after image rebuild
```

---

## Phase 3 — Access and test

```bash
kubectl port-forward -n csv-processor svc/csv-processor 8080:80
# http://localhost:8080
```

Alternatives: `minikube service csv-processor -n csv-processor --url` or NodePort `http://<minikube-ip>:30080`.

Upload: `../../csv-processor-app/sample-data/soh.csv` (relative to this file), or `csv-processor-app/sample-data/soh.csv` from the monorepo root.

---

## Phase 4 — Day-2

```bash
kubectl logs -n csv-processor deploy/csv-processor -c app -f
cd csv-processor-k8s-assets/minikube && ./deploy.sh    # rebuild + redeploy
USE_ANSIBLE=1 ./deploy.sh                                 # Linux/WSL: re-render values
```

---

## Phase 5 — Remove application

```bash
helm uninstall csv-processor -n csv-processor
kubectl delete namespace csv-processor    # optional
```

To stop/delete the Minikube cluster itself: `minikube stop` or `minikube delete` (local environment, not part of this chart).

---

## Full copy-paste flow

```bash
minikube start
kubectl config use-context minikube

cd csv-processor-k8s-assets/minikube
chmod +x deploy.sh && ./deploy.sh

kubectl get pods -n csv-processor -w
kubectl port-forward -n csv-processor svc/csv-processor 8080:80

helm uninstall csv-processor -n csv-processor
```

---

See also: [README.md](README.md) · [DEPLOY_QUICK_REFERENCE.md](../DEPLOY_QUICK_REFERENCE.md) · [csv-processor-app](../../csv-processor-app)
