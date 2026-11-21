# Step 06 — Pod Identity + AWS Secrets Manager: No Passwords in Git or YAML

[⬅ Back to the project overview](../README.md) · [⬅ Step 05](../step-05-pod-hardening/README.md) · [Step 07 ➡](../step-07-kyverno/README.md)

## What you will build in this step

The database passwords move to **AWS Secrets Manager**. A tool inside the cluster, **External Secrets Operator (ESO)**, reads them using **its own IAM role through Pod Identity** and keeps the Kubernetes Secret in sync.

```
Terraform (laptop)
   ├── random passwords ──► Secrets Manager: abhigna-prod/three-tier/mysql  {"password", "root-password"}
   └── IAM role "external-secrets" (may read ONLY that secret) ◄── Pod Identity association
                                                                       │ external-secrets/external-secrets
┌────────────── cluster ───────────────────────────────────────────────┼────────────┐
│ ESO controller (system node) ──── temporary credentials ─────────────┘            │
│      │ reads every 1h                                                             │
│      ▼                                                                            │
│ ExternalSecret "mysql-secret" ──► Kubernetes Secret "mysql-secret" ──► backend, mysql
└───────────────────────────────────────────────────────────────────────────────────┘
```

| Item | Value |
|---|---|
| Needs | Steps 03–05 |
| Runs on | 💻 Laptop (Terraform) + 🖥️ Bastion |
| New AWS resources | 1 Secrets Manager secret ($0.40/month), 1 IAM role, 1 Pod Identity association |
| ⚠️ Data | The DB is **reset** in Task 5 (new password = new database). Your test tasks disappear |
| Time | ~40 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### The problem with Kubernetes Secrets

A Kubernetes **Secret** is only **base64-encoded**, which is **not encryption**: anyone who can read it can decode it in one command. And if you put it in a YAML file in Git, everyone with the repo has the password forever.

| Where a password could live | Problem |
|---|---|
| In code / Dockerfile | Everyone with the image or repo sees it |
| In a YAML Secret in Git | Same, plus it stays in Git history forever |
| Created by hand with `kubectl` (Step 03) | Not in Git ✅, but nobody knows the source of truth, no rotation, no audit |
| **AWS Secrets Manager + ESO** | Encrypted with KMS, access logged in CloudTrail, rotation possible, Git holds only the **name** ✅ |

### External Secrets Operator (ESO)

| Object | Meaning |
|---|---|
| **ClusterSecretStore** | *Where* to read: "AWS Secrets Manager in us-east-1" (usable from any namespace) |
| **ExternalSecret** | *What* to read and *which* Kubernetes Secret to create: "copy `abhigna-prod/three-tier/mysql` → `mysql-secret`" |
| **Kubernetes Secret** | The result, used by the Pods as before. Nothing changes in the app |

### EKS Pod Identity: how ESO gets AWS access

**Definition:** an EKS feature that gives a **Pod** temporary AWS credentials of an **IAM role**, based on its **namespace + ServiceAccount**. No access keys, no node role.

```
1. Terraform: IAM role (trust: pods.eks.amazonaws.com) + association (external-secrets/external-secrets → role)
2. Pod starts with ServiceAccount external-secrets → EKS adds 2 env vars:
      AWS_CONTAINER_CREDENTIALS_FULL_URI = http://169.254.170.23/v1/credentials
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
3. The AWS SDK in the Pod calls that address → the Pod Identity agent (DaemonSet, Step 01)
   → returns temporary credentials for the role (auto-refreshed)
```

| | Pod Identity ✅ (we use it) | IRSA (older) |
|---|---|---|
| Setup | Association in EKS (1 resource) | OIDC provider + role trust per cluster + ServiceAccount annotation |
| Role trust policy | Same for every cluster (`pods.eks.amazonaws.com`) | Contains the cluster's OIDC URL |
| Needs | Pod Identity agent add-on (Step 01) | Nothing extra |

### Least privilege

The ESO role may do **2 actions on 1 secret**: `secretsmanager:GetSecretValue` and `DescribeSecret` on `abhigna-prod/three-tier/mysql`. If ESO were hacked, the attacker could read only this one secret.

### Why the database must be reset (Task 5)

MySQL sets the passwords **only once**, the first time it creates its data folder. The new passwords from Secrets Manager won't match the database that was created with the Step 03 passwords. In this lab we delete the disk and start fresh.

> **Production way:** rotate a DB password with a real process: create the new password in Secrets Manager, run `ALTER USER` in the database, then let the app pick it up (Secrets Manager can automate this for RDS).

## 1.2 The code, file by file

### `terraform/platform_iam.tf` (Step 06 part)

```hcl
resource "random_password" "mysql" {
  count   = var.enable_external_secrets ? 1 : 0
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "mysql" {
  count                   = var.enable_external_secrets ? 1 : 0
  name                    = "${var.cluster_name}/${var.app_namespace}/mysql"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mysql" {
  count     = var.enable_external_secrets ? 1 : 0
  secret_id = aws_secretsmanager_secret.mysql[0].id
  secret_string = jsonencode({
    password        = random_password.mysql[0].result
    "root-password" = random_password.mysql_root[0].result
  })
}

data "aws_iam_policy_document" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.mysql[0].arn]
  }
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  count           = var.enable_external_secrets ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets[0].arn
}
```

| Line | Explained |
|---|---|
| `random_password` (×2) | Terraform makes 24-character passwords. `special = false` avoids characters that break shells or URLs |
| `name = ".../three-tier/mysql"` | `abhigna-prod/three-tier/mysql`: a clear naming pattern `<cluster>/<namespace>/<app>` |
| `recovery_window_in_days = 0` | Lab: delete at once on destroy, so the same name works next time. Production: 7–30 days to undo mistakes |
| `jsonencode({...})` | One secret holding a small JSON with 2 keys |
| `resources = [...mysql[0].arn]` | The role can read **only this secret** |
| `aws_eks_pod_identity_association` | ServiceAccount `external-secrets/external-secrets` → this role |

> ⚠️ The passwords are also stored in your local `terraform.tfstate`. That's why state files must never be committed (`.gitignore` blocks them). Teams keep state in an encrypted S3 bucket.

### `platform/values/external-secrets.yaml`

```yaml
installCRDs: true
serviceAccount:
  create: true
  name: external-secrets
```

`name` **must** match the Pod Identity association.

### `platform/k8s/cluster-secret-store.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
```

| Line | Explained |
|---|---|
| `kind: ClusterSecretStore` | One store for the whole cluster |
| `service: SecretsManager` | (The other option is `ParameterStore`) |
| no `auth:` block | Use the controller's **own** credentials = the Pod Identity role |

### `helm/three-tier/templates/externalsecret.yaml`

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mysql-secret
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: mysql-secret
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: abhigna-prod/three-tier/mysql
        property: password
    - secretKey: root-password
      remoteRef:
        key: abhigna-prod/three-tier/mysql
        property: root-password
```

| Line | Explained |
|---|---|
| `refreshInterval: 1h` | Re-read AWS every hour (a changed value reaches the cluster within 1 hour) |
| `target.name: mysql-secret` | The Kubernetes Secret to create: same name as before, so **the app doesn't change** |
| `creationPolicy: Owner` | ESO owns it: delete the ExternalSecret and the Secret is deleted too |
| `remoteRef.key` / `property` | Secret name in AWS / the JSON key inside it |

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Create the secret and the ESO role   💻 terraform apply
Task 2  Look at the secret in AWS            💻
Task 3  Install External Secrets             🖥️
Task 4  Connect ESO to Secrets Manager       🖥️
Task 5  Switch the app to the AWS secret     🖥️  (DB reset)
Task 6  Prove it works                       🖥️ + browser
```

---

## Task 1 — Create the secret and the ESO role

📍 **Where:** 📝 VS Code → 💻 Terminal in `05-production-eks/terraform`

▶️ **Do:** in `terraform.tfvars`:

```hcl
enable_external_secrets = true  # Step 06
```

> sed: `sed -i 's/^enable_external_secrets *= false/enable_external_secrets = true/' terraform.tfvars`

```bash
terraform init -upgrade
```

> Needed once: downloads the `random` provider used for the passwords.

```bash
terraform apply
```

✅ **Check:** `Plan: 7 to add` (2 random passwords, secret, secret version, role, role policy, Pod Identity association). Type `yes`. Then:

```bash
terraform output mysql_secret_name
```

> ✅ `"abhigna-prod/three-tier/mysql"`

---

## Task 2 — Look at the secret in AWS

📍 **Where:** 💻 Terminal

▶️ **Do:** see the metadata (not the value):

```bash
aws secretsmanager describe-secret --secret-id abhigna-prod/three-tier/mysql --region us-east-1 --query '{Name:Name,KMS:KmsKeyId,Created:CreatedDate}'
```

See the Pod Identity associations EKS knows about:

```bash
aws eks list-pod-identity-associations --cluster-name abhigna-prod --region us-east-1 --query 'associations[].[namespace,serviceAccount]' --output table
```

✅ **Check:** the table shows `kube-system | aws-load-balancer-controller` and `external-secrets | external-secrets`.

> Don't print the secret value on screen in real work: terminals get recorded and shared.

---

## Task 3 — Install External Secrets

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
```

```bash
helm install external-secrets external-secrets/external-secrets --version 2.15.0 -n external-secrets --create-namespace -f ~/k8s-eks-projects/05-production-eks/platform/values/external-secrets.yaml
```

✅ **Check:**

```bash
kubectl get pods -n external-secrets
```

> ✅ 3 Pods `Running`: `external-secrets`, `...-webhook`, `...-cert-controller`.

---

## Task 4 — Connect ESO to Secrets Manager

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/cluster-secret-store.yaml
```

✅ **Check:**

```bash
kubectl get clustersecretstore aws-secrets-manager
```

> ✅ `STATUS Valid`, `READY True`. ESO reached AWS with its Pod Identity role.

---

## Task 5 — Switch the app to the AWS secret

📍 **Where:** 🖥️ Bastion

**Why:** the hand-made secret from Step 03 is replaced by one managed by ESO. MySQL must start with an empty disk so it uses the new passwords (see Part 1).

▶️ **Do:** 1) stop MySQL and delete its disk (lab data is lost):

```bash
kubectl scale statefulset mysql -n three-tier --replicas=0
```

```bash
kubectl delete pvc data-mysql-0 -n three-tier
```

2) Delete the hand-made secret:

```bash
kubectl delete secret mysql-secret -n three-tier
```

3) Turn on the ExternalSecret (Helm keeps all other values):

```bash
cd ~/k8s-eks-projects/05-production-eks
```

```bash
helm upgrade three-tier ./helm/three-tier -n three-tier --reuse-values --set externalSecret.enabled=true
```

> The upgrade also sets MySQL back to 1 replica, with a new EBS disk.

✅ **Check:**

```bash
kubectl get externalsecret -n three-tier
```

> ✅ `mysql-secret   aws-secrets-manager   1h   SecretSynced   True`

```bash
kubectl get pods -n three-tier
```

> ✅ After 1–2 minutes all Pods are `1/1 Running`. The backend may restart once while MySQL starts: that's fine.

---

## Task 6 — Prove it works

📍 **Where:** 🖥️ Bastion

▶️ **Do:** the Secret is now **owned** by the ExternalSecret:

```bash
kubectl get secret mysql-secret -n three-tier -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}'
```

> ✅ `ExternalSecret`

ESO's Pod uses Pod Identity:

```bash
kubectl get pod -n external-secrets -l app.kubernetes.io/name=external-secrets -o yaml | grep -A1 AWS_CONTAINER_CREDENTIALS_FULL_URI
```

> ✅ `http://169.254.170.23/v1/credentials`

Open the app in the browser (Step 03, Task 6), add a task, refresh.

✅ **Check:** the app works. The passwords exist only in AWS Secrets Manager (and, synced, in the cluster). There's nothing in Git, nothing typed by hand.

🎉 **Step 06 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| ClusterSecretStore `InvalidProviderConfig` / `AccessDenied` | No Pod Identity for ESO | `aws eks list-pod-identity-associations ...` (Task 2). ServiceAccount must be `external-secrets` in namespace `external-secrets`. Restart: `kubectl rollout restart deploy/external-secrets -n external-secrets` |
| ExternalSecret `SecretSyncedError` | Wrong secret name or property | `kubectl describe externalsecret mysql-secret -n three-tier`. Name must be `abhigna-prod/three-tier/mysql` |
| Backend logs `Access denied for user 'appuser'` | MySQL disk still has the old password | Repeat Task 5 step 1 (scale to 0, delete PVC), then `kubectl scale statefulset mysql -n three-tier --replicas=1` |
| `terraform apply`: `secret ... scheduled for deletion` | A secret with that name was deleted with a recovery window | `aws secretsmanager delete-secret --secret-id abhigna-prod/three-tier/mysql --force-delete-without-recovery --region us-east-1`, then apply again |
| `Inconsistent dependency lock file` for `random` | New provider | `terraform init -upgrade` |

## Interview Questions

### Other Questions

**Q1. Are Kubernetes Secrets encrypted?**
By default they are only base64-encoded in the API. EKS encrypts etcd storage, and you can add envelope encryption with KMS, but anyone with RBAC `get secrets` can read them, so RBAC on Secrets matters.

**Q2. How do you get secrets from AWS Secrets Manager into a Pod?**
External Secrets Operator (or the Secrets Store CSI driver) reads them with an IAM role through Pod Identity/IRSA and creates a Kubernetes Secret. Git only references the secret's name.

**Q3. Pod Identity vs IRSA?**
Both give Pods IAM roles without keys. Pod Identity uses an EKS association and an agent, with the same trust policy for every cluster. IRSA uses the cluster's OIDC provider and ServiceAccount annotations.

**Q4. How do you rotate a database password safely?**
Create the new value in Secrets Manager, update the DB user (`ALTER USER`), let the sync pick it up and restart Pods if needed. For RDS, Secrets Manager rotation can automate it.

**Q5. Why least privilege on the ESO role?**
If ESO is compromised, the attacker gets only the secrets that role can read: one secret here, not all of Secrets Manager.
