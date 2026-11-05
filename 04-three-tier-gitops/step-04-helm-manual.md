# Step 04 — Deploy with Helm (by hand)

Install the chart yourself with `helm install`. In Step 05, Argo CD takes over this job.

## About this step

| Item | Value |
|---|---|
| Where | 🖥️ Bastion |
| Chart | `three-tier-gitops/charts/three-tier` (written by **us**, not downloaded) |
| Namespace | `three-tier` |
| Result | App open on a public AWS load balancer URL |

## Concepts

**Helm chart:** a folder of YAML **templates** + `values.yaml`. Helm fills `{{ .Values.x }}` and applies the result.
**Release:** one installed copy of a chart (`helm list`).

### What the chart creates

| Template | Objects | Why |
|---|---|---|
| `frontend.yaml` | Deployment (2) + Service **LoadBalancer** | Stateless, public |
| `backend.yaml` | ConfigMap + Deployment (2) + Service **ClusterIP** | Stateless, internal only |
| `mysql.yaml` | Secret + **headless** Service + **StatefulSet** (1) + PVC | Stateful: stable name `mysql-0` + own EBS disk |
| `storageclass.yaml` | StorageClass `gp3` | EKS 1.30+ has no default StorageClass |
| `servicemonitor.yaml` | ServiceMonitor (off until Step 08) | Prometheus scraping |

```
                 AWS LB (public)
                      │
         ┌── Service frontend (LoadBalancer) ──┐
         │  frontend pod   frontend pod        │   Deployment
         └──────────────┬──────────────────────┘
                        │ http://backend:8080
         ┌── Service backend (ClusterIP) ──────┐
         │  backend pod    backend pod         │   Deployment
         └──────────────┬──────────────────────┘
                        │ mysql:3306
         ┌── Service mysql (headless) ─────────┐
         │  mysql-0 ── PVC data-mysql-0 ── EBS gp3   StatefulSet
         └─────────────────────────────────────┘
```

**Values order:** `charts/three-tier/values.yaml` (defaults) → `values/dev.yaml` (overrides) → `--set` (highest).

---

## Lab

### 4.1 Get the gitops repo on the bastion

```bash
# 💻 LAPTOP
ssh -i ~/.ssh/abhigna-eks-key.pem ubuntu@<bastion-ip>
```
```bash
# 🖥️ BASTION
git clone https://github.com/Abhignadumpala/three-tier-gitops.git
```
```bash
cd three-tier-gitops
```

### 4.2 See what Helm will create (no install yet)

```bash
helm lint charts/three-tier -f values/dev.yaml
```
```bash
helm template three-tier charts/three-tier -f values/dev.yaml -n three-tier | less
```

Find each `kind:` and match it to the table above.

### 4.3 Install

```bash
helm install three-tier charts/three-tier -f values/dev.yaml -n three-tier --create-namespace
```

### 4.4 Watch it come up

```bash
kubectl get pods -n three-tier -w
```

Expected order: `mysql-0` starts (~1 min). The backend pods become `READY 1/1` once the DB answers, and the frontend becomes ready right away. Press Ctrl+C to stop watching.

```bash
kubectl get pvc -n three-tier
```

`data-mysql-0` → `Bound` (an EBS volume was created).

### 4.5 Open the app

```bash
kubectl get svc frontend -n three-tier
```

Copy `EXTERNAL-IP` (a `...elb.amazonaws.com` name) and open `http://<that-name>` in the 💻 laptop browser after 2–3 min. Add some tasks.

### 4.6 Prove the StatefulSet keeps data

```bash
kubectl delete pod mysql-0 -n three-tier
```
```bash
kubectl get pods -n three-tier -w
```

`mysql-0` comes back **with the same name**, re-attaches the **same disk**, and your tasks are still there.

### 4.7 Try a manual upgrade and rollback

```bash
helm upgrade three-tier charts/three-tier -f values/dev.yaml -n three-tier --set backend.replicas=3
```
```bash
helm history three-tier -n three-tier
```
```bash
helm rollback three-tier 1 -n three-tier
```

### 4.8 Uninstall (Argo CD takes over in Step 05)

```bash
helm uninstall three-tier -n three-tier
```

> The PVC `data-mysql-0` is **not** deleted by `helm uninstall` (StatefulSet PVCs are kept on purpose). Argo CD will reuse it, so your tasks survive the move.

---

## ✅ Check before Step 05

| Check | Expected |
|---|---|
| App worked on the LB URL | tasks saved |
| Deleting `mysql-0` kept the data | yes |
| `helm list -n three-tier` after uninstall | empty |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `mysql-0` and PVC `Pending` | EBS CSI driver not running | Step 01 → 1.4; `kubectl describe pvc data-mysql-0 -n three-tier` |
| `ImagePullBackOff` | Wrong username/tag, or Docker Hub repo is private | `kubectl describe pod <pod> -n three-tier`; fix `values/dev.yaml` |
| backend `0/1 Running` | Readiness waits for the DB | Wait for `mysql-0`; `kubectl logs deploy/backend -n three-tier` |
| `storageclasses "gp3" already exists` | Created earlier by another release | `--set storageClass.create=false` |
| MySQL log: *data directory has files* | Mounted disk not empty | The chart uses `subPath: mysql`; keep it |

## Interview one-liners

- **Why a headless Service for MySQL?** → It gives each StatefulSet pod a stable DNS name (`mysql-0.mysql`) instead of load-balancing across pods.
- **Why are StatefulSet PVCs kept on delete?** → To protect data. You delete them on purpose when you really want the data gone.
- **`helm template` vs `helm install`?** → `template` only renders YAML locally. `install` renders it and applies it as a tracked release.
