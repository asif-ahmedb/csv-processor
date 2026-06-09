# kops — Provision from Scratch (Command Reference)

End-to-end: **configure → bootstrap cluster → validate infrastructure → teardown**.

Provisioning only. Application deployment is in [`../../csv-processor-k8s-assets`](../../csv-processor-k8s-assets).

Run bootstrap/teardown from **Git Bash** on Windows (`bash`, `envsubst` required).

---

## Phase 0 — Prerequisites (one-time)

```bash
aws sts get-caller-identity    # AWS credentials OK
kops version
kubectl version --client
envsubst --version             # from Git for Windows
```

You need IAM permissions to create EC2, VPC, ELB, S3, IAM roles/policies.

---

## Phase 1 — Configure settings

```bash
cd csv-processor-infrastructure/kops
cp settings.env.example settings.env
```

Edit `settings.env` — set at minimum:

```bash
export AWS_ACCOUNT_ID=<YOUR_12_DIGIT_ACCOUNT_ID>
export AWS_REGION=us-east-1
```

Other values are derived automatically (`PROCESSED_BUCKET`, `KOPS_STATE_BUCKET`, etc.).

```bash
source settings.env
echo "Cluster: ${CLUSTER_NAME}  Bucket: ${PROCESSED_BUCKET}"
```

---

## Phase 2 — Bootstrap (~15–20 min)

```bash
cd csv-processor-infrastructure/kops
chmod +x scripts/*.sh
./scripts/bootstrap.sh
```

### What bootstrap creates

| Resource | Example name |
|----------|----------------|
| kops cluster | `csv-processor.k8s.local` |
| kops state S3 | `csv-processor-kops-state-<account>` |
| Processed data S3 | `csv-processor-processed-<account>` |
| IRSA discovery S3 | `csv-processor-irsa-discovery-<account>` |
| IAM policy | `csv-processor-app-s3` |
| IRSA IAM role | `csv-processor.csv-processor.sa.csv-processor.k8s.local` |
| Node groups | on-demand, spot, mixed |
| cluster-autoscaler | Deployment in `kube-system` |

### If bootstrap fails mid-way

Re-run `./scripts/bootstrap.sh` — it is idempotent for S3/IAM and will continue cluster setup.

---

## Phase 3 — Validate infrastructure

Bootstrap configures kubeconfig automatically. Confirm:

```bash
cd csv-processor-infrastructure/kops
./scripts/configure-kubeconfig.sh    # re-run if kubectl cannot connect
kubectl get nodes                    # all nodes Ready
kubectl get pods -n kube-system | grep cluster-autoscaler
```

**Note:** `api.csv-processor.k8s.local` does **not** resolve on your laptop. Always use `configure-kubeconfig.sh` (points kubectl at the API ELB).

`kops validate cluster` may fail from a laptop — use `kubectl get nodes` instead.

### Validate AWS resources

```bash
source settings.env

# S3 buckets
aws s3 ls | grep csv-processor

# IAM role + policy
aws iam get-role --role-name "csv-processor.csv-processor.sa.csv-processor.k8s.local"
aws iam get-policy --policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/csv-processor-app-s3"

# IRSA discovery bucket reachable
aws s3 ls "s3://${IRSA_DISCOVERY_BUCKET}/"
```

### Outputs for application deploy

Pass these to [csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md](../../csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md):

| Variable | Source |
|----------|--------|
| `PROCESSED_BUCKET` | `settings.env` |
| `AWS_ACCOUNT_ID` | `settings.env` |
| `CLUSTER_NAME` | `settings.env` |

Helm release must be **`csv-processor`** in namespace **`csv-processor`** (IRSA role name depends on this).

---

## Phase 4 — Day-2 (infrastructure)

```bash
# Re-export kubeconfig after kops update
cd csv-processor-infrastructure/kops
./scripts/configure-kubeconfig.sh

# Cluster status
kubectl get nodes
kubectl get pods -n kube-system
```

---

## Phase 5 — Teardown

```bash
cd csv-processor-infrastructure/kops
./scripts/teardown.sh              # preview what will be deleted
./scripts/teardown.sh --yes        # delete cluster + S3 + IAM
```

Teardown runs `helm uninstall` best-effort, then removes kubectl context.

### Verify nothing left in AWS

```bash
aws s3 ls | grep csv-processor
aws iam list-roles --query "Roles[?contains(RoleName,'csv-processor')].RoleName" --output text
aws iam list-policies --scope Local --query "Policies[?contains(PolicyName,'csv-processor')].PolicyName" --output text
```

All three should return empty.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `lookup api.csv-processor.k8s.local: no such host` | `./scripts/configure-kubeconfig.sh` |
| `kubectl` → `localhost:8080` refused | `kubectl config use-context csv-processor.k8s.local` then `configure-kubeconfig.sh` |
| Helm TLS / cert + insecure error | `./scripts/configure-kubeconfig.sh` |
| `Unable to load paramfile file:///tmp/...` (Windows) | Fixed in `bootstrap.sh`; re-run bootstrap |
| `apiVersion not set` on kubectl apply | Never `kubectl apply -f manifests/cluster-autoscaler/` — IAM JSON is under `iam/` |
| Pods `Pending` in `kube-system` | `kubectl describe pod ...` — cluster-autoscaler may be scaling nodes; wait |
| S3 `AccessDenied` on `history/` prefix | IAM policy needs `history/*` in `iam/app-s3-policy.json.tmpl` |

---

## Full copy-paste flow

```bash
# ── 1. CONFIGURE ──────────────────────────────────────────
cd csv-processor-infrastructure/kops
cp settings.env.example settings.env
# edit AWS_ACCOUNT_ID in settings.env
source settings.env
chmod +x scripts/*.sh

# ── 2. BOOTSTRAP (~15 min) ────────────────────────────────
./scripts/bootstrap.sh
./scripts/configure-kubeconfig.sh
kubectl get nodes
kubectl get pods -n kube-system | grep cluster-autoscaler

# ── 3. VALIDATE AWS ───────────────────────────────────────
aws s3 ls | grep csv-processor
aws iam get-role --role-name "csv-processor.csv-processor.sa.csv-processor.k8s.local"

# ── 4. DEPLOY APP ─────────────────────────────────────────
# ../../csv-processor-k8s-assets → DEPLOY_QUICK_REFERENCE.md

# ── 5. TEARDOWN ───────────────────────────────────────────
./scripts/teardown.sh --yes
aws s3 ls | grep csv-processor    # should be empty
```

---

## Key resource names (account `638386391095` example)

| Resource | Name |
|----------|------|
| Cluster | `csv-processor.k8s.local` |
| kops state bucket | `csv-processor-kops-state-638386391095` |
| Processed S3 bucket | `csv-processor-processed-638386391095` |
| IRSA discovery bucket | `csv-processor-irsa-discovery-638386391095` |
| IRSA role | `csv-processor.csv-processor.sa.csv-processor.k8s.local` |
| IAM policy | `csv-processor-app-s3` |

---

See also: [README.md](README.md) · [Infrastructure README](../README.md) · [csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md](../../csv-processor-k8s-assets/DEPLOY_QUICK_REFERENCE.md)
