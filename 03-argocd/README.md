# 03 — Argo CD with Helm

**Argo CD** is a GitOps tool: it watches a Git repo and keeps the cluster the same as the YAML in Git.

## What runs where

| Tool | Where | Notes |
|---|---|---|
| `helm`, `kubectl` | 🖥️ **Bastion** | Client tools; send commands to the API server (HTTPS 443) |
| **Argo CD** | ☸️ **Inside the cluster**, as **pods on the worker nodes** | Namespace `argocd`, pods spread across nodes by the scheduler |

## Files

| File | Purpose |
|---|---|
| `values.yaml` | My chart settings (`server.service.type: LoadBalancer`) |
| `install.sh` | Adds the Argo repo, installs/upgrades Argo CD, prints UI URL + admin password |
| `uninstall.sh` | Removes Argo CD and its load balancer (run before `terraform destroy`) |

## Install

```bash
# 💻 LAPTOP: SSH into the bastion
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-ip>

# 🖥️ BASTION
git clone https://github.com/Abhignadumpala/k8s-eks-projects.git
cd k8s-eks-projects/03-argocd
bash install.sh
```

Then open the printed `https://<LB DNS>` in the 💻 laptop browser → user `admin` + printed password (accept the self-signed certificate warning).

## Check

```bash
# 🖥️ BASTION
helm list -n argocd                       # STATUS deployed
kubectl get pods -n argocd -o wide        # NODE column = worker nodes
kubectl get svc argocd-server -n argocd   # EXTERNAL-IP = load balancer
```

## Remove (before terraform destroy)

```bash
# 🖥️ BASTION
bash uninstall.sh
```
