# 02 — Helm

**Helm** is the package manager for Kubernetes. One `helm install` applies a whole app (all its YAML) to the cluster.

> Helm is a **client tool**. It runs on the machine where I type commands (the **bastion**) and sends YAML to the EKS API server. Nothing Helm-related runs inside the cluster.

## Install Helm

The bastion's bootstrap script (`01-eks-terraform/bastion_bootstrap.sh.tpl`) already installs Helm on first boot. Use this script only if `helm` is missing:

```bash
# 🖥️ BASTION
bash install-helm.sh
helm version
```

## Helm words

| Word | Meaning |
|---|---|
| **Chart** | A package: folder of templated K8s YAML |
| **Repository** | Where charts are stored |
| **Release** | One installed copy of a chart in the cluster |
| **values.yaml** | Settings you can change |
| **Revision** | Version of a release; +1 on every upgrade |

## Commands

| Command | Use |
|---|---|
| `helm repo add <name> <url>` | Add a chart repo |
| `helm repo update` | Refresh chart lists |
| `helm search repo <word>` | Find charts |
| `helm show values <repo/chart>` | See all settings |
| `helm install <release> <repo/chart> -n <ns> -f values.yaml` | Install |
| `helm upgrade --install ...` | Install, or upgrade if it exists |
| `helm list -A` | List releases |
| `helm history <release> -n <ns>` | See revisions |
| `helm rollback <release> <rev> -n <ns>` | Go back |
| `helm uninstall <release> -n <ns>` | Remove |

Example: [03-argocd](../03-argocd) installs Argo CD with Helm.
