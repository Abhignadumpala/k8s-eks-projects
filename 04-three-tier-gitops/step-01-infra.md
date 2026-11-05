# Step 01 — Infrastructure: EKS Cluster + Storage + Argo CD

**Infra first.** The app needs a cluster to run on, a disk for MySQL, and Argo CD to deploy it.

## About this step

| Item | Value |
|---|---|
| Tool | Terraform (cluster), Helm (Argo CD) |
| Code | [01-eks-terraform](../01-eks-terraform) + [03-argocd](../03-argocd), already written |
| New this time | **EBS CSI driver** add-on, so MySQL can get a disk (PVC) |
| Time | ~25 min (most of it is waiting for EKS) |

## Concepts

**EBS CSI driver:** an EKS add-on that lets Kubernetes create AWS EBS disks when a pod asks for storage (PVC).
Without it, the MySQL PVC stays `Pending` forever and `mysql-0` never starts.

**StorageClass:** tells K8s *what kind* of disk to create (gp2, gp3...). EKS 1.30+ has **no default** StorageClass, so in Step 04 the chart will create its own `gp3` one.

```
mysql-0 pod ──asks──► PVC (10Gi) ──uses──► StorageClass gp3
                                              │
                                   EBS CSI driver creates
                                              ▼
                                     AWS EBS volume (gp3)
```

| Without EBS CSI | With EBS CSI |
|---|---|
| PVC `Pending`, mysql-0 `Pending` | PVC `Bound`, EBS volume created automatically |

---

## Lab

### 1.1 EBS CSI driver in Terraform (already added)

`01-eks-terraform/eks.tf` already has both changes. Read them so you know what they do:

**(a)** Inside `module "eks"`, the add-on:

```hcl
  cluster_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }
```

**(b)** In the node group `iam_role_additional_policies`, the permission:

```hcl
        AmazonEBSCSIDriverPolicy             = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
```

> Why (b)? The driver runs on the worker nodes and calls the AWS API to create disks. This policy on the node role gives it permission to do that.

```bash
# 💻 LAPTOP
cd ~/k8s-eks-projects/01-eks-terraform
```
```bash
terraform validate
```

### 1.2 Create the cluster

Check your AWS login first:

```bash
# 💻 LAPTOP
aws sts get-caller-identity
```

```bash
terraform init
```
```bash
terraform plan
```

In the plan, look for `aws_eks_addon` (the EBS CSI driver). Then apply:

```bash
terraform apply -auto-approve
```

⏳ ~15–20 min.

### 1.3 Log in to the bastion

```bash
# 💻 LAPTOP
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@$(terraform output -raw bastion_public_ip)
```

```bash
# 🖥️ BASTION
kubectl get nodes
```

You should see 2 nodes in `Ready` state.

### 1.4 Check the EBS CSI driver

```bash
# 🖥️ BASTION
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

You should see `ebs-csi-controller-...` (2 pods) and `ebs-csi-node-...` (1 per node), all `Running`.

```bash
kubectl get storageclass
```

You'll see `gp2`, but **without `(default)`**. That's expected. We create our own `gp3` class in Step 04.

### 1.5 Install Argo CD

```bash
# 🖥️ BASTION
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git
```
```bash
cd k8s-eks-projects/03-argocd
```
```bash
bash install.sh
```

The script prints the **UI URL** and the **admin password**. Wait 2–3 min, then open the URL in your 💻 laptop browser (accept the certificate warning) and log in as `admin`.

---

## ✅ Check before Step 02

| Check | Command (🖥️ bastion) | Expected |
|---|---|---|
| Nodes ready | `kubectl get nodes` | 2 × `Ready` |
| EBS CSI running | `kubectl get pods -n kube-system \| grep ebs` | all `Running` |
| Argo CD running | `kubectl get pods -n argocd` | all `Running` |
| Argo CD UI | browser → LB URL | login works |

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `terraform apply` fails on key pair | `abhigna-eks-key` missing in us-east-1 | Create it in EC2 → Key Pairs (us-east-1) |
| `ebs-csi-controller` in `CrashLoopBackOff`, log says *no credentials* | Node role is missing the policy | Check step 1.1(b), then `terraform apply` again |
| `kubectl` says *Unauthorized* on bastion | kubeconfig not set | `aws eks update-kubeconfig --region us-east-1 --name abhigna-cluster` |
| Argo CD URL doesn't open | LB DNS still propagating | Wait 3–5 min; `kubectl get svc argocd-server -n argocd` |

## Interview one-liners

- **Why the EBS CSI driver?** → So PVCs from StatefulSets (like MySQL) can create EBS volumes dynamically. Without it, PVCs stay Pending.
- **Why install Argo CD before the app?** → Argo CD is the deploy tool. It must already be running inside the cluster to pull the app from Git.
- **Why Terraform for EKS?** → Repeatable infra: one `apply` to create and one `destroy` to delete, which keeps lab costs under control.

> 💸 Stopping for the day? Run `bash uninstall.sh` (bastion), then `terraform destroy -auto-approve` (laptop).
