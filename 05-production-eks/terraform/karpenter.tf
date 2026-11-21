# ───────────────────────────────────────────────
# karpenter.tf: node autoscaling (Step 09)
#   - IAM role for the Karpenter controller (Pod Identity, kube-system/karpenter)
#   - IAM role + access entry for the nodes Karpenter launches
#   - SQS queue + EventBridge rules: Spot interruption warnings → Karpenter
#     drains the node before AWS takes it back
# ───────────────────────────────────────────────

module "karpenter" {
  count   = var.enable_karpenter ? 1 : 0
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  # Karpenter v1.x permissions + Pod Identity (no IRSA, no keys)
  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # Fixed names, so the NodePool / EC2NodeClass YAML can refer to them
  queue_name                    = "Karpenter-${var.cluster_name}"
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  # Karpenter nodes: SSM access instead of SSH, like our managed nodes
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Extra read permissions that Karpenter 1.15 uses but this module
  # version does not include yet
  iam_policy_statements = [
    {
      sid = "KarpenterV115Extras"
      actions = [
        "ec2:DescribeCapacityReservations",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribePlacementGroups",
        "iam:ListInstanceProfiles",
      ]
      resources = ["*"]
    }
  ]
}
