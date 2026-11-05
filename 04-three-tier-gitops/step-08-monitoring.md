# Step 08 (Extra) — Monitoring with kube-prometheus-stack

Install Prometheus + Grafana + Node Exporter with **one Helm chart someone else wrote**, then point it at **your** backend with one small YAML (ServiceMonitor).

## About this step

| Item | Value |
|---|---|
| Where | 🖥️ Bastion |
| Chart | `prometheus-community/kube-prometheus-stack` (YAML written by the community) |
| My files | [monitoring/values.yaml](./monitoring/values.yaml) + `servicemonitor.yaml` in our chart |
| Namespace | `monitoring` |

## Concepts

| Component | K8s kind (chosen by the chart authors) | Job |
|---|---|---|
| Prometheus | StatefulSet (via Operator) | Scrapes and stores metrics |
| Grafana | Deployment | Dashboards |
| Node Exporter | **DaemonSet** (1 pod per node) | Node CPU/memory/disk |
| kube-state-metrics | Deployment | Pod/Deployment status as metrics |
| Prometheus Operator | Deployment | Watches `ServiceMonitor` objects → updates scrape config |

**ServiceMonitor:** "Prometheus, scrape Services with label `app: backend` on port `http` at `/metrics`." Prometheus only picks it up if it carries the label `release: kube-prometheus-stack`.

```
backend pods /metrics ◄── scrape ── Prometheus ◄── query ── Grafana (LB) ◄── you
        ▲                                 ▲
  Service backend (app=backend)    ServiceMonitor (release=kube-prometheus-stack)
```

---

## Lab

### 8.1 Install the stack

```bash
# 🖥️ BASTION
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
```
```bash
helm repo update
```
```bash
cd ~/k8s-eks-projects && git pull && cd 04-three-tier-gitops/monitoring
```
```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f values.yaml
```
```bash
kubectl get pods -n monitoring -o wide
```

You'll see one `node-exporter` pod **per node** (that's the DaemonSet).

### 8.2 Turn on the ServiceMonitor through GitOps

In `~/three-tier-gitops/values/dev.yaml` set:

```yaml
metrics:
  serviceMonitor:
    enabled: true
```

```bash
# 💻 LAPTOP
cd ~/three-tier-gitops
```
```bash
git commit -am "dev: enable backend ServiceMonitor" && git push
```

```bash
# 🖥️ BASTION
kubectl get servicemonitor -n three-tier
```

### 8.3 Open Grafana

```bash
kubectl get svc kube-prometheus-stack-grafana -n monitoring
```

Open `http://<EXTERNAL-IP>` and log in as `admin` / `admin123`.

- **Dashboards → Kubernetes / Compute Resources / Namespace (Pods)** → namespace `three-tier`
- **Dashboards → Node Exporter / Nodes** → node CPU/memory
- **Explore** → Prometheus → run: `sum(rate(http_requests_total{namespace="three-tier"}[1m])) by (route)`

Use the app in the browser and watch the request rate go up.

---

## ✅ Check before Step 09

| Check | Expected |
|---|---|
| node-exporter pods | 1 per node |
| Prometheus → Status → Targets | `serviceMonitor/three-tier/backend` **UP** |
| Grafana query | `http_requests_total` shows data |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Argo CD: `no matches for kind "ServiceMonitor"` | Install the stack (8.1) **before** enabling the ServiceMonitor |
| Target missing in Prometheus | Label `release: kube-prometheus-stack` must match the Helm release name |
| Grafana URL not opening | Wait for the LB DNS (2–3 min) |

## Interview one-liners

- **Did you write YAML for Prometheus?** → No. I used kube-prometheus-stack and customized `values.yaml`. For my app I only wrote a ServiceMonitor.
- **Why is Node Exporter a DaemonSet?** → It must run on every node to read that node's metrics.
