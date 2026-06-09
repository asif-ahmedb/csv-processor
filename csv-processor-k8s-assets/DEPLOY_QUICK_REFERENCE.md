# Kubernetes — Deploy Application (Command Reference)

End-to-end: **Helm install → validate workload → access → upgrade → remove app**.

Assumes a cluster already exists. Provision infrastructure first:

| Environment | Provision in |
|-------------|--------------|
| AWS kops | [csv-processor-infrastructure/kops](https://github.com/asif-ahmedb/csv-processor-infrastructure/tree/main/kops) |
| AWS EKS | [csv-processor-infrastructure/terraform](https://github.com/asif-ahmedb/csv-processor-infrastructure/tree/main/terraform) |
| Local | [minikube/MINIKUBE_QUICK_REFERENCE.md](minikube/MINIKUBE_QUICK_REFERENCE.md) |

Default image: `barbhua786/csv-processor:latest` (Docker Hub).

---

## Phase 0 — Prerequisites

```bash
kubectl version --client
helm version
kubectl config current-context    # must point at your cluster
kubectl get nodes               # all Ready
```

---

## Phase 1 — Deploy on kops (AWS)

**Requires:** kops cluster bootstrapped; `settings.env` sourced.

```bash
cd csv-processor-k8s-assets
source ../csv-processor-infrastructure/kops/settings.env

helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-kops.yaml \
  --namespace csv-processor \
  --create-namespace \
  --set config.s3Bucket="${PROCESSED_BUCKET}" \
  --set-string aws.accountId="${AWS_ACCOUNT_ID}"
```

### Critical flags

| Flag | Why |
|------|-----|
| `--set-string aws.accountId` | Plain `--set` turns 12-digit IDs into scientific notation → **invalid IAM ARN** |
| `config.s3Bucket` | Enables S3 upload + cross-pod history |
| `values-kops.yaml` | LoadBalancer, IRSA, emptyDir, HPA |

---

## Phase 2 — Deploy on EKS (Terraform)

**Requires:** `terraform apply` completed in `csv-processor-infrastructure/terraform`.

```bash
cd csv-processor-k8s-assets

helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-eks.yaml \
  -n csv-processor --create-namespace \
  --set config.s3Bucket=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw s3_bucket_name) \
  --set aws.irsaRoleArn=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw app_irsa_role_arn)
```

---

## Phase 3 — Validate deployment

```bash
# Pods: 2/2 Running (app + nginx)
kubectl get pods -n csv-processor -w

kubectl get svc -n csv-processor
kubectl get hpa -n csv-processor

# IRSA (kops): full role ARN, not scientific notation
kubectl get sa csv-processor -n csv-processor -o yaml | grep role-arn
kubectl exec -n csv-processor deploy/csv-processor -c app -- env | grep AWS_ROLE
```

### Restart after Helm IRSA fix

```bash
kubectl rollout restart deployment/csv-processor -n csv-processor
kubectl rollout status deployment/csv-processor -n csv-processor
```

---

## Phase 4 — Access and test

### kops (LoadBalancer)

```bash
kubectl get svc -n csv-processor csv-processor -w
```

Wait for `EXTERNAL-IP` (AWS hostname), then open `http://<EXTERNAL-IP>`.

### EKS (ClusterIP)

```bash
kubectl port-forward -n csv-processor svc/csv-processor 8080:80
# http://localhost:8080
```

### Upload test file

```
csv-processor-app/sample-data/soh.csv
```

### Confirm S3 objects (kops / EKS with S3 enabled)

```bash
source ../csv-processor-infrastructure/kops/settings.env   # kops
# or use terraform output s3_bucket_name for EKS

aws s3 ls "s3://${PROCESSED_BUCKET}/processed/" --recursive
aws s3 ls "s3://${PROCESSED_BUCKET}/history/" --recursive
```

---

## Phase 5 — Day-2

```bash
# Logs
kubectl logs -n csv-processor deploy/csv-processor -c app -f
kubectl logs -n csv-processor deploy/csv-processor -c nginx -f

# Upgrade image tag
source ../csv-processor-infrastructure/kops/settings.env   # kops only
helm upgrade csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-kops.yaml \
  -n csv-processor \
  --set config.s3Bucket="${PROCESSED_BUCKET}" \
  --set-string aws.accountId="${AWS_ACCOUNT_ID}" \
  --set image.tag=<git-sha-or-tag>
```

---

## Phase 6 — Remove application

```bash
helm uninstall csv-processor -n csv-processor
kubectl delete namespace csv-processor          # optional
```

Cluster and AWS infrastructure remain. Redeploy with Phase 1 or 2.

To delete infrastructure too, use teardown in [csv-processor-infrastructure](https://github.com/asif-ahmedb/csv-processor-infrastructure).

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `AssumeRoleWithWebIdentity` Request ARN is invalid | Redeploy with `--set-string aws.accountId=...`; restart pods |
| S3 `Unable to locate credentials` | Check IRSA env vars in pod; verify `aws.accountId` or `aws.irsaRoleArn` |
| S3 `AccessDenied` on `history/` | Fix IAM policy in infrastructure repo; redeploy infra |
| Pods `ImagePullBackOff` | Confirm `barbhua786/csv-processor:latest` exists on Docker Hub |
| LoadBalancer `<pending>` forever | `kubectl describe svc` — AWS LB provisioning (2–5 min) |
| `kubectl` cannot reach cluster | Re-run infrastructure kubeconfig / `aws eks update-kubeconfig` |

---

## Full copy-paste — kops

```bash
cd csv-processor-k8s-assets
source ../csv-processor-infrastructure/kops/settings.env
helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-kops.yaml \
  -n csv-processor --create-namespace \
  --set config.s3Bucket="${PROCESSED_BUCKET}" \
  --set-string aws.accountId="${AWS_ACCOUNT_ID}"

kubectl get pods -n csv-processor -w
kubectl exec -n csv-processor deploy/csv-processor -c app -- env | grep AWS_ROLE
kubectl get svc -n csv-processor csv-processor -w
# open http://<EXTERNAL-IP>
```

## Full copy-paste — EKS

```bash
cd csv-processor-k8s-assets
helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-eks.yaml \
  -n csv-processor --create-namespace \
  --set config.s3Bucket=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw s3_bucket_name) \
  --set aws.irsaRoleArn=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw app_irsa_role_arn)

kubectl get pods -n csv-processor -w
kubectl port-forward -n csv-processor svc/csv-processor 8080:80
```

---

## Key resource names

| Resource | Value |
|----------|--------|
| Helm release / namespace | `csv-processor` / `csv-processor` |
| kops values file | `helm/csv-processor/values-kops.yaml` |
| EKS values file | `helm/csv-processor/values-eks.yaml` |
| Docker image | `barbhua786/csv-processor:latest` |

---

See also: [README.md](README.md) · [minikube deploy](minikube/MINIKUBE_QUICK_REFERENCE.md) · [csv-processor-infrastructure](https://github.com/asif-ahmedb/csv-processor-infrastructure)
