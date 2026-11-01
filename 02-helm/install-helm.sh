#!/bin/bash
# ───────────────────────────────────────────────
# Install Helm (the Kubernetes package manager)
# Run on: 🖥️ BASTION (the machine where kubectl works)
# Helm is a client tool only. Nothing is installed inside the cluster.
# ───────────────────────────────────────────────
set -euo pipefail

if command -v helm >/dev/null 2>&1; then
  echo "helm is already installed: $(helm version --short)"
  exit 0
fi

echo "Installing Helm..."
cd /tmp
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4
chmod 700 get_helm.sh
sudo ./get_helm.sh          # installs /usr/local/bin/helm
rm -f get_helm.sh

echo "Done: $(helm version --short)"
