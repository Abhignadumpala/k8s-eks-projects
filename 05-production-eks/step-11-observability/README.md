# Step 11 — Observability: Prometheus, Grafana and Alerts

[⬅ Back to the project overview](../README.md) · [⬅ Step 10](../step-10-gitops-canary/README.md) · [Step 12 ➡](../step-12-break-and-fix/README.md)

## What you will build in this step

**See** what the cluster and the app are doing (metrics, dashboards) and **get told** when something breaks (alerts). The app's metrics are switched on **the GitOps way**: a commit to Git.

```
backend /metrics ◄──── scrape every 30 s (mTLS through the mesh) ──── Prometheus (monitoring ns, in ambient)
node-exporter (every node) ◄────────────────────────────────────────────┤
kube-state-metrics (object states) ◄────────────────────────────────────┤
                                                                          │ PromQL
                                                Grafana dashboards ◄──────┤
                                                Alertmanager ◄── alert rules (CrashLooping, 5xx > 5%, ...)
You ──ssh tunnel──► bastion ──port-forward──► Grafana / Prometheus UIs   (never public)
```

| Item | Value |
|---|---|
| Needs | Steps 03–10 (the app is managed by Argo CD) |
| Runs on | 🖥️ Bastion + 💻 Laptop (Git, ssh tunnel) |
| Chart | `kube-prometheus-stack` 93.6.1 |
| New AWS resources | none (Prometheus keeps 2 days of data inside its Pod) |
| Time | ~60 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### The 3 pillars of observability

| Pillar | Answers | Tool (this step) |
|---|---|---|
| **Metrics** | *How much / how fast / how many?* (numbers over time) | Prometheus + Grafana ✅ |
| **Logs** | *What exactly happened?* (text events) | `kubectl logs` today; Loki / CloudWatch in production |
| **Traces** | *Where did this one request spend its time?* | OpenTelemetry + Tempo/X-Ray (a next step) |

### What is in `kube-prometheus-stack`

| Part | Job |
|---|---|
| **Prometheus** | Pulls (scrapes) metrics every 30 s and stores them |
| **Prometheus Operator** | Lets you configure Prometheus with Kubernetes objects (ServiceMonitor, PrometheusRule) |
| **node-exporter** (DaemonSet) | CPU, memory, disk, network of each **node** |
| **kube-state-metrics** | The **state** of objects: restarts, replicas wanted vs ready, Pending Pods |
| **Grafana** | Dashboards (many ready-made Kubernetes ones) |
| **Alertmanager** | Receives fired alerts, groups them, sends to Slack/email/PagerDuty |

### Pull model and the ServiceMonitor

Prometheus **pulls** metrics from `/metrics` endpoints. A **ServiceMonitor** tells it *which Service and port to scrape*:

```yaml
kind: ServiceMonitor
spec:
  selector:
    matchLabels:
      app: backend          # the backend Service
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
```

Our backend exposes `http_requests_total{method, route, status}` (Step 02 `server.js`).

### PromQL basics

| Query | Means |
|---|---|
| `up` | 1 if a target was scraped OK, 0 if not |
| `http_requests_total` | Counter: total requests since start (only goes up) |
| `rate(http_requests_total[5m])` | Requests **per second**, averaged over 5 min |
| `sum by (status) (rate(...[5m]))` | Requests/s grouped by HTTP status |
| `sum(rate(...{status=~"5.."}[5m])) / sum(rate(...[5m]))` | **Error rate** (share of 5xx) |

### The 4 golden signals (Google SRE)

| Signal | Our metric |
|---|---|
| **Latency** | (add a histogram to the app: a next step) |
| **Traffic** | `rate(http_requests_total[5m])` |
| **Errors** | 5xx share |
| **Saturation** | CPU/memory vs requests (`kubectl top`, Grafana) |

### Why Prometheus must join the mesh

The backend is **STRICT mTLS** with an allow-list (Step 08). Plain-text scrapes are refused. So we put the `monitoring` namespace in **ambient** too: Prometheus gets an identity, and the backend's AuthorizationPolicy already allows `namespaces: ["monitoring"]`.

### Turning on the ServiceMonitor = a Git commit

The app is managed by Argo CD now. **Don't** use `helm upgrade` any more: change `gitops/values-prod.yaml` and push. Argo CD does the rest.

## 1.2 The code, file by file

### `platform/values/kube-prometheus-stack.yaml`

```yaml
prometheus:
  prometheusSpec:
    retention: 2d
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    resources:
      requests:
        cpu: 200m
        memory: 1Gi
kubeControllerManager:
  enabled: false
kubeScheduler:
  enabled: false
kubeEtcd:
  enabled: false
```

| Line | Explained |
|---|---|
| `retention: 2d` | Keep 2 days of data (lab). Production: weeks, on a PVC or a long-term store (Amazon Managed Prometheus) |
| `...SelectorNilUsesHelmValues: false` | Pick up **every** ServiceMonitor/PodMonitor/rule in the cluster, not only those labelled for this release |
| `kubeControllerManager/kubeScheduler/kubeEtcd: false` | EKS runs these in AWS's account: Prometheus can't reach them, so it would raise false "target down" alerts |
| Grafana password | Not set here: the chart **generates** one and stores it in a Secret |

### `helm/three-tier/templates/servicemonitor.yaml`

Rendered only when `metrics.serviceMonitor.enabled: true`. Selects the backend Service, port `http`, path `/metrics`, every 30 s.

### `platform/k8s/alerts.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: three-tier-alerts
  namespace: monitoring
spec:
  groups:
    - name: three-tier.rules
      rules:
        - alert: BackendHighErrorRate
          expr: |
            sum(rate(http_requests_total{namespace="three-tier", status=~"5.."}[5m]))
              /
            sum(rate(http_requests_total{namespace="three-tier"}[5m])) > 0.05
          for: 2m
          labels:
            severity: critical
        - alert: BackendDown
          expr: |
            sum(up{namespace="three-tier", service="backend"}) == 0
          for: 2m
```

| Line | Explained |
|---|---|
| `expr` | The PromQL condition |
| `status=~"5.."` | Regex: any 5xx status |
| `> 0.05` | More than 5% |
| `for: 2m` | Must stay true for 2 minutes (no alerts for a 10-second blip) |
| `severity: critical` | Alertmanager can route critical alerts to on-call |

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Install kube-prometheus-stack              🖥️
Task 2  Put monitoring in the mesh                 🖥️
Task 3  Turn on the app's metrics (Git commit)     📝 laptop
Task 4  Open Grafana and Prometheus                💻 tunnel + 🌐
Task 5  Queries and dashboards                     🌐
Task 6  Fire a real alert                          🖥️ + 🌐
```

---

## Task 1 — Install kube-prometheus-stack

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update
```

```bash
kubectl create namespace monitoring
```

```bash
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 93.6.1 -n monitoring -f ~/k8s-eks-projects/05-production-eks/platform/values/kube-prometheus-stack.yaml --wait --timeout 10m
```

✅ **Check:**

```bash
kubectl get pods -n monitoring
```

> ✅ `prometheus-...-0`, `alertmanager-...-0`, `...-grafana`, `...-operator`, `...-kube-state-metrics` and 4× `...-prometheus-node-exporter` (one per node), all `Running`.

---

## Task 2 — Put monitoring in the mesh

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl label namespace monitoring istio.io/dataplane-mode=ambient
```

Add our app alert rules:

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/alerts.yaml
```

✅ **Check:**

```bash
kubectl get prometheusrules -n monitoring | grep three-tier
```

> ✅ `three-tier-alerts`

---

## Task 3 — Turn on the app's metrics (a Git commit)

📍 **Where:** 📝 VS Code + 💻 laptop terminal

▶️ **Do:** in `05-production-eks/gitops/values-prod.yaml` change:

```yaml
metrics:
  serviceMonitor:
    enabled: true          # Step 11
```

```bash
cd ~/k8s-eks-projects && git pull && git add 05-production-eks/gitops/values-prod.yaml && git commit -m "prod: enable backend ServiceMonitor" && git push
```

▶️ **Do (🖥️ bastion):** wait for Argo CD (≤3 min):

```bash
kubectl get servicemonitor -n three-tier
```

✅ **Check:** `backend` appears. Nobody ran `helm` or `kubectl apply` for the app: **Git did it**.

---

## Task 4 — Open Grafana and Prometheus

📍 **Where:** 🖥️ Bastion + 💻 laptop + 🌐

▶️ **Do (🖥️ bastion):** Grafana's generated admin password:

```bash
kubectl get secret kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Forward both UIs (leave running):

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 & kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

▶️ **Do (💻 laptop, new terminal):** tunnel both ports:

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform && ssh -i ~/.ssh/abhigna-eks-key.pem -N -L 3000:localhost:3000 -L 9090:localhost:9090 ubuntu@$(terraform output -raw bastion_public_ip)
```

Open:
- **http://localhost:9090** → Prometheus. Menu **Status → Target health**
- **http://localhost:3000** → Grafana, user `admin` + the password

✅ **Check:** in Prometheus **Target health**, `serviceMonitor/three-tier/backend/0` shows **2 targets UP** (more if HPA scaled). If they're DOWN with a connection reset, Task 2's label is missing.

---

## Task 5 — Queries and dashboards

📍 **Where:** 🌐 Prometheus (localhost:9090) → **Query**

▶️ **Do:** generate some traffic: open the app in the browser and click around. Then run each query (**Graph** tab):

```promql
up{namespace="three-tier"}
```

```promql
sum by (status) (rate(http_requests_total{namespace="three-tier"}[5m]))
```

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="three-tier", container!=""}[5m]))
```

```promql
kube_deployment_status_replicas_available{namespace="three-tier"}
```

▶️ **Do (🌐 Grafana):** **Dashboards** → open:
- **Kubernetes / Compute Resources / Namespace (Pods)** → namespace `three-tier`
- **Node Exporter / Nodes**

✅ **Check:** you see CPU/memory per Pod and per node, and the request-rate graph by status (mostly `200`).

---

## Task 6 — Fire a real alert

📍 **Where:** 🖥️ Bastion + 🌐 Prometheus **Alerts** page

**Why:** an alert you never saw fire is an alert you can't trust.

▶️ **Do:** pause Argo CD's auto-sync for this test (otherwise self-heal undoes the break in seconds):

```bash
kubectl patch application three-tier -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Break the database:

```bash
kubectl scale statefulset mysql -n three-tier --replicas=0
```

The backend's `/api/ready` now answers **503** (counted in `http_requests_total`).

✅ **Check:** in Prometheus → **Alerts**: `BackendHighErrorRate` goes **Pending** (yellow), then after 2 minutes **Firing** (red). Alertmanager has it too:

```bash
kubectl exec -n monitoring alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager -- amtool alert query --alertmanager.url=http://localhost:9093
```

Fix it: turn auto-sync back on. Argo CD sees MySQL at 0 (Git says 1) and **heals it**:

```bash
envsubst '${ACCOUNT_ID}' < ~/k8s-eks-projects/05-production-eks/platform/argocd/three-tier-app.yaml | kubectl apply -f -
```

> ✅ `mysql-0` comes back with its data (EBS), the backend becomes Ready, and the alert **resolves** a few minutes later.

🎉 **Step 11 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| Backend targets `DOWN`, `connection reset` | Prometheus not in the mesh (STRICT mTLS) | Task 2 label; then `kubectl delete pod -n monitoring -l app.kubernetes.io/name=prometheus` |
| No `serviceMonitor/three-tier/backend` target | ServiceMonitor not synced | `kubectl get servicemonitor -n three-tier`; check Argo CD app status |
| Grafana login fails | Wrong password | Read it from the Secret (Task 4) |
| Helm install times out | System nodes full | `kubectl get pods -n monitoring` → Pending? Set `system_nodes.desired = 3` in `terraform.tfvars` and apply |
| `KubeControllerManagerDown`-type alerts | Control plane scraping on | Keep those `enabled: false` (EKS manages them) |

## Interview Questions

### Other Questions

**Q1. How does Prometheus collect metrics?**
It pulls them over HTTP from `/metrics` endpoints it discovers through Kubernetes service discovery. On Kubernetes, ServiceMonitors and PodMonitors (Prometheus Operator) say what to scrape.

**Q2. What is the difference between `rate()` and `increase()`?**
`rate()` gives the per-second average over the window; `increase()` gives the total increase over the window. Both handle counter resets.

**Q3. Which alerts would you set for a web service?**
The golden signals: error rate, latency (p95/p99), traffic drops, saturation; plus availability (`up == 0`), CrashLooping Pods and Pending Pods.

**Q4. Why `for: 2m` in an alert rule?**
To avoid paging on short spikes: the condition must hold for 2 minutes before firing.

**Q5. Metrics vs logs vs traces?**
Metrics show trends and trigger alerts, logs explain individual events, traces follow one request across services.

**Q6. Why not expose Grafana with a public LoadBalancer?**
It shows internal data and can run queries. Keep it private (SSH tunnel, VPN, or SSO behind an internal ALB).
