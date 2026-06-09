# CSV Processor — Kubernetes assets

Helm chart, Ansible config, and deploy scripts. **Deploy and validate the application** on an existing cluster.

Provision AWS infrastructure first in [`../csv-processor-infrastructure`](../csv-processor-infrastructure).

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

## Deploy

Full step-by-step commands for each environment are in the reference docs below — no need to repeat them here.

| Environment | Provision first | Then deploy using |
|-------------|----------------|-------------------|
| AWS kops | [../csv-processor-infrastructure/kops](../csv-processor-infrastructure/kops) | [DEPLOY_QUICK_REFERENCE.md](DEPLOY_QUICK_REFERENCE.md) Phase 1 |
| AWS EKS | [../csv-processor-infrastructure/terraform](../csv-processor-infrastructure/terraform) | [DEPLOY_QUICK_REFERENCE.md](DEPLOY_QUICK_REFERENCE.md) Phase 2 |
| Minikube (local) | — | [minikube/README.md](minikube/README.md) |

## Related modules

| Module | Purpose |
|--------|---------|
| [`../csv-processor-app`](../csv-processor-app) | Flask application, Docker image, pytest, and GitHub Actions CI that publishes to Docker Hub. |
| [`../csv-processor-infrastructure`](../csv-processor-infrastructure) | AWS cluster and storage — kops bootstrap/teardown or Terraform EKS, S3 buckets, and IRSA. |
