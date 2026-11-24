# Step 08 — Service Mesh: Encrypted Traffic and Allow-Lists with Istio Ambient

[⬅ Back to the project overview](../README.md) · [⬅ Step 07](../step-07-kyverno/README.md) · [Step 09 ➡](../step-09-high-availability/README.md)

## What you will build in this step

All traffic **between** the app's services is **encrypted (mTLS)** and **allowed only on the right path**: frontend → backend → mysql. Anything else is refused, even from inside the cluster.

```
ALB ──plain HTTP──► frontend ══mTLS══► backend ══mTLS══► mysql
                       ▲                  ▲                 ▲
                       │                  │ ALLOW only      │ ALLOW only
                       │                  │ sa/frontend     │ sa/backend
 test Pod (no identity) ───────────X──────┘                 │
 frontend ──────────────────────────────────────────X───────┘   (frontend may NOT talk to the DB)

 How: ztunnel (DaemonSet, one per node) encrypts and checks every connection. No sidecars.
```

| Item | Value |
|---|---|
| Needs | Steps 03–07 |
| Runs on | 🖥️ Bastion |
| Istio | **1.31.4**, **ambient** mode (supports Kubernetes 1.36) |
| New AWS resources | none |
| Time | ~45 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### What is a service mesh?

**Definition:** a layer that handles **service-to-service traffic** for you: encryption, identity, access rules and traffic metrics, **without changing the app code**.

- Pods talk to each other all the time: frontend → backend → mysql.
- A mesh puts a **small helper** on the path of that traffic.
- The helper **encrypts** it, **checks who is calling**, and **blocks** callers that aren't allowed. The app doesn't notice.

**Analogy 🏢:** an office where every internal letter goes in a **sealed envelope** (encryption), with the **sender's ID card** checked (identity), and a **guard list** at each door: "the database room accepts letters only from the backend team" (authorization).

### Why do we need it? Isn't the cluster private?

**Definition:** **zero trust** = never trust a connection just because it comes from **inside** the network. Check **every** connection.

- Without a mesh, Pod-to-Pod traffic is **plain text** (anyone on the path can read it).
- **Any Pod can call any Pod**, even MySQL directly.
- If **one** Pod is hacked, the attacker can read traffic or connect straight to the database.

```
Without mesh                              With mesh (our setup)
hacked Pod ──plain text──► mysql ✅ 😱      hacked Pod ──► mysql ❌ "not allowed"
frontend ──plain text──► backend           frontend ══mTLS 🔒══► backend ══mTLS 🔒══► mysql
```

| | No mesh | **Istio mesh** |
|---|---|---|
| Traffic between Pods | Plain text ❌ | Encrypted (mTLS) ✅ |
| Who may call MySQL | Any Pod ❌ | Only backend ✅ |
| App code changes | — | None ✅ |

> **Interview one-liner:** "Inside a cluster any Pod can reach any Pod in plain text; a service mesh adds mTLS and identity-based allow-lists for zero trust, without code changes."

### mTLS (mutual TLS)

**Definition:** **TLS** encrypts a connection (the 🔒 in HTTPS). **mTLS** = **mutual** TLS: **both** sides show a certificate, so each side knows **exactly who** the other is.

**Analogy 🪪:** normal TLS is a shop showing **its** licence to you. mTLS is **both** of you showing ID cards before talking.

| | Normal TLS (HTTPS website) | **mTLS** |
|---|---|---|
| Who proves identity | Only the server | **Both** sides |
| Encrypted | Yes | Yes |
| Identity | Domain name | Workload identity: `cluster.local/ns/three-tier/sa/backend` |

The identity comes from the **ServiceAccount** (Step 04). Istio issues short-lived certificates to each workload and rotates them automatically.

> **Interview one-liner:** "mTLS means both client and server present certificates; Istio gives each ServiceAccount its own certificate and rotates it automatically."

### Sidecar vs ambient

**Definition:** 2 ways Istio puts its helper proxy on the traffic path. **Sidecar** = an extra proxy container **inside every Pod**. **Ambient** = **one shared proxy per node** (called **ztunnel**).

**Analogy 🚌:** sidecar = every passenger gets their **own bodyguard**. Ambient = **one guard per bus** protects everyone on it.

```
Sidecar:   [ app + envoy ]  [ app + envoy ]  [ app + envoy ]     ← proxy in every Pod
Ambient:   [ app ]  [ app ]  [ app ]  ──── ztunnel (1 per node)  ← Pods untouched ✅
```

| | Sidecar mode (classic) | **Ambient mode** ✅ (we use it) |
|---|---|---|
| How | An Envoy proxy container inside **every** Pod | One **ztunnel** per node handles all Pods on it |
| Pod changes | Pods restarted, an extra container injected | **None**: Pods are not touched |
| Pod Security `restricted` | Needs a privileged init container (conflicts) ❌ | Works ✅ (the privileged parts run in `istio-system`) |
| Resources | One proxy per Pod | One ztunnel per node |
| L7 features (retries, HTTP routing) | Built in | Add an optional **waypoint** proxy |

Ambient is the better fit for our hardened namespace.

> **Interview one-liner:** "We use Istio ambient mode: a per-node ztunnel does mTLS, so Pods need no sidecar and still pass Pod Security restricted."

### The 4 Istio parts we install

**Definition:** Istio is split into a **control plane** (the brain: hands out certificates and rules) and a **data plane** (the workers: actually encrypt and check traffic).

```
istiod (brain 🧠) ──certificates + rules──► ztunnel on every node (workers 💪) ──► mTLS between Pods
```

| Chart | Runs as | Job |
|---|---|---|
| `base` | CRDs only | Istio's object types (PeerAuthentication, AuthorizationPolicy...) |
| `istiod` | Deployment (system node) | Control plane: issues certificates, sends config |
| `cni` | DaemonSet (every node) | Redirects traffic of mesh Pods to ztunnel |
| `ztunnel` | DaemonSet (every node) | Data plane: mTLS + authorization for all Pods on the node |

### PeerAuthentication and AuthorizationPolicy

**Definition:** 2 Istio rules. **PeerAuthentication** = *"you must come encrypted"*. **AuthorizationPolicy** = *"and only these callers may come in"*.

**Analogy 🚪:** PeerAuthentication = **"show your ID card at the door"**. AuthorizationPolicy = **the guest list** at that door.

```
frontend ──mTLS──► backend ──mTLS──► mysql
other Pod ───────► backend ❌ not on the list
other Pod ─────────────────────────► mysql ❌ not on the list
```

| Object | Question | Our setting |
|---|---|---|
| **PeerAuthentication** | *Must* callers use mTLS? | `STRICT` on backend and mysql: plain text is refused |
| **AuthorizationPolicy** | *Who* may call? | backend ← frontend only · mysql ← backend only |

**Why is the frontend not STRICT?** The ALB is outside the mesh and sends plain HTTP. In production you'd also put TLS on the ALB (HTTPS with an ACM certificate).

**Health checks:** kubelet probes are handled by ambient automatically, so they keep working with STRICT.

> **Interview one-liner:** "PeerAuthentication STRICT forces mTLS; AuthorizationPolicy allows only named ServiceAccounts, so mysql accepts connections from backend only."

### Mesh vs NetworkPolicy

**Definition:** a **NetworkPolicy** is Kubernetes' built-in **firewall** between Pods, based on **labels / IPs**. Istio's AuthorizationPolicy is based on **certificates** (who you really are).

**Analogy 🏠:** NetworkPolicy checks the **house address** a letter came from. Istio checks the **signature** on it. An address can be faked more easily than a signature.

| | Kubernetes NetworkPolicy | Istio AuthorizationPolicy |
|---|---|---|
| Based on | IP addresses / labels | **Cryptographic identity** (certificate) |
| Encryption | No | Yes (mTLS) |
| On EKS | Needs the VPC CNI network policy feature turned on | Works with ambient |

Many companies use **both** (defence in depth). We use Istio here.

> **Interview one-liner:** "NetworkPolicy filters by IP and labels without encryption; Istio authorizes by certificate identity and encrypts with mTLS, and many teams use both."

## 1.2 The code, file by file

### `platform/values/istiod.yaml`

```yaml
profile: ambient
resources:
  requests:
    cpu: 100m
    memory: 512Mi
```

| Line | Explained |
|---|---|
| `profile: ambient` | Turn on ambient mode in the control plane |
| `resources.requests` | Default asks for 500m CPU + 2 GiB: too much for our 2 small system nodes |

**In simple steps:**
1. Settings for **istiod**, Istio's brain (control plane).
2. `profile: ambient` → run in **ambient** mode (ztunnel per node, no sidecars).
3. Ask for **less CPU and memory** than the default, so it fits on our small system nodes.

### `platform/values/istio-cni.yaml`

```yaml
profile: ambient
```

ztunnel needs no values: its default tolerations already let it run on **every** node, including the tainted app nodes.

**In simple steps:**
1. Settings for **istio-cni**, a DaemonSet on every node.
2. `profile: ambient` → it **redirects** traffic of mesh Pods into the node's **ztunnel**.
3. That redirect is what lets ambient work **without changing the Pods**.

### `helm/three-tier/templates/mesh.yaml` (turned on with `mesh.enabled=true`)

```yaml
{{- range $app := list "backend" "mysql" }}
---
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: {{ $app }}-strict-mtls
spec:
  selector:
    matchLabels:
      app: {{ $app }}
  mtls:
    mode: STRICT
{{- end }}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: backend-allow-frontend
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/three-tier/sa/frontend"]
    - from:
        - source:
            namespaces: ["monitoring"]       # Step 11: Prometheus
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: mysql-allow-backend
spec:
  selector:
    matchLabels:
      app: mysql
  action: ALLOW
  rules:
    - from:
        - source:
            principals: ["cluster.local/ns/three-tier/sa/backend"]
```

| Line | Explained |
|---|---|
| `range $app := list "backend" "mysql"` | One STRICT PeerAuthentication each |
| `selector.matchLabels.app` | Which Pods the rule protects |
| `mode: STRICT` | Only mTLS connections are accepted |
| `action: ALLOW` + `rules` | Once an ALLOW policy exists for a workload, **everything not listed is denied** |
| `principals: [".../sa/frontend"]` | The caller's identity = namespace + ServiceAccount |
| `namespaces: ["monitoring"]` | Prometheus (Step 11) may scrape `/metrics` |

**In simple steps:** this file creates **4 rules**.
1. **PeerAuthentication `backend-strict-mtls`:** backend accepts **only mTLS** (encrypted, with an ID). Plain text is refused.
2. **PeerAuthentication `mysql-strict-mtls`:** same for mysql.
3. **AuthorizationPolicy `backend-allow-frontend`:** backend accepts calls **only** from ServiceAccount `frontend` (and from the `monitoring` namespace for Step 11). Everyone else is denied.
4. **AuthorizationPolicy `mysql-allow-backend`:** mysql accepts calls **only** from ServiceAccount `backend`.

```
frontend (sa/frontend) ══mTLS══► backend ✅      anyone else ──► backend ❌
backend  (sa/backend)  ══mTLS══► mysql   ✅      anyone else ──► mysql   ❌ (even frontend)
Prometheus (ns monitoring) ═════► backend /metrics ✅
```

The identity `cluster.local/ns/three-tier/sa/frontend` = **namespace + ServiceAccount** (Step 04's ServiceAccounts in action).

### Joining the mesh: one label

```bash
kubectl label namespace three-tier istio.io/dataplane-mode=ambient
```

All Pods in the namespace join ambient **without a restart**.

**In simple steps:**
1. Add the label `istio.io/dataplane-mode=ambient` to the **namespace**.
2. istio-cni sees it and sends all Pod traffic in that namespace through **ztunnel**.
3. Pods are **not restarted** and **not changed**. From that moment, their traffic is mTLS.

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Prove traffic is wide open today      🖥️
Task 2  Install Istio (ambient)               🖥️
Task 3  Add the app to the mesh               🖥️
Task 4  Turn on STRICT mTLS + allow-lists     🖥️
Task 5  Prove the rules work                  🖥️
```

---

## Task 1 — Prove traffic is wide open today

📍 **Where:** 🖥️ Bastion

**Why:** see the problem before fixing it.

▶️ **Do:** start a test Pod in another namespace (no special identity):

```bash
kubectl create namespace mesh-test
```

```bash
kubectl run attacker -n mesh-test --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never -- sleep 3600
```

```bash
kubectl wait pod/attacker -n mesh-test --for=condition=Ready --timeout=60s
```

Call the backend directly, skipping the frontend:

```bash
kubectl exec -n mesh-test attacker -- wget -qO- -T 5 http://backend.three-tier:8080/api/tasks
```

> ❌ It works: the "attacker" reads the task list. And MySQL's port is open to it too:

```bash
kubectl exec -n mesh-test attacker -- sh -c 'nc -w 3 mysql.three-tier 3306 </dev/null | head -c 40; echo'
```

> ❌ Prints MySQL's greeting (you can read `8.4...` in it): the database port answers anyone. That's what we fix.

---

## Task 2 — Install Istio (ambient)

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add istio https://blob.istio.io/istio-release/charts && helm repo update
```

> Istio's official chart repo. (Old guides use `istio-release.storage.googleapis.com`; it doesn't have 1.31.)

Install the 4 parts **in this order** (each waits until ready):

```bash
helm install istio-base istio/base --version 1.31.4 -n istio-system --create-namespace --wait
```

```bash
helm install istiod istio/istiod --version 1.31.4 -n istio-system -f ~/k8s-eks-projects/05-production-eks/platform/values/istiod.yaml --wait
```

```bash
helm install istio-cni istio/cni --version 1.31.4 -n istio-system -f ~/k8s-eks-projects/05-production-eks/platform/values/istio-cni.yaml --wait
```

```bash
helm install ztunnel istio/ztunnel --version 1.31.4 -n istio-system --wait
```

✅ **Check:**

```bash
kubectl get pods -n istio-system -o wide
```

> ✅ `istiod` ×1 on a system node; `istio-cni-node` ×4 and `ztunnel` ×4 (one per node, **including** app nodes).

---

## Task 3 — Add the app to the mesh

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl label namespace three-tier istio.io/dataplane-mode=ambient
```

✅ **Check:** the Pods **did not restart** (same AGE), and the app still works:

```bash
kubectl get pods -n three-tier
```

```bash
curl -s http://$(kubectl get ingress frontend -n three-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/api/tasks
```

> ✅ JSON list of tasks.

Traffic is now **encrypted**, but still **allowed** from anywhere (no rules yet). The attacker test from Task 1 still works.

---

## Task 4 — Turn on STRICT mTLS and the allow-lists

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks
```

```bash
helm upgrade three-tier ./helm/three-tier -n three-tier --reuse-values --set mesh.enabled=true
```

✅ **Check:**

```bash
kubectl get peerauthentication,authorizationpolicy -n three-tier
```

> ✅ 2 PeerAuthentications (backend, mysql) and 2 AuthorizationPolicies.

---

## Task 5 — Prove the rules work

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

**1. The real path still works** (browser → ALB → frontend → backend → mysql):

```bash
curl -s http://$(kubectl get ingress frontend -n three-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/api/tasks
```

> ✅ JSON list.

**2. The attacker can't reach the backend:**

```bash
kubectl exec -n mesh-test attacker -- wget -qO- -T 5 http://backend.three-tier:8080/api/tasks
```

> ✅ Fails (`Connection reset` / `timed out`): plain text is refused by STRICT mode.

**3. The attacker can't reach MySQL:**

```bash
kubectl exec -n mesh-test attacker -- sh -c 'nc -w 3 mysql.three-tier 3306 </dev/null | head -c 40; echo'
```

> ✅ Prints nothing (connection reset): no MySQL greeting any more.

**4. Even the frontend can't reach MySQL directly** (it has a valid identity, but not the right one):

```bash
kubectl exec -n three-tier deploy/frontend -- sh -c 'nc -w 3 mysql 3306 </dev/null | head -c 40; echo'
```

> ✅ Prints nothing: only `sa/backend` is allowed. (Before Task 4 the same command printed the greeting.)

See ztunnel deciding (look for `RBAC` / `denied` lines):

```bash
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep -i -E "deny|denied|rbac" | tail -5
```

Clean up the test namespace:

```bash
kubectl delete namespace mesh-test
```

✅ **Check:** real traffic works ✅, attacker blocked ✅, frontend → mysql blocked ✅.

🎉 **Step 08 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| App returns 503 after Task 4 | backend can't reach mysql | `kubectl get authorizationpolicy mysql-allow-backend -n three-tier -o yaml`: principal must be `cluster.local/ns/three-tier/sa/backend` |
| ztunnel not on app nodes | Tolerations missing | `kubectl get ds ztunnel -n istio-system -o yaml \| grep -A8 tolerations` |
| `istiod` Pending | Not enough CPU on system nodes | `kubectl describe pod -n istio-system -l app=istiod`. Increase `system_nodes.desired` to 3 in `terraform.tfvars` and apply |
| Attacker still connects | Namespace label missing | `kubectl get ns three-tier --show-labels` must show `istio.io/dataplane-mode=ambient` |
| ALB health checks fail | STRICT set on the frontend | Frontend must stay PERMISSIVE (no PeerAuthentication on it) |

## Interview Questions

### Other Questions

**Q1. What problems does a service mesh solve?**
Encryption in transit (mTLS), workload identity, service-to-service authorization, and traffic visibility, without changing app code.

**Q2. Sidecar vs ambient mode?**
Sidecar injects an Envoy proxy in every Pod. Ambient uses a per-node ztunnel for L4 mTLS and authorization, plus optional waypoint proxies for L7. It's lighter, needs no Pod restarts, and works with PSS restricted.

**Q3. PeerAuthentication vs AuthorizationPolicy?**
PeerAuthentication says whether mTLS is required. AuthorizationPolicy says who (which identity/namespace) may call a workload.

**Q4. Where does a workload's identity come from?**
From its Kubernetes ServiceAccount, encoded as a SPIFFE ID like `cluster.local/ns/three-tier/sa/backend` in a short-lived certificate issued by istiod.

**Q5. Why not STRICT on the frontend?**
It receives traffic from the ALB, which is outside the mesh. Protect that hop with HTTPS on the load balancer.

**Q6. NetworkPolicy or Istio?**
NetworkPolicy filters by IP/labels at L3/L4; Istio adds encryption and identity-based rules. Use both for defence in depth.
