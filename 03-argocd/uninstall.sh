#!/bin/bash
# ───────────────────────────────────────────────
# Remove Argo CD (and its AWS load balancer)
# Run on: 🖥️ BASTION, BEFORE `terraform destroy`
# The load balancer was created by Kubernetes, not Terraform.
# If it stays, terraform destroy can get stuck deleting the VPC.
# ───────────────────────────────────────────────
set -euo pipefail

helm uninstall argocd -n argocd || echo "Release argocd not found, skipping."
kubectl delete namespace argocd --ignore-not-found

echo "Argo CD removed. Check no load balancer is left:"
kubectl get svc -A | grep LoadBalancer || echo "No LoadBalancer services left. Safe to run terraform destroy."
