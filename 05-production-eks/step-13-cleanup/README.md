# Step 13 — Clean Up: Delete Everything (and Stop Paying)

[⬅ Back to the project overview](../README.md) · [⬅ Step 12](../step-12-break-and-fix/README.md)

## What you will do in this step

Delete everything in the **right order**, so nothing is left behind that `terraform destroy` doesn't know about, and confirm the bill stops.

| Item | Value |
|---|---|
| Runs on | 🖥️ Bastion first, then 💻 Laptop |
| Time | ~25 min (mostly waiting) |

---

# Part 1 — Understand (read first)

## Why the order matters

**Definition:** **Terraform only deletes what Terraform created.** Some AWS resources were created **by controllers inside the cluster**, so Terraform doesn't know they exist.

- The **LB Controller** made the ALB, the **EBS CSI driver** made the disk, **Karpenter** made extra EC2 nodes.
- If you destroy the cluster **first**, those controllers die and **nobody** deletes their AWS resources.
- They keep **billing**, and they block the VPC from being deleted.

**Analogy 🏠:** before demolishing a house (cluster), the tenants (controllers) must **take their furniture out** (ALB, EBS, EC2). If you demolish first, the furniture is left on the land, and you still pay for storage.

| AWS resource | Created by | If you destroy the cluster first |
|---|---|---|
| **ALB** + its security groups | AWS Load Balancer Controller (from the Ingress) | ALB keeps running and **billing**; VPC delete fails (`DependencyViolation`) |
| **EBS volume** for MySQL | EBS CSI driver (from the PVC) | Volume stays, billing ~$0.40/month forever |
| **EC2 nodes** from Karpenter | Karpenter (from the NodePool) | Instances keep running and **billing**; subnets can't be deleted |

So: **delete the Kubernetes objects first**, let the controllers clean up AWS, **then** `terraform destroy`.

> **Interview one-liner:** "Before terraform destroy, delete the Ingresses, PVCs and Karpenter NodePools so the controllers remove the ALBs, EBS volumes and nodes they created; otherwise they leak cost and block the VPC deletion."

```
1. Argo CD app      ─► stop GitOps from re-creating things
2. namespace three-tier ─► Ingress → ALB deleted · PVC → EBS deleted
3. Karpenter NodePool   ─► its EC2 nodes terminated
4. check AWS: no ALB, no extra EC2, no leftover EBS
5. terraform destroy    ─► everything else (VPC, EKS, IAM, ECR, secret, SQS...)
6. final check
```

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

## Task 1 — Stop GitOps and delete the app

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl delete application three-tier -n argocd
```

```bash
kubectl delete namespace three-tier
```

> Takes 1–3 minutes: the Load Balancer Controller deletes the ALB, the CSI driver deletes the EBS volume.

✅ **Check:**

```bash
kubectl get ingress,pvc -A
```

> ✅ Nothing in `three-tier` (the namespace is gone).

---

## Task 2 — Remove Karpenter's nodes

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl delete nodepool --all && kubectl delete ec2nodeclass --all
```

✅ **Check:**

```bash
kubectl get nodeclaims && kubectl get nodes -L role
```

> ✅ No NodeClaims; only the 4 managed nodes (2 system, 2 app).

```bash
exit
```

---

## Task 3 — Check AWS before destroying

📍 **Where:** 💻 Laptop

▶️ **Do:**

```bash
aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[].LoadBalancerName' --output text
```

> ✅ Empty (or no `k8s-...` names).

```bash
aws ec2 describe-volumes --region us-east-1 --filters Name=tag-key,Values=kubernetes.io/created-for/pvc/name --query 'Volumes[].[VolumeId,State]' --output text
```

> ✅ Empty.

```bash
aws ec2 describe-instances --region us-east-1 --filters Name=tag-key,Values=karpenter.sh/nodepool Name=instance-state-name,Values=running,pending --query 'Reservations[].Instances[].InstanceId' --output text
```

> ✅ Empty.

Something still listed? Wait 2 minutes and check again. (Last resort: delete it in the console.)

---

## Task 4 — terraform destroy

📍 **Where:** 💻 Laptop, in `05-production-eks/terraform`

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform && terraform destroy
```

> Shows everything it will delete (VPC, EKS, node groups, bastion, ECR + images, IAM roles, the secret, the SQS queue, the GitHub OIDC role...). Type `yes`. About 15 minutes.

✅ **Check:** `Destroy complete! Resources: N destroyed.`

---

## Task 5 — Final check

📍 **Where:** 💻 Laptop

▶️ **Do:**

```bash
aws eks list-clusters --region us-east-1 --output text
```

```bash
aws ec2 describe-instances --region us-east-1 --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text
```

```bash
aws ec2 describe-nat-gateways --region us-east-1 --filter Name=state,Values=available --query 'NatGateways[].NatGatewayId' --output text
```

✅ **Check:** all three print nothing (no cluster, no running instances, no NAT gateway). The hourly cost is **$0**.

> Your `terraform.tfvars` keeps all the switches set to `true`. Next time, one `terraform apply` recreates **all** AWS parts of Steps 01–10 at once. Then follow **"Coming back after a destroy"** in the [project overview](../README.md).

🎉 **The project is complete.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| `terraform destroy`: `DependencyViolation` on a subnet / security group / VPC | An ALB, ENI or Karpenter EC2 still exists | Tasks 1–3, then `terraform destroy` again |
| Namespace stuck `Terminating` | A finalizer waits for a controller that's gone | Make sure the LB Controller still runs; check `kubectl get ingress -n three-tier -o yaml` finalizers |
| `destroy` fails on the Kubernetes provider (ClusterRoleBinding) | The cluster is already gone | `terraform state rm kubernetes_cluster_role_binding.bastion_admin`, then destroy again |

## Interview Questions

### Other Questions

**Q1. Why does `terraform destroy` sometimes fail on EKS?**
Controllers in the cluster create AWS resources (ALBs, EBS, Karpenter instances) that Terraform doesn't track. They block subnet/VPC deletion. Delete the Kubernetes objects first so the controllers clean up.

**Q2. How do you avoid surprise AWS bills in labs?**
Destroy when done, check for controller-created resources (ELB, EBS, EC2), use budgets and billing alerts, and tag everything by project.
