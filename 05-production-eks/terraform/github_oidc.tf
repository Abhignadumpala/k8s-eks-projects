# ───────────────────────────────────────────────
# github_oidc.tf: GitHub Actions → AWS without access keys (Step 10)
#   GitHub gives every workflow run a short-lived OIDC token.
#   AWS trusts tokens from GitHub, but ONLY from our repo's main branch,
#   and swaps them for 1-hour credentials of the CI role below.
#   The CI role can only push to our 2 ECR repositories.
# ───────────────────────────────────────────────

locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"
}

# One per AWS account. Set create_github_oidc_provider = false if it exists already.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.enable_github_oidc && var.create_github_oidc_provider ? 1 : 0
  url            = local.github_oidc_url
  client_id_list = ["sts.amazonaws.com"]
  # AWS verifies GitHub's certificate itself; these are GitHub's published thumbprints
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.enable_github_oidc && !var.create_github_oidc_provider ? 1 : 0
  url   = local.github_oidc_url
}

locals {
  github_oidc_provider_arn = var.enable_github_oidc ? (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  ) : ""
}

data "aws_iam_policy_document" "github_ci_trust" {
  count = var.enable_github_oidc ? 1 : 0
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    # The token must be meant for AWS STS...
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # ...and come from our repo, main branch only (not forks, not other branches)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "github_ci_ecr_push" {
  count = var.enable_github_oidc ? 1 : 0
  statement {
    sid       = "Login"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushAndSignOurRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [for repo in aws_ecr_repository.app : repo.arn]
  }
}

resource "aws_iam_role" "github_ci" {
  count                = var.enable_github_oidc ? 1 : 0
  name                 = "${var.cluster_name}-github-ci"
  assume_role_policy   = data.aws_iam_policy_document.github_ci_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "github_ci" {
  count  = var.enable_github_oidc ? 1 : 0
  name   = "push-app-images"
  role   = aws_iam_role.github_ci[0].id
  policy = data.aws_iam_policy_document.github_ci_ecr_push[0].json
}
