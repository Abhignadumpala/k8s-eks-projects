# ───────────────────────────────────────────────
# platform_iam.tf: AWS permissions for the cluster tools (later steps)
#   Every tool gets its OWN small IAM role through EKS Pod Identity:
#     IAM role  ◄── Pod Identity association ──►  namespace + ServiceAccount
#   No access keys anywhere, and the node's own role is never used (IMDS hop limit 1).
# ───────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# Trust policy shared by every Pod Identity role:
# "the EKS Pod Identity service may hand this role to a Pod"
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole", "sts:TagSession"]
  }
}

# ── Step 03: AWS Load Balancer Controller ────────
# Creates the ALB for our Ingress. Policy = the official one for v3.6.3
# (downloaded into iam/ so it always matches the controller version).
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

resource "aws_iam_role_policy_attachment" "lb_controller" {
  count      = var.enable_lb_controller ? 1 : 0
  role       = aws_iam_role.lb_controller[0].name
  policy_arn = aws_iam_policy.lb_controller[0].arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  count           = var.enable_lb_controller ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.lb_controller[0].arn
}

# ── Step 06: DB passwords in Secrets Manager + External Secrets ──
# Terraform generates strong random passwords and stores them in AWS.
# They never appear in Git. (They are in the local terraform.tfstate,
# so never commit the state file.)
resource "random_password" "mysql" {
  count   = var.enable_external_secrets ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "mysql_root" {
  count   = var.enable_external_secrets ? 1 : 0
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret" "mysql" {
  count       = var.enable_external_secrets ? 1 : 0
  name        = "${var.cluster_name}/${var.app_namespace}/mysql"
  description = "MySQL passwords for the 3-tier app"

  # Lab: delete immediately on destroy, so the same name works next time.
  # Production keeps the default 7-30 day recovery window.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "mysql" {
  count     = var.enable_external_secrets ? 1 : 0
  secret_id = aws_secretsmanager_secret.mysql[0].id
  secret_string = jsonencode({
    password        = random_password.mysql[0].result
    "root-password" = random_password.mysql_root[0].result
  })
}

# External Secrets may READ only this one secret
data "aws_iam_policy_document" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_secretsmanager_secret.mysql[0].arn]
  }
}

resource "aws_iam_role" "external_secrets" {
  count              = var.enable_external_secrets ? 1 : 0
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  count  = var.enable_external_secrets ? 1 : 0
  name   = "read-mysql-secret"
  role   = aws_iam_role.external_secrets[0].id
  policy = data.aws_iam_policy_document.external_secrets[0].json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  count           = var.enable_external_secrets ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets[0].arn
}

# ── Step 07: Kyverno reads image signatures from ECR ──
data "aws_iam_policy_document" "kyverno_ecr" {
  count = var.enable_kyverno_ecr ? 1 : 0
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "ReadOurRepos"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [for repo in aws_ecr_repository.app : repo.arn]
  }
}

resource "aws_iam_role" "kyverno_ecr" {
  count              = var.enable_kyverno_ecr ? 1 : 0
  name               = "${var.cluster_name}-kyverno-ecr"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "kyverno_ecr" {
  count  = var.enable_kyverno_ecr ? 1 : 0
  name   = "read-app-images"
  role   = aws_iam_role.kyverno_ecr[0].id
  policy = data.aws_iam_policy_document.kyverno_ecr[0].json
}

resource "aws_eks_pod_identity_association" "kyverno_ecr" {
  count           = var.enable_kyverno_ecr ? 1 : 0
  cluster_name    = module.eks.cluster_name
  namespace       = "kyverno"
  service_account = "kyverno-admission-controller"
  role_arn        = aws_iam_role.kyverno_ecr[0].arn
}
