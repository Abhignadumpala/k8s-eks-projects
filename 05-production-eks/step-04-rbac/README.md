# Step 04 — RBAC and ServiceAccounts: Least Privilege for People and Apps

[⬅ Back to the project overview](../README.md) · [⬅ Step 03](../step-03-deploy-app/README.md) · [Step 05 ➡](../step-05-pod-hardening/README.md)

## What you will build in this step

**Only the permissions that are needed, nothing more**, for:
- **people:** a read-only developer group and a "debug" group, limited to the app namespace
- **apps:** the 3 app ServiceAccounts, which can do **nothing** in the Kubernetes API

```
                 who are you? (AuthN)                    what may you do? (AuthZ = RBAC)
IAM role ──► EKS access entry ──► group "dev-readonly" ──► RoleBinding ──► ClusterRole "view"   (three-tier only)
IAM role ──► EKS access entry ──► group "dev-debug"    ──► RoleBinding ──► Role "pod-debugger"  (three-tier only)
IAM role ──► EKS access entry ──► group "bastion-admin" ─► ClusterRoleBinding ──► cluster-admin (Step 01)

Pod ──► ServiceAccount "backend" ──► no RoleBinding ──► can't call the Kubernetes API at all
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

### RBAC in one table

**RBAC (Role-Based Access Control)** = rules that say **who** may do **which action** on **which objects**, and **where**.

| Object | Question it answers | Scope |
|---|---|---|
| **Role** | *What* is allowed (verbs on resources) | One namespace |
| **ClusterRole** | *What* is allowed | Whole cluster (or reused inside namespaces) |
| **RoleBinding** | *Who* gets a Role/ClusterRole | **One namespace** |
| **ClusterRoleBinding** | *Who* gets a ClusterRole | **Whole cluster** |
| **Subject** | The *who*: User, Group or ServiceAccount | — |

**Trick:** a **RoleBinding can point to a ClusterRole**. You reuse a ready-made role (like `view`) but **only inside that namespace**. That's what we do for developers.

### Verbs

| Verb | Means |
|---|---|
| `get`, `list`, `watch` | Read |
| `create`, `update`, `patch`, `delete` | Write |
| `pods/log` (sub-resource) + `get` | Read logs |
| `pods/exec` + `create` | Open a shell in a Pod (powerful: often **not** given) |
| `pods/portforward` + `create` | Port-forward to a Pod |

### Built-in ClusterRoles (recap from Step 01)

| ClusterRole | Allows |
|---|---|
| `cluster-admin` | Everything |
| `admin` | Everything in a namespace, including RBAC there |
| `edit` | Change most things in a namespace, not RBAC |
| `view` | Read most things, **not Secrets** |

### People vs apps

| | People | Apps (Pods) |
|---|---|---|
| Identity | IAM role → **EKS access entry** → Kubernetes group | **ServiceAccount** |
| Kubernetes permissions | RBAC bindings to the group | RBAC bindings to the ServiceAccount |
| AWS permissions | Their IAM role | **Pod Identity** role (Step 06) |

### Why our app ServiceAccounts have NO permissions

Our app never talks to the Kubernetes API. So:
1. **No RoleBinding** for `frontend`, `backend`, `mysql`.
2. **`automountServiceAccountToken: false`**: Kubernetes doesn't even put an API token file inside the Pods.

If an attacker breaks into the backend Pod, there is **no token to steal** and nothing it could do with one.

> Default behaviour (without our setting): every Pod gets a token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. Many attacks start by stealing it.

### Testing permissions without new users: impersonation

As `cluster-admin` (the bastion), you can **pretend** to be someone else:

```bash
kubectl auth can-i list pods -n three-tier --as=jane --as-group=dev-readonly
```

Kubernetes answers `yes` or `no` exactly as it would for that user and group. It's the standard way to test RBAC.

### How a real developer would log in (EKS access entry)

In a company, each developer team has an **IAM role** (often from SSO). One command maps it to a Kubernetes group (like `bastion-admin` in Step 01):

```bash
aws eks create-access-entry --cluster-name abhigna-prod --principal-arn arn:aws:iam::<account-id>:role/<developer-role> --kubernetes-groups dev-readonly
```

The RoleBindings in this step then decide what that group may do. We test with impersonation, so we don't need to create extra IAM roles.

## 1.2 The code: `platform/k8s/rbac-developer.yaml`

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-readonly-view
  namespace: three-tier
subjects:
  - kind: Group
    name: dev-readonly
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-debugger
  namespace: three-tier
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-debug-pod-debugger
  namespace: three-tier
subjects:
  - kind: Group
    name: dev-debug
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-debugger
  apiGroup: rbac.authorization.k8s.io
```

| Part | Explained |
|---|---|
| `RoleBinding dev-readonly-view` | Group `dev-readonly` gets the built-in `view` role, **only in `three-tier`** |
| `roleRef: ClusterRole view` | Reuse the built-in role instead of writing our own |
| `Role pod-debugger` | Our own small role: read Pods and their logs, port-forward. **No** exec, **no** delete, **no** Secrets |
| `apiGroups: [""]` | `""` = the core API group (Pods, Services, Secrets...) |
| `RoleBinding dev-debug-pod-debugger` | Group `dev-debug` gets `pod-debugger` in `three-tier` |

### The app ServiceAccounts (`helm/three-tier/templates/serviceaccounts.yaml`)

```yaml
{{- range $name := list "frontend" "backend" "mysql" }}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $name }}
automountServiceAccountToken: false
{{- end }}
```

| Line | Explained |
|---|---|
| `range $name := list ...` | Helm loop: one ServiceAccount per tier |
| `automountServiceAccountToken: false` | No API token inside the Pods |
| (no RoleBinding anywhere) | These identities have **zero** Kubernetes permissions |

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Look at the built-in roles          🖥️
Task 2  Apply the developer RBAC            🖥️
Task 3  Test people's permissions           🖥️
Task 4  Test the app's ServiceAccounts      🖥️
```

---

## Task 1 — Look at the built-in roles

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
kubectl get clusterroles | grep -E "^(cluster-admin|admin|edit|view) "
```

```bash
kubectl describe clusterrole view | grep -i secret
```

✅ **Check:** the 4 roles are listed, and `view` has **no** `secrets` line (it can't read Secrets).

---

## Task 2 — Apply the developer RBAC

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/rbac-developer.yaml
```

✅ **Check:**

```bash
kubectl get role,rolebinding -n three-tier
```

> ✅ `role.../pod-debugger`, `rolebinding.../dev-readonly-view`, `rolebinding.../dev-debug-pod-debugger`.

---

## Task 3 — Test people's permissions

📍 **Where:** 🖥️ Bastion

▶️ **Do:** fill in the table by running each line (`yes` / `no`):

```bash
kubectl auth can-i list pods -n three-tier --as=jane --as-group=dev-readonly
```

```bash
kubectl auth can-i get secrets -n three-tier --as=jane --as-group=dev-readonly
```

```bash
kubectl auth can-i delete pods -n three-tier --as=jane --as-group=dev-readonly
```

```bash
kubectl auth can-i list pods -n kube-system --as=jane --as-group=dev-readonly
```

```bash
kubectl auth can-i get pods --subresource=log -n three-tier --as=ravi --as-group=dev-debug
```

```bash
kubectl auth can-i create pods --subresource=exec -n three-tier --as=ravi --as-group=dev-debug
```

✅ **Check:**

| Who | Action | Expected |
|---|---|---|
| dev-readonly | list pods in three-tier | `yes` |
| dev-readonly | get secrets | `no` |
| dev-readonly | delete pods | `no` |
| dev-readonly | list pods in **kube-system** | `no` (only their namespace) |
| dev-debug | read logs | `yes` |
| dev-debug | exec into a Pod | `no` |

See **everything** a group may do in one list:

```bash
kubectl auth can-i --list -n three-tier --as=ravi --as-group=dev-debug
```

---

## Task 4 — Test the app's ServiceAccounts

📍 **Where:** 🖥️ Bastion

▶️ **Do:** can the backend's identity read Pods or Secrets?

```bash
kubectl auth can-i list pods -n three-tier --as=system:serviceaccount:three-tier:backend
```

```bash
kubectl auth can-i get secrets -n three-tier --as=system:serviceaccount:three-tier:backend
```

> ✅ Both `no`.

Is there an API token inside the backend Pod?

```bash
kubectl exec -n three-tier deploy/backend -- ls /var/run/secrets/kubernetes.io/serviceaccount
```

✅ **Check:** `ls: /var/run/secrets/kubernetes.io/serviceaccount: No such file or directory`. No token exists to steal.

> `system:serviceaccount:<namespace>:<name>` is the full username Kubernetes uses for a ServiceAccount.

🎉 **Step 04 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| Everything says `yes` | You forgot `--as` / `--as-group`: you're checking yourself (cluster-admin) | Add the flags |
| `kubectl exec` works for the bastion | The bastion is `cluster-admin`: correct | Only test users with `--as` |
| RoleBinding has no effect | Group name typo (`dev-readonly` vs `dev-read-only`) | Names must match exactly |

## Interview Questions

### Other Questions

**Q1. Role vs ClusterRole, RoleBinding vs ClusterRoleBinding?**
Role and RoleBinding live in one namespace; ClusterRole and ClusterRoleBinding are cluster-wide. A RoleBinding can reference a ClusterRole to grant it in one namespace only.

**Q2. How do you give a developer read-only access to one namespace on EKS?**
Map their IAM role to a group with an EKS access entry, then create a RoleBinding in that namespace to the built-in `view` ClusterRole.

**Q3. Why doesn't `view` include Secrets?**
Reading Secrets would expose passwords and tokens: that's effectively write access to other systems.

**Q4. What is `automountServiceAccountToken: false` for?**
Pods that don't call the Kubernetes API shouldn't carry an API token. A stolen token is a common first step in cluster attacks.

**Q5. How do you test RBAC without logging in as the user?**
`kubectl auth can-i <verb> <resource> --as=<user> --as-group=<group>`, or `--list` to show everything.

**Q6. Why not give developers `exec`?**
`exec` is a shell inside a running container: they could read mounted secrets or change the app. Logs and port-forward are usually enough for debugging.
