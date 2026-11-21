# ───────────────────────────────────────────────
# platform_outputs.tf: values the later steps need
# (empty until the matching switch is turned on)
# ───────────────────────────────────────────────

output "mysql_secret_name" {
  description = "Step 06: Secrets Manager secret with the DB passwords"
  value       = var.enable_external_secrets ? aws_secretsmanager_secret.mysql[0].name : ""
}

output "karpenter_queue_name" {
  description = "Step 09: SQS queue for Spot interruption events"
  value       = var.enable_karpenter ? module.karpenter[0].queue_name : ""
}

output "karpenter_node_role_name" {
  description = "Step 09: IAM role used by nodes that Karpenter launches"
  value       = var.enable_karpenter ? module.karpenter[0].node_iam_role_name : ""
}

output "github_ci_role_arn" {
  description = "Step 10: put this in the GitHub secret AWS_ROLE_ARN"
  value       = var.enable_github_oidc ? aws_iam_role.github_ci[0].arn : ""
}
