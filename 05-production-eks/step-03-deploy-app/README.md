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

**Definition:** the package manager for Kubernetes. A **chart** is a folder of YAML templates with blanks, plus a `values.yaml` that fills the blanks.

| Word | Meaning | Example |
|---|---|---|
| **Chart** | The package (templates + default values) | `helm/three-tier` |
| **Values** | Settings that fill the templates | `backend.replicas: 2` |
| **Release** | One installed copy of a chart | `three-tier` in namespace `three-tier` |
| **`helm upgrade --reuse-values --set x=y`** | Change one setting, keep the others | Turn on a feature in a later step |

**Analogy 🍰:** the chart is a cake recipe with blanks ("___ eggs"), values are the amounts you choose, a release is the cake you baked.

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

| Setting | Our value | Why |
|---|---|---|
| `scheme: internet-facing` | Public ALB | Users on the internet reach the app. It lands in the **public** subnets (tag `kubernetes.io/role/elb`, Step 01) |
| `target-type: ip` | Pod IPs | The ALB talks straight to the Pods (no extra node hop) |
| `healthcheck-path: /healthz` | nginx answers `ok` | The ALB sends traffic only to healthy Pods |

**Why does the controller need `--set vpcId`?** It would normally ask the node's metadata service (IMDS) for the VPC. We blocked Pods from IMDS (hop limit 1, Step 01), so we tell it directly. That's the price of the security setting, and it's normal in production.

### Storage: StorageClass → PVC → PV → EBS

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

EKS has **no default StorageClass**, so the chart creates `gp3`.

> ⚠️ An EBS volume lives in **one AZ**. If `mysql-0` moves, it can only go to a node in that same AZ. That's one reason production uses **Amazon RDS Multi-AZ** for databases.

### The DB password in this step

The app needs a Kubernetes Secret called `mysql-secret`. In this step **you create it by hand** with random passwords, straight into the cluster: it's never written to a file or Git. In **Step 06** we replace this with AWS Secrets Manager.

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
