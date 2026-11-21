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

# Later steps: switches. Leave all false in Step 01.
# Each step tells you which one to set to true (then run terraform apply).
enable_lb_controller    = false # Step 03
enable_external_secrets = false # Step 06
enable_kyverno_ecr      = false # Step 07
enable_karpenter        = false # Step 09
enable_github_oidc      = false # Step 10
