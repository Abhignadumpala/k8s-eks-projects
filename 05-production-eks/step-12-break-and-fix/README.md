# Step 12 — Break & Fix: Real Troubleshooting Drills

[⬅ Back to the project overview](../README.md) · [⬅ Step 11](../step-11-observability/README.md) · [Step 13 ➡](../step-13-cleanup/README.md)

## What you will do in this step

Break the app **on purpose**, 5 different ways, and fix it **like an on-call engineer**: symptom → investigate → root cause → fix. At the end, **Git puts everything back** in one command.

| # | Drill | What you'll see |
|---|---|---|
| 1 | Bad image tag | New Pods **never appear** (not even ImagePullBackOff) |
| 2 | Bad config | `CrashLoopBackOff` |
| 3 | Impossible resource request | `Pending` forever |
| 4 | Database down | Browser shows **502 Bad Gateway** for API calls |
| 5 | Wrong mesh rule | Backend `0/1 Ready`, `connection reset` to MySQL |

| Item | Value |
|---|---|
| Needs | Steps 03–11 |
| Runs on | 🖥️ Bastion |
| Time | ~60 min |

---

# Part 1 — Understand (read first)

## The troubleshooting method (use it every time)

**Definition:** a **troubleshooting method** is a fixed order of checks, so you find the real cause **step by step** instead of guessing.

- Start from **what users see** (symptom), then narrow down to **one broken object**.
- Read what **Kubernetes** says (events), then what the **app** says (logs).
- Change **one thing** at a time, and **check** the symptom is really gone.

**Analogy 🩺:** a doctor: listen to the patient (symptom) → find where it hurts (scope) → check the test results (events, logs) → diagnose (root cause) → treat and re-check.

```
1. SYMPTOM      What do users / alerts see?             (browser, curl, Grafana, alerts)
2. SCOPE        Which object is unhealthy?               kubectl get pods,deploy,rs,rollout -n three-tier
3. EVENTS       What did Kubernetes say?                 kubectl describe <object>   (read Events at the bottom)
4. LOGS         What did the app say?                    kubectl logs <pod> [--previous]
5. ROOT CAUSE   One sentence: "X because Y"
6. FIX + VERIFY Change one thing, check the symptom is gone
```

> **Interview one-liner:** "I go symptom → scope → events (`kubectl describe`) → logs (`--previous`) → one-sentence root cause → one fix, then verify."

## Pod status cheat sheet

**Definition:** the **STATUS** column in `kubectl get pods` tells you **at which stage** a Pod is stuck: before a node is chosen, while downloading the image, or after the app started.

```
Pending ──► ContainerCreating ──► Running (0/1 → 1/1 Ready ✅)
  │ no node fits    │ image / volume         │ app crashes
  ▼                 ▼                        ▼
Pending         ImagePullBackOff        CrashLoopBackOff / OOMKilled
```

| Status | Means | First command |
|---|---|---|
| `Pending` | Not scheduled on any node | `kubectl describe pod` → Events: `Insufficient cpu`, `untolerated taint`, `volume node affinity` |
| `ContainerCreating` (long) | Volume or network setup stuck | `kubectl describe pod` |
| `ImagePullBackOff` / `ErrImagePull` | Can't download the image | `kubectl describe pod` → wrong name/tag, no permission |
| `CrashLoopBackOff` | Starts, then exits, again and again | `kubectl logs <pod> --previous` |
| `Running` but `0/1` | Readiness probe failing | `kubectl describe pod` → `Readiness probe failed`; check dependencies |
| `OOMKilled` | Used more memory than its limit | Raise the limit or fix the leak |
| No Pod at all | The controller can't create it | `kubectl describe rs` / `rollout` → `FailedCreate` (admission webhook, quota) |

## HTTP errors at the edge

**Definition:** the **edge** is the entry point users hit (the ALB and nginx). When it can't get a good answer from behind, it returns a **5xx** error code.

**Analogy 📞:** a receptionist (ALB) forwarding a call. 502 = the line behind is **dead**. 503 = **nobody is available**. 504 = the person **took too long** to answer.

| Error | Usually means |
|---|---|
| **502 Bad Gateway** | The proxy (nginx/ALB) reached nothing behind it: no ready backend, connection refused |
| **503 Service Unavailable** | ALB has no healthy targets; or the app says "not ready" |
| **504 Gateway Timeout** | Something behind is too slow |

## Why we pause Argo CD first

- Argo CD **self-heal** undoes manual changes within seconds.
- In production that's great; here it would "fix" our drills **before we can study them**.
- So we **pause auto-sync** at the start and turn it back on at the end.

**Analogy 🧹:** a cleaner who instantly tidies the room. Great normally, but you ask them to wait while you practise finding the mess.

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

## Task 0 — Prepare

📍 **Where:** 🖥️ Bastion

▶️ **Do:** pause GitOps auto-sync:

```bash
kubectl patch application three-tier -n argocd --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

Save the app URL for quick checks:

```bash
export URL=http://$(kubectl get ingress frontend -n three-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
```

```bash
curl -s -o /dev/null -w "%{http_code}\n" $URL/api/tasks
```

> ✅ `200`: healthy starting point.

---

## Drill 1 — Bad image tag

▶️ **Break:**

```bash
kubectl set image deploy/frontend -n three-tier frontend=$ECR/prod-frontend:v999
```

**Symptom:** the app still works (old Pods keep running), but the rollout never finishes:

```bash
kubectl rollout status deploy/frontend -n three-tier --timeout=30s
```

**Investigate:**

```bash
kubectl get pods -n three-tier -l app=frontend
```

> No new Pod at all, not even `ImagePullBackOff`. So look one level **up**, at the ReplicaSet:

```bash
kubectl describe rs -n three-tier -l app=frontend | grep -A3 FailedCreate
```

**Root cause:** `admission webhook ... denied the request`, with an error about the image (no signature / manifest unknown). `v999` doesn't exist, so Kyverno can't verify a signature and **refuses to create the Pod**. (Without Kyverno you would see `ImagePullBackOff` instead.)

▶️ **Fix:**

```bash
kubectl rollout undo deploy/frontend -n three-tier && kubectl rollout status deploy/frontend -n three-tier
```

✅ **Check:** `successfully rolled out`.

> 💡 Lesson: a Deployment that "doesn't roll out" with no new Pods → `describe rs` → `FailedCreate`.

---

## Drill 2 — Bad config → CrashLoopBackOff

▶️ **Break:** a typo in the backend address:

```bash
kubectl set env deploy/frontend -n three-tier BACKEND_URL=http://backendd:8080
```

**Symptom:**

```bash
kubectl get pods -n three-tier -l app=frontend -w
```

> New Pods: `Error` → `CrashLoopBackOff`, restarts going up. (`Ctrl+C`.) The old Pods keep serving users, which is why rolling updates are safe.

**Investigate:** logs of the **previous** (crashed) run:

```bash
kubectl logs -n three-tier $(kubectl get pods -n three-tier -l app=frontend --sort-by=.metadata.creationTimestamp -o name | tail -1) --previous | tail -3
```

**Root cause:** `host not found in upstream "backendd"`: nginx checks the backend name at start, can't resolve it, and exits.

▶️ **Fix:**

```bash
kubectl rollout undo deploy/frontend -n three-tier && kubectl rollout status deploy/frontend -n three-tier
```

✅ **Check:** all frontend Pods `1/1 Running`.

---

## Drill 3 — Impossible request → Pending

▶️ **Break:** ask for 8 CPUs per Pod (our biggest allowed node has 4):

```bash
kubectl set resources deploy/frontend -n three-tier --requests=cpu=8
```

**Symptom:**

```bash
kubectl get pods -n three-tier -l app=frontend
```

> A new Pod stays `Pending`.

**Investigate:**

```bash
kubectl describe pod -n three-tier $(kubectl get pods -n three-tier -l app=frontend --field-selector=status.phase=Pending -o name | head -1) | tail -5
```

> `0/4 nodes are available: 2 Insufficient cpu, 2 node(s) didn't match Pod's node affinity/selector...`

Why doesn't Karpenter add a node?

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50 | grep -i -E "incompatible|could not schedule" | tail -2
```

**Root cause:** no instance type in our NodePool (`large`/`xlarge`, max 4 vCPU) can fit 8 CPUs. Karpenter **correctly refuses**, because the NodePool is our cost guard.

▶️ **Fix:**

```bash
kubectl rollout undo deploy/frontend -n three-tier && kubectl rollout status deploy/frontend -n three-tier
```

---

## Drill 4 — Database down → 502

▶️ **Break:**

```bash
kubectl scale statefulset mysql -n three-tier --replicas=0
```

**Symptom:** the page loads (frontend is fine) but the task list fails:

```bash
curl -s -o /dev/null -w "%{http_code}\n" $URL/api/tasks
```

> `502` (nginx found no ready backend) or `500`.

**Investigate** top-down:

```bash
kubectl get pods -n three-tier
```

> backend `0/1 Running` (not Ready), no `mysql-0`.

```bash
kubectl describe pod -n three-tier -l app=backend | grep -m2 "Readiness probe failed"
```

> `HTTP probe failed with statuscode: 503`: `/api/ready` says the DB is unreachable.

```bash
kubectl get endpoints backend -n three-tier
```

> No ready addresses: the Service sends traffic nowhere → nginx returns **502**. Grafana/Prometheus shows `BackendHighErrorRate` pending.

**Root cause:** MySQL scaled to 0 → backend not Ready → removed from the Service → 502 at the edge.

▶️ **Fix:**

```bash
kubectl scale statefulset mysql -n three-tier --replicas=1 && kubectl rollout status statefulset mysql -n three-tier
```

✅ **Check:** `curl ... $URL/api/tasks` → `200`, and your tasks are still there (EBS).

> 💡 Readiness worked as designed: the broken backend got no traffic, and **liveness did not restart it** (restarting wouldn't fix a DB outage).

---

## Drill 5 — Wrong mesh rule

▶️ **Break:** change the MySQL allow-list to the wrong identity:

```bash
kubectl patch authorizationpolicy mysql-allow-backend -n three-tier --type json -p '[{"op":"replace","path":"/spec/rules/0/from/0/source/principals/0","value":"cluster.local/ns/three-tier/sa/frontend"}]'
```

Restart the backend so it opens new DB connections:

```bash
kubectl argo rollouts restart backend -n three-tier
```

**Symptom:** after ~30 s, backend Pods `0/1`, API returns 502.

**Investigate:**

```bash
kubectl logs -n three-tier -l app=backend --tail=5
```

> `DB not ready (ECONNRESET) ...` (or another connection error like `PROTOCOL_CONNECTION_LOST`): the network **resets** the connection. That's a mesh/policy sign, not a password problem (that would be `ER_ACCESS_DENIED_ERROR`).

```bash
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep -i -E "denied|rbac" | tail -3
```

> ztunnel: connection to `mysql` **denied** by policy.

```bash
kubectl get authorizationpolicy mysql-allow-backend -n three-tier -o jsonpath='{.spec.rules[0].from[0].source.principals}{"\n"}'
```

**Root cause:** the allow-list names `sa/frontend` instead of `sa/backend`.

▶️ **Fix:** this time let **GitOps** fix it, along with everything else. Turn auto-sync back on:

```bash
envsubst '${ACCOUNT_ID}' < ~/k8s-eks-projects/05-production-eks/platform/argocd/three-tier-app.yaml | kubectl apply -f -
```

✅ **Check:**

```bash
kubectl get application three-tier -n argocd
```

> ✅ `Synced`, `Healthy`. The policy is correct again (from Git), the backend is Ready, and `curl` gives `200`.

🎉 **Step 12 is done.** You've debugged admission, crash, scheduling, dependency and network failures.

---

## Your incident notes template (copy for real incidents)

| Field | Example (Drill 4) |
|---|---|
| Symptom | `/api/tasks` returns 502; alert BackendHighErrorRate |
| Impact | Users can see the page but not their tasks |
| Root cause | MySQL StatefulSet scaled to 0 |
| Fix | Scaled back to 1 |
| Prevention | GitOps self-heal on; RDS Multi-AZ; alert on `kube_statefulset_status_replicas_ready == 0` |

## Interview Questions

### Other Questions

**Q1. A Pod is in CrashLoopBackOff. What do you do?**
`kubectl logs --previous` to see why the last run exited, `kubectl describe pod` for events/exit code (OOMKilled = 137), then check config, env vars, secrets and dependencies.

**Q2. A Deployment won't roll out and there are no new Pods. Why?**
The ReplicaSet can't create them: an admission webhook (Kyverno/PSA) denied them, or a quota was hit. `kubectl describe rs` shows `FailedCreate`.

**Q3. A Pod is Pending. What do you check?**
`kubectl describe pod` events: insufficient CPU/memory, taints without tolerations, node selectors, PVC zone affinity. Then the autoscaler (Karpenter) logs.

**Q4. The site gives 502. How do you debug?**
Go layer by layer: ALB targets healthy? Service endpoints? Pod readiness? App logs? Its dependencies (DB)? Mesh policies?

**Q5. Connection reset vs access denied from a database?**
Reset/timeout = network or mesh policy. Access denied = credentials. It tells you which layer to look at.
