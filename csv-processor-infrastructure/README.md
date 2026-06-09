# CSV Processor — Infrastructure

AWS infrastructure for the CSV processor platform. **Provision and validate** cluster, S3, and IAM — then deploy the app from [csv-processor-k8s-assets](https://github.com/asif-ahmedb/csv-processor-k8s-assets).

Pick **one** Kubernetes approach per environment.

| Path | Use when |
|------|----------|
| [`kops/`](kops/) | Self-managed Kubernetes — IRSA, spot + on-demand nodes, bootstrap/teardown scripts |
| [`terraform/`](terraform/) | Managed **EKS** — VPC, node groups, S3 + Glacier lifecycle, IRSA |

## kops (recommended)

```bash
cd kops
cp settings.env.example settings.env
chmod +x scripts/*.sh
./scripts/bootstrap.sh    # Git Bash on Windows (needs envsubst)
```

**Quick reference:** [KOPS_QUICK_REFERENCE.md](kops/KOPS_QUICK_REFERENCE.md) · **Overview:** [kops/README.md](kops/README.md)

After validation, deploy: [csv-processor-k8s-assets DEPLOY_QUICK_REFERENCE.md](https://github.com/asif-ahmedb/csv-processor-k8s-assets/blob/main/DEPLOY_QUICK_REFERENCE.md)

## Terraform (EKS alternative)

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init && terraform apply
```

**Overview:** [terraform/README.md](terraform/README.md)

Outputs `s3_bucket_name` and `app_irsa_role_arn` are consumed by Helm in k8s-assets.

## Repository layout

```
csv-processor-infrastructure/
├── README.md
├── kops/
│   ├── KOPS_QUICK_REFERENCE.md
│   ├── settings.env.example
│   ├── scripts/          # bootstrap, teardown, kubeconfig
│   ├── iam/              # app-s3-policy.json.tmpl, cluster-autoscaler-policy.json
│   └── manifests/        # kops cluster + instance groups + autoscaler
└── terraform/
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    └── terraform.tfvars.example
```

## Related repositories

| Repository | Purpose |
|------------|---------|
| [csv-processor-app](https://github.com/asif-ahmedb/csv-processor-app) | Flask application, Docker image, pytest, and GitHub Actions CI that publishes to Docker Hub. |
| [csv-processor-k8s-assets](https://github.com/asif-ahmedb/csv-processor-k8s-assets) | Helm chart, Ansible values, and Minikube scripts to deploy the app on Kubernetes. |
