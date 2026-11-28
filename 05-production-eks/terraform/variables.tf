# ───────────────────────────────────────────────
# variables.tf: the list of settings and their default values.
# Put YOUR values in terraform.tfvars (it overrides these defaults).
# ───────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-north-1"
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
  default     = "ami-01613d9e4755fbdf3" # Ubuntu 22.04 LTS, eu-north-1
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
  default     = ["eu-north-1a", "eu-north-1b", "eu-north-1c"]
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
