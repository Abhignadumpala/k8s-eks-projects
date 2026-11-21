# ───────────────────────────────────────────────
# platform_variables.tf: ON/OFF switches for the later steps.
# All are false in Step 01. Each step tells you which one to turn on
# in terraform.tfvars, then you run terraform apply again.
# ───────────────────────────────────────────────

variable "enable_lb_controller" {
  description = "Step 03: IAM role (Pod Identity) for the AWS Load Balancer Controller"
  type        = bool
  default     = false
}

variable "enable_external_secrets" {
  description = "Step 06: DB passwords in AWS Secrets Manager + IAM role for External Secrets"
  type        = bool
  default     = false
}

variable "enable_kyverno_ecr" {
  description = "Step 07: IAM role so Kyverno can read image signatures from ECR"
  type        = bool
  default     = false
}

variable "enable_karpenter" {
  description = "Step 09: Karpenter (node autoscaling): IAM roles, node role, SQS interruption queue"
  type        = bool
  default     = false
}

variable "enable_github_oidc" {
  description = "Step 10: IAM role that GitHub Actions can assume (OIDC, no access keys)"
  type        = bool
  default     = false
}

variable "create_github_oidc_provider" {
  description = "Step 10: false if your AWS account already has the GitHub OIDC provider"
  type        = bool
  default     = true
}

variable "github_repo" {
  description = "Step 10: the only GitHub repo allowed to assume the CI role (owner/name)"
  type        = string
  default     = "Abhignadumpala/k8s-eks-projects"
}

variable "app_namespace" {
  description = "Namespace of the 3-tier app"
  type        = string
  default     = "three-tier"
}
