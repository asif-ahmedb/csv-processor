# CSV Processor — Kubernetes assets

Helm chart, Ansible config, and deploy scripts. **Deploy and validate the application** on an existing cluster.

Provision AWS infrastructure first in [csv-processor-infrastructure](https://github.com/asif-ahmedb/csv-processor-infrastructure).

## Layout

- `helm/csv-processor/` — Deployment (nginx + app, `emptyDir` static, optional PVC, Service, HPA)
- `ansible/` — Renders Helm values per environment
- `minikube/` — Local deploy scripts
- `rendered/` — Ansible output (`values-dev.yaml` committed as fallback)
- `DEPLOY_QUICK_REFERENCE.md` — kops + EKS deploy, validate, access

## Quick reference

| Environment | Guide |
|-------------|--------|
| AWS kops / EKS | [DEPLOY_QUICK_REFERENCE.md](DEPLOY_QUICK_REFERENCE.md) |
| Minikube (local) | [minikube/MINIKUBE_QUICK_REFERENCE.md](minikube/MINIKUBE_QUICK_REFERENCE.md) |

## kops (AWS)

**Prerequisite:** kops cluster bootstrapped — [KOPS_QUICK_REFERENCE.md](https://github.com/asif-ahmedb/csv-processor-infrastructure/blob/main/kops/KOPS_QUICK_REFERENCE.md)

```bash
source ../csv-processor-infrastructure/kops/settings.env
helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-kops.yaml \
  --namespace csv-processor --create-namespace \
  --set config.s3Bucket="${PROCESSED_BUCKET}" \
  --set-string aws.accountId="${AWS_ACCOUNT_ID}"
```

## EKS (Terraform)

**Prerequisite:** `terraform apply` in `csv-processor-infrastructure/terraform`

```bash
helm upgrade --install csv-processor ./helm/csv-processor \
  -f ./helm/csv-processor/values-eks.yaml \
  -n csv-processor --create-namespace \
  --set config.s3Bucket=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw s3_bucket_name) \
  --set aws.irsaRoleArn=$(terraform -chdir=../csv-processor-infrastructure/terraform output -raw app_irsa_role_arn)
```

## Minikube (local)

Clone [csv-processor-app](https://github.com/asif-ahmedb/csv-processor-app) next to this repo:

```powershell
.\minikube\deploy.ps1
kubectl port-forward -n csv-processor svc/csv-processor 8080:80
```

Default image: `barbhua786/csv-processor:latest` (kops/EKS) or `csv-processor:local` (Minikube).

## Related repositories

| Repository | Purpose |
|------------|---------|
| [csv-processor-app](https://github.com/asif-ahmedb/csv-processor-app) | Flask application, Docker image, pytest, and GitHub Actions CI that publishes to Docker Hub. |
| [csv-processor-infrastructure](https://github.com/asif-ahmedb/csv-processor-infrastructure) | AWS cluster and storage — kops bootstrap/teardown or Terraform EKS, S3 buckets, and IRSA. |
