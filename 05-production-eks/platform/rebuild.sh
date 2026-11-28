#!/usr/bin/env bash
# ───────────────────────────────────────────────
# rebuild.sh: reinstall everything inside the cluster after a
# "terraform destroy" + "terraform apply", up to the step you had finished.
#
# Run on the BASTION:
#   bash ~/k8s-eks-projects/05-production-eks/platform/rebuild.sh <last-step-you-finished>
#   e.g.  bash .../rebuild.sh 9
#
# Before running it:
#   💻 terraform apply (all your switches are still true in terraform.tfvars)
#   💻 images in ECR again:  Step 02 Tasks 4–8 (steps 3–9)
#                            or GitHub → Actions → Run workflow (step 10+)
# It runs the same commands as the guides; it does not replace learning them.
# ───────────────────────────────────────────────
set -euo pipefail

STEP="${1:?Usage: rebuild.sh <last step you finished: 3 to 11>}"
ROOT="$HOME/k8s-eks-projects/05-production-eks"
CLUSTER=abhigna-prod
REGION=eu-north-1
: "${ACCOUNT_ID:?ACCOUNT_ID is empty. Run: source ~/.bashrc  (Step 03, Task 2)}"
ECR="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
on()  { if (( STEP >= $1 )); then echo true; else echo false; fi; }   # "true" from step N on

say "Updating the code"
git -C "$HOME/k8s-eks-projects" pull --ff-only

say "Helm repositories"
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo add kyverno https://kyverno.github.io/kyverno >/dev/null 2>&1 || true
helm repo add istio https://blob.istio.io/istio-release/charts >/dev/null 2>&1 || true
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# ── Step 03: Load Balancer Controller + namespace ──
if (( STEP >= 3 )); then
  say "Step 03: AWS Load Balancer Controller"
  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.resourcesVpcConfig.vpcId --output text)
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller --version 3.6.3 \
    -n kube-system -f "$ROOT/platform/values/aws-load-balancer-controller.yaml" --set vpcId="$VPC_ID" --wait
  kubectl apply -f "$ROOT/platform/k8s/namespace.yaml"
fi

# ── Step 04: developer RBAC ──
if (( STEP >= 4 )); then
  say "Step 04: RBAC"
  kubectl apply -f "$ROOT/platform/k8s/rbac-developer.yaml"
fi

# ── Step 06: External Secrets (else: a hand-made secret like Step 03) ──
if (( STEP >= 6 )); then
  say "Step 06: External Secrets"
  helm upgrade --install external-secrets external-secrets/external-secrets --version 2.15.0 \
    -n external-secrets --create-namespace -f "$ROOT/platform/values/external-secrets.yaml" --wait
  kubectl apply -f "$ROOT/platform/k8s/cluster-secret-store.yaml"
elif (( STEP >= 3 )); then
  if ! kubectl get secret mysql-secret -n three-tier >/dev/null 2>&1; then
    kubectl create secret generic mysql-secret -n three-tier \
      --from-literal=password="$(openssl rand -hex 16)" --from-literal=root-password="$(openssl rand -hex 16)"
  fi
fi

# ── Step 07: Kyverno + policies ──
if (( STEP >= 7 )); then
  say "Step 07: Kyverno"
  helm upgrade --install kyverno kyverno/kyverno --version 3.10.0 -n kyverno --create-namespace --wait
  for f in restrict-registries disallow-latest-tag require-resources disallow-aws-keys; do
    envsubst '${ACCOUNT_ID}' < "$ROOT/platform/policies/$f.yaml" | kubectl apply -f -
  done
  kubectl apply -f "$ROOT/platform/policies/verify-image-signatures.yaml"
fi

# ── Step 08: Istio ambient ──
if (( STEP >= 8 )); then
  say "Step 08: Istio ambient"
  helm upgrade --install istio-base istio/base --version 1.31.4 -n istio-system --create-namespace --wait
  helm upgrade --install istiod istio/istiod --version 1.31.4 -n istio-system -f "$ROOT/platform/values/istiod.yaml" --wait
  helm upgrade --install istio-cni istio/cni --version 1.31.4 -n istio-system -f "$ROOT/platform/values/istio-cni.yaml" --wait
  helm upgrade --install ztunnel istio/ztunnel --version 1.31.4 -n istio-system --wait
  kubectl label namespace three-tier istio.io/dataplane-mode=ambient --overwrite
fi

# ── Step 09: metrics-server + Karpenter ──
if (( STEP >= 9 )); then
  say "Step 09: metrics-server + Karpenter"
  helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system --wait
  helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.3 \
    -n kube-system -f "$ROOT/platform/values/karpenter.yaml" --wait
  kubectl apply -f "$ROOT/platform/karpenter/nodepool.yaml"
fi

# ── The app: Helm (steps 3–9) or Argo CD (step 10+) ──
if (( STEP >= 10 )); then
  say "Step 10: Argo CD + Argo Rollouts, app from Git"
  helm upgrade --install argocd argo/argo-cd --version 10.18.2 -n argocd --create-namespace \
    -f "$ROOT/platform/values/argo-cd.yaml" --wait
  helm upgrade --install argo-rollouts argo/argo-rollouts --version 2.43.12 -n argo-rollouts --create-namespace --wait
  if ! command -v kubectl-argo-rollouts >/dev/null; then
    curl -sSLo /tmp/kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/kubectl-argo-rollouts-linux-amd64
    sudo install -m 0755 /tmp/kubectl-argo-rollouts /usr/local/bin/
  fi
  envsubst '${ACCOUNT_ID}' < "$ROOT/platform/argocd/three-tier-app.yaml" | kubectl apply -f -
elif (( STEP >= 3 )); then
  say "Steps 03–09: app with Helm"
  helm upgrade --install three-tier "$ROOT/helm/three-tier" -n three-tier \
    --set global.registry="$ECR" \
    --set externalSecret.enabled="$(on 6)" \
    --set mesh.enabled="$(on 8)" \
    --set autoscaling.enabled="$(on 9)"
fi

# ── Step 11: monitoring ──
if (( STEP >= 11 )); then
  say "Step 11: kube-prometheus-stack"
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace monitoring istio.io/dataplane-mode=ambient --overwrite
  helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 93.6.1 \
    -n monitoring -f "$ROOT/platform/values/kube-prometheus-stack.yaml" --wait --timeout 10m
  kubectl apply -f "$ROOT/platform/k8s/alerts.yaml"
fi

say "Done. Check:  kubectl get pods -A | grep -v Running"
