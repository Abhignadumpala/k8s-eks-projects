# k8s-eks-projects

Hands-on Kubernetes projects on **AWS EKS**: cluster setup with Terraform, Helm, Argo CD and Kubernetes manifests.

| Folder | What's inside | Status |
|---|---|---|
| [01-eks-terraform](./01-eks-terraform) | VPC + EKS cluster + managed node group + bastion host, built with Terraform modules | ✅ |
| [02-helm](./02-helm) | Install Helm on the bastion + Helm basics | ✅ |
| [03-argocd](./03-argocd) | Install Argo CD into EKS with Helm (`values.yaml`, `install.sh`, `uninstall.sh`) | ✅ |
| [manifests](./manifests) | Pods, Deployments, Services, Jobs | Coming soon |

## Tools

Terraform · AWS (VPC, EC2, EKS, IAM) · kubectl · eksctl · Helm · Argo CD

## Notes

Step-by-step learning notes: [devops-interview-prep / Kubernetes](https://github.com/Abhignadumpala/devops-interview-prep/tree/main/day-22-kubernetes)
