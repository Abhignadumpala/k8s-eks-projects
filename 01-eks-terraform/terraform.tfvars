# ───────────────────────────────────────────────
# terraform.tfvars
# Edit these values before running `terraform apply`.
# My values for the Day 23 EKS lab.
# ───────────────────────────────────────────────

aws_region   = "ap-southeast-1"
project_name = "abhigna"

# Bastion / Admin host — Ubuntu, m7i-flex.large, 30 GB EBS (as requested)
bastion_ami_id           = "ami-095f155a67469a548" # Ubuntu 22.04 LTS - ap-southeast-1
bastion_instance_type    = "m7i-flex.large"
bastion_root_volume_size = 30
key_pair_name            = "abhigna-eks-key" # must already exist in your AWS account
ssh_allowed_cidr         = "0.0.0.0/0"       # restrict to your IP in production, e.g. "203.0.113.10/32"

# Networking
vpc_cidr             = "10.0.0.0/16"
azs                  = ["ap-southeast-1a", "ap-southeast-1b", "ap-southeast-1c"]
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
private_subnet_cidrs = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS Cluster
cluster_name    = "abhigna-cluster"
cluster_version = "1.33"

# EKS Managed Nodegroup
nodegroup_name      = "abhigna-cluster-ng-1"
node_instance_types = ["m7i-flex.large"] # t3.micro is too small for EKS worker nodes
node_volume_size    = 20
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 6
