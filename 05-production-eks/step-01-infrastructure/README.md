# Step 01 — Infrastructure

[⬅ Back to the project overview](../README.md)

## What you will build in this step

**A production-grade EKS cluster**: the network, the cluster, two groups of worker machines, a bastion to manage it, and a private image registry. All of it is created by the Terraform code in [`../terraform`](../terraform).

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

This guide has 2 parts:

| Part | What you do | Time |
|---|---|---|
| **Part 1 — Understand** | Read what each piece is, why it's there, and what every line of code does | ~30 min reading |
| **Part 2 — 🛠️ Hands-On Lab** | Run the commands, task by task, with a check after each one | ~45 min (20 of it waiting for AWS) |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

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

The Terraform commands you will use:

| Command | What it does | Costs money? |
|---|---|---|
| `terraform init` | Downloads the plugins and modules the code needs | No |
| `terraform fmt` | Tidies the spacing in the `.tf` files | No |
| `terraform validate` | Checks the code for mistakes | No |
| `terraform plan` | Shows what **would** be created (a preview) | No |
| `terraform apply` | Actually creates everything in AWS | **Yes** |
| `terraform destroy` | Deletes everything it created | Stops the cost |

### What makes this cluster "production-grade"?

A simple practice cluster **works**, but it isn't how companies run Kubernetes. This code already includes the 10 things below. Nothing to change: you just need to understand them.

| # | Topic | Practice cluster | This production cluster | Why it matters |
|---|---|---|---|---|
| 1 | **EKS version** | Any version, often old | **1.36**, in standard support | Old versions go into *extended support*: the control plane costs **$0.60/hr instead of $0.10/hr** (6×) |
| 2 | **Spread** | 1 AZ | **3 AZs** | If one data center fails, the others keep running |
| 3 | **Node placement** | Public subnets | **Private subnets** | Nobody on the internet can reach the nodes directly |
| 4 | **Node groups** | 1 group runs everything | **system** group + **app** group | Cluster tools (monitoring, Argo CD) can't steal CPU/RAM from your app, and the other way round |
| 5 | **Taint on app nodes** | none | `workload=app:NoSchedule` | A "keep out" sign: only app Pods are allowed on app nodes |
| 6 | **Pod Identity agent** | not installed | installed | Pods get **temporary** AWS access instead of stored access keys (used in Step 05) |
| 7 | **Instance metadata (IMDS)** | default | IMDSv2, hop limit **1** | Stops a Pod from secretly using the node's AWS permissions |
| 8 | **Logging in to nodes** | SSH key | **SSM Session Manager** | No open SSH port and no key that can leak |
| 9 | **Node permissions** | many `FullAccess` policies | only what is needed | *Least privilege*: if a node is hacked, the attacker gets very little |
| 10 | **Image registry** | public Docker Hub | **ECR**, immutable tags, scan on push | Images stay in your own AWS account and are scanned for vulnerabilities |

#### The 10 points in plain words

1. **EKS version:** AWS charges more for old Kubernetes versions, so we use a new one (1.36).
2. **3 AZs:** the cluster lives in 3 separate data centers. One can go down and the app keeps running.
3. **Private subnets:** the worker machines have no public IP. They can go out (through NAT), but nobody can come in.
4. **Node groups:** the **system** machines run the cluster tools, the **app** machines run only your app, like separate kitchens for staff and customers.
5. **Taint:** a "keep out" sign on the app machines. Only Pods that carry a matching pass (a *toleration*) can go there, and only your app has that pass.
6. **Pod Identity agent:** your backend will need AWS access (for example, to read the DB password). Instead of putting AWS keys in the Pod, Pod Identity gives it **temporary** access that expires on its own.
7. **IMDS hop limit 1:** every AWS machine has an internal address where it can ask "what are my AWS permissions?". A Pod could ask the same question and borrow the machine's permissions. Hop limit 1 means only the machine gets the answer.
8. **SSM instead of SSH:** SSH needs an open port and a key file that can leak. SSM needs neither, and AWS records every login.
9. **Least privilege:** the machines get only the permissions they need, so a hacker who gets in can do very little.
10. **ECR:** your private image registry in AWS. Every image is scanned, and a tag like `v1` can never be overwritten with a different image.

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

**Nodes** are the EC2 machines where Pods run. In production we split them into two groups, each with its own job.

| | **System nodes** | **App nodes** |
|---|---|---|
| **What runs there** | Cluster tools: CoreDNS, Argo CD, Prometheus, Grafana, Karpenter, EBS CSI driver | Only **your application**: frontend, backend |
| **Label** | `role = system` | `role = app` |
| **Taint** | none | `workload=app:NoSchedule` |
| **Size in this lab** | min 2, max 4, start with 2 | min 2, max 4, start with 2 |

#### Why separate them?

Think of a **hospital**:
- 🏥 **System nodes** = the power, water and oxygen supply. If these fail, *everything* fails.
- 👩‍⚕️ **App nodes** = the patient wards, where the real work happens.

You never put patients in the power room.

**Without the split:** your backend has a memory leak and uses all the RAM on a node. Kubernetes starts killing Pods to free memory, and it may kill **CoreDNS**. Now *every* app in the cluster loses DNS and the whole cluster breaks. 💥

**With the split:** the backend can only hurt its own app nodes. CoreDNS and monitoring keep running on the system nodes, so you can still see what is wrong and fix it. ✅

#### How do Pods go to the right nodes?

**1. A taint on the app nodes** (in `eks.tf`):

```hcl
taints = { app = { key = "workload", value = "app", effect = "NO_SCHEDULE" } }
```

This is a "🚫 No entry" sign on the app nodes. No Pod can run there **unless** it has a matching **toleration**. So the cluster tools (CoreDNS and so on) cannot land on app nodes; they go to the system nodes automatically.

**2. Your app's Deployment** (in later steps) gets two things:

```yaml
tolerations:                 # the "pass" for the No entry sign
  - key: workload
    value: app
    effect: NoSchedule
nodeSelector:
  role: app                  # "I want to go to app nodes"
```

| Setting | What it does |
|---|---|
| `tolerations` | The Pod is **allowed** on app nodes |
| `nodeSelector` | The Pod **must go** to app nodes |

You need **both**: a toleration only lets the Pod in, it does not send it there.

#### Why `min = 2` for each group?

2 nodes in different AZs means **if one node or one AZ dies, the other keeps running**. One node = a single point of failure, which is not acceptable in production.

> 🎯 **Interview one-liner:** "I separate system and app node groups and taint the app nodes, so cluster-critical add-ons like CoreDNS and monitoring are isolated from application workloads. A noisy app can't take down the cluster."

You will **see this live** in Task 7: `kubectl get nodes -L role` shows 2 `system` + 2 `app` nodes, and `kubectl describe nodes -l role=app | grep Taints` shows the taint.

### Is everything in EKS a Pod?

Mostly yes, with 3 important exceptions.

| Component | Pod? | Where it runs | Kind |
|---|---|---|---|
| **CoreDNS** | ✅ | System nodes | Deployment (2 replicas) |
| **Argo CD, Prometheus, Grafana, Karpenter** | ✅ | System nodes | Deployments / StatefulSets |
| **EBS CSI controller** | ✅ | System nodes | Deployment |
| **kube-proxy** (Service networking) | ✅ | **Every node**, app nodes too | DaemonSet |
| **aws-node** (VPC CNI, gives Pods IPs) | ✅ | **Every node** | DaemonSet |
| **eks-pod-identity-agent** | ✅ | **Every node** | DaemonSet |
| **ebs-csi-node** (attaches disks) | ✅ | **Every node** | DaemonSet |
| **Your frontend / backend** | ✅ | App nodes | Deployment |
| **API server, etcd, scheduler, controller-manager** | ❌ | **AWS's account** (managed control plane) | You never see them |
| **kubelet, containerd** | ❌ | Every node, as Linux services (systemd) | They *start* the Pods |
| **ECR** | ❌ | An AWS service, outside the cluster | Stores the images Pods pull |

**3 things to remember:**

1. **The control plane is not on your nodes.** AWS runs the API server and etcd for you, in their account, across 3 AZs. That is what the $0.10/hr pays for. Your nodes only run workloads.
2. **kubelet is not a Pod.** It is the agent that *creates* Pods, so it must exist before any Pod. It runs as a normal Linux service.
3. **DaemonSets run on app nodes too, even with the taint.** kube-proxy, aws-node and the other node agents carry a "tolerate everything" toleration, because *every* node needs networking and disks. So on an app node you see your app Pods **plus** these DaemonSet Pods. That is expected.

See it in Task 7:

```bash
kubectl get pods -n kube-system -o wide
```

> ✅ The `NODE` column shows CoreDNS only on system nodes, but `aws-node` and `kube-proxy` on all 4 nodes.

> 🎯 **Interview one-liner:** "In EKS, add-ons like CoreDNS run as Deployments on system nodes, node agents like kube-proxy and the VPC CNI run as DaemonSets on every node, and the control plane is managed by AWS outside my nodes. kubelet runs as a systemd service, not a Pod."

### kubelet and containerd: processes, not Pods

They run directly on each node's Linux, managed by **systemd**, like `nginx` or `sshd` on a normal server.

| Process | Job | Analogy 🏗️ |
|---|---|---|
| **kubelet** | The Kubernetes **agent** on each node. Asks the API server "which Pods should run on me?", tells containerd to start them, runs probes, reports node health | The **site manager**: gets the plan, gives orders, reports progress |
| **containerd** | The **container runtime**. Pulls images (from ECR) and starts and stops containers | The **worker**: does the actual building |

How they work together when a Pod is created:

```
API server ──"run backend Pod on node-3"──► kubelet (node-3)
                                              │
                                              ▼
                                       containerd ── pull image from ECR ──► start container
                                              │
kubelet ◄──── "container running" ────────────┘
   │
   └──► reports to API server: Pod is Running ✅
```

**Why can't they be Pods?** Pods need kubelet and containerd to exist first (chicken and egg), so they start before Kubernetes, as normal OS services.

See them on a node (via SSM):

```bash
systemctl status kubelet
```

```bash
systemctl status containerd
```

> 🎯 **Interview one-liner:** "kubelet is the node agent that talks to the API server and manages Pods; containerd is the runtime that pulls images and runs containers. Both run as systemd services, not Pods."

### ECR: one registry, many repositories

| Word | Meaning | In this lab |
|---|---|---|
| **Registry** | Your **one** ECR per AWS account + region | `<account-id>.dkr.ecr.us-east-1.amazonaws.com` |
| **Repository** | A folder for **one app's images** (all its versions) | `prod-frontend`, `prod-backend` |
| **Tag** | One version of an image | `v1`, `v2`, `v3` |

```
<account-id>.dkr.ecr.us-east-1.amazonaws.com     ← registry (one)
 ├── prod-frontend                               ← repository
 │     ├── v1
 │     └── v2
 └── prod-backend                                ← repository
       ├── v1
       └── v2
```

Full image name a Pod pulls: `<account-id>.dkr.ecr.us-east-1.amazonaws.com/prod-backend:v2`

**Why one repository per app?**
- Each app has its **own versions**: frontend on `v5`, backend on `v2`.
- **Separate permissions**: the frontend CI can push only to `prod-frontend`.
- **Separate scan results and cleanup rules** per app.

> 🎯 **Interview one-liner:** "ECR has one registry per account and region; I create one repository per microservice, with immutable tags for versions."

### What is IMDS and why hop limit 1?

**IMDS (Instance Metadata Service)** = a special address (`169.254.169.254`) every EC2 machine can call to get information about itself, **including temporary AWS credentials of the node's IAM role**.

The problem: a Pod running on the node can call the same address and **borrow the node's permissions**.

```
hop limit 2 (risky):  Pod ──► node ──► IMDS  ✅ answer reaches the Pod
hop limit 1 (safe):   Pod ──► node ──► IMDS  ❌ answer stops at the node
```

#### What is a "hop"?

A **hop** = one step a network packet takes from one network to the next (one router or one network "door").

Every packet carries a counter called **TTL** (Time To Live). Each hop **subtracts 1**. When it reaches **0**, the packet is thrown away.

**Why a Pod is one extra hop away:** a Pod has its **own little network** (its own network namespace and IP), separate from the node. So an answer from IMDS must travel:

```
IMDS ──hop 1──► node ──hop 2──► Pod
```

| Hop limit | IMDS answer starts with TTL | Reaches the node? | Reaches a Pod? |
|---|---|---|---|
| **2** (risky) | 2 | ✅ (TTL 1 left) | ✅ (TTL 0, just arrives) → Pod can steal node credentials |
| **1** (safe) | 1 | ✅ (TTL 0, just arrives) | ❌ dropped on the way |

**Analogy 🏠:** a parcel with "deliver within 1 step". The house (node) receives it; the room inside the house (Pod) never does.

#### The 3 settings

| Setting | Meaning |
|---|---|
| `http_endpoint = "enabled"` | IMDS is on. The node itself still needs it (kubelet, the node's own AWS calls) |
| `http_tokens = "required"` | **IMDSv2 only**: a caller must first get a session token with a `PUT` request. Blocks old v1 style attacks (SSRF) that use a simple `GET` |
| `http_put_response_hop_limit = 1` | The **token answer** can travel only 1 hop: reaches the node, never a Pod. No token = no credentials |

**So how do Pods get AWS access?** Not from the node. Each app gets **its own small IAM role through Pod Identity** (Step 05): least privilege per app.

> ⚠️ Exception: a Pod with `hostNetwork: true` uses the node's network directly (no extra hop), so it can still reach IMDS. That is one reason Kyverno (Step 06) blocks `hostNetwork` for app Pods.

> **Interview one-liner:** "I set the IMDS hop limit to 1 so Pods can't use the node's IAM role. Pods get AWS access only through Pod Identity, each with its own role."

### The bastion: why we create it, what it can do, what we use it for

**Bastion (jump box)** = one small, controlled EC2 machine inside the VPC that you log in to, and **from there** you manage the cluster.

#### Why create a bastion at all?

Your laptop could run `kubectl` too. Companies still use a bastion (or a similar admin box) because:

| Without a bastion (kubectl from every laptop) | With a bastion |
|---|---|
| Every admin needs AWS keys + kubeconfig on their own laptop | Admins only need SSH. The **bastion's role** talks to AWS, with temporary credentials |
| Tools on each laptop are different versions | One machine with the **right** `kubectl` (1.36), `helm`, `aws` versions |
| Hard to see who did what | One entry point → easy to control and audit |
| If the API server is made **private** later, laptops can't reach it | The bastion is **inside the VPC**, so it still works |

```
💻 Laptop ──SSH (port 22, your .pem key)──► 🖥️ Bastion (public subnet)
                                               │  IAM role: temporary credentials
                                               ▼
                                       ☸️ EKS API server (port 443)
                                               │
                                               ▼
                                    worker nodes (private subnets)
```

#### What we will do on the bastion (in this project)

| Step | What you run on the bastion |
|---|---|
| 01 | `kubectl get nodes` → check the cluster is healthy |
| 01–10 | `helm install` → install Argo CD, Kyverno, Istio, Prometheus, the load balancer controller |
| 03–08 | `kubectl apply` → RBAC, Pods, Services, policies, HPA, PDB |
| 11 | Debug: `kubectl describe`, `kubectl logs`, `kubectl get events` |

> Terraform does **not** run on the bastion. The bastion is created **by** Terraform, so Terraform always runs on your laptop.

#### What permissions the bastion gets (and why only these)

The bastion needs access in **two different places**: AWS, and inside Kubernetes.

| Where | Permission | Given by | Why it needs it |
|---|---|---|---|
| **AWS** | Use the IAM role `abhigna-prod-bastion-server-role-eks` | Trust policy: only `ec2.amazonaws.com` may use it | The bastion gets **temporary** credentials automatically, so no access keys are stored on it |
| **AWS** | `eks:DescribeCluster`, `ListClusters`, `DescribeNodegroup`, `ListNodegroups` | `aws_iam_role_policy` (read-only) | `aws eks update-kubeconfig` needs to read the cluster's address and certificate |
| **AWS** | Pull images from ECR (read-only) | `AmazonEC2ContainerRegistryReadOnly` | To check or test images in ECR |
| **EKS login** | Access entry → Kubernetes group `bastion-admin` | `access_entries` in `eks.tf` | Lets the bastion's IAM role **log in** to the cluster (authentication: *who are you?*) |
| **Inside Kubernetes** | `cluster-admin` | `ClusterRoleBinding` in `eks.tf` | Lets it **do everything** in the cluster: install tools, create namespaces (authorization: *what can you do?*) |
| **Network** | SSH in (port 22) from `ssh_allowed_cidr` | Security group | So you can log in from your laptop |
| **Network** | Call the API server (port 443) | Extra rule on the cluster's security group | So `kubectl` on the bastion can reach the cluster |

What the bastion **cannot** do in AWS: create or delete EC2 machines, change IAM, delete the cluster, or read Secrets Manager. Its AWS permissions are **read-only**. That is **least privilege**: if someone breaks into the bastion, they can't destroy your AWS account.

> It is `cluster-admin` **inside Kubernetes** because in this project it is the admin machine. In a real company you'd lock it down more (Step 03 shows how to make limited users with RBAC).

#### Keeping the bastion safe

| Risk | How it's handled |
|---|---|
| Anyone on the internet can try SSH | Set `ssh_allowed_cidr` to **your IP only** (`<your-ip>/32`) |
| Stolen key file | `.pem` stays on your laptop, `chmod 400`, never pushed to Git |
| Stored AWS keys get leaked | None stored: the IAM role gives temporary credentials |
| Disk data | Root disk is **encrypted** |

> **Production alternatives:** many companies remove port 22 entirely and log in with **AWS SSM Session Manager**, or run `kubectl` from a CI/CD pipeline / GitOps tool (Argo CD, Step 09) so humans rarely touch the cluster.

> **Interview one-liner:** "The bastion is a single admin entry point inside the VPC. It has an IAM role with read-only EKS permissions and gets cluster-admin inside Kubernetes through an access entry and a ClusterRoleBinding. SSH is limited to my IP, and no AWS keys are stored on it."

---

## 1.2 The code, file by file

All the code is in [`05-production-eks/terraform/`](../terraform):

```
05-production-eks/terraform/
├── providers.tf               which cloud, region and plugins
├── variables.tf               the list of settings (with defaults)
├── terraform.tfvars           YOUR values for those settings  ← the only file you edit
├── vpc.tf                     network: VPC, subnets, NAT
├── eks.tf                     the cluster, 2 node groups, add-ons
├── bastion.tf                 the admin jump box + its IAM role
├── bastion_bootstrap.sh.tpl   script that sets up the bastion on first boot
├── ecr.tf                     2 private image repositories
└── outputs.tf                 values printed after apply
```

### Terraform words you will see

| Word | Example | Meaning |
|---|---|---|
| `resource` | `resource "aws_instance" "bastion"` | "Create this thing in AWS". Type = `aws_instance`, my name for it = `bastion` |
| `module` | `module "vpc"` | Use a ready-made package of resources, so you don't write 500 lines yourself |
| `variable` | `var.cluster_name` | A setting whose value comes from `terraform.tfvars` |
| `output` | `output "bastion_public_ip"` | Print a value after `apply` |
| `data` | `data "aws_eks_cluster_auth"` | **Read** something that already exists (creates nothing) |
| Reference | `module.vpc.vpc_id` | Use a value from another resource → Terraform creates things **in the right order** |
| `${...}` | `"${var.cluster_name}-bastion"` | Put a value inside text → `abhigna-prod-bastion` |
| `jsonencode({...})` | IAM policies | Turn Terraform code into the JSON that AWS expects |
| `#` | `# comment` | A note for humans. Terraform ignores it |

---

### `providers.tf`: which cloud and which plugins

```hcl
# ───────────────────────────────────────────────
# providers.tf: which cloud, which region, which plugins
# ───────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "~> 2.3"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # Every AWS resource gets these tags automatically
  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

# Login token for the new cluster, so Terraform can create Kubernetes objects
# (the bastion's ClusterRoleBinding in eks.tf)
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}
```

**Explained:**

| Block | What it does |
|---|---|
| `required_version = ">= 1.5.0"` | Terraform itself must be version 1.5 or newer |
| `required_providers { aws, kubernetes, tls, cloudinit }` | Plugins to download in `terraform init`. `aws` talks to AWS, `kubernetes` talks to the cluster |
| `version = "~> 5.0"` | Any 5.x version (not 6.0), so a big new release can't break the code |
| `provider "aws" { region = var.aws_region }` | Create everything in `us-east-1` |
| `default_tags { Project, ManagedBy }` | Every AWS resource gets these tags automatically → easy to find, and you can see it was made by Terraform |
| `data "aws_eks_cluster_auth" "this"` | Gets a login token for the new cluster |
| `provider "kubernetes" { host, cluster_ca_certificate, token }` | Lets Terraform create Kubernetes objects (the bastion's RoleBinding in `eks.tf`) |

---

### `variables.tf`: the settings

```hcl
# ───────────────────────────────────────────────
# variables.tf: the list of settings and their default values.
# Put YOUR values in terraform.tfvars (it overrides these defaults).
# ───────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for resource names and tags"
  type        = string
  default     = "abhigna-prod"
}

# ── Bastion ──────────────────────────────────────
variable "bastion_ami_id" {
  description = "Ubuntu 22.04 AMI for the bastion (region-specific)"
  type        = string
  default     = "ami-033ea4ff4a9c726dc" # Ubuntu 22.04 LTS, us-east-1
}

variable "bastion_instance_type" {
  description = "EC2 size of the bastion"
  type        = string
  default     = "m7i-flex.large"
}

variable "bastion_root_volume_size" {
  description = "Bastion disk size in GB"
  type        = number
  default     = 30
}

variable "key_pair_name" {
  description = "Existing EC2 key pair used to SSH into the bastion"
  type        = string
  default     = "abhigna-eks-key"
}

variable "ssh_allowed_cidr" {
  description = "Who may SSH to the bastion. Best: your IP only, like 203.0.113.10/32"
  type        = string
  default     = "0.0.0.0/0"
}

# ── Network ──────────────────────────────────────
variable "vpc_cidr" {
  description = "IP range of the whole VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "3 Availability Zones for high availability"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "One public subnet per AZ: bastion, NAT gateway, internet-facing load balancers"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One private subnet per AZ: worker nodes (no public IPs)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# ── EKS cluster ──────────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "abhigna-prod"
}

variable "cluster_version" {
  description = "Kubernetes version. Must be in STANDARD support (extended support costs 6x)"
  type        = string
  default     = "1.36"
}

# ── Node groups ──────────────────────────────────
variable "node_instance_types" {
  description = "EC2 size for worker nodes (2 vCPU, 8 GB RAM)"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "system_nodes" {
  description = "System node group size: runs cluster tools (CoreDNS, Argo CD, monitoring...)"
  type        = object({ min = number, max = number, desired = number })
  default     = { min = 2, max = 4, desired = 2 }
}

variable "app_nodes" {
  description = "App node group size: runs only the application Pods"
  type        = object({ min = number, max = number, desired = number })
  default     = { min = 2, max = 4, desired = 2 }
}

# ── ECR ──────────────────────────────────────────
variable "ecr_repos" {
  description = "Private image repositories for the app"
  type        = list(string)
  default     = ["prod-frontend", "prod-backend"]
}
```

**Explained:** every setting has the same 4 parts:

| Part | Example | Meaning |
|---|---|---|
| `variable "..."` | `variable "cluster_version"` | The setting's name. Code uses it as `var.cluster_version` |
| `description` | `"Kubernetes version..."` | What it's for (for humans) |
| `type` | `string`, `number`, `list(string)` | What kind of value: text, a number, a list of texts |
| `type = object({...})` | `object({ min = number, max = number, desired = number })` | A small group of values together, like `{ min = 2, max = 4, desired = 2 }` |
| `default` | `"1.36"` | The value used if `terraform.tfvars` doesn't set it |

---

### `terraform.tfvars`: your values

```hcl
# ───────────────────────────────────────────────
# terraform.tfvars: YOUR values. This is the only file you need to edit.
# ───────────────────────────────────────────────

aws_region   = "us-east-1"
project_name = "abhigna-prod"

# Bastion
bastion_ami_id           = "ami-033ea4ff4a9c726dc" # Ubuntu 22.04 LTS, us-east-1
bastion_instance_type    = "m7i-flex.large"
bastion_root_volume_size = 30
key_pair_name            = "abhigna-eks-key" # the key pair you created (Lab Task 1)
ssh_allowed_cidr         = "0.0.0.0/0"       # safer: "<your-ip>/32"  (find it: curl -s ifconfig.me)

# Network: 3 AZs
vpc_cidr             = "10.0.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS
cluster_name    = "abhigna-prod"
cluster_version = "1.36"

# Node groups
node_instance_types = ["m7i-flex.large"]
system_nodes        = { min = 2, max = 4, desired = 2 }
app_nodes           = { min = 2, max = 4, desired = 2 }

# ECR
ecr_repos = ["prod-frontend", "prod-backend"]
```

**Explained:**

```
variables.tf        →  "there is a setting called cluster_name, default abhigna-prod"
terraform.tfvars    →  "for MY project, cluster_name = abhigna-prod"     ← this one wins
```

| Setting | Value | What it controls |
|---|---|---|
| `aws_region` | `us-east-1` | Where everything is created |
| `project_name` | `abhigna-prod` | Prefix for names and tags |
| `bastion_*` | Ubuntu 22.04, `m7i-flex.large`, 30 GB | The bastion machine |
| `key_pair_name` | `abhigna-eks-key` | The key pair you create in Lab Task 1. **Must match** |
| `ssh_allowed_cidr` | `0.0.0.0/0` | Who may SSH to the bastion. `0.0.0.0/0` = anyone; `<your-ip>/32` = only you (safer) |
| `vpc_cidr`, `*_subnet_cidrs` | `10.0.0.0/16`, 3 public + 3 private | The network ranges |
| `azs` | `1a`, `1b`, `1c` | The 3 Availability Zones |
| `cluster_name`, `cluster_version` | `abhigna-prod`, `1.36` | The cluster |
| `node_instance_types` | `m7i-flex.large` | Worker size: 2 vCPU, 8 GB RAM |
| `system_nodes`, `app_nodes` | `{ min = 2, max = 4, desired = 2 }` | Each group starts with 2 nodes, never fewer than 2, never more than 4 |
| `ecr_repos` | `prod-frontend`, `prod-backend` | The 2 image repositories |

---

### `vpc.tf`: the network

```hcl
# ───────────────────────────────────────────────
# vpc.tf: the network
#   public subnets  → bastion, NAT gateway, internet-facing load balancers
#   private subnets → worker nodes (never get public IPs)
# ───────────────────────────────────────────────

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.8"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.azs
  public_subnets  = var.public_subnet_cidrs
  private_subnets = var.private_subnet_cidrs

  enable_nat_gateway   = true
  single_nat_gateway   = true # one NAT to save cost; real production: one per AZ
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags that tell AWS where to create load balancers
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  tags = {
    Name = "${var.project_name}-vpc"
  }
}
```

**Explained:**

| Line | Meaning |
|---|---|
| `source = "terraform-aws-modules/vpc/aws"` | Use the popular community VPC module from the Terraform Registry |
| `version = "~> 5.8"` | Any 5.x version from 5.8 up (not 6.0) |
| `name = "${var.project_name}-vpc"` | The VPC is named `abhigna-prod-vpc` |
| `cidr = var.vpc_cidr` | IP range of the whole VPC: `10.0.0.0/16` (65,536 addresses) |
| `azs = var.azs` | Spread across `us-east-1a`, `1b`, `1c` |
| `public_subnets` | `10.0.1.0/24`, `10.0.2.0/24`, `10.0.3.0/24`: one public subnet per AZ |
| `private_subnets` | `10.0.101.0/24` ...: one private subnet per AZ, for worker nodes |
| `enable_nat_gateway = true` | Create a NAT gateway, so private nodes can reach the internet (to pull images) |
| `single_nat_gateway = true` | Only **one** NAT for all 3 AZs → cheaper. *Strict production uses one per AZ, so one AZ failing doesn't cut the internet for the others* |
| `enable_dns_hostnames / enable_dns_support` | Machines get DNS names; EKS needs this |
| `kubernetes.io/role/elb = 1` (public) | Tells AWS: put **internet-facing** load balancers here |
| `kubernetes.io/role/internal-elb = 1` (private) | Tells AWS: put **internal** load balancers here |
| `kubernetes.io/cluster/<name> = shared` | Tells EKS: these subnets belong to my cluster |

> Without those subnet tags, a `Service type: LoadBalancer` or an Ingress can't find where to create the load balancer.

#### The subnet tags, explained

**Tags** are labels (key = value) on AWS resources. Usually they are only for humans (`Name`, `Project`). These ones are different: **Kubernetes reads them** to make decisions.

When you create a `Service type: LoadBalancer` or an Ingress, Kubernetes (the **AWS Load Balancer Controller**) asks AWS to build a load balancer. The first question it has is: **"In which subnets do I put it?"** It answers that by searching for subnets with these tags.

| Tag | On | Meaning |
|---|---|---|
| `kubernetes.io/role/elb = 1` | Public subnets | "Put **internet-facing** load balancers here." Users on the internet reach your app through them |
| `kubernetes.io/role/internal-elb = 1` | Private subnets | "Put **internal** load balancers here." Only reachable inside the VPC (service to service, or over VPN) |
| `kubernetes.io/cluster/abhigna-prod = shared` | Both | "These subnets belong to cluster `abhigna-prod`." `shared` = other clusters may use them too (the other value, `owned`, means only this cluster) |
| `Name = abhigna-prod-vpc` | The VPC | Just a name you see in the AWS console |

`${var.cluster_name}` is replaced by Terraform with `abhigna-prod`, so the real tag is `kubernetes.io/cluster/abhigna-prod`.

```
User on the internet
        │
        ▼
Public subnets  (role/elb = 1)          ← internet-facing ALB lands here
        │
        ▼
Private subnets (role/internal-elb = 1) ← worker nodes + internal load balancers
```

**Which one does Kubernetes pick?** It depends on one setting in your YAML:

```yaml
alb.ingress.kubernetes.io/scheme: internet-facing   # → public subnets
alb.ingress.kubernetes.io/scheme: internal          # → private subnets
```

**Without these tags:** the load balancer is never created. The Ingress stays with an empty `ADDRESS`, and the controller logs say *"couldn't auto-discover subnets"*. A very common EKS problem.

> 🎯 **Interview one-liner:** "I tag public subnets with `kubernetes.io/role/elb` and private subnets with `kubernetes.io/role/internal-elb`, so the AWS Load Balancer Controller can auto-discover where to place internet-facing and internal load balancers."

---

### `eks.tf`: the cluster

```hcl
# ───────────────────────────────────────────────
# eks.tf: the EKS cluster, production layout
#   - worker nodes in private subnets across 3 AZs
#   - 2 node groups: system (cluster tools) and app (tainted, app Pods only)
#   - Pod Identity agent: Pods get temporary AWS credentials, no access keys
#   - IMDSv2 with hop limit 1: Pods can't borrow the node's IAM role
#   - SSM instead of SSH keys on nodes, least-privilege node permissions
# ───────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  # kubectl can reach the API server from the internet (login still required)
  cluster_endpoint_public_access = true

  # The IAM user who runs terraform apply becomes cluster admin
  enable_cluster_creator_admin_permissions = true

  # The bastion's IAM role may log in to the cluster as group "bastion-admin"
  access_entries = {
    bastion-admin = {
      principal_arn     = aws_iam_role.bastion.arn
      type              = "STANDARD"
      kubernetes_groups = ["bastion-admin"]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # OIDC provider, so tools that use IRSA also work
  enable_irsa = true

  # Add-ons that EKS installs and keeps updated
  cluster_addons = {
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true # installed before nodes join
    }
    aws-ebs-csi-driver = {
      most_recent = true # creates EBS disks for PVCs (MySQL)
    }
  }

  # Settings shared by both node groups
  eks_managed_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    instance_types = var.node_instance_types

    # IMDSv2 only, hop limit 1 → Pods can't reach the node's metadata (and its IAM role)
    metadata_options = {
      http_endpoint               = "enabled"
      http_tokens                 = "required"
      http_put_response_hop_limit = 1
    }

    # Only what's needed on top of the module's defaults (worker, CNI, ECR read-only)
    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      AmazonEBSCSIDriverPolicy     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    }
  }

  eks_managed_node_groups = {
    # Cluster tools: CoreDNS, Argo CD, Kyverno, Prometheus, Istio
    system = {
      min_size     = var.system_nodes.min
      max_size     = var.system_nodes.max
      desired_size = var.system_nodes.desired

      labels = { role = "system" }
    }

    # Only the application. The taint keeps everything else out.
    app = {
      min_size     = var.app_nodes.min
      max_size     = var.app_nodes.max
      desired_size = var.app_nodes.desired

      labels = { role = "app" }

      taints = {
        app = {
          key    = "workload"
          value  = "app"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  # Firewall rule: the bastion may call the API server on port 443
  cluster_security_group_additional_rules = {
    ingress_from_bastion = {
      description              = "Allow bastion host to access EKS API"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.bastion_sg.id
    }
  }

  tags = {
    Name = var.cluster_name
  }
}

# Inside Kubernetes: group "bastion-admin" gets the built-in cluster-admin role
resource "kubernetes_cluster_role_binding" "bastion_admin" {
  metadata {
    name = "${var.cluster_name}-bastion-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "Group"
    name      = "bastion-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}
```

**Explained:**

| Line | Meaning |
|---|---|
| `source = "terraform-aws-modules/eks/aws"`, `version = "~> 20.31"` | The community EKS module, version 20.x |
| `cluster_name / cluster_version` | `abhigna-prod`, `1.36`, from `terraform.tfvars` |
| `cluster_endpoint_public_access = true` | The API server (what `kubectl` talks to) can be reached from the internet, still protected by login. *Strictest production: private endpoint only* |
| `enable_cluster_creator_admin_permissions = true` | Whoever runs `terraform apply` becomes cluster admin. Without it you'd lock yourself out |
| `access_entries { bastion-admin ... }` | Lets the **bastion's IAM role** log in to the cluster, as the Kubernetes group `bastion-admin` |
| `vpc_id`, `subnet_ids = module.vpc.private_subnets` | The cluster lives in our VPC; worker nodes go in the **private** subnets |
| `enable_irsa = true` | Creates an OIDC provider, so tools that use IRSA (the older way, next to Pod Identity) also work |
| `cluster_addons` | Add-ons that EKS installs and keeps updated for you |
| `eks-pod-identity-agent` | Runs on every node and hands out **temporary** AWS credentials to Pods |
| `before_compute = true` | Installed **before** the nodes start, so every node has it from minute one |
| `aws-ebs-csi-driver` | Creates an EBS disk when a Pod asks for storage. MySQL needs it to save data |
| `eks_managed_node_group_defaults` | Settings shared by **both** node groups, written once |
| `ami_type = "AL2023_x86_64_STANDARD"` | The nodes' operating system: Amazon Linux 2023 |
| `instance_types = var.node_instance_types` | Machine size: `m7i-flex.large` (2 vCPU, 8 GB RAM) |
| `http_tokens = "required"` | IMDSv2 only (needs a session token; safer than v1) |
| `http_put_response_hop_limit = 1` | The metadata answer can't reach Pods (see *What is IMDS*) |
| `AmazonSSMManagedInstanceCore` | Log in to a node through AWS SSM, without SSH keys |
| `AmazonEBSCSIDriverPolicy` | Permission to create EBS disks. *On the node role for now; Step 05 moves it to Pod Identity* |
| `system = { ... }` | Node group for cluster tools. Size from `var.system_nodes` (2 → 4) |
| `labels = { role = "system" }` | Puts the label `role=system` on these nodes |
| `app = { ... }` | Node group for the application. Size from `var.app_nodes` (2 → 4) |
| `taints = { ... NO_SCHEDULE }` | Puts `workload=app:NoSchedule` on app nodes: no Pod lands there without a matching toleration |
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

### `bastion.tf`: the jump box

> **Why** we create it and **what** we do with it is in *1.1 → The bastion*. Here is how the code builds it.

```hcl
# ───────────────────────────────────────────────
# bastion.tf: the admin "jump box"
#   - lives in a public subnet, you SSH in from your laptop
#   - has an IAM role (temporary credentials, read-only EKS + ECR)
#   - installs aws, kubectl, helm on first boot (bastion_bootstrap.sh.tpl)
# ───────────────────────────────────────────────

resource "aws_security_group" "bastion_sg" {
  name        = "${var.cluster_name}-bastion-sg"
  description = "Security group for the bastion/admin host"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-bastion-sg"
  }
}

resource "aws_iam_role" "bastion" {
  name = "${var.cluster_name}-bastion-server-role-eks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-bastion-server-role-eks"
  }
}

resource "aws_iam_role_policy" "bastion_eks_read" {
  name = "${var.cluster_name}-bastion-server-eks-read"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:DescribeNodegroup",
          "eks:ListNodegroups"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ecr_readonly" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile-eks"
  role = aws_iam_role.bastion.name
}

resource "aws_instance" "bastion" {
  ami                    = var.bastion_ami_id
  instance_type          = var.bastion_instance_type
  key_name               = var.key_pair_name
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [aws_security_group.bastion_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.bastion_root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  depends_on = [module.eks]

  user_data = templatefile("${path.module}/bastion_bootstrap.sh.tpl", {
    aws_region   = var.aws_region
    cluster_name = var.cluster_name
  })

  tags = {
    Name = "${var.cluster_name}-bastion"
  }
}

output "bastion_public_ip" {
  description = "Public IP of the bastion: SSH here to run kubectl and helm"
  value       = aws_instance.bastion.public_ip
}

output "bastion_ssh_command" {
  description = "Ready-to-use SSH command to connect to the bastion host"
  value       = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_instance.bastion.public_ip}"
}
```

**Explained, part by part:**

**1. Security group** `aws_security_group.bastion_sg` (the bastion's firewall)

| Line | Meaning |
|---|---|
| `name = "${var.cluster_name}-bastion-sg"` | Named `abhigna-prod-bastion-sg` |
| `ingress { from_port 22, to_port 22, protocol tcp }` | **Incoming**: allow SSH (port 22)... |
| `cidr_blocks = [var.ssh_allowed_cidr]` | ...only from this IP range |
| `egress { protocol "-1", 0.0.0.0/0 }` | **Outgoing**: allow everything (`-1` = all protocols), so it can download tools |

**2. IAM role** `aws_iam_role.bastion` (the bastion's AWS identity)

| Line | Meaning |
|---|---|
| `assume_role_policy` | **Trust policy**: *who* may use this role |
| `Principal = { Service = "ec2.amazonaws.com" }` | Only an EC2 machine may use it |
| `Action = "sts:AssumeRole"` | EC2 receives **temporary** credentials for this role. No access keys are stored on the bastion |

**3. What the role may do**

| Resource | Permission |
|---|---|
| `aws_iam_role_policy.bastion_eks_read` | `eks:DescribeCluster`, `ListClusters`, `DescribeNodegroup`, `ListNodegroups`. Read-only: just enough for `aws eks update-kubeconfig` |
| `aws_iam_role_policy_attachment.bastion_ecr_readonly` | Read (pull) images from ECR |

> Permissions in **AWS** (this role) are separate from permissions **inside Kubernetes** (the ClusterRoleBinding in `eks.tf`). You need both.

**4. Instance profile** `aws_iam_instance_profile.bastion`

> An EC2 can't hold an IAM role directly. The **instance profile** is the holder that attaches the role to the machine.

**5. The EC2 machine** `aws_instance.bastion`

| Line | Meaning |
|---|---|
| `ami = var.bastion_ami_id` | Operating system: Ubuntu 22.04 |
| `instance_type` | Machine size: `m7i-flex.large` |
| `key_name = var.key_pair_name` | The key pair from Lab Task 1 → you can `ssh` in |
| `subnet_id = module.vpc.public_subnets[0]` | In the **first public subnet** (`[0]` = first in the list) |
| `vpc_security_group_ids` | Attach the firewall from part 1 |
| `iam_instance_profile` | Attach the IAM role from parts 2–4 |
| `associate_public_ip_address = true` | A public IP, so you can reach it from your laptop |
| `root_block_device { 30 GB, gp3, encrypted }` | Its disk: 30 GB, fast `gp3`, encrypted |
| `delete_on_termination = true` | The disk is deleted with the machine (no leftover cost) |
| `depends_on = [module.eks]` | Create the bastion **after** the cluster, because its first-boot script connects to the cluster |
| `user_data = templatefile(...)` | Run `bastion_bootstrap.sh.tpl` on first boot, filling in `aws_region` and `cluster_name` |

**6. Outputs**

| Output | Prints |
|---|---|
| `bastion_public_ip` | The bastion's public IP |
| `bastion_ssh_command` | A ready-to-copy `ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<ip>` |

---

### `bastion_bootstrap.sh.tpl`: what runs on the bastion's first boot

> `${aws_region}` and `${cluster_name}` are filled in by Terraform (`templatefile`) before the script runs.

<details>
<summary>Show the full script</summary>

```bash
#!/bin/bash
# ───────────────────────────────────────────────
# bastion_bootstrap.sh.tpl: runs ONCE on the bastion's first boot (EC2 user_data)
#   - installs AWS CLI v2, kubectl (same version as the cluster), eksctl, helm
#   - waits for the cluster, then writes ~/.kube/config so kubectl works
# Log file: /var/log/bastion-bootstrap.log
# ───────────────────────────────────────────────
set -euo pipefail

LOGFILE="/var/log/bastion-bootstrap.log"
exec > >(tee -a "$LOGFILE") 2>&1

echo "==== Bastion bootstrap started at $(date) ===="

# STEP 1: System update
apt-get update -y
apt-get install -y unzip curl wget tar git jq

# STEP 2a: AWS CLI v2 installation
cd /tmp
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -o awscliv2.zip
./aws/install
aws --version

# STEP 2b: kubectl installation (v1.36.0, same minor version as the cluster)
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl
kubectl version --client

# STEP 2c: eksctl installation
curl -L "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" -o eksctl.tar.gz
tar -xzvf eksctl.tar.gz -C /tmp
mv /tmp/eksctl /usr/local/bin/eksctl
eksctl version

# STEP 2d: helm installation (useful for installing add-ons post-cluster-creation)
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Configure kubectl to talk to the cluster created by Terraform automatically
# When the instance boots, write kubeconfig for ubuntu and verify cluster access.
mkdir -p /home/ubuntu/.kube /root/.kube
chown -R ubuntu:ubuntu /home/ubuntu/.kube

export HOME=/home/ubuntu
export AWS_DEFAULT_REGION="${aws_region}"

retry_count=0
until aws eks describe-cluster --region "${aws_region}" --name "${cluster_name}" --query "cluster.status" --output text | grep -q "ACTIVE"; do
  retry_count=$((retry_count + 1))
  if [ "$retry_count" -ge 40 ]; then
    echo "Cluster ${cluster_name} is not ACTIVE after $((retry_count * 15)) seconds. Exiting."
    exit 1
  fi
  echo "Waiting for EKS cluster ${cluster_name} to become ACTIVE... (attempt $retry_count)"
  sleep 15
done

sudo -u ubuntu bash -lc "HOME=/home/ubuntu AWS_DEFAULT_REGION=${aws_region} aws eks update-kubeconfig --region ${aws_region} --name ${cluster_name}"
cp /home/ubuntu/.kube/config /root/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
chmod 600 /home/ubuntu/.kube/config /root/.kube/config

cat > /etc/profile.d/eks-kubeconfig.sh <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/home/ubuntu/.kube/config
alias k='kubectl'
EOF

cat > /home/ubuntu/.profile <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/home/ubuntu/.kube/config
alias k='kubectl'
EOF

cat > /root/.profile <<EOF
export AWS_REGION=${aws_region}
export KUBECONFIG=/root/.kube/config
alias k='kubectl'
EOF

chown ubuntu:ubuntu /home/ubuntu/.profile

echo "==== Bastion bootstrap completed at $(date) ===="
echo "kubectl config path: /home/ubuntu/.kube/config"
echo "Run: kubectl get nodes"
```

</details>

**Explained:**

| Part of the script | What it does |
|---|---|
| `set -euo pipefail` | Stop at the first error (don't continue half-broken) |
| `exec > >(tee -a /var/log/bastion-bootstrap.log)` | Save all output to a log file. If something fails, read this log |
| `apt-get install unzip curl git jq ...` | Basic tools |
| AWS CLI v2 install | So the bastion can run `aws` commands |
| `kubectl` install (v1.36.0) | So it can talk to the cluster. Same version as the cluster |
| `eksctl` + `helm` install | Extra EKS tool + the Kubernetes package manager |
| `until aws eks describe-cluster ... ACTIVE` | Wait until the cluster is ready (checks every 15 s, up to 10 min) |
| `aws eks update-kubeconfig` | Writes `~/.kube/config`, so `kubectl` knows which cluster to talk to and how to log in |
| `/etc/profile.d/...`, `.profile` | Sets `AWS_REGION`, `KUBECONFIG` and the alias `k=kubectl` at every login |

> If `kubectl` doesn't work on the bastion, read the log: `sudo tail -50 /var/log/bastion-bootstrap.log`

---

### `ecr.tf`: the private image registry

```hcl
# ───────────────────────────────────────────────
# ecr.tf: private image registry for the app
# ───────────────────────────────────────────────

resource "aws_ecr_repository" "app" {
  for_each = toset(var.ecr_repos)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE" # a tag like v1 can never be overwritten
  force_delete         = true        # terraform destroy works even with images inside

  image_scanning_configuration {
    scan_on_push = true # scan every pushed image for vulnerabilities
  }
}
```

**Explained:**

| Line | Meaning |
|---|---|
| `resource "aws_ecr_repository" "app"` | Create an ECR repository, called `app` inside Terraform |
| `for_each = toset(var.ecr_repos)` | Repeat once per name in the list: 2 repos from 1 block |
| `name = each.value` | The repo name: `prod-frontend`, then `prod-backend` |
| `IMMUTABLE` | Once tag `v1` is pushed, no one can push a different image as `v1`. A tag always means the same image |
| `force_delete = true` | `terraform destroy` can delete the repo even if images are inside |
| `scan_on_push = true` | ECR checks every new image for known vulnerabilities (CVEs) |

---

### `outputs.tf`: what you see after `apply`

```hcl
# ───────────────────────────────────────────────
# outputs.tf: values printed after `terraform apply`
# ───────────────────────────────────────────────

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS control plane"
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "vpc_id" {
  description = "VPC ID where EKS and the bastion host are deployed"
  value       = module.vpc.vpc_id
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN (equivalent to: eksctl utils associate-iam-oidc-provider)"
  value       = module.eks.oidc_provider_arn
}

output "configure_kubectl" {
  description = "Run this command on the bastion host (or locally) to configure kubectl"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "node_groups" {
  description = "Managed node groups"
  value       = keys(module.eks.eks_managed_node_groups)
}

output "ecr_repository_urls" {
  description = "Push your images here"
  value       = { for name, repo in aws_ecr_repository.app : name => repo.repository_url }
}
```

**Explained:**

| Output | Use |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_version` | Basic cluster info |
| `cluster_security_group_id`, `vpc_id` | Needed later (for example, by the load balancer controller) |
| `oidc_provider_arn` | Needed for IRSA |
| `configure_kubectl` | The `aws eks update-kubeconfig` command, ready to copy |
| `node_groups` | `["app", "system"]` |
| `ecr_repository_urls` | Where to push your images in Step 02 |

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

Now you build it. Do the tasks **in order**, one at a time. Don't skip the ✅ Check at the end of each task.

## How to read each task

| Label | Meaning |
|---|---|
| 📍 **Where** | Which window to use |
| 💻 **Terminal** | The black window where you type commands, **on your laptop** |
| 📝 **VS Code** | The editor, for reading and changing files |
| 🖥️ **Bastion** | The EC2 you log in to with `ssh` (Task 7) |
| ▶️ **Do** | What to type or click. Commands: one box at a time, copy, paste, Enter |
| ✅ **Check** | How to know the task worked |

```
Task 0  Tools ready?                    💻      free
Task 1  Create the key pair             💻      free
Task 2  Get the code                    💻      free
Task 3  Open and read the code          📝      free
Task 4  Set your values                 📝      free
Task 5  Check the code                  💻      free
Task 6  Create everything in AWS        💻      💰 cost starts
Task 7  Test the cluster                🖥️      bastion
Task 8  Delete everything               💻      when you stop
```

---

## Task 0 — Are your tools ready?

📍 **Where:** 💻 Terminal

**Why:** the lab uses the AWS CLI, Terraform and Git. If one is missing, later tasks fail.

▶️ **Do:**

```bash
aws --version
```

```bash
terraform -version
```

```bash
git --version
```

> Missing one? Install guides: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) · [Terraform](https://developer.hashicorp.com/terraform/install) · [Git](https://git-scm.com/downloads) · [VS Code](https://code.visualstudio.com/)

Connect the AWS CLI to your account (only the first time). It asks for your Access Key ID, Secret Access Key, region (`us-east-1`) and output format (`json`):

```bash
aws configure
```

✅ **Check:**

```bash
aws sts get-caller-identity
```

> Shows your account number and user name. An error means the AWS CLI is not connected yet.

---

## Task 1 — Create the key pair

📍 **Where:** 💻 Terminal (any folder)

**Why:** the bastion is locked with this key pair. You keep the private key (the `.pem` file) and use it to `ssh` in.

▶️ **Do:**

```bash
aws ec2 create-key-pair --key-name abhigna-eks-key --region us-east-1 --query 'KeyMaterial' --output text > ~/.ssh/abhigna-eks-key.pem
```

```bash
chmod 400 ~/.ssh/abhigna-eks-key.pem
```

> `chmod 400` = only you can read the file. `ssh` refuses a key that others can read.
> Want another name? Use it here **and** in `key_pair_name` in Task 4.

✅ **Check:**

```bash
aws ec2 describe-key-pairs --region us-east-1 --key-names abhigna-eks-key --query 'KeyPairs[].KeyName' --output text
```

> Prints `abhigna-eks-key`.

⚠️ AWS shows the private key **only once**. Don't delete the `.pem` file, and never push it to GitHub.

---

## Task 2 — Get the code

📍 **Where:** 💻 Terminal

**Why:** download the repository that has the Terraform code.

▶️ **Do:**

> Already have the repo? Skip `cd ~` and `git clone`, and run `git pull` inside `~/k8s-eks-projects` instead to get the latest code.

```bash
cd ~
```

```bash
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git
```

> Run `git clone` from your home folder (`~`), never inside another project, or you get a copy inside a copy.

Go to the Terraform folder. **Every 💻 command from now on runs here.**

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform
```

✅ **Check:**

```bash
ls
```

> Shows: `bastion.tf  bastion_bootstrap.sh.tpl  ecr.tf  eks.tf  outputs.tf  providers.tf  terraform.tfvars  variables.tf  vpc.tf`

> 💡 Your terminal prompt should end with `05-production-eks/terraform$`. If you open a new terminal, run the `cd` above again first.

---

## Task 3 — Open and read the code

📍 **Where:** 📝 VS Code

**Why:** never run code you don't understand. Reading it now makes the `plan` output in Task 6 make sense.

▶️ **Do:**

```bash
code ~/k8s-eks-projects
```

1. In the Explorer on the left, open `05-production-eks` → `terraform`.
2. Open each file and read it next to its explanation in *Part 1 → 1.2 The code, file by file*. Start with `eks.tf`, the most important one.
3. Tip: open this guide in VS Code too, with `Ctrl+Shift+V` on `step-01-infrastructure/README.md`, to read it formatted.

✅ **Check:** you can answer these:
- Which file do you edit to change the cluster name? (`terraform.tfvars`)
- Which node group has the taint? (`app`)
- Where do worker nodes live, public or private subnets? (private)

---

## Task 4 — Set your values

📍 **Where:** 📝 VS Code

**Why:** `terraform.tfvars` holds the values for **your** account. Two of them may need to change.

▶️ **Do:**

1. Open **`05-production-eks/terraform/terraform.tfvars`**.
2. Check these 2 lines:

| Line | What to put |
|---|---|
| `key_pair_name = "abhigna-eks-key"` | The key pair name from Task 1. Leave it if you used the same name |
| `ssh_allowed_cidr = "0.0.0.0/0"` | Recommended: your own IP, like `"203.0.113.10/32"`, so only you can SSH to the bastion |

Find your IP (💻 terminal):

```bash
curl -s ifconfig.me
```

3. Save with `Ctrl+S`. The ● on the tab disappears when the file is saved.

> Everything else (names, version 1.36, sizes) is ready to use. Only change it if you know why.

<details>
<summary>Alternative: set your IP from the terminal with <code>sed</code></summary>

```bash
sed -i "s#^ssh_allowed_cidr .*#ssh_allowed_cidr         = \"$(curl -s ifconfig.me)/32\"#" terraform.tfvars
```

</details>

✅ **Check:**

```bash
grep -n "key_pair_name\|ssh_allowed_cidr\|cluster_name\|cluster_version" terraform.tfvars
```

> Shows your key name, your IP (or `0.0.0.0/0`), `abhigna-prod` and `1.36`.

> ⚠️ Using your own IP? If your home IP changes (router restart), SSH stops working. Fix: put the new IP and run `terraform apply` again.

---

## Task 5 — Check the code (free)

📍 **Where:** 💻 Terminal, in `05-production-eks/terraform`

**Why:** find mistakes **before** anything is created in AWS. Nothing in this task costs money.

▶️ **Do:**

```bash
terraform init
```

> Downloads the AWS plugin and the VPC/EKS modules into a hidden `.terraform/` folder. Takes 1–2 minutes the first time.
> `connection reset by peer`? Run it again. Still failing? See *Common problems*.

```bash
terraform fmt
```

```bash
terraform validate
```

✅ **Check:** `validate` prints **Success! The configuration is valid.**

---

## Task 6 — Create everything in AWS (💰 cost starts here)

📍 **Where:** 💻 Terminal, in `05-production-eks/terraform`

**Why:** `plan` shows what will be created; `apply` creates it.

▶️ **Do:**

```bash
terraform plan
```

> A **preview only**. Scroll through it: you should see the VPC and subnets, `aws_eks_cluster`, node groups `["system"]` and `["app"]`, the add-ons `eks-pod-identity-agent` and `aws-ebs-csi-driver`, 2 `aws_ecr_repository` and `aws_instance.bastion`. The last line: **`Plan: 82 to add, 0 to change, 0 to destroy.`**

```bash
terraform apply
```

> Shows the plan again and asks for confirmation: type `yes`. It takes about **20 minutes** (the EKS control plane is the slow part). Don't close the terminal.

✅ **Check:** the end says **`Apply complete! Resources: 82 added`** and prints the outputs: `bastion_public_ip`, `bastion_ssh_command`, `cluster_name = "abhigna-prod"`, `node_groups = ["app", "system"]`, `ecr_repository_urls`...

---

## Task 7 — Test the cluster

📍 **Where:** 💻 Terminal first, then 🖥️ the bastion

**Why:** prove that the cluster, both node groups, the taint, the add-ons and ECR all work.

▶️ **Do (💻 laptop):** print the ready-made ssh command:

```bash
terraform output -raw bastion_ssh_command
```

Copy what it prints and run it. It looks like this (user `ubuntu`):

```bash
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-public-ip>
```

> First time it asks `Are you sure you want to continue connecting?`: type `yes`.
> `kubectl: command not found`? The setup script is still running. Wait 2–3 minutes, type `exit`, and log in again.

▶️ **Do (🖥️ bastion):**

```bash
kubectl get nodes -L role
```

> ✅ 4 nodes, all `Ready`: 2 with ROLE `system`, 2 with ROLE `app`.

```bash
kubectl describe nodes -l role=app | grep Taints
```

> ✅ Both show `workload=app:NoSchedule`.

```bash
kubectl get pods -n kube-system
```

> ✅ `eks-pod-identity-agent-...` and `ebs-csi-...` Pods are `Running`.

```bash
aws ecr describe-repositories --region us-east-1 --query 'repositories[].repositoryName' --output text
```

> ✅ Prints `prod-backend    prod-frontend`.

```bash
exit
```

> Back on your laptop.

🎉 All 4 checks pass? **Step 01 is done.**

---

## Task 8 — Delete everything when you stop

📍 **Where:** 💻 Terminal **on the laptop**, in `05-production-eks/terraform` (not on the bastion)

**Why:** the cluster costs about $0.63 every hour, even when you aren't using it.

▶️ **Do:**

```bash
terraform destroy
```

> Type `yes`. It takes about 15 minutes. The end says `Destroy complete!`.
> Next time, `terraform apply` builds it all again exactly the same way.

---

## Common problems

| Error | Why it happens | Fix |
|---|---|---|
| `connection reset by peer` during `terraform init` | The download was cut off. Often an IPv6 network problem | Run `terraform init` again. If it keeps failing, try another network (e.g. phone hotspot) |
| `InvalidKeyPair.NotFound` | `key_pair_name` doesn't exist in us-east-1 | Do Task 1, or fix `key_pair_name` in `terraform.tfvars` |
| `Unsupported Kubernetes version` | That version isn't offered any more | Pick a `STANDARD_SUPPORT` version: `aws eks describe-cluster-versions --region us-east-1 --query 'clusterVersions[].[clusterVersion,versionStatus]' --output text` |
| `VcpuLimitExceeded` | Your account's vCPU quota is too low for 5 machines | Request a quota increase in *Service Quotas*, or lower `desired`/`min` in `terraform.tfvars` |
| `ssh: Permission denied (publickey)` | Wrong key file or wrong user | Use `-i ~/.ssh/abhigna-eks-key.pem` and user `ubuntu` |
| `ssh: Connection timed out` | Your IP isn't allowed in `ssh_allowed_cidr` | Put your current IP from `curl -s ifconfig.me`, then `terraform apply` again |
| `kubectl: command not found` on the bastion | Setup script still running | Wait 2–3 minutes and log in again. Log: `sudo tail -50 /var/log/bastion-bootstrap.log` |
| `No configuration files` | You're in the wrong folder | `cd ~/k8s-eks-projects/05-production-eks/terraform` |

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

**Q7. Why use a bastion host, and what permissions should it have?**
It's a single admin entry point inside the VPC with the right tool versions. It gets only read-only EKS permissions in AWS through an IAM role (temporary credentials, no stored keys), and its Kubernetes permissions come from an access entry + RBAC binding. SSH should be limited to your IP, or replaced by SSM.

**Q8. What is the difference between `terraform plan` and `terraform apply`?**
`plan` only shows what would change. `apply` makes the changes in AWS. Always read the plan before you apply.

---

[⬅ Back to the project overview](../README.md) · Next: Step 02 — Secure images (coming soon)

