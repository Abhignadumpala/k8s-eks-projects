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
| Time | ~70 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### The problem with Kubernetes Secrets

**Definition:** **base64** is a way to **write** data with safe characters. It is **not encryption**: anyone can turn it back in one command (`base64 -d`).

- A Kubernetes **Secret** stores passwords only **base64-encoded**.
- Anyone who can **read** the Secret can **decode** the password.
- If you put it in a YAML file in **Git**, everyone with the repo has the password, **forever** (Git history).

**Analogy ✉️:** base64 is writing a password in **mirror writing**. It looks strange, but anyone with a mirror reads it. Encryption is a **locked safe**.

```
password: "Secret123"  ──base64──►  "U2VjcmV0MTIz"  ──base64 -d──►  "Secret123"   😱 anyone can do this
```

| Where a password could live | Problem |
|---|---|
| In code / Dockerfile | Everyone with the image or repo sees it ❌ |
| In a YAML Secret in Git | Same, plus it stays in Git history forever ❌ |
| Created by hand with `kubectl` (Step 03) | Not in Git ✅, but nobody knows the source of truth, no rotation, no audit |
| **AWS Secrets Manager + ESO** | Encrypted with KMS, access logged in CloudTrail, rotation possible, Git holds only the **name** ✅ |

> **Interview one-liner:** "Kubernetes Secrets are only base64-encoded, not encrypted, so we keep the real passwords in AWS Secrets Manager and Git holds only the secret's name."

### External Secrets Operator (ESO)

**Definition:** **ESO** is a tool running in the cluster that **copies** a secret from **AWS Secrets Manager** into a normal **Kubernetes Secret**, and keeps it in sync.

- The real password lives in **Secrets Manager** (encrypted, audited).
- ESO **reads it** and **creates** `mysql-secret` in the cluster.
- The app reads `mysql-secret` **exactly as before**. Nothing changes in the app.

**Analogy 📮:** Secrets Manager is the **bank vault**, ESO is the **trusted courier**, and the Kubernetes Secret is the **envelope** delivered to the app's desk.

```
AWS Secrets Manager                  cluster
abhigna-prod/three-tier/mysql ──ESO reads──► Kubernetes Secret mysql-secret ──► backend, mysql
   (the vault 🏦)               (courier)       (envelope ✉️)                    (no change)
```

| Object | Meaning |
|---|---|
| **ClusterSecretStore** | *Where* to read: "AWS Secrets Manager in us-east-1" (usable from any namespace) |
| **ExternalSecret** | *What* to read and *which* Kubernetes Secret to create: "copy `abhigna-prod/three-tier/mysql` → `mysql-secret`" |
| **Kubernetes Secret** | The result, used by the Pods as before. Nothing changes in the app |

> **Interview one-liner:** "External Secrets Operator syncs secrets from AWS Secrets Manager into Kubernetes Secrets, so the app is unchanged and Git holds no passwords."

### EKS Pod Identity: how ESO gets AWS access

**Definition:** **EKS Pod Identity** gives **one Pod** temporary AWS credentials of an **IAM role**, based on its **namespace + ServiceAccount**. No access keys, no node role.

- ESO must call **Secrets Manager**, so it needs **AWS permissions**.
- **Bad ways:** put access keys in the Pod (can leak), or give the **node** the permission (every Pod on the node gets it).
- **Pod Identity:** only Pods with ServiceAccount `external-secrets` get the role, and the keys are **temporary** and **auto-refreshed**.

**Analogy 🎫:** instead of giving everyone in the building the vault key (node role), the security desk hands **one named courier** a **visitor badge** that expires in an hour, and renews it.

```
1. Terraform: IAM role (trust: pods.eks.amazonaws.com) + association (external-secrets/external-secrets → role)
2. Pod starts with ServiceAccount external-secrets → EKS adds 2 env vars:
      AWS_CONTAINER_CREDENTIALS_FULL_URI = http://169.254.170.23/v1/credentials
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE = /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/eks-pod-identity-token
3. The AWS SDK in the Pod calls that address → the Pod Identity agent (DaemonSet, Step 01)
   → returns temporary credentials for the role (auto-refreshed)
```

| | Access keys in Pod | Node IAM role | **Pod Identity** ✅ |
|---|---|---|---|
| Who gets the permission | Whoever sees the keys ❌ | **Every** Pod on the node ❌ | Only this ServiceAccount ✅ |
| Keys expire | No ❌ | Yes | Yes, auto-refreshed ✅ |
| Keys can leak from Git | Yes ❌ | No | No ✅ |

| | Pod Identity ✅ (we use it) | IRSA (older) |
|---|---|---|
| Setup | Association in EKS (1 resource) | OIDC provider + role trust per cluster + ServiceAccount annotation |
| Role trust policy | Same for every cluster (`pods.eks.amazonaws.com`) | Contains the cluster's OIDC URL |
| Needs | Pod Identity agent add-on (Step 01) | Nothing extra |
| Where the link lives | In **EKS** (an association). The ServiceAccount has **no** annotation | On the **ServiceAccount**: annotation `eks.amazonaws.com/role-arn` |
| EKS Fargate | ❌ Not supported | ✅ Use IRSA |

> Don't mix them on one ServiceAccount: they are different mechanisms. Use IRSA only where Pod Identity doesn't work (Fargate) or where a cluster already uses it.

> **Interview one-liner:** "EKS Pod Identity maps a namespace + ServiceAccount to an IAM role and gives that Pod temporary, auto-rotated credentials: no access keys and no broad node role."

### The role's trust policy

**Definition:** a **trust policy** on an IAM role says **who is allowed to use** the role. (The **permissions policy** says what the role can do.)

- Our role trusts only the **EKS Pod Identity service**.
- So only EKS can hand this role to a Pod. A human or another service can't.
- We create it in Terraform as `pod_identity_trust` (file for the CLI way: [`platform/pod-identity-lab/pod-identity-trust.json`](../platform/pod-identity-lab/pod-identity-trust.json)).

**Analogy 🚗:** the permissions policy is **what the car can do**; the trust policy is **who is allowed to drive it**.

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"]
}
```

| Part | Meaning |
|---|---|
| `pods.eks.amazonaws.com` | Only the EKS Pod Identity service may hand out this role |
| `sts:AssumeRole` | Get temporary credentials for the role |
| `sts:TagSession` | EKS tags the session with cluster, namespace, ServiceAccount (visible in CloudTrail; usable in conditions) |

> **Production:** add **conditions** so only one cluster / namespace / ServiceAccount can use the role (session tags like `aws:RequestTag/kubernetes-namespace`). See the AWS doc *"EKS Pod Identity role"*.

### 4 ways to set up Pod Identity

**Definition:** the same 3 pieces (agent, role, association) can be created by clicking, with a tool, or with code. Production uses **code** (Terraform) so it's repeatable.

| Way | Effort | Best for |
|---|---|---|
| AWS Console | Clicking | Learning, demos |
| `eksctl` | A few commands | Quick labs |
| AWS CLI | Scriptable commands | Light automation. **Task 7 uses this** |
| **Terraform** / CloudFormation | More setup at first | Repeatable production, many clusters. **Tasks 1–6 use this** |

The same 3 pieces every time:

```
1. Agent add-on   eks-pod-identity-agent on every node        (Step 01, Terraform)
2. IAM role       trust: pods.eks.amazonaws.com + a small permissions policy
3. Association    cluster + namespace + ServiceAccount  ──►  role   (stored in EKS)
```

**Console:** EKS → your cluster → **Add-ons** → *Amazon EKS Pod Identity Agent* · IAM → **Roles** → *Create role* → use case *EKS - Pod Identity* · EKS → your cluster → **Access** → *Pod Identity associations* → *Create*.

**eksctl:**

```bash
eksctl create addon --cluster abhigna-prod --name eks-pod-identity-agent --region us-east-1
```

```bash
eksctl create podidentityassociation --cluster abhigna-prod --region us-east-1 --namespace media --service-account-name uploader --create-service-account --permission-policy-arns <policy-arn>
```

> eksctl creates the role for you. A broad AWS-managed policy (e.g. `AmazonS3ReadOnlyAccess`) is fine for a demo only; real workloads get a small policy of their own.

**AWS CLI** (the role already exists):

```bash
aws eks create-pod-identity-association --cluster-name abhigna-prod --namespace media --service-account uploader --role-arn arn:aws:iam::<account-id>:role/<role-name> --region us-east-1
```

### IRSA, the alternative

**Definition:** **IRSA (IAM Roles for Service Accounts)** is the **older** way to give Pods an IAM role. It links the role to the cluster's **OIDC provider** and puts the role ARN as an **annotation** on the ServiceAccount. Still needed on **Fargate**.

```bash
eksctl utils associate-iam-oidc-provider --cluster abhigna-prod --region us-east-1 --approve
```

```bash
eksctl create iamserviceaccount --cluster abhigna-prod --region us-east-1 --namespace media --name uploader --attach-policy-arn <policy-arn> --approve
```

> The first command creates the cluster's OIDC provider (our Terraform already did: `enable_irsa = true`). The second creates the role **and** the annotated ServiceAccount.

### Important: credentials arrive when the Pod starts

**Definition:** EKS adds the Pod Identity env variables **only at the moment a Pod is created**. It never adds them to a Pod that is already running.

- You create the **association** (namespace + ServiceAccount → role).
- A Pod that started **before** that has **no** credentials → AWS calls fail.
- Fix: create the association **first**, or **restart** the Pod after (`kubectl rollout restart`).

**Analogy 🎟️:** badges are handed out **at the entrance**. Someone already inside the building doesn't get one until they walk out and back in.

```
Pod started ──► association created ──► Pod has NO credentials ❌
association created ──► Pod (re)started ──► Pod HAS credentials ✅
```

> **Interview one-liner:** "Pod Identity injects credentials at Pod creation, so after adding an association you must restart existing Pods."

### Least privilege

**Definition:** **least privilege** = give a role **only** the actions it really needs, on **only** the resources it really needs.

- The ESO role may do **2 actions** on **1 secret**: `secretsmanager:GetSecretValue` and `DescribeSecret` on `abhigna-prod/three-tier/mysql`.
- It can't read other secrets, delete anything, or touch S3/EC2.
- If ESO were hacked, the attacker could read **only this one secret**.

**Analogy 🗝️:** give the courier the key to **one locker**, not the master key to the whole bank.

| | Broad policy (`secretsmanager:*` on `*`) | **Our policy** |
|---|---|---|
| Secrets it can read | All ❌ | 1 ✅ |
| Can delete / change secrets | Yes ❌ | No ✅ |
| Damage if hacked | Every password ❌ | One password ✅ |

> A working `get-caller-identity` does **not** prove least privilege. Also test that **forbidden** actions fail (Task 7).

> **Interview one-liner:** "Least privilege means the ESO role can only read one specific secret, and we prove it by testing that other actions are denied."

### Why the database must be reset (Task 5)

**Definition:** MySQL sets its passwords **only once**: the first time it creates its data folder on the disk.

- In Step 03 the database was created with the **old** passwords.
- Secrets Manager now has **new** passwords, so they **don't match** the database.
- In this lab we **delete the disk** and start fresh, so MySQL is created with the new passwords.

**Analogy 🔐:** changing the paper with the code doesn't change the **lock**. You must set the new code **on the lock** too.

| | This lab | **Production** |
|---|---|---|
| Change password | Delete the disk, start fresh | Keep the data ✅ |
| How | Reset MySQL | New password in Secrets Manager → `ALTER USER` in the DB → app picks it up |
| Automation | — | Secrets Manager rotation (built in for RDS) |

> **Interview one-liner:** "A database stores its own password, so rotation means updating both Secrets Manager and the database; for RDS, Secrets Manager can automate it."

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

**In simple steps:**
1. Terraform **makes 2 random passwords** (app user + root), 24 characters each.
2. It creates a secret in **AWS Secrets Manager** called `abhigna-prod/three-tier/mysql`.
3. It **stores** both passwords in that secret as a small JSON: `{"password": "...", "root-password": "..."}`.
4. It writes a **policy**: read **only this one secret** (2 actions).
5. It creates a **role** with that policy (trusted only by EKS Pod Identity) and **links** it to ServiceAccount `external-secrets` in namespace `external-secrets`.

```
random_password ──► Secrets Manager: abhigna-prod/three-tier/mysql  🏦
policy "read this 1 secret" ──► role ──association──► external-secrets/external-secrets (ESO Pods)
```

Nobody ever types or sees the passwords. Terraform makes them, AWS keeps them, ESO delivers them.

### `platform/values/external-secrets.yaml`

```yaml
installCRDs: true
serviceAccount:
  create: true
  name: external-secrets
```

`name` **must** match the Pod Identity association.

**In simple steps:**
1. Settings for the ESO Helm install (Task 3).
2. `installCRDs: true` → also installs ESO's **new object types** (ExternalSecret, ClusterSecretStore).
3. Creates the ServiceAccount `external-secrets`, with the **exact name** Terraform linked to the role. That's how ESO gets AWS access.

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

**In simple steps:**
1. Tells ESO **where** the secrets live: AWS **Secrets Manager** in **us-east-1**.
2. "Cluster" = **any namespace** can use this store.
3. No passwords or keys here: ESO logs in to AWS with its **Pod Identity role**.

**Analogy 🏦:** this file is the **bank's address**. It says where the vault is, not what to take out.

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

**In simple steps:**
1. Tells ESO **what** to copy: from AWS secret `abhigna-prod/three-tier/mysql`, take `password` and `root-password`.
2. ESO **creates** the Kubernetes Secret `mysql-secret` with those 2 keys.
3. It's the **same name** the app already uses → backend and mysql need **no change**.
4. Every **1 hour** ESO checks AWS again and updates the Secret if the value changed.
5. Turned on with `externalSecret.enabled=true` (it's off in Step 03).

```
AWS: abhigna-prod/three-tier/mysql {password, root-password}
        │ ESO reads (every 1h) via ClusterSecretStore aws-secrets-manager
        ▼
Kubernetes Secret mysql-secret {password, root-password} ──► backend, mysql (unchanged)
```

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Create the secret and the ESO role   💻 terraform apply
Task 2  Look at the secret in AWS            💻
Task 3  Install External Secrets             🖥️
Task 4  Connect ESO to Secrets Manager       🖥️
Task 5  Switch the app to the AWS secret     🖥️  (DB reset)
Task 6  Prove it works                       🖥️ + browser
Task 7  Least-privilege test: S3 reader Pod  💻 AWS CLI + 🖥️  (then clean up)
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

---

## Task 7 — Least-privilege test: a Pod that may only read one S3 bucket

📍 **Where:** 💻 Laptop (AWS CLI) and 🖥️ Bastion (kubectl), back and forth

**Scenario:** an app `uploader` in namespace `media` needs to **read** one S3 bucket. Nothing else. This time you set up Pod Identity with the **AWS CLI** (not Terraform), so you see each piece, and you prove that **forbidden** actions fail.

```
S3 bucket ◄── read only ── IAM role abhigna-prod-uploader ◄── association ──► media / uploader ◄── Pod awscli
```

**Part A: AWS side (💻 laptop)**

▶️ **Do:** set 2 variables (the bucket name must be unique worldwide, so it includes your account ID):

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text) && export BUCKET=abhigna-prod-uploader-$ACCOUNT_ID
```

Create the bucket and put one file in it:

```bash
aws s3 mb s3://$BUCKET --region us-east-1
```

```bash
echo "hello from S3" > /tmp/hello.txt && aws s3 cp /tmp/hello.txt s3://$BUCKET/hello.txt
```

Create the **permissions** policy (list this bucket, read its objects; no write, no delete). `envsubst` fills in your bucket name:

```bash
cd ~/k8s-eks-projects/05-production-eks/platform/pod-identity-lab
```

```bash
aws iam create-policy --policy-name abhigna-prod-uploader-s3-read --policy-document "$(envsubst '${BUCKET}' < uploader-s3-read.json)"
```

Create the role with the Pod Identity **trust** policy, and attach the permissions:

```bash
aws iam create-role --role-name abhigna-prod-uploader --assume-role-policy-document file://pod-identity-trust.json
```

```bash
aws iam attach-role-policy --role-name abhigna-prod-uploader --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/abhigna-prod-uploader-s3-read
```

✅ **Check:** `aws iam list-attached-role-policies --role-name abhigna-prod-uploader --output text` shows `abhigna-prod-uploader-s3-read`.

**Part B: start the Pod BEFORE the association (🖥️ bastion)**

▶️ **Do:**

```bash
kubectl create namespace media && kubectl create serviceaccount uploader -n media
```

```bash
kubectl run awscli -n media --image=amazon/aws-cli:2.41.0 --restart=Never --overrides='{"spec":{"serviceAccountName":"uploader"}}' --command -- sleep 3600
```

> A pinned version, not `latest`. `media` is not checked by our Kyverno rules (Step 07), so a Docker Hub image is allowed here.

```bash
kubectl wait pod/awscli -n media --for=condition=Ready --timeout=120s && kubectl exec awscli -n media -- aws sts get-caller-identity
```

> ✅ Fails: `Unable to locate credentials`. No association yet, and **IMDS hop limit 1** (Step 01) stops the Pod from borrowing the node's role. Exactly what we want.

**Part C: create the association (💻 laptop)**

```bash
aws eks create-pod-identity-association --cluster-name abhigna-prod --namespace media --service-account uploader --role-arn arn:aws:iam::$ACCOUNT_ID:role/abhigna-prod-uploader --region us-east-1
```

**Part D: recreate the Pod and test (🖥️ bastion)**

The old Pod still has no credentials (they're added only at Pod start). Recreate it:

```bash
kubectl delete pod awscli -n media
```

```bash
kubectl run awscli -n media --image=amazon/aws-cli:2.41.0 --restart=Never --overrides='{"spec":{"serviceAccountName":"uploader"}}' --command -- sleep 3600
```

```bash
kubectl wait pod/awscli -n media --for=condition=Ready --timeout=120s
```

See what EKS injected:

```bash
kubectl get pod awscli -n media -o yaml | grep -A1 AWS_CONTAINER
```

> ✅ `AWS_CONTAINER_CREDENTIALS_FULL_URI` and `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.

**Allowed** actions:

```bash
kubectl exec awscli -n media -- aws sts get-caller-identity
```

> ✅ `"Arn": "arn:aws:sts::...:assumed-role/abhigna-prod-uploader/eks-abhigna-pr-awscli-..."`

```bash
export BUCKET=abhigna-prod-uploader-$ACCOUNT_ID
```

```bash
kubectl exec awscli -n media -- aws s3 ls s3://$BUCKET
```

> ✅ `hello.txt`

```bash
kubectl exec awscli -n media -- aws s3 cp s3://$BUCKET/hello.txt -
```

> ✅ `hello from S3`

**Forbidden** actions (each must fail):

```bash
kubectl exec awscli -n media -- sh -c "echo hack | aws s3 cp - s3://$BUCKET/hack.txt"
```

> ✅ `AccessDenied` (no `s3:PutObject`).

```bash
kubectl exec awscli -n media -- aws s3 rm s3://$BUCKET/hello.txt
```

> ✅ `AccessDenied` (no `s3:DeleteObject`).

```bash
kubectl exec awscli -n media -- aws s3 ls
```

> ✅ `AccessDenied` (can't even list other buckets).

```bash
kubectl exec awscli -n media -- aws secretsmanager list-secrets --region us-east-1
```

> ✅ `AccessDenied`: this Pod can't see the MySQL secret.

✅ **Check:** 3 allowed actions work, 4 forbidden ones fail. **That** is least privilege, proven.

**Part E: clean up (Terraform doesn't know these, so `terraform destroy` would leave them)**

🖥️ Bastion:

```bash
kubectl delete namespace media
```

💻 Laptop:

```bash
aws eks delete-pod-identity-association --cluster-name abhigna-prod --region us-east-1 --association-id $(aws eks list-pod-identity-associations --cluster-name abhigna-prod --namespace media --region us-east-1 --query 'associations[0].associationId' --output text)
```

```bash
aws iam detach-role-policy --role-name abhigna-prod-uploader --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/abhigna-prod-uploader-s3-read && aws iam delete-role --role-name abhigna-prod-uploader
```

```bash
aws iam delete-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/abhigna-prod-uploader-s3-read && aws s3 rb s3://$BUCKET --force
```

✅ **Check:** `aws eks list-pod-identity-associations --cluster-name abhigna-prod --region us-east-1 --query 'associations[].namespace' --output text` no longer shows `media`.

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
| `Unable to locate credentials` in a Pod | No association for this namespace + ServiceAccount, **or** the Pod started before it | `aws eks list-pod-identity-associations ...`; then **recreate** the Pod |
| `AccessDenied` on an action that should work | Role policy misses the action or the exact ARN (`bucket` vs `bucket/*`) | Compare the policy with the action; also check bucket policies, permissions boundaries, SCPs |
| `AccessDenied` on `AssumeRole` / no credentials at all | Role trust doesn't allow `pods.eks.amazonaws.com` with `sts:AssumeRole` + `sts:TagSession` | Fix the trust policy (Part 1) |
| Pod Identity doesn't work at all | Agent add-on not `Active`, or the Pod runs on **Fargate** | `kubectl get pods -n kube-system \| grep pod-identity`; on Fargate use IRSA |

## Interview Questions

### ⭐ Very Important

**Q1. How do you give a Pod AWS permissions without access keys?**
Workload identity: link an IAM role to the Pod's ServiceAccount with **EKS Pod Identity** (or IRSA). The Pod gets temporary, auto-refreshed credentials. No keys in images, env vars or Secrets.

**Q2. What are the 3 pieces of EKS Pod Identity?**
The Pod Identity **agent** add-on on the nodes, an **IAM role** that trusts `pods.eks.amazonaws.com` (`sts:AssumeRole` + `sts:TagSession`), and an **association** (cluster + namespace + ServiceAccount → role) stored in EKS.

**Q3. Pod Identity vs IRSA: when do you use which?**
Pod Identity is the newer, simpler default for EC2 nodes: no annotation, same trust policy for every cluster. IRSA uses the cluster's OIDC provider and a ServiceAccount annotation; use it on **Fargate** or where it's already in place. Don't mix both on one ServiceAccount.

**Q4. `get-caller-identity` works. Is the role least privilege?**
No, that only proves the identity. Test that forbidden actions fail (`PutObject`, `DeleteObject`, other services) and scope the policy to exact ARNs.

**Q5. You created the association but the Pod still has no credentials. Why?**
The Pod started before the association. Credentials are injected at Pod creation, so recreate the Pod. Also check namespace/ServiceAccount names and the agent add-on.

### Other Questions

**Q6. Are Kubernetes Secrets encrypted?**
By default they are only base64-encoded in the API. EKS encrypts etcd storage, and you can add envelope encryption with KMS, but anyone with RBAC `get secrets` can read them, so RBAC on Secrets matters.

**Q7. How do you get secrets from AWS Secrets Manager into a Pod?**
External Secrets Operator (or the Secrets Store CSI driver) reads them with an IAM role through Pod Identity/IRSA and creates a Kubernetes Secret. Git only references the secret's name.

**Q8. How do you rotate a database password safely?**
Create the new value in Secrets Manager, update the DB user (`ALTER USER`), let the sync pick it up and restart Pods if needed. For RDS, Secrets Manager rotation can automate it.

**Q9. Why least privilege on the ESO role?**
If ESO is compromised, the attacker gets only the secrets that role can read: one secret here, not all of Secrets Manager.
