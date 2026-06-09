# CSV Processor

A containerised Python/Flask web application that accepts CSV file uploads, parses each row, displays the results in the browser, and stores processed files and upload history in AWS S3. Deployed on Kubernetes with nginx as a reverse proxy, IRSA-based S3 access, and Helm for multi-environment configuration.

---

## How it works

```
Developer → git push → GitHub Actions (pytest + docker build) → Docker Hub
                                                                      ↓
Browser → Load Balancer → nginx (port 80) → Flask app (port 8080) → S3 Bucket
                                                                  ↑
                          Helm + Ansible render values ───────────┘
                          kops or Terraform provision cluster
```

1. A developer pushes to `main` — CI runs tests and publishes a new Docker image to Docker Hub.
2. The Helm chart deploys two containers per pod: **nginx** (serves static files, proxies everything else) and the **Flask app** (parses CSV, writes to S3).
3. Upload history is read from S3, giving all pod replicas a consistent view.
4. Infrastructure is provisioned separately — choose **kops** (self-managed K8s) or **Terraform/EKS** (managed). Both set up IRSA so pods access S3 without static credentials.

---

## Repository structure

```
csv-processor/
├── .github/
│   └── workflows/
│       └── ci.yml                  # CI — triggers only on csv-processor-app/** changes
│
├── csv-processor-app/              # Application source code and Docker image
│   ├── web/                        #   Flask app, templates, static assets, pytest suite
│   ├── nginx/                      #   Standalone nginx config (non-K8s mode)
│   ├── docker/                     #   entrypoint.sh for standalone Docker run
│   ├── sample-data/                #   Example SOH CSV files for testing
│   └── Dockerfile
│
├── csv-processor-infrastructure/   # AWS cluster provisioning (pick one path)
│   ├── kops/                       #   Self-managed Kubernetes on EC2
│   │   ├── scripts/                #     bootstrap.sh · teardown.sh · configure-kubeconfig.sh
│   │   ├── iam/                    #     IAM policy templates for S3 + cluster-autoscaler
│   │   ├── manifests/              #     Cluster spec, instance groups, cluster-autoscaler manifests
│   │   ├── settings.env.example    #     Copy to settings.env and fill in account ID + region
│   │   └── KOPS_QUICK_REFERENCE.md #     Full phase-by-phase kops command reference
│   └── terraform/                  #   Managed EKS alternative
│       ├── main.tf                 #     VPC, EKS cluster, S3 bucket, IRSA role
│       ├── variables.tf
│       ├── outputs.tf              #     s3_bucket_name + app_irsa_role_arn (consumed by Helm)
│       └── terraform.tfvars.example
│
└── csv-processor-k8s-assets/       # Kubernetes deployment assets (all environments)
    ├── helm/csv-processor/         #   Helm chart — Deployment, Service, HPA, SA, ConfigMap
    │   ├── values.yaml             #     Base defaults
    │   ├── values-minikube.yaml    #     Local dev overrides
    │   ├── values-kops.yaml        #     kops / AWS overrides
    │   └── values-eks.yaml         #     EKS / Terraform overrides
    ├── ansible/                    #   Renders env-specific Helm values from inventory vars
    ├── rendered/                   #   Pre-rendered values-dev.yaml (Windows / no-Ansible fallback)
    ├── minikube/                   #   Local deploy scripts (deploy.sh · deploy.ps1)
    │   └── MINIKUBE_QUICK_REFERENCE.md  # Full Minikube command reference
    └── DEPLOY_QUICK_REFERENCE.md   #   Full kops + EKS Helm deploy command reference
```

---

## Module roles

| Module | What it owns | When you need it |
|--------|-------------|-----------------|
| `csv-processor-app` | Flask app source, Dockerfile, CI pipeline, sample data | Always — it's the application |
| `csv-processor-infrastructure/kops` | Self-managed K8s cluster on AWS EC2 | AWS deployment (primary path) |
| `csv-processor-infrastructure/terraform` | Managed EKS cluster on AWS | AWS deployment (alternative path) |
| `csv-processor-k8s-assets` | Helm chart, Ansible config, Minikube scripts | Deploying the app to any cluster |

---

## Quick start — Minikube (local, no AWS required)

Prerequisites: Docker Desktop, Minikube, kubectl, Helm 3.

```bash
git clone https://github.com/asif-ahmedb/csv-processor
cd csv-processor/csv-processor-k8s-assets/minikube

.\deploy.ps1          # Windows PowerShell
# or: ./deploy.sh     # Git Bash / Linux

kubectl port-forward -n csv-processor svc/csv-processor 8080:80
# open http://localhost:8080 — upload csv-processor-app/sample-data/soh.csv
```

> S3 is disabled in Minikube mode — the app parses and displays rows without storing them.

For the full command reference including validation, day-2, and teardown: [csv-processor-k8s-assets/minikube/MINIKUBE_QUICK_REFERENCE.md](csv-processor-k8s-assets/minikube/MINIKUBE_QUICK_REFERENCE.md)

---

## AWS deployment

Both paths provision S3 (with Glacier lifecycle), IRSA for credential-less pod access, and a Kubernetes cluster. Deploy the app from `csv-processor-k8s-assets` after the cluster is ready.

| Path | Provision | Then deploy |
|------|-----------|-------------|
| kops (self-managed K8s) | [csv-processor-infrastructure/kops](csv-processor-infrastructure/kops) · [KOPS_QUICK_REFERENCE.md](csv-processor-infrastructure/kops/KOPS_QUICK_REFERENCE.md) | [DEPLOY_QUICK_REFERENCE.md](csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md) Phase 1 |
| Terraform / EKS | [csv-processor-infrastructure/terraform](csv-processor-infrastructure/terraform) | [DEPLOY_QUICK_REFERENCE.md](csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md) Phase 2 |

---

## CI/CD

`.github/workflows/ci.yml` runs on every push to `main` that changes files under `csv-processor-app/`:

1. **pytest** — runs the full test suite
2. **Docker build + push** — publishes `barbhua786/csv-processor:latest` and `:<git-sha>` to Docker Hub

Required secrets in the `csv-processor` repository (Settings → Secrets → Actions): `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`.
