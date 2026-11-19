# 05 — Production-Grade Secure EKS Project

Build **one real project** that uses everything from the Kubernetes notes Day 29 → Day 38: a 3-tier app (frontend → backend → MySQL) on EKS, set up the way a company runs it in production.

## About this project

| Item | Value |
|---|---|
| Goal | Take a plain EKS cluster and make it **production-grade**: HA, secure, observable, automated |
| App | frontend (nginx) → backend (Node.js) → MySQL (reused from [04-three-tier-gitops](../04-three-tier-gitops)) |
| Cluster | `abhigna-prod`, EKS **1.36**, `us-east-1`, 3 AZs |
| Infra tool | Terraform (copied from [01-eks-terraform](../01-eks-terraform) and upgraded) |
| Who builds it | Me, step by step. Every step ends with a ✅ Check |

## The 12 steps (and which notes each uses)

| # | Step | What I do | Notes it uses | Status |
|---|---|---|---|---|
| 01 | **Infrastructure** | Terraform: VPC, EKS 1.36, system + app node groups, Pod Identity agent, EBS CSI, ECR | Day 23, 26, 36, 38 | ⬜ |
| 02 | Secure images | Build, scan with Trivy, sign with Cosign, push to ECR | Day 32, 38 | ⬜ |
| 03 | RBAC + ServiceAccounts | dev/ops users, one ServiceAccount per app, `kubectl auth can-i` | Day 30, 31 | ⬜ |
| 04 | Pod hardening | securityContext (non-root, drop ALL), Pod Security Standards | Day 31 | ⬜ |
| 05 | Pod Identity | Backend reads the DB password from Secrets Manager, no keys | Day 36 | ⬜ |
| 06 | Kyverno | ECR only, no `:latest`, no static keys, signed images (Audit → Deny) | Day 36 | ⬜ |
| 07 | Istio | mTLS STRICT + AuthorizationPolicy (frontend → backend → db only) | Day 35 | ⬜ |
| 08 | High availability | Probes, HPA, PDB, topology spread, PriorityClass | Day 24, 34, 38 | ⬜ |
| 09 | GitOps + canary | Helm + Argo CD, Argo Rollouts canary, rollback | Day 23, 29 | ⬜ |
| 10 | Observability | Prometheus + Grafana, OpenTelemetry → Jaeger | Day 27, 33 | ⬜ |
| 11 | Break & fix | CrashLoopBackOff, ImagePullBackOff, OOMKilled, 502/503, Pending | Day 37 | ⬜ |
| 12 | Destroy | `terraform destroy`, add to resume log | Cost control | ⬜ |

> Only Step 01 is written out below. Each next step gets added here when I reach it.

## Where each command runs

```
💻 Laptop  : terraform, aws cli, git, docker
     │ ssh (abhigna-eks-key.pem)
     ▼
🖥️ Bastion : kubectl, helm  ──────►  ☸️ EKS cluster abhigna-prod
```

---

# Step 01 — Infrastructure

## Concepts

### Why do we need infrastructure first?

Kubernetes is only the **manager** of containers. It needs machines to run on. On AWS that means:

| Piece | What it is | Simple meaning |
|---|---|---|
| **VPC** | Your private network in AWS | The "building" everything lives in |
| **Public subnets** | Parts of the VPC that reach the internet | The "front door": load balancers, bastion, NAT |
| **Private subnets** | Parts with no direct internet access | The "back rooms": worker nodes live here, safe |
| **NAT gateway** | Lets private machines go **out** to the internet | Nodes can download images, but nobody can come **in** |
| **EKS control plane** | API server, etcd, scheduler, run by AWS | The "brain" (AWS manages it, we pay $0.10/hr) |
| **Worker nodes** | EC2 machines that run our Pods | The "hands" |
| **Bastion** | A small EC2 in the public subnet with kubectl/helm | My "jump box" to talk to the cluster |
| **ECR** | AWS's private image registry | Where my Docker images will be stored |

### Why Terraform and not clicking in the console?

| Console (clicking) | Terraform (code) |
|---|---|
| Hard to repeat exactly | `terraform apply` builds the same thing every time |
| No history | Code is in Git: every change is reviewed and saved |
| Deleting = clicking 30 things | `terraform destroy` removes everything → no surprise bill |

### Why copy `01-eks-terraform` instead of starting from zero?

`01-eks-terraform` (Day 23) already builds a **working** VPC + EKS + bastion. A basic cluster is not production-grade, so I copy it and **upgrade** it. This is exactly how real teams work: start from a known-good base, then improve.

### What changes from Day 23 → production (and why)

| # | Change | Day 23 (basic) | Now (production) | Why — from my notes |
|---|---|---|---|---|
| 1 | **EKS version** | 1.33 | **1.36** | 1.33 is in *extended support* = **$0.60/hr instead of $0.10/hr** (6× cost). Always stay on a standard-support version |
| 2 | **Names** | `abhigna-cluster` | `abhigna-prod` | New cluster, so it never clashes with the old lab |
| 3 | **kubectl on bastion** | v1.35 | v1.36 | kubectl must be within ±1 minor version of the cluster |
| 4 | **Node groups** | 1 group for everything | **system** + **app** | Day 38: add-ons (Argo CD, Kyverno, Prometheus) can't steal CPU/RAM from the app, and the reverse |
| 5 | **Taint on app nodes** | none | `workload=app:NoSchedule` | Day 26: only Pods with a matching toleration land on app nodes |
| 6 | **Pod Identity agent** | not installed | installed as add-on | Day 36: lets Pods get **temporary** AWS credentials (used in Step 05) |
| 7 | **IMDS hop limit** | default | **1** | Day 36 *node role trap*: a Pod can't reach the node's metadata and steal the node's IAM role |
| 8 | **Node access** | SSH key on nodes | **SSM** (`AmazonSSMManagedInstanceCore`) | No open SSH port, no key to leak; still lets me log in for `crictl` (Day 37) |
| 9 | **Node IAM** | many `FullAccess` policies | only what's needed | Least privilege (Day 38, 4C's Cloud layer) |
| 10 | **ECR repos** | Docker Hub | 2 ECR repos, **IMMUTABLE**, scan on push | Day 36 Kyverno: only ECR images, a tag can never be overwritten (no `:latest` tricks) |

### System vs app node groups (picture)

```
                 EKS cluster abhigna-prod
   ┌────────────────────────────┬──────────────────────────────┐
   │ system node group (2)      │ app node group (2)           │
   │ label role=system          │ label role=app               │
   │ no taint                   │ taint workload=app:NoSchedule│
   │                            │                              │
   │ CoreDNS, Argo CD, Kyverno, │ frontend, backend, mysql     │
   │ Prometheus, Istio          │ (they have the toleration)   │
   └────────────────────────────┴──────────────────────────────┘
```

> **Interview one-liner:** "I split nodes into a system group for cluster add-ons and a tainted app group for workloads, so a noisy add-on can never starve the application."

---

## Lab

### 1.1 Create the EC2 key pair — ✅ DONE

**What:** an SSH key pair. AWS keeps the public half, I keep the private half (`.pem`).
**Why:** the bastion is created with this key, so I can `ssh` into it.

```bash
aws ec2 create-key-pair --key-name abhigna-eks-key --region us-east-1 --query 'KeyMaterial' --output text > ~/.ssh/abhigna-eks-key.pem
```

```bash
chmod 400 ~/.ssh/abhigna-eks-key.pem
```

> `chmod 400` = only I can read it. `ssh` refuses a key that others can read. AWS shows the private key **only once**, never delete this file.

---

### 1.2 Copy the Day 23 Terraform — ✅ DONE

**What:** make a copy of the working Terraform into this project.
**Why:** keep `01-eks-terraform` untouched (it's my Day 23 reference) and upgrade the copy.

```bash
mkdir -p ~/k8s-eks-projects/05-production-eks
```

```bash
cp -r ~/k8s-eks-projects/01-eks-terraform ~/k8s-eks-projects/05-production-eks/terraform
```

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform
```

What I copied, file by file:

| File | What it creates |
|---|---|
| `providers.tf` | Tells Terraform to use AWS (and Kubernetes) and which region |
| `variables.tf` | The list of settings (names, sizes, CIDRs) with defaults |
| `terraform.tfvars` | **My values** for those settings (the only file I edit for names/versions) |
| `vpc.tf` | VPC, 3 public + 3 private subnets, NAT gateway |
| `eks.tf` | EKS control plane + worker node groups + add-ons |
| `bastion.tf` | Bastion EC2, its security group and IAM role |
| `bastion_bootstrap.sh.tpl` | Script that runs on the bastion's first boot: installs aws cli, kubectl, helm, sets kubeconfig |
| `outputs.tf` | Values printed after `apply` (cluster name, bastion IP, ssh command) |

---

### 1.3 (a) `terraform.tfvars` — new names and version

**What:** change 3 values.
**Why:** a new cluster name (no clash with the old lab) and a version in standard support (cheaper).

```bash
nano terraform.tfvars
```

| Find | Change to | Why |
|---|---|---|
| `project_name = "abhigna"` | `project_name = "abhigna-prod"` | Prefix for VPC and tags |
| `cluster_name    = "abhigna-cluster"` | `cluster_name    = "abhigna-prod"` | New cluster name |
| `cluster_version = "1.33"` | `cluster_version = "1.36"` | 1.33 = extended support = 6× price |

> Leave the `nodegroup_name` / `node_*` lines. They are not used any more, and Terraform does not complain about unused values.

How to check which versions are cheap (standard support):

```bash
aws eks describe-cluster-versions --region us-east-1 --query 'clusterVersions[].[clusterVersion,versionStatus]' --output text
```

---

### 1.3 (b) `bastion_bootstrap.sh.tpl` — kubectl version

**What:** install kubectl v1.36 on the bastion.
**Why:** kubectl and the cluster should be the same minor version (±1 allowed).

```bash
sed -i 's#v1.35.0/bin#v1.36.0/bin#' bastion_bootstrap.sh.tpl
```

```bash
grep -n "dl.k8s.io" bastion_bootstrap.sh.tpl
```

> `sed -i 's#old#new#'` = find and replace inside the file. The grep line should now show `v1.36.0`.

---

### 1.3 (c) `eks.tf` — add-ons and two node groups (the main change)

```bash
nano eks.tf
```

**Delete** everything from the line `cluster_addons = {` down to the closing `}` of `eks_managed_node_groups` (the old `abhigna-cluster-ng-1` block with `remote_access` and the `FullAccess` policies).

**Keep** everything above it (`cluster_name`, `access_entries`, `vpc_id`, `enable_irsa`) and below it (`cluster_security_group_additional_rules`, `kubernetes_cluster_role_binding`).

**Paste** this in the same place:

```hcl
  cluster_addons = {
    eks-pod-identity-agent = { most_recent = true, before_compute = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = ["m7i-flex.large"]
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
    }
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  eks_managed_node_groups = {
    system = {
      min_size     = 2
      max_size     = 4
      desired_size = 2
      labels       = { role = "system" }
    }
    app = {
      min_size     = 2
      max_size     = 4
      desired_size = 2
      labels       = { role = "app" }
      taints = {
        app = { key = "workload", value = "app", effect = "NO_SCHEDULE" }
      }
    }
  }
```

**Line by line:**

| Line | Meaning |
|---|---|
| `cluster_addons` | EKS add-ons that AWS installs and upgrades for me |
| `eks-pod-identity-agent` | DaemonSet that hands out temporary AWS credentials to Pods (Day 36) |
| `before_compute = true` | Install it **before** nodes join, so every node has it from the start |
| `aws-ebs-csi-driver` | Creates EBS disks when a PVC asks for storage (MySQL needs this) |
| `eks_managed_node_group_defaults` | Settings shared by **both** node groups (written once) |
| `ami_type = "AL2023_x86_64_STANDARD"` | Amazon Linux 2023 OS for the nodes |
| `instance_types = ["m7i-flex.large"]` | 2 vCPU, 8 GB RAM per node |
| `http_tokens = "required"` | IMDSv2 only (needs a session token, safer than v1) |
| `http_put_response_hop_limit = 1` | Metadata answer can't travel 1 extra hop into a Pod → Pods can't use the node's role |
| `AmazonSSMManagedInstanceCore` | Lets me log in to nodes with SSM Session Manager, no SSH |
| `AmazonEBSCSIDriverPolicy` | Lets the EBS CSI driver create disks. *For now on the node role; in Step 05 I move it to Pod Identity* |
| `system = { ... }` | Node group for add-ons, 2 nodes (can grow to 4) |
| `labels = { role = "system" }` | Label on the nodes → `kubectl get nodes -L role` shows it |
| `app = { ... }` | Node group for my app, 2 nodes |
| `taints = { ... NO_SCHEDULE }` | "Keep out" sign: only Pods with a matching toleration can be scheduled here |

> **Interview one-liner (hop limit):** "I set the IMDS hop limit to 1 so Pods can't fall back to the node's IAM role. Pods get AWS access only through Pod Identity."

---

### 1.3 (d) `outputs.tf` — fix one output

**What:** the output `nodegroup_name` pointed at the old single node group.
**Why:** that node group no longer exists, so print the new group names instead.

```bash
nano outputs.tf
```

Find `value = var.nodegroup_name` and change it to:

```hcl
  value       = keys(module.eks.eks_managed_node_groups)
```

> After `apply` this prints `["app", "system"]`.

---

### 1.3 (e) `ecr.tf` — my private image registry (new file)

**What:** 2 ECR repositories: `prod-frontend` and `prod-backend`.
**Why:** in production, images come from **my own** registry, not Docker Hub. Kyverno (Step 06) will block anything that is not from ECR.

```bash
nano ecr.tf
```

```hcl
resource "aws_ecr_repository" "app" {
  for_each             = toset(["prod-frontend", "prod-backend"])
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}
```

| Line | Meaning |
|---|---|
| `for_each = toset([...])` | Create one repo per name in the list (2 repos from 1 block) |
| `IMMUTABLE` | Once `v1` is pushed, nobody can push a different image as `v1` again |
| `force_delete = true` | `terraform destroy` can delete the repo even if images are inside |
| `scan_on_push = true` | ECR scans every pushed image for CVEs automatically |

---

### 1.4 Check the code (free, nothing is created yet)

```bash
terraform init
```

> Downloads the AWS provider and the VPC/EKS modules into `.terraform/`. If it fails with `connection reset by peer`, run it again.

```bash
terraform fmt
```

> Fixes spacing/indentation in all `.tf` files (neat code).

```bash
terraform validate
```

> Checks the code is correct (spelling, brackets, missing values). Must say **Success!**

---

### 1.5 Plan and apply (💰 cost starts here)

```bash
terraform plan
```

> Shows **what will be created** without creating anything. Read it: you should see the VPC, the EKS cluster, node groups `system` and `app`, the add-ons, 2 ECR repos and the bastion.

```bash
terraform apply
```

> Type `yes`. Takes about **20 minutes** (EKS control plane is the slow part).

---

### ✅ Check (🖥️ bastion)

Get the ssh command from the outputs:

```bash
terraform output bastion_ssh_command
```

```bash
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-public-ip>
```

```bash
kubectl get nodes -L role
```

> 4 nodes: 2 with `role=system`, 2 with `role=app`, all `Ready`.

```bash
kubectl describe nodes -l role=app | grep Taints
```

> Both app nodes show `workload=app:NoSchedule`.

```bash
kubectl get pods -n kube-system
```

> `eks-pod-identity-agent-*` and `ebs-csi-*` Pods are `Running`.

```bash
aws ecr describe-repositories --query 'repositories[].repositoryName' --output text
```

> `prod-frontend  prod-backend`

---

## Cost

| What | Approx. per hour |
|---|---|
| EKS control plane (standard support) | $0.10 |
| 4 × m7i-flex.large nodes + bastion (~$0.096 each) | ~$0.48 |
| NAT gateway | ~$0.045 + data |
| **Total** | **~$0.63/hr (~$15/day)** |

Stop for the day? Run this from the terraform folder on the laptop:

```bash
terraform destroy
```

## Interview Questions

### ⭐ Very Important

**Q1. Why do you separate system and app node groups?**
So cluster add-ons (CoreDNS, Argo CD, monitoring) and the application don't fight for CPU/RAM. The app group is tainted, so only app Pods with a toleration land there.

**Q2. Why are worker nodes in private subnets?**
Nobody on the internet can reach them directly. They go out through the NAT gateway; users come in only through the load balancer.

**Q3. Why should you avoid EKS versions in extended support?**
The control plane costs 6× more ($0.60/hr vs $0.10/hr) and you are running an old version. Upgrade regularly.

### Other Questions

**Q4. What does IMDS hop limit 1 protect against?**
A Pod reading the node's instance metadata and using the node's IAM role. With hop limit 1 the answer never reaches the Pod.

**Q5. Why ECR with immutable tags?**
Images stay in my AWS account, are scanned on push, and a tag like `v1` always means the same image, so deployments are repeatable.

**Q6. Why SSM instead of SSH keys on nodes?**
No port 22 open, no key to lose or leak, and every session is logged in AWS.
