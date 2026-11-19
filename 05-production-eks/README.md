# Production-Grade EKS Project (Beginner Friendly, Step by Step)

Build a **production-style Kubernetes cluster on AWS (EKS)** and deploy a 3-tier app on it: **frontend → backend → MySQL**.
Every step explains **what** you are doing and **why**, so you can follow it even if this is your first EKS project.

## About this project

| Item | Value |
|---|---|
| Goal | Go from a basic EKS cluster to a **production-grade** one: highly available, secure, monitored, automated |
| App | frontend (nginx) → backend (Node.js API) → MySQL database |
| Cloud | AWS, region `us-east-1` (N. Virginia), spread across 3 Availability Zones |
| Kubernetes | Amazon EKS, version **1.36** |
| Infra tool | Terraform (infrastructure as code) |
| Level | Beginner → intermediate. You should know basic Linux commands and what a container is |
| Cost | About **$0.63 per hour** while the cluster is running. Destroy it when you stop (Step 12) |

## The roadmap (12 steps)

| # | Step | What you do | Topic you learn |
|---|---|---|---|
| 01 | **Infrastructure** | Create the network, EKS cluster, worker nodes and image registry with Terraform | VPC, EKS, node groups, taints, add-ons |
| 02 | Secure images | Build images, scan them, sign them, push to ECR | Supply chain security (Trivy, Cosign) |
| 03 | RBAC + ServiceAccounts | Give people and apps only the permissions they need | RBAC, ServiceAccounts |
| 04 | Pod hardening | Run containers as non-root with minimal privileges | securityContext, Pod Security Standards |
| 05 | Pod Identity | Backend reads the DB password from AWS Secrets Manager, with no keys in code | EKS Pod Identity |
| 06 | Policy guardrails | Block images not from ECR, `:latest` tags, hard-coded keys, unsigned images | Kyverno |
| 07 | Service mesh | Encrypt traffic between services and allow only frontend → backend → db | Istio mTLS |
| 08 | High availability | App keeps running when a Pod, a node or a whole AZ fails | Probes, HPA, PDB, topology spread |
| 09 | GitOps + canary | Git push → Argo CD deploys → new version goes to 10% of users first | Argo CD, Argo Rollouts |
| 10 | Observability | Metrics, dashboards and request tracing | Prometheus, Grafana, OpenTelemetry |
| 11 | Break & fix | Break the app on purpose and fix it | CrashLoopBackOff, ImagePullBackOff, 502/503 |
| 12 | Clean up | Delete everything so you stop paying | `terraform destroy` |

> Step 01 is below. The next steps are added to this guide one by one.

## Where each command runs

You use **two machines**:

```
💻 Your laptop
   │  terraform, aws cli   → creates everything in AWS
   │
   │  ssh (with your .pem key)
   ▼
🖥️ Bastion (a small EC2 created by Terraform)
   │  kubectl, helm        → already installed for you
   ▼
☸️ EKS cluster
```

| Where | What runs there |
|---|---|
| 💻 Laptop | `terraform`, `aws`, `git`, `docker` |
| 🖥️ Bastion | `kubectl`, `helm` (it has access to the cluster) |

---

# Step 01 — Infrastructure

## What you will build in this step

```
                         AWS region us-east-1
 ┌─────────────────────────── VPC 10.0.0.0/16 ───────────────────────────┐
 │                                                                        │
 │   AZ us-east-1a          AZ us-east-1b          AZ us-east-1c          │
 │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │
 │  │ public subnet│       │ public subnet│       │ public subnet│        │
 │  │ bastion, NAT │       │ (load        │       │ (load        │        │
 │  │              │       │  balancers)  │       │  balancers)  │        │
 │  └──────────────┘       └──────────────┘       └──────────────┘        │
 │  ┌──────────────┐       ┌──────────────┐       ┌──────────────┐        │
 │  │private subnet│       │private subnet│       │private subnet│        │
 │  │ worker nodes │       │ worker nodes │       │ worker nodes │        │
 │  └──────────────┘       └──────────────┘       └──────────────┘        │
 └────────────────────────────────────────────────────────────────────────┘
        + EKS control plane (run by AWS)   + 2 ECR repositories
```

## Concepts (read this first)

### The pieces, in simple words

| Piece | What it is | Think of it as |
|---|---|---|
| **VPC** | Your own private network inside AWS | The building everything lives in |
| **Availability Zone (AZ)** | A separate data center inside a region | Different floors of the building: if one floor loses power, the others keep working |
| **Public subnet** | Part of the VPC that can talk to the internet | The front door: load balancers and the bastion |
| **Private subnet** | Part of the VPC with no direct internet access | Back rooms: worker nodes live here, safe from the internet |
| **NAT gateway** | Lets private machines go **out** to the internet | Nodes can download images, but nobody outside can come **in** |
| **EKS control plane** | The Kubernetes "brain" (API server, etcd, scheduler), run by AWS | The manager. AWS takes care of it; you pay $0.10/hour |
| **Worker nodes** | EC2 machines where your Pods actually run | The workers |
| **Node group** | A group of identical worker nodes managed together | A team of workers with the same job |
| **Bastion** | A small EC2 in the public subnet with `kubectl` and `helm` | Your jump box to reach the cluster |
| **ECR** | Elastic Container Registry: AWS's private image storage | Your private Docker Hub |
| **Add-on** | Extra software that EKS installs and upgrades for you | Plug-ins for the cluster |

### What is Terraform, and why use it?

**Terraform** = a tool where you **write your infrastructure as code** (`.tf` files) and Terraform creates it in AWS for you.

| Clicking in the AWS console | Terraform |
|---|---|
| Hard to repeat exactly the same way | `terraform apply` builds the same thing every time |
| No history of what changed | Code lives in Git: every change is saved and reviewed |
| Deleting = clicking 30 screens, easy to forget something | `terraform destroy` deletes everything, so no surprise bill |

The 4 Terraform commands you will use:

| Command | What it does | Costs money? |
|---|---|---|
| `terraform init` | Downloads the plugins and modules the code needs | No |
| `terraform validate` | Checks the code for mistakes | No |
| `terraform plan` | Shows what **would** be created (a preview) | No |
| `terraform apply` | Actually creates everything in AWS | **Yes** |

### Basic cluster vs production cluster

This project starts from a **basic, working** Terraform setup ([01-eks-terraform](../01-eks-terraform)) and upgrades it. Here is what changes and why:

| # | Topic | Basic setup | Production setup | Why it matters |
|---|---|---|---|---|
| 1 | **EKS version** | 1.33 | **1.36** | Old versions go into *extended support* and the control plane costs **$0.60/hr instead of $0.10/hr** (6×) |
| 2 | **Cluster name** | `abhigna-cluster` | `abhigna-prod` | A new name, so it never clashes with an older cluster |
| 3 | **kubectl version** | 1.35 | 1.36 | `kubectl` should match the cluster version (±1 is allowed) |
| 4 | **Node groups** | 1 group runs everything | **system** group + **app** group | Cluster tools (monitoring, Argo CD) can't steal CPU/RAM from your app, and the other way round |
| 5 | **Taint on app nodes** | none | `workload=app:NoSchedule` | A "keep out" sign: only app Pods are allowed on app nodes |
| 6 | **Pod Identity agent** | not installed | installed | Lets Pods get **temporary** AWS access instead of storing access keys (used in Step 05) |
| 7 | **Instance metadata (IMDS)** | default | IMDSv2, hop limit **1** | Stops a Pod from secretly using the node's AWS permissions |
| 8 | **Logging in to nodes** | SSH key | **SSM Session Manager** | No open SSH port and no key that can leak |
| 9 | **Node permissions** | many `FullAccess` policies | only what is needed | *Least privilege*: if a node is hacked, the attacker gets very little |
| 10 | **Image registry** | Docker Hub | **ECR**, immutable tags, scan on push | Images stay in your own AWS account and are scanned for vulnerabilities |

### System vs app node groups

```
                    EKS cluster abhigna-prod
   ┌─────────────────────────────┬────────────────────────────────┐
   │ SYSTEM node group (2 nodes) │ APP node group (2 nodes)       │
   │ label: role=system          │ label: role=app                │
   │ no taint                    │ taint: workload=app:NoSchedule │
   │                             │                                │
   │ CoreDNS, Argo CD, Kyverno,  │ frontend, backend, mysql       │
   │ Prometheus, Istio           │ (only Pods with a matching     │
   │                             │  "toleration" can come here)   │
   └─────────────────────────────┴────────────────────────────────┘
```

| Word | Meaning |
|---|---|
| **Label** | A tag on a node, like `role=app`. Used to find or select nodes |
| **Taint** | A "keep out" rule on a node. Pods are refused unless they have a matching **toleration** |
| **Toleration** | A "pass" in the Pod's YAML that lets it ignore a taint |

### What is IMDS and why hop limit 1?

**IMDS (Instance Metadata Service)** = a special address (`169.254.169.254`) every EC2 machine can call to get information about itself, **including temporary AWS credentials of the node's IAM role**.

The problem: a Pod running on the node can call the same address and **borrow the node's permissions**.

```
hop limit 2 (risky):  Pod ──► node ──► IMDS  ✅ answer reaches the Pod
hop limit 1 (safe):   Pod ──► node ──► IMDS  ❌ answer stops at the node
```

> **Interview one-liner:** "I set the IMDS hop limit to 1 so Pods can't use the node's IAM role. Pods get AWS access only through Pod Identity, each with its own role."

---

## Before you start

### Tools on your laptop

| Tool | Check command | Install guide |
|---|---|---|
| AWS CLI v2 | `aws --version` | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| Terraform ≥ 1.5 | `terraform -version` | https://developer.hashicorp.com/terraform/install |
| Git | `git --version` | https://git-scm.com/downloads |

### AWS access

You need an AWS account and an IAM user with admin permissions (for learning).
Connect the AWS CLI to your account:

```bash
aws configure
```

> It asks for your Access Key ID, Secret Access Key, region (`us-east-1`) and output format (`json`).

Check that it works:

```bash
aws sts get-caller-identity
```

> You should see your account number and user name. If you get an error, the CLI is not connected yet.

---

## Lab

### 1.1 Create an EC2 key pair

**What:** a key pair is like a lock and key. AWS keeps the **lock** (public key) and you keep the **key** (private key, a `.pem` file).
**Why:** the bastion is created with this lock, so only you (with the key) can `ssh` into it.

```bash
aws ec2 create-key-pair --key-name abhigna-eks-key --region us-east-1 --query 'KeyMaterial' --output text > ~/.ssh/abhigna-eks-key.pem
```

> You can use any name instead of `abhigna-eks-key`. If you do, use the same name in `terraform.tfvars` (`key_pair_name`) in step 1.3.

```bash
chmod 400 ~/.ssh/abhigna-eks-key.pem
```

> `chmod 400` = only you can read the file. `ssh` refuses a key file that other users can read.

**✅ Check:**

```bash
head -1 ~/.ssh/abhigna-eks-key.pem
```

> Shows `-----BEGIN RSA PRIVATE KEY-----`

```bash
aws ec2 describe-key-pairs --region us-east-1 --key-names abhigna-eks-key --query 'KeyPairs[].KeyName' --output text
```

> Shows `abhigna-eks-key`

⚠️ AWS shows the private key **only once**. If you delete the `.pem` file, you have to create a new key pair. Never push it to GitHub.

---

### 1.2 Get the starting Terraform code

**What:** download this repository and make a copy of the basic EKS Terraform setup.
**Why:** you start from code that already works, and keep the original untouched so you can compare "basic" vs "production" later.

```bash
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git
```

```bash
cd k8s-eks-projects
```

```bash
mkdir -p 05-production-eks
```

```bash
cp -r 01-eks-terraform 05-production-eks/terraform
```

```bash
cd 05-production-eks/terraform
```

```bash
ls
```

What each file does:

| File | What it does |
|---|---|
| `providers.tf` | Tells Terraform "we are using AWS, in this region" |
| `variables.tf` | The list of settings (names, sizes, network ranges) with default values |
| `terraform.tfvars` | **Your values** for those settings. This is the main file you edit |
| `vpc.tf` | Creates the VPC, 3 public + 3 private subnets and the NAT gateway |
| `eks.tf` | Creates the EKS cluster, worker node groups and add-ons |
| `bastion.tf` | Creates the bastion EC2, its firewall (security group) and its IAM role |
| `bastion_bootstrap.sh.tpl` | A script that runs on the bastion's first boot: installs `aws`, `kubectl`, `helm` and connects to the cluster |
| `outputs.tf` | Values printed at the end of `apply` (cluster name, bastion IP, ssh command) |

> The code uses ready-made **Terraform modules** for the VPC and EKS. A module = a reusable package of Terraform code, so you don't write 500 lines yourself.

---

### 1.2 (b) Understand the code you copied

Before changing anything, read what the existing code does. Open the folder in VS Code:

```bash
code .
```

#### Terraform words you will see

| Word | Example | Meaning |
|---|---|---|
| `resource` | `resource "aws_instance" "bastion"` | "Create this thing in AWS". Type = `aws_instance`, my name for it = `bastion` |
| `module` | `module "vpc"` | Use a ready-made package of resources |
| `variable` | `var.cluster_name` | A setting whose value comes from `terraform.tfvars` |
| `output` | `output "bastion_public_ip"` | Print a value after `apply` |
| `data` | `data "aws_eks_cluster_auth"` | **Read** something that already exists (doesn't create anything) |
| Reference | `module.vpc.vpc_id` | Use a value from another resource → Terraform creates things **in the right order** |
| `${...}` | `"${var.cluster_name}-bastion"` | Put a value inside text → `abhigna-prod-bastion` |
| `jsonencode({...})` | IAM policies | Turn Terraform code into the JSON that AWS expects |

---

#### `providers.tf`: which cloud and which plugins

| Block | What it does |
|---|---|
| `required_version = ">= 1.5.0"` | Terraform itself must be version 1.5 or newer |
| `required_providers { aws, kubernetes, tls, cloudinit }` | Plugins to download in `terraform init`. `aws` talks to AWS, `kubernetes` talks to the cluster |
| `provider "aws" { region = var.aws_region }` | Create everything in `us-east-1` |
| `default_tags { Project, ManagedBy }` | Every AWS resource gets these tags automatically → easy to find and to see "this was made by Terraform" |
| `data "aws_eks_cluster_auth" "this"` | Gets a login token for the new cluster |
| `provider "kubernetes" { host, cluster_ca_certificate, token }` | Lets Terraform create Kubernetes objects (used for the bastion's RoleBinding in `eks.tf`) |

---

#### `vpc.tf`: the network

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  ...
}
```

| Line | Meaning |
|---|---|
| `source = "terraform-aws-modules/vpc/aws"` | Use the popular, community VPC module from the Terraform Registry |
| `version = "~> 5.8"` | Any 5.x version from 5.8 up (not 6.0) → updates don't break the code |
| `cidr = var.vpc_cidr` | IP range of the whole VPC: `10.0.0.0/16` (65,536 addresses) |
| `azs = var.azs` | Spread across `us-east-1a`, `1b`, `1c` |
| `public_subnets` | `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`: one public subnet per AZ |
| `private_subnets` | `10.0.101.0/24` ... : one private subnet per AZ, for worker nodes |
| `enable_nat_gateway = true` | Create a NAT gateway so private nodes can reach the internet (to pull images) |
| `single_nat_gateway = true` | Only **one** NAT for all 3 AZs → cheaper. *Real production uses one per AZ, so one AZ failing doesn't cut internet for the others* |
| `enable_dns_hostnames / enable_dns_support` | Machines get DNS names; EKS needs this |
| `public_subnet_tags: kubernetes.io/role/elb = 1` | Tells AWS "put **internet-facing** load balancers here" |
| `private_subnet_tags: kubernetes.io/role/internal-elb = 1` | Tells AWS "put **internal** load balancers here" |
| `kubernetes.io/cluster/<name> = shared` | Tells EKS "these subnets belong to my cluster" |

> Without those subnet tags, a `Service type: LoadBalancer` or an Ingress can't find where to create the load balancer.

---

#### `eks.tf`: the cluster (the parts you keep)

| Line | Meaning |
|---|---|
| `source = "terraform-aws-modules/eks/aws"`, `version = "~> 20.31"` | The community EKS module, version 20.x |
| `cluster_name / cluster_version` | Name and Kubernetes version, from `terraform.tfvars` |
| `cluster_endpoint_public_access = true` | The API server (what `kubectl` talks to) can be reached from the internet, still protected by login. *Strict production: private endpoint only* |
| `enable_cluster_creator_admin_permissions = true` | The IAM user who runs `terraform apply` becomes cluster admin. Without it you'd lock yourself out |
| `access_entries { bastion-admin ... }` | Lets the **bastion's IAM role** log in to the cluster, as the Kubernetes group `bastion-admin` |
| `vpc_id = module.vpc.vpc_id` | Put the cluster in the VPC from `vpc.tf` |
| `subnet_ids = module.vpc.private_subnets` | Worker nodes go in the **private** subnets |
| `enable_irsa = true` | Creates an OIDC provider so Pods can use IAM roles (IRSA, the older way next to Pod Identity) |
| `cluster_addons`, node groups | **You replace these in step 1.3 (c)** |
| `cluster_security_group_additional_rules` | Firewall rule: the bastion may call the API server on port **443** |
| `resource "kubernetes_cluster_role_binding" "bastion_admin"` | Inside Kubernetes: gives the group `bastion-admin` the built-in `cluster-admin` role |

How the bastion gets access, in 2 parts:

```
bastion EC2 ──IAM role──► access entry (AWS side: "you may log in, group = bastion-admin")
                                   │
                                   ▼
            ClusterRoleBinding (K8s side: "group bastion-admin = cluster-admin")
```

> **AuthN vs AuthZ:** the access entry answers *"who are you?"* (authentication). The ClusterRoleBinding answers *"what can you do?"* (authorization, RBAC).

---

#### `bastion.tf`: the jump box

**1. Security group (the bastion's firewall)**

```hcl
resource "aws_security_group" "bastion_sg" {
```

| Line | Meaning |
|---|---|
| `name = "${var.cluster_name}-bastion-sg"` | Name becomes `abhigna-prod-bastion-sg` |
| `vpc_id = module.vpc.vpc_id` | The firewall belongs to our VPC |
| `ingress { from_port 22, to_port 22, protocol tcp }` | **Incoming**: allow SSH (port 22) ... |
| `cidr_blocks = [var.ssh_allowed_cidr]` | ... only from this IP range. `0.0.0.0/0` = anyone; `<your-ip>/32` = only you |
| `egress { protocol "-1", 0.0.0.0/0 }` | **Outgoing**: allow everything (`-1` = all protocols), so it can download tools |

**2. IAM role (the bastion's AWS identity)**

```hcl
resource "aws_iam_role" "bastion" {
```

| Line | Meaning |
|---|---|
| `assume_role_policy` | **Trust policy**: *who* may use this role |
| `Principal = { Service = "ec2.amazonaws.com" }` | Only an EC2 machine may use it |
| `Action = "sts:AssumeRole"` | EC2 receives **temporary** credentials for this role. No access keys stored on the bastion |

**3. What the role is allowed to do**

| Resource | Gives permission to |
|---|---|
| `aws_iam_role_policy "bastion_eks_read"` | `eks:DescribeCluster`, `ListClusters`, `DescribeNodegroup`, `ListNodegroups`. Read-only, just enough for `aws eks update-kubeconfig` |
| `aws_iam_role_policy_attachment "bastion_ecr_readonly"` | Read (pull) images from ECR, using the AWS managed policy `AmazonEC2ContainerRegistryReadOnly` |

> Permissions in **AWS** (this role) are separate from permissions **inside Kubernetes** (the ClusterRoleBinding in `eks.tf`). You need both.

**4. Instance profile**

```hcl
resource "aws_iam_instance_profile" "bastion" {
```

> An EC2 can't hold an IAM role directly. The **instance profile** is the "holder" that attaches the role to the machine.

**5. The EC2 machine**

```hcl
resource "aws_instance" "bastion" {
```

| Line | Meaning |
|---|---|
| `ami = var.bastion_ami_id` | Operating system image: Ubuntu 22.04 |
| `instance_type = var.bastion_instance_type` | Machine size: `m7i-flex.large` |
| `key_name = var.key_pair_name` | The key pair from step 1.1 → you can `ssh` in |
| `subnet_id = module.vpc.public_subnets[0]` | Place it in the **first public subnet** (`[0]` = first in the list) |
| `vpc_security_group_ids` | Attach the firewall from part 1 |
| `iam_instance_profile` | Attach the IAM role from parts 2–4 |
| `associate_public_ip_address = true` | Give it a public IP so you can reach it from your laptop |
| `root_block_device { 30 GB, gp3, encrypted }` | Its disk: 30 GB, fast `gp3` type, encrypted |
| `delete_on_termination = true` | Delete the disk when the machine is deleted (no leftover cost) |
| `depends_on = [module.eks]` | Create the bastion **after** the cluster, because its first-boot script connects to the cluster |
| `user_data = templatefile(...)` | Run `bastion_bootstrap.sh.tpl` on first boot, filling in `aws_region` and `cluster_name` |

**6. Outputs**

| Output | Prints |
|---|---|
| `bastion_public_ip` | The bastion's public IP |
| `bastion_ssh_command` | A ready ssh command. It says `-i abhigna-eks-key.pem`, so either run it from `~/.ssh` or use the full path `~/.ssh/abhigna-eks-key.pem` |

---

#### `bastion_bootstrap.sh.tpl`: what runs on the bastion's first boot

| Part of the script | What it does |
|---|---|
| `set -euo pipefail` | Stop the script at the first error (don't continue half-broken) |
| `exec > >(tee -a /var/log/bastion-bootstrap.log)` | Save all output to a log file → if something fails, read this log |
| `apt-get install unzip curl git jq ...` | Basic tools |
| AWS CLI v2 install | So the bastion can run `aws` commands |
| `kubectl` install (v1.36.0) | So it can talk to the cluster |
| `eksctl` + `helm` install | Extra EKS tool + the Kubernetes package manager |
| `until aws eks describe-cluster ... ACTIVE` | Wait until the cluster is ready (checks every 15 s, up to 10 min) |
| `aws eks update-kubeconfig` | Writes `~/.kube/config` → `kubectl` knows which cluster to talk to and how to log in |
| `/etc/profile.d/...`, `.profile` | Sets `AWS_REGION`, `KUBECONFIG` and the alias `k=kubectl` at every login |

> If `kubectl` doesn't work on the bastion, read the log: `sudo tail -50 /var/log/bastion-bootstrap.log`

---

#### `variables.tf` and `terraform.tfvars`: settings vs values

```
variables.tf          →  "there is a setting called cluster_name, default abhigna-cluster"
terraform.tfvars      →  "for this project, cluster_name = abhigna-prod"   ← wins
```

> Change values in `terraform.tfvars`; leave `variables.tf` alone unless you add a brand-new setting.

#### `outputs.tf`: what you see after `apply`

| Output | Use |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_version` | Basic cluster info |
| `vpc_id`, `cluster_security_group_id` | Needed later (for example, the load balancer controller in a later step) |
| `oidc_provider_arn` | Needed for IRSA |
| `configure_kubectl` | The `aws eks update-kubeconfig` command, ready to copy |
| `nodegroup_name` | **You fix this in step 1.3 (d)** |

---

### 1.3 Upgrade the code to production

You will edit 4 files and create 1 new one. `nano` is a simple text editor: save with `Ctrl+O` → `Enter`, exit with `Ctrl+X`.

#### (a) `terraform.tfvars`: name and version

**What:** change 3 values.
**Why:** give the new cluster its own name, and use a Kubernetes version that is in standard (cheaper) support.

```bash
nano terraform.tfvars
```

| Find this line | Change it to | Why |
|---|---|---|
| `project_name = "abhigna"` | `project_name = "abhigna-prod"` | Used as a prefix for the VPC name and tags |
| `cluster_name    = "abhigna-cluster"` | `cluster_name    = "abhigna-prod"` | The new cluster's name |
| `cluster_version = "1.33"` | `cluster_version = "1.36"` | 1.33 is in extended support (6× the price) |

> Leave the `nodegroup_name` and `node_*` lines as they are. They are no longer used, and Terraform does not complain about unused values.

To see which versions are in standard support (cheap) right now:

```bash
aws eks describe-cluster-versions --region us-east-1 --query 'clusterVersions[].[clusterVersion,versionStatus]' --output text
```

> Pick a version that says `STANDARD_SUPPORT`, never `EXTENDED_SUPPORT`.

**Optional but safer:** allow SSH to the bastion only from your own IP. Find your IP:

```bash
curl -s ifconfig.me
```

> Then in `terraform.tfvars` set `ssh_allowed_cidr = "<your-ip>/32"` instead of `"0.0.0.0/0"` (which means "the whole internet").

#### (b) `bastion_bootstrap.sh.tpl`: kubectl version

**What:** make the bastion install `kubectl` 1.36.
**Why:** `kubectl` should match the cluster version. A big gap can cause errors.

```bash
sed -i 's#v1.35.0/bin#v1.36.0/bin#' bastion_bootstrap.sh.tpl
```

> `sed -i 's#old#new#' file` = find `old` and replace it with `new` inside the file.

**✅ Check:**

```bash
grep -n "dl.k8s.io" bastion_bootstrap.sh.tpl
```

> The line should now contain `v1.36.0`.

#### (c) `eks.tf`: add-ons and two node groups (the main change)

**What:** replace the single node group with a **system** and an **app** node group, and add the Pod Identity add-on.
**Why:** this is what makes the cluster production-style (see the Concepts table above).

```bash
nano eks.tf
```

1. **Find** the line that starts with `cluster_addons = {`.
2. **Delete** from that line down to the closing `}` of the `eks_managed_node_groups` block. This removes the old node group (named `abhigna-cluster-ng-1`) with its `remote_access` and `FullAccess` policies.
3. **Keep** everything above it (`cluster_name`, `access_entries`, `vpc_id`, `enable_irsa`) and everything below it (`cluster_security_group_additional_rules` and the `kubernetes_cluster_role_binding` resource).
4. **Paste** this in the empty space:

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

**What each line means:**

| Line | Meaning |
|---|---|
| `cluster_addons` | Add-ons that EKS installs and keeps updated for you |
| `eks-pod-identity-agent` | Runs on every node and hands out **temporary** AWS credentials to Pods |
| `before_compute = true` | Install it **before** the nodes start, so every node has it from minute one |
| `aws-ebs-csi-driver` | Creates an EBS disk when a Pod asks for storage. MySQL needs this to save data |
| `eks_managed_node_group_defaults` | Settings shared by **both** node groups, written once |
| `ami_type = "AL2023_x86_64_STANDARD"` | The operating system of the nodes: Amazon Linux 2023 |
| `instance_types = ["m7i-flex.large"]` | Machine size: 2 vCPU, 8 GB RAM per node |
| `http_tokens = "required"` | Use IMDSv2 only (requires a session token, safer than v1) |
| `http_put_response_hop_limit = 1` | The metadata answer can't reach Pods (see "What is IMDS" above) |
| `AmazonSSMManagedInstanceCore` | Lets you log in to a node through AWS SSM, without SSH keys |
| `AmazonEBSCSIDriverPolicy` | Permission to create EBS disks. *On the node for now; Step 05 moves it to Pod Identity* |
| `system = { ... }` | The system node group: starts with 2 nodes, can grow to 4 |
| `min_size / max_size / desired_size` | Never fewer than 2, never more than 4, start with 2 |
| `labels = { role = "system" }` | Puts the label `role=system` on these nodes |
| `app = { ... }` | The app node group, also 2 → 4 nodes |
| `taints = { ... NO_SCHEDULE }` | Puts `workload=app:NoSchedule` on app nodes: no Pod lands here without a toleration |

#### (d) `outputs.tf`: fix one output

**What:** one output still points to the old node group name.
**Why:** that node group no longer exists, so Terraform would fail. Print the new group names instead.

```bash
nano outputs.tf
```

Find this line:

```hcl
  value       = var.nodegroup_name
```

Change it to:

```hcl
  value       = keys(module.eks.eks_managed_node_groups)
```

> After `apply` this prints `["app", "system"]`.

#### (e) `ecr.tf`: your private image registry (new file)

**What:** create 2 ECR repositories, `prod-frontend` and `prod-backend`.
**Why:** in production, images come from **your own** registry, not public Docker Hub. In Step 06 a policy will block any image that is not from ECR.

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
| `resource "aws_ecr_repository" "app"` | "Create an ECR repository", called `app` inside Terraform |
| `for_each = toset([...])` | Repeat this block once per name: 2 repos from 1 block |
| `name = each.value` | The repo name: `prod-frontend`, then `prod-backend` |
| `IMMUTABLE` | Once tag `v1` is pushed, no one can push a different image as `v1`. A tag always means the same image |
| `force_delete = true` | `terraform destroy` can delete the repo even if images are still inside |
| `scan_on_push = true` | ECR checks every new image for known vulnerabilities (CVEs) |

---

### 1.4 Check the code (free: nothing is created yet)

```bash
terraform init
```

> Downloads the AWS plugin (provider) and the VPC/EKS modules into a hidden `.terraform/` folder. Run it once per folder.

```bash
terraform fmt
```

> Tidies the spacing and indentation in all `.tf` files.

```bash
terraform validate
```

> Checks the code for mistakes (typos, missing brackets, wrong names). It must say **Success! The configuration is valid.**

---

### 1.5 Preview and create (💰 cost starts here)

```bash
terraform plan
```

> A **preview only**, nothing is created. Scroll through it and check you see: the VPC and subnets, the EKS cluster, node groups `system` and `app`, the 2 add-ons, 2 ECR repositories and the bastion. The last line says `Plan: N to add, 0 to change, 0 to destroy`.

```bash
terraform apply
```

> Shows the plan again and asks for confirmation: type `yes`. It takes about **20 minutes**; creating the EKS control plane is the slow part. Don't close the terminal.

---

### 1.6 ✅ Check that everything works

Print the ssh command for the bastion:

```bash
terraform output bastion_ssh_command
```

Connect to the bastion (user is `ubuntu`):

```bash
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-public-ip>
```

> If it says `kubectl: command not found`, the bootstrap script is still running. Wait 2–3 minutes and log in again.

Now, **on the bastion**:

```bash
kubectl get nodes -L role
```

> Expected: **4 nodes**, all `Ready`. 2 show `system` and 2 show `app` in the ROLE column.

```bash
kubectl describe nodes -l role=app | grep Taints
```

> Expected: both app nodes show `workload=app:NoSchedule`.

```bash
kubectl get pods -n kube-system
```

> Expected: `eks-pod-identity-agent-...` and `ebs-csi-...` Pods are `Running`.

```bash
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output text
```

> Expected: `prod-frontend    prod-backend`

🎉 If all 4 checks pass, Step 01 is done.

---

## Common problems

| Error | Why it happens | Fix |
|---|---|---|
| `connection reset by peer` during `terraform init` | Network dropped the download | Run `terraform init` again |
| `InvalidKeyPair.NotFound` | The key pair name in `terraform.tfvars` doesn't exist in us-east-1 | Do step 1.1, or fix `key_pair_name` |
| `Reference to undeclared ... nodegroup_name` | `outputs.tf` still points to the old node group | Do step 1.3 (d) |
| `Unsupported Kubernetes version` | The version isn't offered any more | Pick a `STANDARD_SUPPORT` version from step 1.3 (a) |
| `VcpuLimitExceeded` | Your AWS account's vCPU quota is too low for 5 machines | Request a quota increase in Service Quotas, or set fewer nodes |
| `ssh: Permission denied (publickey)` | Wrong key file or wrong user | Use `-i ~/.ssh/abhigna-eks-key.pem` and user `ubuntu` |
| `ssh: Connection timed out` | Your IP isn't allowed in `ssh_allowed_cidr` | Put your current IP from `curl -s ifconfig.me` and `apply` again |

## Cost

| What | Approx. per hour |
|---|---|
| EKS control plane (standard support) | $0.10 |
| 4 worker nodes + bastion (m7i-flex.large, ~$0.096 each) | ~$0.48 |
| NAT gateway | ~$0.045 + data |
| **Total** | **~$0.63/hr (~$15/day)** |

Stopping for the day? Delete everything (from the `terraform` folder on your laptop):

```bash
terraform destroy
```

> Type `yes`. Takes about 15 minutes. Next time, `terraform apply` builds it all again in the same way.

## Interview Questions

### ⭐ Very Important

**Q1. Why do you separate system and app node groups?**
So cluster tools (CoreDNS, Argo CD, monitoring) and the application don't fight for CPU and memory. The app group is tainted, so only app Pods with a toleration can run there.

**Q2. Why are worker nodes in private subnets?**
Nobody on the internet can reach them directly. They go out through the NAT gateway, and users come in only through the load balancer.

**Q3. Why should you avoid EKS versions in extended support?**
The control plane costs 6× more ($0.60/hr instead of $0.10/hr) and you are running an old version. Upgrade regularly.

### Other Questions

**Q4. What does an IMDS hop limit of 1 protect against?**
A Pod reading the node's instance metadata and using the node's IAM role. With hop limit 1 the answer never reaches the Pod.

**Q5. Why use ECR with immutable tags?**
Images stay in your AWS account, are scanned on push, and a tag like `v1` always means the same image, so deployments are repeatable.

**Q6. Why use SSM instead of SSH keys on worker nodes?**
No port 22 is open, there is no key to lose or leak, and every session is logged in AWS.

**Q7. What is the difference between `terraform plan` and `terraform apply`?**
`plan` only shows what would change. `apply` makes the changes in AWS. Always read the plan before you apply.
