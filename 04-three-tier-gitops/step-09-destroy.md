# Step 09 — Destroy Everything (stop the bill)

Order matters. AWS load balancers and EBS volumes are created **by Kubernetes**, not Terraform. If you destroy the cluster first, they're left behind, still cost money, and can block `terraform destroy` (the VPC can't be deleted).

## About this step

| What costs money | Created by | Removed by |
|---|---|---|
| frontend / Argo CD / Grafana load balancers | K8s Services `type: LoadBalancer` | deleting the Services (9.1–9.3) |
| EBS volume for MySQL | PVC `data-mysql-0` | deleting the PVC (9.2) |
| EKS, nodes, NAT gateway, bastion | Terraform | `terraform destroy` (9.4) |

---

## Lab

### 9.1 Remove the app from Argo CD

```bash
# 🖥️ BASTION
kubectl delete -f ~/three-tier-gitops/argocd/three-tier-dev.yaml
```
```bash
kubectl delete namespace three-tier
```

### 9.2 Delete the MySQL disk

```bash
kubectl get pvc -A
```

If `data-mysql-0` is still listed:

```bash
kubectl delete pvc data-mysql-0 -n three-tier
```

### 9.3 Remove monitoring and Argo CD

```bash
helm uninstall kube-prometheus-stack -n monitoring
```
```bash
cd ~/k8s-eks-projects/03-argocd && bash uninstall.sh
```

Check that no load balancers are left (must be empty):

```bash
kubectl get svc -A | grep LoadBalancer
```

### 9.4 Destroy the infrastructure

```bash
# 💻 LAPTOP
cd ~/k8s-eks-projects/01-eks-terraform
```
```bash
terraform destroy -auto-approve
```

### 9.5 Double-check in the AWS console (us-east-1)

| Page | Should be |
|---|---|
| EC2 → Load Balancers | empty |
| EC2 → Volumes | no `available` volumes left from the lab |
| EKS → Clusters | empty |
| VPC → NAT gateways | `Deleted` |

---

## Interview one-liners

- **Why did `terraform destroy` hang on the VPC?** → K8s-created load balancers/ENIs were still in the subnets. Delete the `LoadBalancer` Services first, then destroy.
- **How did you control lab costs?** → Everything is in Terraform plus Helm, so I can rebuild in ~25 min and destroy after each session.
