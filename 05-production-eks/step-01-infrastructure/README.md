# Step 01 — Infrastructure

[⬅ Back to the project overview](../README.md)

## What you will build in this step

**A production-grade EKS cluster**: the network, the cluster, two groups of worker machines, a bastion to manage it, and a private image registry.

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

# Part 1 — Understand (read first)

Read this part once before the lab. It explains **what** you are building and **why**. The lab in Part 2 tells you **exactly what to type**.

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

The 4 Terraform commands you will use:

| Command | What it does | Costs money? |
|---|---|---|
| `terraform init` | Downloads the plugins and modules the code needs | No |
| `terraform validate` | Checks the code for mistakes | No |
| `terraform plan` | Shows what **would** be created (a preview) | No |
| `terraform apply` | Actually creates everything in AWS | **Yes** |

### We are building a production cluster now

👉 **In this step you build a production-grade EKS cluster.** Not a practice cluster.

To save time, you don't write it from zero. You start from a **basic EKS cluster** that already works ([01-eks-terraform](../../01-eks-terraform)) and **upgrade it to production** by changing 10 things.

```
 Basic cluster (practice)               Production cluster (what we build now)
 ───────────────────────                ──────────────────────────────────────
 works, but:                            works, AND:
  - old, expensive version               - new version, cheaper
  - one group of machines for all        - separate machines for tools and app
  - Pods can borrow node permissions     - Pods can't borrow node permissions
  - SSH keys, FullAccess policies        - no SSH keys, only needed permissions
  - images on public Docker Hub          - images in private ECR, scanned
```

The 10 changes (you make them in the Part 2 lab, Tasks 3–7):

| # | Topic | Basic cluster (before) | Production cluster (now) | Why it matters |
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

#### The 10 changes in plain words

1. **EKS version:** AWS charges more for old Kubernetes versions. 1.33 is old now, so we use 1.36 (new and cheap).
2. **Cluster name:** a different name so the new cluster doesn't get mixed up with an old one.
3. **kubectl version:** `kubectl` is the tool that talks to the cluster. Tool and cluster should be the same version, like an app and its phone OS.
4. **Node groups:** before, one group of machines ran your app *and* the cluster tools. If monitoring used a lot of CPU, your app got slow. Now the **system** machines run the tools and the **app** machines run only your app, like separate kitchens for staff and customers.
5. **Taint:** a "keep out" sign on the app machines. Only Pods that carry a matching pass (a *toleration*) can go there, and only your app has that pass.
6. **Pod Identity agent:** your backend will need AWS access (for example, to read the DB password). The bad way is putting AWS keys in the Pod. Pod Identity gives the Pod **temporary** access that expires on its own.
7. **IMDS hop limit 1:** every AWS machine has an internal address where it can ask "what are my AWS permissions?". A Pod could ask the same question and borrow the machine's permissions. Hop limit 1 means only the machine gets the answer, not the Pods.
8. **SSM instead of SSH:** logging in with SSH needs an open port and a key file that can leak. SSM needs neither, and AWS records every login.
9. **Least privilege:** before, the machines had lots of "FullAccess" permissions, so a hacker who got in could do a lot. Now they get only what they need.
10. **ECR:** your private image registry in AWS. Every image is scanned for security holes, and a tag like `v1` can never be overwritten with a different image.

> **In one line:** the basic cluster *works*. The production cluster *works, is cheaper, is safer and is organised*.

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

The lab starts from a basic EKS setup that already works ([01-eks-terraform](../../01-eks-terraform)). Here is every file in it, with its code and what each line does.

### Terraform words you will see

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

### `providers.tf`: which cloud and which plugins

```hcl
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

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}

# Used by the kubernetes provider to authenticate against the EKS cluster
# created in this same apply (so kubectl/helm-style resources can be managed
# directly from Terraform if needed later).
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
| `provider "aws" { region = var.aws_region }` | Create everything in `us-east-1` |
| `default_tags { Project, ManagedBy }` | Every AWS resource gets these tags automatically → easy to find and to see "this was made by Terraform" |
| `data "aws_eks_cluster_auth" "this"` | Gets a login token for the new cluster |
| `provider "kubernetes" { host, cluster_ca_certificate, token }` | Lets Terraform create Kubernetes objects (used for the bastion's RoleBinding in `eks.tf`) |

---

### `vpc.tf`: the network

```hcl
# ───────────────────────────────────────────────
# VPC + Subnets for EKS
# Public subnets  → bastion host, NAT gateway, load balancers
# Private subnets → EKS worker nodes (best practice: nodes never get public IPs)
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
  single_nat_gateway   = true # cost-optimised: one NAT gateway shared across all AZs
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS to auto-discover subnets for load balancers
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

### `eks.tf`: the cluster

This is the file as you copied it. The part between `cluster_addons = {` and the end of `eks_managed_node_groups` is the **old node group**: you replace it in Lab Task 5. Everything else you keep.

```hcl
# ───────────────────────────────────────────────
# EKS Cluster + Managed Nodegroup
# Same as the eksctl way:
#   eksctl create cluster --name=<cluster> --version <ver> ...
#   eksctl utils associate-iam-oidc-provider ...
#   eksctl create nodegroup --cluster=<cluster> ...
# ───────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    bastion-admin = {
      principal_arn     = aws_iam_role.bastion.arn
      type              = "STANDARD"
      kubernetes_groups = ["bastion-admin"]
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Equivalent to: eksctl utils associate-iam-oidc-provider --approve
  enable_irsa = true

  # EBS CSI driver: lets PVCs create EBS volumes (needed for the MySQL StatefulSet
  # in 04-three-tier-gitops). Node role below has AmazonEBSCSIDriverPolicy.
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  eks_managed_node_groups = {
    (var.nodegroup_name) = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      disk_size = var.node_volume_size

      # Disable launch template behavior entirely so remote_access can be passed directly to EKS.
      create_launch_template     = false
      use_custom_launch_template = false

      # Equivalent to: --ssh-access --ssh-public-key=abcd
      remote_access = {
        ec2_ssh_key               = var.key_pair_name
        source_security_group_ids = [aws_security_group.bastion_sg.id]
      }

      # Equivalent to: --asg-access --external-dns-access
      #                --full-ecr-access --appmesh-access --alb-ingress-access
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy            = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy                 = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryFullAccess = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"
        AmazonEC2ContainerRegistryReadOnly   = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        ElasticLoadBalancingFullAccess       = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
        AutoScalingFullAccess                = "arn:aws:iam::aws:policy/AutoScalingFullAccess"
        AmazonEBSCSIDriverPolicy             = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }

      labels = {
        role = "worker"
      }

      tags = {
        Name = "${var.project_name}-eks-node"
      }
    }
  }

  # Allow the bastion host to reach the cluster API
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

**Explained (the parts you keep):**

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
| `cluster_addons`, node groups | **You replace these in Lab Task 5** |
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

> **Why** we create it and **what** we do with it is explained in Concepts → *The bastion*. Here is how the code builds it.

**1. Security group (the bastion's firewall)**

```hcl
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
```

| Line | Meaning |
|---|---|
| `assume_role_policy` | **Trust policy**: *who* may use this role |
| `Principal = { Service = "ec2.amazonaws.com" }` | Only an EC2 machine may use it |
| `Action = "sts:AssumeRole"` | EC2 receives **temporary** credentials for this role. No access keys stored on the bastion |

**3. What the role is allowed to do**

```hcl
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
```

| Resource | Gives permission to |
|---|---|
| `aws_iam_role_policy "bastion_eks_read"` | `eks:DescribeCluster`, `ListClusters`, `DescribeNodegroup`, `ListNodegroups`. Read-only, just enough for `aws eks update-kubeconfig` |
| `aws_iam_role_policy_attachment "bastion_ecr_readonly"` | Read (pull) images from ECR, using the AWS managed policy `AmazonEC2ContainerRegistryReadOnly` |

> Permissions in **AWS** (this role) are separate from permissions **inside Kubernetes** (the ClusterRoleBinding in `eks.tf`). You need both.

**4. Instance profile**

```hcl
resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile-eks"
  role = aws_iam_role.bastion.name
}
```

> An EC2 can't hold an IAM role directly. The **instance profile** is the "holder" that attaches the role to the machine.

**5. The EC2 machine**

```hcl
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
```

| Line | Meaning |
|---|---|
| `ami = var.bastion_ami_id` | Operating system image: Ubuntu 22.04 |
| `instance_type = var.bastion_instance_type` | Machine size: `m7i-flex.large` |
| `key_name = var.key_pair_name` | The key pair from Lab Task 1 → you can `ssh` in |
| `subnet_id = module.vpc.public_subnets[0]` | Place it in the **first public subnet** (`[0]` = first in the list) |
| `vpc_security_group_ids` | Attach the firewall from part 1 |
| `iam_instance_profile` | Attach the IAM role from parts 2–4 |
| `associate_public_ip_address = true` | Give it a public IP so you can reach it from your laptop |
| `root_block_device { 30 GB, gp3, encrypted }` | Its disk: 30 GB, fast `gp3` type, encrypted |
| `delete_on_termination = true` | Delete the disk when the machine is deleted (no leftover cost) |
| `depends_on = [module.eks]` | Create the bastion **after** the cluster, because its first-boot script connects to the cluster |
| `user_data = templatefile(...)` | Run `bastion_bootstrap.sh.tpl` on first boot, filling in `aws_region` and `cluster_name` |

**6. Outputs**

```hcl
output "bastion_public_ip" {
  description = "Public IP of the bastion/admin host — SSH here to run kubectl/eksctl commands"
  value       = aws_instance.bastion.public_ip
}

output "bastion_ssh_command" {
  description = "Ready-to-use SSH command to connect to the bastion host"
  value       = "ssh -i ${var.key_pair_name}.pem ubuntu@${aws_instance.bastion.public_ip}"
}
```

| Output | Prints |
|---|---|
| `bastion_public_ip` | The bastion's public IP |
| `bastion_ssh_command` | A ready ssh command. It says `-i abhigna-eks-key.pem`, so either run it from `~/.ssh` or use the full path `~/.ssh/abhigna-eks-key.pem` |

---

### `bastion_bootstrap.sh.tpl`: what runs on the bastion's first boot

> The `${aws_region}` and `${cluster_name}` placeholders are filled in by Terraform (`templatefile`) before the script runs. Shown here with kubectl **v1.36.0** (after Lab Task 4).

<details>
<summary>Show the full script</summary>

```bash
#!/bin/bash
# ───────────────────────────────────────────────
# Bastion Bootstrap Script
# Automates everything from the original manual STEP-1 and STEP-2:
#   - apt update + unzip
#   - AWS CLI v2 installation
#   - kubectl installation (v1.35.0 to match your original script)
#   - eksctl installation
# Runs automatically on first boot via EC2 user_data — no manual SSH needed.
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

# STEP 2b: kubectl installation (matching your specified v1.35.0)
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

### `variables.tf` and `terraform.tfvars`: settings vs values

Every setting in `variables.tf` looks like this (a name, a description, a type and a default):

```hcl
variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.33"
}
```

| Part | Meaning |
|---|---|
| `variable "cluster_version"` | The setting's name. Code uses it as `var.cluster_version` |
| `description` | What it is for (just for humans) |
| `type = string` | What kind of value: `string` (text), `number`, `list(string)` (a list of texts) |
| `default` | Value used if `terraform.tfvars` doesn't set it |

<details>
<summary>Show the full variables.tf</summary>

```hcl
variable "aws_region" {
  description = "AWS region to deploy all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as a prefix for all resources"
  type        = string
  default     = "abhigna"
}

# ───────────────────────────────
# Bastion / Admin EC2 instance vars
# ───────────────────────────────
variable "bastion_ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID for the bastion/admin host (region-specific, update if changing region)"
  type        = string
  default     = "ami-033ea4ff4a9c726dc" # Ubuntu 22.04 LTS - us-east-1 (N. Virginia)
}

variable "bastion_instance_type" {
  description = "EC2 instance type for the bastion host"
  type        = string
  default     = "m7i-flex.large"
}

variable "bastion_root_volume_size" {
  description = "Root EBS volume size in GB for the bastion host"
  type        = number
  default     = 30
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name for SSH access to the bastion host"
  type        = string
  default     = "abhigna-eks-key"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed to SSH into the bastion host — restrict this to your IP in production"
  type        = string
  default     = "0.0.0.0/0"
}

# ───────────────────────────────
# VPC vars
# ───────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread the EKS cluster and subnets across"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ) — EKS worker nodes live here"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

# ───────────────────────────────
# EKS Cluster vars
# ───────────────────────────────
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "abhigna-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.33"
}

# ───────────────────────────────
# EKS Managed Nodegroup vars
# ───────────────────────────────
variable "nodegroup_name" {
  description = "Name of the EKS managed nodegroup"
  type        = string
  default     = "abhigna-cluster-ng-1"
}

variable "node_instance_types" {
  description = "EC2 instance types for EKS worker nodes (t3.micro is too small for production EKS — using t3.medium)"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_volume_size" {
  description = "EBS root volume size in GB for each EKS worker node"
  type        = number
  default     = 20
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes for autoscaling"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes for autoscaling"
  type        = number
  default     = 6
}
```

</details>

And `terraform.tfvars` gives the real values (shown **after** the 3 changes in Lab Task 3):

```hcl
# ───────────────────────────────────────────────
# terraform.tfvars
# Edit these values before running `terraform apply`.
# My values for the Day 23 EKS lab.
# ───────────────────────────────────────────────

aws_region   = "us-east-1"
project_name = "abhigna-prod"

# Bastion / Admin host — Ubuntu, m7i-flex.large, 30 GB EBS (as requested)
bastion_ami_id           = "ami-033ea4ff4a9c726dc" # Ubuntu 22.04 LTS - us-east-1 (N. Virginia)
bastion_instance_type    = "m7i-flex.large"
bastion_root_volume_size = 30
key_pair_name            = "abhigna-eks-key" # must already exist in your AWS account
ssh_allowed_cidr         = "0.0.0.0/0"       # restrict to your IP in production, e.g. "203.0.113.10/32"

# Networking
vpc_cidr             = "10.0.0.0/16"
azs                  = ["us-east-1a", "us-east-1b", "us-east-1c"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS Cluster
cluster_name    = "abhigna-prod"
cluster_version = "1.36"

# EKS Managed Nodegroup
nodegroup_name      = "abhigna-cluster-ng-1"
node_instance_types = ["m7i-flex.large"] # t3.micro is too small for EKS worker nodes
node_volume_size    = 20
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 6
```

```
variables.tf          →  "there is a setting called cluster_name, default abhigna-cluster"
terraform.tfvars      →  "for this project, cluster_name = abhigna-prod"   ← wins
```

> Change values in `terraform.tfvars`; leave `variables.tf` alone unless you add a brand-new setting.

### `outputs.tf`: what you see after `apply`

```hcl
# ───────────────────────────────────────────────
# Outputs — everything you need after `terraform apply`
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

output "nodegroup_name" {
  description = "EKS managed nodegroup name"
  value       = var.nodegroup_name
}
```

**Explained:**

| Output | Use |
|---|---|
| `cluster_name`, `cluster_endpoint`, `cluster_version` | Basic cluster info |
| `vpc_id`, `cluster_security_group_id` | Needed later (for example, the load balancer controller in a later step) |
| `oidc_provider_arn` | Needed for IRSA |
| `configure_kubectl` | The `aws eks update-kubeconfig` command, ready to copy |
| `nodegroup_name` | **You fix this in Lab Task 6** |

---

## 1.3 The new code you will add

In the lab you **replace** the old node group in `eks.tf` with this block:

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
| `http_put_response_hop_limit = 1` | The metadata answer can't reach Pods (see *What is IMDS*) |
| `AmazonSSMManagedInstanceCore` | Lets you log in to a node through AWS SSM, without SSH keys |
| `AmazonEBSCSIDriverPolicy` | Permission to create EBS disks. *On the node for now; Step 05 moves it to Pod Identity* |
| `system = { ... }` | The system node group: starts with 2 nodes, can grow to 4 |
| `min_size / max_size / desired_size` | Never fewer than 2, never more than 4, start with 2 |
| `labels = { role = "system" }` | Puts the label `role=system` on these nodes |
| `app = { ... }` | The app node group, also 2 → 4 nodes |
| `taints = { ... NO_SCHEDULE }` | Puts `workload=app:NoSchedule` on app nodes: no Pod lands here without a toleration |

And you **create** a new file `ecr.tf`:

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

# Part 2 — 🛠️ Hands-On Lab: Let's Start

Now you build it. Do the tasks **in order**, one at a time. Don't skip the ✅ Check at the end of each task.

## How to read each task

| Label | Meaning |
|---|---|
| 📍 **Where** | Which window to use |
| 💻 **Terminal** | The black window where you type commands, **on your laptop** |
| 📝 **VS Code** | The editor, only for changing files |
| 🖥️ **Bastion** | The EC2 you log in to with `ssh` (only in Task 10) |
| ▶️ **Do** | The commands to run, one box at a time: copy, paste, press Enter |
| ✅ **Check** | How to know the task worked |

```
Task 0   Tools ready?                  💻   free
Task 1   Create the key pair           💻   free
Task 2   Get the code                  💻   free
Task 3   Name + version                📝   free
Task 4   kubectl version               📝   free
Task 5   Two node groups (eks.tf)      📝   free
Task 6   Fix outputs.tf                📝   free
Task 7   Create ecr.tf                 📝   free
Task 8   Check the code                💻   free
Task 9   Create everything in AWS      💻   💰 cost starts
Task 10  Test the cluster              🖥️   bastion
Task 11  Delete everything             💻   when you stop
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

> Missing one? Install guides: [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) · [Terraform](https://developer.hashicorp.com/terraform/install) · [Git](https://git-scm.com/downloads)

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
> Using another key name? Then also change `key_pair_name` in `terraform.tfvars` to the same name.

✅ **Check:**

```bash
aws ec2 describe-key-pairs --region us-east-1 --key-names abhigna-eks-key --query 'KeyPairs[].KeyName' --output text
```

> Prints `abhigna-eks-key`.

⚠️ AWS shows the private key **only once**. Don't delete the `.pem` file, and never push it to GitHub.

---

## Task 2 — Get the code

📍 **Where:** 💻 Terminal

**Why:** download the repo and copy the basic EKS code into a new folder. The original stays untouched.

▶️ **Do:**

> Already have the repo? Skip `cd ~` and `git clone`, and start from `cd ~/k8s-eks-projects`.

```bash
cd ~
```

```bash
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git
```

```bash
cd ~/k8s-eks-projects
```

```bash
mkdir -p 05-production-eks
```

```bash
cp -r 01-eks-terraform 05-production-eks/terraform
```

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform
```

✅ **Check:**

```bash
ls
```

> You see `bastion.tf  eks.tf  outputs.tf  providers.tf  terraform.tfvars  variables.tf  vpc.tf ...` and **no** `k8s-eks-projects` folder inside.

Open the whole repo in VS Code (you need it in Tasks 5–7):

```bash
code ~/k8s-eks-projects
```

> 💡 From now on, every 💻 command runs inside `~/k8s-eks-projects/05-production-eks/terraform`. If you open a new terminal, run that `cd` again first.

---

## Task 3 — Set the new name and version

📍 **Where:** 📝 VS Code

**Why:** give the new cluster its own name, and use Kubernetes **1.36** (1.33 is in extended support and costs 6× more). See *1.1 → We are building a production cluster now*.

▶️ **Do:**

1. In VS Code, open **`05-production-eks/terraform/terraform.tfvars`** (not the one in `01-eks-terraform`).
2. Change these 3 lines:

| Line | Before | After |
|---|---|---|
| 8 | `project_name = "abhigna"` | `project_name = "abhigna-prod"` |
| 24 | `cluster_name    = "abhigna-cluster"` | `cluster_name    = "abhigna-prod"` |
| 25 | `cluster_version = "1.33"` | `cluster_version = "1.36"` |

3. Save with `Ctrl+S`. The ● on the tab disappears when the file is saved.

> Leave all other lines as they are. The `nodegroup_name` and `node_*` lines are no longer used (Task 5 replaces the node group), and Terraform doesn't mind unused values.

<details>
<summary>Alternative: do it from the terminal with <code>sed</code></summary>

`sed -i 's/old/new/' file` finds `old` and replaces it with `new` inside the file. Run these in 💻 the terminal, in `05-production-eks/terraform`:

```bash
sed -i 's/^project_name = "abhigna"/project_name = "abhigna-prod"/' terraform.tfvars
```

```bash
sed -i 's/^cluster_name    = "abhigna-cluster"/cluster_name    = "abhigna-prod"/' terraform.tfvars
```

```bash
sed -i 's/^cluster_version = "1.33"/cluster_version = "1.36"/' terraform.tfvars
```

</details>

✅ **Check:**

```bash
grep -n "project_name\|cluster_name \|cluster_version" terraform.tfvars
```

> Shows `abhigna-prod`, `abhigna-prod` and `1.36`.

Want to see which versions are cheap right now? Pick one that says `STANDARD_SUPPORT`:

```bash
aws eks describe-cluster-versions --region us-east-1 --query 'clusterVersions[].[clusterVersion,versionStatus]' --output text
```

---

## Task 4 — Match the kubectl version

📍 **Where:** 📝 VS Code

**Why:** the bastion installs `kubectl` on its first boot. It should match the cluster version (1.36).

▶️ **Do:**

1. Open **`05-production-eks/terraform/bastion_bootstrap.sh.tpl`**.
2. Find **line 30**:

```bash
curl -LO "https://dl.k8s.io/release/v1.35.0/bin/linux/amd64/kubectl"
```

3. Change `v1.35.0` to `v1.36.0`:

```bash
curl -LO "https://dl.k8s.io/release/v1.36.0/bin/linux/amd64/kubectl"
```

4. Save with `Ctrl+S`.

> Lines 7 and 29 still say "v1.35.0" inside comments (lines starting with `#`). Comments are only notes and don't run; you can update them too if you like.

<details>
<summary>Alternative: do it from the terminal with <code>sed</code></summary>

```bash
sed -i 's#v1.35.0/bin#v1.36.0/bin#' bastion_bootstrap.sh.tpl
```

</details>

✅ **Check:**

```bash
grep -n "dl.k8s.io" bastion_bootstrap.sh.tpl
```

> The line contains `v1.36.0`.

---

## Task 5 — Two node groups + add-ons (`eks.tf`)

📍 **Where:** 📝 VS Code

**Why:** this is the main production change: a **system** and an **app** node group, the Pod Identity add-on, IMDS hop limit 1 and least-privilege permissions. Every line is explained in *1.3 The new code you will add*.

▶️ **Do:**

1. In VS Code, open **`05-production-eks/terraform/eks.tf`** (not the one in `01-eks-terraform`).
2. Find **line 33**. It starts with `# EBS CSI driver: lets PVCs create EBS volumes`.
3. Find **line 86**. It is a closing brace on its own line, just **above** `# Allow the bastion host to reach the cluster API`.
4. Select lines 33 to 86: click at the start of line 33, then hold `Shift` and click at the end of line 86.
5. Press `Delete`.
6. Paste this block in the same place:

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

7. Save with `Ctrl+S`. The ● on the tab disappears when the file is saved.

✅ **Check:**

```bash
grep -n "system = {\|app = {\|eks-pod-identity-agent\|hop_limit\|remote_access" eks.tf
```

> Shows `eks-pod-identity-agent`, `hop_limit`, `system = {` and `app = {`. It must **not** show `remote_access` (that belonged to the old node group).

---

## Task 6 — Fix `outputs.tf`

📍 **Where:** 📝 VS Code

**Why:** one output still points to the old node group you just deleted, so Terraform would fail.

▶️ **Do:**

1. Open **`05-production-eks/terraform/outputs.tf`**.
2. Find this line (around line 42):

```hcl
  value       = var.nodegroup_name
```

3. Replace it with:

```hcl
  value       = keys(module.eks.eks_managed_node_groups)
```

4. Save with `Ctrl+S`.

✅ **Check:**

```bash
grep -n "var.nodegroup_name" outputs.tf
```

> Prints **nothing**. That means the old line is gone.

---

## Task 7 — Create `ecr.tf`

📍 **Where:** 📝 VS Code

**Why:** your private image registry. Later steps push images here and block images from anywhere else.

▶️ **Do:**

1. In the Explorer, right-click the folder **`05-production-eks/terraform`** → **New File** → name it `ecr.tf`.
2. Paste:

```hcl
resource "aws_ecr_repository" "app" {
  for_each             = toset(["prod-frontend", "prod-backend"])
  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true
  image_scanning_configuration { scan_on_push = true }
}
```

3. Save with `Ctrl+S`.

✅ **Check:**

```bash
cat ecr.tf
```

> Shows the code you pasted.

---

## Task 8 — Check the code (free)

📍 **Where:** 💻 Terminal, in `05-production-eks/terraform`

**Why:** find mistakes **before** anything is created in AWS. Nothing in this task costs money.

▶️ **Do:**

```bash
terraform init
```

> Downloads the AWS plugin and the VPC/EKS modules. If you see `connection reset by peer`, just run it again.

```bash
terraform fmt
```

> Tidies the spacing in all `.tf` files.

```bash
terraform validate
```

✅ **Check:** `validate` prints **Success! The configuration is valid.**

> Got an error? It names the file and line. Fix it, or look in *Common problems* at the bottom.

---

## Task 9 — Create everything in AWS (💰 cost starts here)

📍 **Where:** 💻 Terminal, in `05-production-eks/terraform`

**Why:** `plan` shows what will be created; `apply` creates it.

▶️ **Do:**

```bash
terraform plan
```

> A preview only. Check you see the VPC, the EKS cluster, node groups `system` and `app`, the 2 add-ons, 2 ECR repos and the bastion. The last line says `Plan: N to add, 0 to change, 0 to destroy`.

```bash
terraform apply
```

> Type `yes`. It takes about **20 minutes**. Don't close the terminal.

✅ **Check:** the last lines say `Apply complete!` and print the outputs (`bastion_public_ip`, `cluster_name = "abhigna-prod"`, `node_groups`...).

---

## Task 10 — Test the cluster

📍 **Where:** 💻 Terminal first, then 🖥️ the bastion

**Why:** prove that the cluster, both node groups, the taint, the add-ons and ECR all work.

▶️ **Do (💻 laptop):** get the bastion's IP.

```bash
terraform output bastion_public_ip
```

Log in. The user is `ubuntu`; use the IP you just got:

```bash
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-public-ip>
```

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

> ✅ Prints `prod-frontend    prod-backend`.

🎉 All 4 checks pass? **Step 01 is done.**

---

## Task 11 — Delete everything when you stop

📍 **Where:** 💻 Terminal on the laptop, in `05-production-eks/terraform`. **Not** on the bastion: type `exit` to leave it first.

**Why:** the cluster costs about $0.63 every hour, even when you're not using it.

▶️ **Do:**

```bash
terraform destroy
```

> Type `yes`. It takes about 15 minutes. Next time, `terraform apply` builds it again exactly the same way.

---

## Common problems

| Error | Why it happens | Fix |
|---|---|---|
| `connection reset by peer` during `terraform init` | Network dropped the download | Run `terraform init` again |
| `InvalidKeyPair.NotFound` | The key pair name in `terraform.tfvars` doesn't exist in us-east-1 | Do Task 1, or fix `key_pair_name` |
| `Reference to undeclared ... nodegroup_name` | `outputs.tf` still points to the old node group | Do Task 6 |
| `Unsupported Kubernetes version` | The version isn't offered any more | Pick a `STANDARD_SUPPORT` version (see Task 3) |
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

**Q7. Why use a bastion host, and what permissions should it have?**
It's a single admin entry point inside the VPC with the right tool versions. It gets only read-only EKS permissions in AWS through an IAM role (temporary credentials, no stored keys), and its Kubernetes permissions come from an access entry + RBAC binding. SSH should be limited to your IP, or replaced by SSM.

**Q8. What is the difference between `terraform plan` and `terraform apply`?**
`plan` only shows what would change. `apply` makes the changes in AWS. Always read the plan before you apply.

---

[⬅ Back to the project overview](../README.md) · Next: Step 02 — Secure images (coming soon)
