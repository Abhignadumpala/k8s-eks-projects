# Step 05 — Let Argo CD Deploy (GitOps)

Stop running `helm install` yourself. Tell Argo CD *"keep the cluster the same as this Git folder"*.

## About this step

| Item | Value |
|---|---|
| Where | 🖥️ Bastion + 💻 Argo CD UI |
| File | `three-tier-gitops/argocd/three-tier-dev.yaml` |
| Result | Argo CD shows `three-tier-dev`: **Synced + Healthy** |

## Concepts

**Argo CD Application:** a K8s object that says *which Git repo/path to watch* → *which cluster/namespace to deploy to*.
**Sync:** making the cluster match Git. **OutOfSync:** Git and the cluster differ.

| Setting | Meaning |
|---|---|
| `path: charts/three-tier` + `valueFiles: ../../values/dev.yaml` | Argo CD runs `helm template` with these values |
| `automated` | Syncs by itself (polls Git every ~3 min) |
| `prune: true` | Deleted from Git → deleted from the cluster |
| `selfHeal: true` | Someone runs `kubectl edit` → Argo CD changes it back |
| `CreateNamespace=true` | Creates `three-tier` if missing |

```
three-tier-gitops (GitHub)
        ▲  pull every ~3 min
        │
   Argo CD (in cluster) ── helm template ── kubectl apply ──► namespace three-tier
```

> Argo CD uses Helm **only to render** templates. `helm list` will show **nothing**; the Argo CD UI is where you see the app.

---

## Lab

### 5.1 Create the Application

```bash
# 🖥️ BASTION
cd ~/three-tier-gitops && git pull
```
```bash
kubectl apply -f argocd/three-tier-dev.yaml
```

### 5.2 Watch it sync

```bash
kubectl get applications -n argocd
```

Wait for `SYNC STATUS: Synced` and `HEALTH STATUS: Healthy`. In the Argo CD UI, click `three-tier-dev` to see the tree: Deployments → ReplicaSets → Pods, StatefulSet → Pod → PVC.

```bash
kubectl get svc frontend -n three-tier
```

Open the new LB URL. Your old tasks are still there (same PVC).

### 5.3 GitOps test 1: change Git, cluster follows

On the 💻 laptop, edit `~/three-tier-gitops/values/dev.yaml`: set `frontend.replicas: 3`.

```bash
# 💻 LAPTOP
cd ~/three-tier-gitops
```
```bash
git commit -am "dev: frontend 3 replicas" && git push
```

Within ~3 min (or click **Refresh** in the UI):

```bash
# 🖥️ BASTION
kubectl get deploy frontend -n three-tier
```

`READY 3/3`, and you never ran kubectl or helm to make it happen.

### 5.4 GitOps test 2: self-heal

```bash
# 🖥️ BASTION
kubectl scale deploy backend -n three-tier --replicas=5
```
```bash
kubectl get deploy backend -n three-tier -w
```

Argo CD sets it back to 2, because Git says 2.

---

## ✅ Check before Step 06

| Check | Expected |
|---|---|
| App in Argo CD | Synced + Healthy |
| Git change (replicas) | applied automatically |
| Manual `kubectl scale` | reverted by Argo CD |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ComparisonError ... repository not found` | Repo must be public, or add it in Argo CD → Settings → Repositories |
| `values/dev.yaml: no such file` | Check `path` + `valueFiles` in the Application; the folder must exist in `main` |
| Stuck `Progressing` | `kubectl get pods -n three-tier`, then the same fixes as Step 04 |
| Change not picked up | UI → **Refresh**, or `kubectl -n argocd annotate app three-tier-dev argocd.argoproj.io/refresh=hard --overwrite` |

## Interview one-liners

- **Push vs pull deployment?** → Push: CI runs kubectl/helm with cluster credentials. Pull (GitOps): an agent in the cluster pulls from Git, so CI needs no cluster access.
- **What is drift and how do you handle it?** → Live state differs from Git. Argo CD shows it as OutOfSync, and `selfHeal` reverts it.
