# AWS infrastructure (VPC, EKS, S3 + Glacier lifecycle)

Terraform provisions and validates:

- VPC with public/private subnets across 2 AZs
- **EKS** cluster with on-demand and spot managed node groups (tags for cluster-autoscaler)
- **S3** bucket for processed CSV uploads with lifecycle:
  - `processed/` prefix → **GLACIER** after `glacier_transition_days` (default 30)
  - → **DEEP_ARCHIVE** after `glacier_deep_archive_days` (default 180)
  - Object expiration at 365 days
  - Noncurrent versions → **GLACIER** at 90 days, expire at 365 days
- **IRSA** IAM role for the application service account (S3 upload from pods)

## Apply

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

## Validate

```bash
terraform output
aws eks describe-cluster --name $(terraform output -raw eks_cluster_name)
kubectl get nodes    # after aws eks update-kubeconfig
```

Install [cluster-autoscaler](https://github.com/kubernetes/autoscaler/tree/master/charts/cluster-autoscaler) on EKS with `autoDiscovery.clusterName` set to the EKS cluster name.

## Outputs for application deploy

| Output | Used by Helm |
|--------|----------------|
| `s3_bucket_name` | `--set config.s3Bucket` |
| `app_irsa_role_arn` | `--set aws.irsaRoleArn` |

Deploy the app from [csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md](../../csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md).

## kops vs EKS

- **kops** (`../kops/`): self-managed Kubernetes on AWS with multiple instance groups
- **terraform**: managed EKS

Use one control plane approach per environment.
