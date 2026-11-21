# Step 05 — Pod Hardening: Non-Root, Read-Only, No Extra Powers

[⬅ Back to the project overview](../README.md) · [⬅ Step 04](../step-04-rbac/README.md) · [Step 06 ➡](../step-06-pod-identity-secrets/README.md)

## What you will build in this step

You **prove** that every app container is locked down, and that the namespace **rejects** any Pod that isn't.

```
                    namespace three-tier  (Pod Security Standard: restricted)
 kubectl apply bad-root-pod.yaml ──► ❌ REJECTED: runAsUser 0, privileged, privilege escalation
 frontend / backend / mysql      ──► ✅ allowed: non-root, read-only filesystem, no capabilities
```

| Item | Value |
|---|---|
| Needs | Step 03 (app running) |
| Runs on | 🖥️ Bastion |
| New AWS resources | none (free) |
| Time | ~30 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### Why harden a Pod?

A container is **not** a virtual machine: it shares the node's Linux kernel. If a container runs as **root** with extra powers and an attacker breaks into the app, they are one step from the **node**, and from every other Pod on it.

**Analogy 🏨:** a hotel guest (container) gets a key to **their own room only**. Hardening means no master key (root), no tools to break walls (capabilities), and furniture bolted down (read-only filesystem).

### The settings, one by one

| Setting | Where | What it does | Stops |
|---|---|---|---|
| `runAsNonRoot: true` | Pod | Kubernetes refuses to start the container as root | Root inside the container |
| `runAsUser / runAsGroup` | Pod | Runs as a fixed user ID (101 nginx, 1000 node, 999 mysql) | Unknown users |
| `fsGroup` | Pod | Mounted volumes get this group, so the app can write its own disk | Permission errors on EBS |
| `seccompProfile: RuntimeDefault` | Pod | Blocks ~50 dangerous Linux system calls | Kernel exploits |
| `allowPrivilegeEscalation: false` | Container | A process can never gain more rights (no `sudo`, no setuid) | Becoming root later |
| `readOnlyRootFilesystem: true` | Container | The container can't change its own files | Attackers installing tools or changing the app |
| `capabilities: drop: ["ALL"]` | Container | Removes every special Linux power (change network, mount, kill other processes...) | Abusing root-like powers |
| `automountServiceAccountToken: false` | ServiceAccount | No Kubernetes API token in the Pod (Step 04) | Token theft |

### Read-only root filesystem: but apps need to write somewhere!

Some apps must write small temporary files. We give them **only** those folders, as `emptyDir` volumes (a fresh, empty folder that disappears with the Pod):

| App | Writable folders | Why |
|---|---|---|
| frontend (nginx) | `/tmp`, `/etc/nginx/conf.d` | nginx temp files; the config file made from the template at start |
| backend (Node.js) | `/tmp` | Node temp files |
| mysql | `/var/lib/mysql` (EBS), `/var/run/mysqld`, `/tmp`, `/var/lib/mysql-files` | Data, socket file, temp files |

Everything else, like the app code and `/etc`, is read-only.

### Pod Security Standards (PSS) and Pod Security Admission (PSA)

Kubernetes has 3 ready-made security levels, the **Pod Security Standards**:

| Level | Meaning | Use for |
|---|---|---|
| `privileged` | No limits | System tools (CNI, CSI drivers) |
| `baseline` | Blocks the obvious dangers (privileged, host network) | Most legacy apps |
| `restricted` | **Strictest**: non-root, drop ALL, no escalation, seccomp | **Our app** ✅ |

**Pod Security Admission** is the built-in checker that applies a level to a **namespace**, using labels:

| Label | Effect |
|---|---|
| `pod-security.kubernetes.io/enforce: restricted` | Bad Pods are **rejected** |
| `pod-security.kubernetes.io/warn: restricted` | `kubectl` prints a warning |
| `pod-security.kubernetes.io/audit: restricted` | Written to the audit log |
| `...-version: latest` | Use the rules of the current Kubernetes version |

> PSA checks only **security settings**. Rules like "only images from our ECR" need a policy engine: **Kyverno** (Step 07).

## 1.2 The code

### `helm/three-tier/templates/_helpers.tpl` (security snippets)

```yaml
{{- define "three-tier.podSecurity" -}}
securityContext:
  runAsNonRoot: true
  runAsUser: {{ .uid }}
  runAsGroup: {{ .uid }}
  fsGroup: {{ .uid }}
  seccompProfile:
    type: RuntimeDefault
{{- end -}}

{{- define "three-tier.containerSecurity" -}}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
{{- end -}}
```

| Line | Explained |
|---|---|
| `define "three-tier.podSecurity"` | A reusable snippet; each template includes it with its own user ID |
| `{{ .uid }}` | 101 for frontend, 1000 for backend, 999 for mysql: the user each image is built for |
| the rest | See the settings table above |

### How the frontend uses them (`templates/frontend.yaml`)

```yaml
      {{- include "three-tier.podSecurity" (dict "uid" 101) | nindent 6 }}
      containers:
        - name: frontend
          {{- include "three-tier.containerSecurity" . | nindent 10 }}
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
            - { name: nginx-conf, mountPath: /etc/nginx/conf.d }
      volumes:
        - { name: tmp, emptyDir: {} }
        - { name: nginx-conf, emptyDir: {} }
```

| Line | Explained |
|---|---|
| `include ... (dict "uid" 101)` | Insert the pod snippet with user 101 |
| `nindent 6` | Put it on a new line, indented 6 spaces, so the YAML stays valid |
| `emptyDir: {}` | Small writable folders for nginx; the rest of the filesystem is read-only |

### `platform/k8s/namespace.yaml` (applied in Step 03)

```yaml
metadata:
  name: three-tier
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

### `platform/k8s/bad-pod.yaml` (the test)

```yaml
      securityContext:
        runAsUser: 0                    # root ❌
        privileged: true                # full access to the node ❌
        allowPrivilegeEscalation: true  # ❌
```

`privileged: true` is the most dangerous setting: the container can see and change the **node** itself.

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Check who the containers run as     🖥️
Task 2  Prove the filesystem is read-only   🖥️
Task 3  Try a dangerous Pod (must fail)     🖥️
Task 4  Check the whole namespace           🖥️
```

---

## Task 1 — Check who the containers run as

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl exec -n three-tier deploy/frontend -- id
```

```bash
kubectl exec -n three-tier deploy/backend -- id
```

```bash
kubectl exec -n three-tier mysql-0 -- id
```

✅ **Check:**

| Pod | Expected |
|---|---|
| frontend | `uid=101(nginx) gid=101(nginx)` |
| backend | `uid=1000(node) gid=1000(node)` |
| mysql | `uid=999(mysql) gid=999(mysql)` |

Not one says `uid=0(root)`.

---

## Task 2 — Prove the filesystem is read-only

📍 **Where:** 🖥️ Bastion

▶️ **Do:** try to change the app's code folder:

```bash
kubectl exec -n three-tier deploy/backend -- touch /app/hacked.js
```

> ✅ `touch: /app/hacked.js: Read-only file system`

Writing to `/tmp` is allowed (it's the emptyDir):

```bash
kubectl exec -n three-tier deploy/backend -- touch /tmp/ok.txt && echo "tmp is writable"
```

> ✅ `tmp is writable`

Check the capabilities of the process (all zeros = none):

```bash
kubectl exec -n three-tier deploy/backend -- grep Cap /proc/1/status
```

✅ **Check:** `CapEff: 0000000000000000`. The process has **no** special Linux powers.

---

## Task 3 — Try a dangerous Pod (must fail)

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/bad-pod.yaml
```

✅ **Check:** the Pod is **rejected**:

```
Error from server (Forbidden): error when creating "...bad-pod.yaml": pods "bad-root-pod" is forbidden:
violates PodSecurity "restricted:latest": privileged (container "shell" must not set securityContext.privileged=true),
allowPrivilegeEscalation != false ..., unrestricted capabilities ..., runAsNonRoot != true ..., runAsUser=0 ..., seccompProfile ...
```

> The error lists **every** rule the Pod breaks. Pod Security Admission is a "bouncer at the door": it checks before anything runs.

```bash
kubectl get pod bad-root-pod -n three-tier
```

> ✅ `NotFound`: it was never created.

---

## Task 4 — Check the whole namespace

📍 **Where:** 🖥️ Bastion

▶️ **Do:** "would the running Pods pass `restricted`?" (a dry run on the namespace label):

```bash
kubectl label --dry-run=server --overwrite ns three-tier pod-security.kubernetes.io/enforce=restricted
```

✅ **Check:** `namespace/three-tier labeled (server dry run)` with **no** `Warning: existing pods ... violate` lines. All app Pods meet the strictest level.

🎉 **Step 05 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| `bad-root-pod created` | Namespace labels missing | `kubectl apply -f platform/k8s/namespace.yaml` |
| A new app fails with `Read-only file system` in its logs | It writes somewhere we didn't allow | Find the folder in the error, add an `emptyDir` mount for it |
| `container has runAsNonRoot and image will run as root` | Image has no `USER` line | Add `USER` to the Dockerfile, or set `runAsUser` |
| `Permission denied` on a mounted volume | Volume owned by root | Set `fsGroup` to the app's group |

## Interview Questions

### Other Questions

**Q1. How do you harden a Pod?**
`runAsNonRoot`, a fixed `runAsUser`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, `seccompProfile: RuntimeDefault`, no automounted API token, plus resource limits.

**Q2. What are the Pod Security Standards?**
Three levels (`privileged`, `baseline`, `restricted`), enforced per namespace by Pod Security Admission through labels, in `enforce`, `warn` or `audit` mode.

**Q3. The app needs to write files but the filesystem is read-only. What do you do?**
Mount an `emptyDir` (or a PVC for data) only at the folders it really needs.

**Q4. Why is `privileged: true` dangerous?**
The container gets almost all access to the host: devices, kernel features, the node's filesystem. It's a container escape waiting to happen.

**Q5. PSA vs Kyverno?**
PSA is built in and checks the fixed security profiles. Kyverno adds custom rules: allowed registries, tags, signatures, required labels, and can also mutate or generate resources.
