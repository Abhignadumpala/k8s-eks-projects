# 01 — EKS Cluster with Terraform

One `terraform apply` creates a full EKS setup on AWS.

```
                     Internet
                        │
┌────────────── VPC 10.0.0.0/16 (3 AZs) ──────────────┐
│ Public subnets:  Bastion EC2 · NAT gateway · LBs    │
│ Private subnets: EKS worker nodes (2–6)             │
└─────────────────────────────────────────────────────┘
        EKS control plane (managed by AWS)
```

## What it creates

| Resource | Details |
|---|---|
| VPC | 3 public + 3 private subnets, 1 NAT gateway (`terraform-aws-modules/vpc/aws`) |
| EKS cluster | `abhigna-cluster`, Kubernetes 1.33 (`terraform-aws-modules/eks/aws`) |
| Managed node group | `m7i-flex.large`, 2 nodes, scales 2–6, in private subnets |
| IAM OIDC provider | IRSA, so pods can use IAM roles |
| Bastion EC2 | Ubuntu, auto-installs AWS CLI, kubectl, eksctl, helm and sets up kubeconfig |

## Files

| File | Purpose |
|---|---|
| `providers.tf` | AWS + Kubernetes providers |
| `variables.tf` | Inputs with defaults |
| `terraform.tfvars` | My values (edit this) |
| `vpc.tf` | VPC module |
| `eks.tf` | EKS module, node group, bastion RBAC |
| `bastion.tf` | Bastion EC2, security group, IAM role |
| `outputs.tf` | Cluster name, endpoint, kubeconfig command |
| `bastion_bootstrap.sh.tpl` | First-boot script for the bastion |

## Before you start

- Terraform >= 1.5 and AWS credentials (`aws sts get-caller-identity`)
- EC2 key pair **`abhigna-eks-key`** in **`ap-southeast-1`**
- Changing region? Update `aws_region`, `azs` and `bastion_ami_id` in `terraform.tfvars`

## Run

```bash
terraform init
terraform plan
terraform apply -auto-approve        # ~15–20 min

ssh -i abhigna-eks-key.pem ubuntu@$(terraform output -raw bastion_public_ip)
kubectl get nodes
```

## Destroy

```bash
# on the bastion first: remove load balancers created by Kubernetes
helm uninstall argocd -n argocd

terraform destroy -auto-approve
```

> Costs money while running: EKS control plane, EC2 nodes + bastion, NAT gateway, load balancers.

Based on class code from [devopsbyraham/eks-code](https://github.com/devopsbyraham/eks-code).
