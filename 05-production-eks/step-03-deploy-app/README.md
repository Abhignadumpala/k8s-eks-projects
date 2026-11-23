# Step 03 — Deploy the App: Helm, EBS Storage and an ALB

[⬅ Back to the project overview](../README.md) · [⬅ Step 02](../step-02-secure-images/README.md) · [Step 04 ➡](../step-04-rbac/README.md)

## What you will build in this step

The 3-tier app running on the **app nodes**, with its database on an **encrypted EBS disk**, reachable from the internet through an **Application Load Balancer (ALB)**.

```
Browser
   │ http://<alb-dns-name>
   ▼
ALB (public subnets)   ◄── created by the AWS Load Balancer Controller (system nodes)
   │ target-type ip: straight to the Pod IPs
   ▼
┌──────────────── namespace three-tier · app nodes ────────────────┐
│ frontend ×2 (nginx)  ──/api──►  backend ×2 (Node.js)  ──►  mysql-0 │
│                                                             │     │
│                                         PVC data-mysql-0 ──► EBS gp3 (encrypted)
└───────────────────────────────────────────────────────────────────┘
```

| Item | Value |
|---|---|
| Needs | Step 01 cluster running, Step 02 images in ECR |
| Runs on | 💻 Laptop (Terraform) + 🖥️ Bastion (kubectl, helm) |
| New AWS resources | IAM role + policy for the Load Balancer Controller (Pod Identity), 1 ALB, 1 EBS volume |
| Extra cost | ALB ~$0.025/hr, EBS 5 GB ~$0.40/month |
| Time | ~45 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### What is Helm?

**Definition:** **Helm** is the **package manager for Kubernetes**. Like `apt` or `yum` for Linux, but it installs whole apps into a cluster.

- Our app needs **12 template files** (Deployments, Services, Ingress, StatefulSet…).
- Without Helm you `kubectl apply` each file and edit values by hand in many places.
- With Helm you install **all of them with one command**, and change settings in **one file** (`values.yaml`).

**Analogy 🍰:** the **chart** is a cake recipe with blanks ("___ eggs"), the **values** are the amounts you choose, and the **release** is the cake you baked.

```
helm/three-tier/  (chart)        values.yaml            helm install
┌──────────────────────┐        ┌────────────────┐     ┌──────────────────────┐
│ templates/*.yaml     │   +    │ replicas: 2    │ ──► │ release "three-tier" │
│ replicas: {{ ___ }}  │        │ image: v1      │     │ running in the cluster│
└──────────────────────┘        └────────────────┘     └──────────────────────┘
   recipe with blanks             your amounts            the baked cake 🎂
```

| Word | Meaning | Example |
|---|---|---|
| **Chart** | The package (templates + default values) | `helm/three-tier` |
| **Values** | Settings that fill the templates | `backend.replicas: 2` |
| **Release** | One installed copy of a chart | `three-tier` in namespace `three-tier` |
| **`helm upgrade --reuse-values --set x=y`** | Change one setting, keep the others | Turn on a feature in a later step |

| | Plain `kubectl apply` | **Helm** |
|---|---|---|
| Install 12 files | Apply each one (or a folder) | 1 command ✅ |
| Change replicas / image | Edit YAML in many places ❌ | One value ✅ |
| Undo a bad change | Find old files by hand ❌ | `helm rollback` ✅ |
| Same app for dev + prod | Copy all files ❌ | Same chart, different values ✅ |

> **Interview one-liner:** "Helm packages Kubernetes YAML into a chart with templates and values, so we install, upgrade and roll back the whole app with one command."

### The AWS Load Balancer Controller

**Definition:** the **AWS Load Balancer Controller** is a program running inside the cluster. When you create an **Ingress**, it creates a real **ALB** (Application Load Balancer) in AWS for you.

**Why we need it:**
- An **Ingress** is only a **rule written on paper**: *"send website traffic to the frontend"*.
- Kubernetes itself **can't build** a load balancer in AWS.
- The **controller reads the rule** and **builds the ALB** in AWS.

**Analogy 🏠:** the Ingress is the **house plan**, the controller is the **builder**, and the ALB is the **real house**. A plan with no builder stays on paper.

| Thing | Who | Job |
|---|---|---|
| **Ingress** | You (YAML) | Says *what* you want: "traffic for `/` → frontend" |
| **LB Controller** | Pod in the cluster | Sees the Ingress, calls AWS |
| **ALB** | AWS | The real load balancer users hit from the internet |

```
You write Ingress ──► Controller sees it ──► asks AWS ──► ALB is created 🌐
                      (needs AWS permission → Pod Identity role from Terraform)
```

> **Interview one-liner:** "An Ingress is just a rule; the AWS Load Balancer Controller watches Ingresses and creates the ALB in AWS."

#### Our ALB settings

| Setting | Our value | Why |
|---|---|---|
| `scheme: internet-facing` | Public ALB | Users on the internet reach the app. It lands in the **public** subnets (tag `kubernetes.io/role/elb`, Step 01) |
| `target-type: ip` | Pod IPs | The ALB talks straight to the Pods (no extra node hop) |
| `healthcheck-path: /healthz` | nginx answers `ok` | The ALB sends traffic only to healthy Pods |

**`target-type: ip` vs `instance`:**

```
instance:  ALB ──► node:30080 (NodePort) ──► kube-proxy ──► Pod     (2 hops)
ip:        ALB ─────────────────────────────────────────► Pod IP    (1 hop) ✅
```

#### Why the controller needs `--set vpcId`

**IMDS (Instance Metadata Service)** = a small web address on every EC2 server (`169.254.169.254`) that answers "which VPC am I in? what are my AWS keys?".

- Normally the controller **asks IMDS** "which VPC am I in?".
- In Step 01 we **blocked Pods from IMDS** (hop limit 1), so a hacked Pod can't steal the node's AWS keys.
- So the controller can't ask anymore → we **tell it the VPC ID** directly with `--set vpcId`.

**Analogy 🏨:** IMDS is the hotel front desk. We locked the desk so guests (Pods) can't grab the master key, so we hand the controller its room number ourselves.

| | IMDS open to Pods | **IMDS blocked (our setup)** |
|---|---|---|
| Controller finds VPC | Asks IMDS by itself | We pass `--set vpcId` |
| Hacked Pod steals node's AWS keys | Possible ❌ | Blocked ✅ |

> **Interview one-liner:** "We block Pods from IMDS so they can't steal the node's IAM credentials; the LB Controller then needs the VPC ID passed in, which is normal in hardened clusters."

### Storage: StorageClass → PVC → PV → EBS

**Definition:** a Pod's own files are **deleted when the Pod dies**. MySQL needs a disk that **survives restarts**. Kubernetes gets one from AWS (an **EBS volume**) through 3 objects.

- **StorageClass** = the menu: "what kind of disk can I order?" (gp3, encrypted).
- **PVC (PersistentVolumeClaim)** = the order: "I need **5 GiB** of gp3".
- **PV (PersistentVolume)** = the real disk you got. The **EBS CSI driver** (add-on from Step 01) creates it in AWS.

**Analogy 🍕:** StorageClass = the **menu**, PVC = your **order**, PV = the **pizza that arrives**, EBS CSI driver = the **kitchen**.

```
StatefulSet volumeClaimTemplate ──► PVC data-mysql-0 (I need 5 GiB, class gp3)
                                          │ EBS CSI driver (add-on from Step 01)
                                          ▼
                                   PV + EBS gp3 volume, encrypted, in the SAME AZ as mysql-0
```

| Object | Meaning |
|---|---|
| **StorageClass `gp3`** | The "type of disk" menu: EBS gp3, encrypted, created in the Pod's AZ (`WaitForFirstConsumer`) |
| **PVC** | A request: "I need 5 GiB of gp3" |
| **PV** | The real disk Kubernetes got for that request |

| | No PVC (Pod's own disk) | **PVC + EBS** |
|---|---|---|
| Pod restarts | Data **lost** ❌ | Data **kept** ✅ |
| Where data lives | Inside the container | Separate EBS disk in AWS |

**Why the chart creates `gp3`:** a new EKS cluster has **no default StorageClass** (no "default disk type"). Without one, a PVC asking for a disk just waits in `Pending` and MySQL never starts. So our Helm chart creates the `gp3` StorageClass itself.

> **Interview one-liner:** "A PVC asks for storage, the StorageClass says what kind, and the EBS CSI driver creates the real EBS volume as a PV, so the database keeps its data when the Pod restarts."

#### ⚠️ An EBS disk is stuck in one AZ

**AZ (Availability Zone)** = one separate AWS data center in the region. Our cluster uses 3: `us-east-1a`, `1b`, `1c`.

- An **EBS volume** is like a **hard disk plugged into one building**. It can only connect to a server (node) in **that same AZ**.
- So if the `mysql-0` Pod moves (node dies, upgrade), it can only restart on a node **in the same AZ as its disk**.
- If that whole AZ goes down, **MySQL is down** until the AZ comes back, even though the other 2 AZs are fine.

```
us-east-1a            us-east-1b            us-east-1c
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│ mysql-0     │       │ node ✅      │       │ node ✅      │
│ EBS disk 💾 │  ✗──► │ can't use   │       │ can't use   │
│ (stuck here)│       │ the disk    │       │ the disk    │
└─────────────┘       └─────────────┘       └─────────────┘
   AZ down = DB down
```

**What production does instead: Amazon RDS Multi-AZ**

| | MySQL in a Pod + EBS (this lab) | **RDS Multi-AZ** (production) |
|---|---|---|
| Copies of the data | 1 disk, 1 AZ | Primary in one AZ + **standby copy in another AZ** |
| AZ goes down | DB down ❌ | AWS **switches to the standby automatically** (about 1–2 min) ✅ |
| Backups, patching | You do it | AWS does it |
| Why we use it here | Learn StatefulSet, PVC, EBS | — |

> **Interview one-liner:** "An EBS volume lives in one AZ, so a database Pod using it can't fail over to another AZ. In production we use RDS Multi-AZ, which keeps a standby copy in a second AZ and fails over automatically."

### The DB password in this step

**Definition:** a **Kubernetes Secret** is an object that holds passwords or keys, so they are **not written inside** the app's YAML or image.

- The app needs a Secret called **`mysql-secret`** (MySQL root + app passwords).
- In this step **you create it by hand** with random passwords, **straight into the cluster**.
- It's **never saved to a file or Git**, so nobody can find it in the repo.

**Analogy 🔑:** the Secret is a **locked key box** on the wall. The app takes the key from the box; the key is never printed on the door.

```
openssl rand ──► kubectl create secret mysql-secret ──► mysql + backend Pods read it
 (random pw)       (only inside the cluster)              (as env variables)
```

| | Step 03 (now) | **Step 06** (production way) |
|---|---|---|
| Where the password lives | Only in the cluster | **AWS Secrets Manager** |
| Who creates it | You, by hand | External Secrets syncs it automatically |
| Rotate / audit | Hard ❌ | Easy, logged in AWS ✅ |

> **Interview one-liner:** "Passwords go in a Kubernetes Secret, never in Git; in production we sync them from AWS Secrets Manager."

## 1.2 The code, file by file

### `terraform/platform_iam.tf` (the Load Balancer Controller part)

```hcl
resource "aws_iam_policy" "lb_controller" {
  count  = var.enable_lb_controller ? 1 : 0
  name   = "${var.cluster_name}-aws-load-balancer-controller"
  policy = file("${path.module}/iam/aws-load-balancer-controller-policy.json")
}

resource "aws_iam_role" "lb_controller" {
  count              = var.enable_lb_controller ? 1 : 0
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  count           = var.enable_lb_controller ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller[0].arn
}
```

| Line | Explained |
|---|---|
| `count = var.enable_lb_controller ? 1 : 0` | An **on/off switch**: 0 copies when false (Step 01), 1 copy when true |
| `file(".../iam/aws-load-balancer-controller-policy.json")` | The **official** policy for controller v3.6.3, saved in the repo so it always matches the version we install |
| `assume_role_policy = ...pod_identity_trust` | Trust: *"the EKS Pod Identity service (`pods.eks.amazonaws.com`) may give this role to a Pod"* |
| `aws_eks_pod_identity_association` | The link: Pods using ServiceAccount `kube-system/aws-load-balancer-controller` get this role |
| `[0]` | Because of `count`, the resource is a list; `[0]` is the first (only) copy |

### `platform/values/aws-load-balancer-controller.yaml`

```yaml
clusterName: abhigna-prod
region: us-east-1
replicaCount: 2
serviceAccount:
  create: true
  name: aws-load-balancer-controller
```

| Line | Explained |
|---|---|
| `clusterName` | Which cluster's Ingresses to manage (also used to tag the ALB) |
| `region` | Pods can't read it from IMDS, so we set it |
| `replicaCount: 2` | Two copies on the system nodes: one can fail |
| `serviceAccount.name` | **Must match** the Pod Identity association, or the controller gets no AWS permissions |

### `platform/k8s/namespace.yaml`

Creates `three-tier` with **Pod Security Standards = restricted** labels. Step 05 explains them; the chart is already built to pass them.

### The Helm chart `helm/three-tier`

| File | Creates | Key points |
|---|---|---|
| `values.yaml` | — | All settings. `global.registry` is empty on purpose: you pass your ECR address with `--set`, so your account ID never goes into Git |
| `templates/_helpers.tpl` | — | Shared snippets: labels, image name, **app-node scheduling**, **AZ spreading**, **security settings** |
| `templates/serviceaccounts.yaml` | 3 ServiceAccounts | One identity per tier, `automountServiceAccountToken: false` (Step 04) |
| `templates/frontend.yaml` | Deployment + Service | nginx as uid 101, read-only filesystem, `/tmp` and `/etc/nginx/conf.d` as small writable folders |
| `templates/ingress.yaml` | Ingress | Becomes the ALB |
| `templates/backend.yaml` | ConfigMap + Deployment + Service | DB host/user from the ConfigMap, password from `mysql-secret`; readiness = DB reachable |
| `templates/mysql.yaml` | headless Service + StatefulSet | uid 999, data in `/var/lib/mysql/data` on the EBS disk |
| `templates/storageclass.yaml` | StorageClass `gp3` | Encrypted gp3, created in the Pod's AZ |
| `templates/ha.yaml` | 2 PodDisruptionBudgets (+ HPA later) | Step 09 |
| `templates/externalsecret.yaml`, `mesh.yaml`, `servicemonitor.yaml` | nothing yet | Switched off until Steps 06, 08, 11 |

The scheduling snippet every app Pod gets:

```yaml
nodeSelector:
  role: app                    # must go to app nodes
tolerations:
  - key: workload              # the "pass" for the app-node taint
    operator: Equal
    value: app
    effect: NoSchedule
```

The image name is built like this, and the install **fails on purpose** if you forget the registry:

```
{{ required "Set global.registry ..." .Values.global.registry }}/prod-backend:v1
   → 123456789012.dkr.ecr.us-east-1.amazonaws.com/prod-backend:v1
```

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Turn on the LB Controller role         💻 laptop   terraform apply
Task 2  Get the code on the bastion            🖥️ bastion
Task 3  Install the AWS Load Balancer Controller 🖥️
Task 4  Create the namespace and the DB secret  🖥️
Task 5  Install the app with Helm               🖥️
Task 6  Open the app and test it                🖥️ + browser
```

---

## Task 1 — Turn on the LB Controller role

📍 **Where:** 📝 VS Code, then 💻 Terminal in `05-production-eks/terraform`

**Why:** the controller needs AWS permissions to create ALBs.

▶️ **Do:** in `terraform/terraform.tfvars`, change:

```hcl
enable_lb_controller    = true  # Step 03
```

> Alternative with sed: `sed -i 's/^enable_lb_controller *= false/enable_lb_controller    = true/' terraform.tfvars`

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform
```

```bash
terraform apply
```

✅ **Check:** the plan says **`Plan: 4 to add, 0 to change, 0 to destroy.`** (policy, role, attachment, Pod Identity association). Type `yes`.

---

## Task 2 — Get the code on the bastion

📍 **Where:** 💻 Terminal → 🖥️ Bastion

▶️ **Do:** log in (Step 01, Task 7):

```bash
terraform output -raw bastion_ssh_command
```

Run the printed `ssh ...` command. Then on the bastion:

```bash
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git ~/k8s-eks-projects
```

> Already cloned? `cd ~/k8s-eks-projects && git pull`

Save 2 values **once** in `~/.bashrc`, so every new login has them (they stay on the bastion, not in Git):

```bash
echo "export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)" >> ~/.bashrc
```

```bash
echo 'export ECR=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com' >> ~/.bashrc
```

```bash
source ~/.bashrc && echo $ECR
```

✅ **Check:** prints `<your-account-id>.dkr.ecr.us-east-1.amazonaws.com`.

---

## Task 3 — Install the AWS Load Balancer Controller

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update
```

The VPC ID (the controller can't read it from IMDS):

```bash
VPC_ID=$(aws eks describe-cluster --name abhigna-prod --region us-east-1 --query cluster.resourcesVpcConfig.vpcId --output text) && echo $VPC_ID
```

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 -n kube-system -f ~/k8s-eks-projects/05-production-eks/platform/values/aws-load-balancer-controller.yaml --set vpcId=$VPC_ID
```

✅ **Check:**

```bash
kubectl get deploy aws-load-balancer-controller -n kube-system
```

> ✅ `READY 2/2` (wait ~1 minute).

Prove it uses **Pod Identity** (not the node's role):

```bash
kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o yaml | grep -A1 AWS_CONTAINER_CREDENTIALS_FULL_URI
```

> ✅ Shows `value: http://169.254.170.23/v1/credentials`: the **Pod Identity agent** on the node hands out the role's credentials.

---

## Task 4 — Create the namespace and the DB secret

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/namespace.yaml
```

Create `mysql-secret` with 2 random passwords. They go straight into the cluster: not in a file, not in Git, not on screen:

```bash
kubectl create secret generic mysql-secret -n three-tier --from-literal=password=$(openssl rand -hex 16) --from-literal=root-password=$(openssl rand -hex 16)
```

✅ **Check:**

```bash
kubectl get ns three-tier --show-labels && kubectl get secret mysql-secret -n three-tier
```

> ✅ Labels include `pod-security.kubernetes.io/enforce=restricted`; the secret shows `DATA 2`.

---

## Task 5 — Install the app with Helm

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks
```

```bash
helm install three-tier ./helm/three-tier -n three-tier --set global.registry=$ECR
```

Watch the Pods start (`Ctrl+C` to stop watching):

```bash
kubectl get pods -n three-tier -o wide -w
```

> MySQL needs ~1 minute (new EBS disk + first start). The backend shows `0/1 Running` until MySQL is ready: that's the **readiness probe** working.

✅ **Check:**

```bash
kubectl get pods -n three-tier -o wide
```

> ✅ `frontend` ×2, `backend` ×2, `mysql-0`: all `1/1 Running`. The `NODE` column shows only your 2 **app** nodes.

```bash
kubectl get pvc -n three-tier
```

> ✅ `data-mysql-0   Bound   ...   5Gi   RWO   gp3`

---

## Task 6 — Open the app and test it

📍 **Where:** 🖥️ Bastion, then your browser

▶️ **Do:**

```bash
kubectl get ingress frontend -n three-tier
```

> The `ADDRESS` is like `k8s-threetie-frontend-xxxx.us-east-1.elb.amazonaws.com`. A new ALB needs **2–3 minutes** before it answers.

```bash
curl -s http://$(kubectl get ingress frontend -n three-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/api/health
```

> ✅ `{"status":"ok","version":"v1"}`

Open `http://<ADDRESS>` in your browser and add 2 tasks.

**Test the database disk:** delete the MySQL Pod. The StatefulSet recreates it with the **same** disk:

```bash
kubectl delete pod mysql-0 -n three-tier
```

```bash
kubectl get pods -n three-tier -w
```

> Wait for `mysql-0 1/1 Running` (~1 minute), then refresh the browser.

✅ **Check:** your 2 tasks are still there. The data lives on EBS, not in the Pod.

🎉 **Step 03 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| Ingress `ADDRESS` stays empty | The controller can't create the ALB | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` · `AccessDenied` → Task 1 not applied or ServiceAccount name mismatch · `couldn't auto-discover subnets` → public subnet tags missing (Step 01 `vpc.tf`) |
| Helm: `Set global.registry` error | `$ECR` empty in this shell | `source ~/.bashrc` (Task 2) |
| Pods `ImagePullBackOff` | Wrong image name/tag, or images not pushed | `kubectl describe pod <name> -n three-tier` → Events. Repeat Step 02 Tasks 4–8 |
| Pods `Pending` | No space on the app nodes, or missing toleration | `kubectl describe pod` → Events: `Insufficient cpu` / `untolerated taint` |
| `mysql-0` `CrashLoopBackOff` | Data folder from an old, different password | Lab fix: `helm uninstall three-tier -n three-tier`, `kubectl delete pvc data-mysql-0 -n three-tier`, install again |
| `backend 0/1 Running` for a long time | MySQL not ready or wrong password | `kubectl logs deploy/backend -n three-tier` |
| PVC `Pending` | EBS CSI driver not running | `kubectl get pods -n kube-system \| grep ebs` |
| Browser: 503 | ALB has no healthy targets yet | Wait 2 min; check frontend Pods are Ready |

## Interview Questions

### Other Questions

**Q1. How does an Ingress become an ALB on EKS?**
The AWS Load Balancer Controller watches Ingress objects and calls the AWS API to create an ALB, listeners and target groups. It needs IAM permissions, which we give through Pod Identity.

**Q2. Target type `ip` vs `instance`?**
`ip` sends traffic straight to Pod IPs (VPC CNI gives Pods real VPC IPs). `instance` goes to a NodePort on every node, then kube-proxy forwards it: an extra hop.

**Q3. Why does MySQL use a StatefulSet?**
Stable name (`mysql-0`), stable DNS, and its own PVC that follows it when the Pod is recreated.

**Q4. What is `WaitForFirstConsumer`?**
The EBS volume is created only when the Pod is scheduled, in the same AZ as that Pod. Otherwise the disk might be created in an AZ where the Pod can't run.

**Q5. Why is the ECR registry not in `values.yaml`?**
It contains the AWS account ID. It's passed at install time (`--set` / the Argo CD Application), so the public Git repo holds no account details.

**Q6. What does `helm upgrade --reuse-values --set x=true` do?**
Upgrades the release, keeping all previous values and changing only `x`.
