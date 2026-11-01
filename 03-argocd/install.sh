#!/bin/bash
# ───────────────────────────────────────────────
# Install Argo CD into the EKS cluster with Helm
# Run on: 🖥️ BASTION
# Argo CD runs INSIDE the cluster as pods on the worker nodes (namespace argocd).
# The bastion only sends the install command.
# ───────────────────────────────────────────────
set -euo pipefail

RELEASE="argocd"
NAMESPACE="argocd"
CHART="argo/argo-cd"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Check tools and cluster access
command -v helm >/dev/null    || { echo "helm not found. Run: bash ../02-helm/install-helm.sh"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found."; exit 1; }
kubectl get nodes >/dev/null  || { echo "Cannot reach the cluster. Run: aws eks update-kubeconfig --region us-east-1 --name abhigna-cluster"; exit 1; }

# 2. Add the Argo Helm repo
helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo update argo

# 3. Install (or upgrade if already installed) and wait until pods are ready
helm upgrade --install "$RELEASE" "$CHART" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  -f "$SCRIPT_DIR/values.yaml" \
  --wait --timeout 10m

# 4. Show where the pods are running (NODE column = worker nodes)
kubectl get pods -n "$NAMESPACE" -o wide

# 5. Wait for the AWS load balancer address (up to 5 min)
echo "Waiting for the load balancer address..."
LB=""
for _ in $(seq 1 30); do
  LB=$(kubectl get svc "$RELEASE-server" -n "$NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$LB" ] && break
  sleep 10
done

# 6. Admin password
PASSWORD=$(kubectl -n "$NAMESPACE" get secret argocd-initial-admin-secret \
            -o jsonpath='{.data.password}' | base64 -d)

echo
echo "Argo CD is installed."
echo "  UI:       https://${LB:-<not ready yet: kubectl get svc $RELEASE-server -n $NAMESPACE>}"
echo "  User:     admin"
echo "  Password: $PASSWORD"
echo "Wait 2-3 minutes for the load balancer DNS before opening the UI."
