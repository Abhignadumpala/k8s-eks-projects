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
      # Its controller Pod gets AWS permissions through Pod Identity.
      # It can't use the node's role: IMDS hop limit 1 blocks Pods from it.
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
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

# EBS CSI driver's own IAM role (Pod Identity), used by the add-on above
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Inside Kubernetes: group "bastion-admin" gets the built-in cluster-admin role
resource "kubernetes_cluster_role_binding" "bastion_admin" {
  # Wait until the whole cluster is ready, including YOUR admin access.
  # Without this, Terraform may try before EKS has made you admin → "forbidden".
  depends_on = [module.eks]

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
