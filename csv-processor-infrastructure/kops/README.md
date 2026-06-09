# kops — CSV processor cluster

Self-managed Kubernetes on AWS with **IRSA**, multi instance groups (on-demand / spot / mixed), and cluster-autoscaler.

## Layout

```
kops/
├── settings.env.example    # copy to settings.env (gitignored)
├── scripts/
│   ├── bootstrap.sh        # create cluster + IRSA + autoscaler
│   ├── teardown.sh         # delete cluster + IAM + S3
│   └── configure-kubeconfig.sh
├── iam/
│   ├── app-s3-policy.json.tmpl        # IRSA S3 policy template
│   └── cluster-autoscaler-policy.json # CA IAM policy (AWS only, not kubectl)
└── manifests/
    ├── cluster-config.yaml.tmpl  # cluster spec template (IRSA at create time)
    ├── instancegroup-*.yaml
    └── cluster-autoscaler/
        ├── rbac.yaml             # SA, ClusterRole, ClusterRoleBinding
        └── deployment.yaml       # template — ${CLUSTER_NAME} + ${AWS_REGION} substituted by bootstrap.sh
```

## Quick start

**Windows:** run from **Git Bash** (`envsubst` is required).

```bash
cp settings.env.example settings.env   # edit AWS_ACCOUNT_ID
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

**Provision + validate:** [KOPS_QUICK_REFERENCE.md](KOPS_QUICK_REFERENCE.md)

**Deploy application:** [csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md](../../csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md)

## IRSA + S3

kops creates role `csv-processor.csv-processor.sa.csv-processor.k8s.local` with policy `csv-processor-app-s3`:

| Action | Scope |
|--------|--------|
| `ListBucket` | `processed/*` and `history/*` prefixes |
| `PutObject`, `GetObject`, `DeleteObject` | all objects under processed bucket |

Helm release must be **`csv-processor`** in namespace **`csv-processor`**.

`bootstrap.sh` also applies an S3 lifecycle policy to the processed bucket:

- `processed/` → **GLACIER** after `GLACIER_TRANSITION_DAYS` days (default 30)
- → **DEEP_ARCHIVE** after `GLACIER_DEEP_ARCHIVE_DAYS` days (default 180)
- Object expiration at 365 days; noncurrent versions → GLACIER at 90 days, expire at 365 days

Configure `GLACIER_TRANSITION_DAYS` and `GLACIER_DEEP_ARCHIVE_DAYS` in `settings.env`.

## Teardown

```bash
./scripts/teardown.sh        # preview
./scripts/teardown.sh --yes  # delete everything
```

## kubectl from laptop

`api.csv-processor.k8s.local` does not resolve locally. After every `kops update` that re-exports kubeconfig, run:

```bash
./scripts/configure-kubeconfig.sh
```

Full phase-by-phase commands (bootstrap, validate, day-2, teardown): [KOPS_QUICK_REFERENCE.md](KOPS_QUICK_REFERENCE.md)
