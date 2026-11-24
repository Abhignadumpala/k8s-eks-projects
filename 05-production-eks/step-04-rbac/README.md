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

**Definition:** **RBAC (Role-Based Access Control)** = rules that say **who** may do **which action** on **which objects**, and **where** (which namespace).

- First Kubernetes asks **"who are you?"** (**AuthN**, authentication: your IAM role).
- Then it asks **"what may you do?"** (**AuthZ**, authorization: RBAC).
- If no rule says "yes", the answer is **no**. Nothing is allowed by default.

**Analogy 🏢:** an office building. The **Role** is a key card type ("can open meeting rooms"), the **RoleBinding** gives that card to a person, and the **namespace** is the floor the card works on.

```
WHO (Subject)          gets           WHAT (Role)                    WHERE
group dev-readonly ──► RoleBinding ──► ClusterRole "view"   ──►  only namespace three-tier
                       (the link)      (get, list, watch)
```

| Object | Question it answers | Scope |
|---|---|---|
| **Role** | *What* is allowed (verbs on resources) | One namespace |
| **ClusterRole** | *What* is allowed | Whole cluster (or reused inside namespaces) |
| **RoleBinding** | *Who* gets a Role/ClusterRole | **One namespace** |
| **ClusterRoleBinding** | *Who* gets a ClusterRole | **Whole cluster** |
| **Subject** | The *who*: User, Group or ServiceAccount | — |

**Trick:** a **RoleBinding can point to a ClusterRole**. You reuse a ready-made role (like `view`) but **only inside that namespace**. That's what we do for developers.

> **Interview one-liner:** "A Role says what is allowed, a RoleBinding says who gets it; RoleBinding is per namespace, ClusterRoleBinding is cluster-wide, and everything is denied by default."

### Verbs

**Definition:** a **verb** is the **action** in an RBAC rule, like a word in a sentence: "**list** pods", "**delete** deployments".

| Verb | Means |
|---|---|
| `get`, `list`, `watch` | Read |
| `create`, `update`, `patch`, `delete` | Write |
| `pods/log` (sub-resource) + `get` | Read logs |
| `pods/exec` + `create` | Open a shell in a Pod (powerful: often **not** given) |
| `pods/portforward` + `create` | Port-forward to a Pod |

> ⚠️ `pods/exec` = a shell **inside** the Pod: you can read its files and env variables (passwords!). Give it only to people who debug.

### Built-in ClusterRoles (recap from Step 01)

**Definition:** Kubernetes ships with **4 ready-made ClusterRoles**, from "can do everything" to "can only look".

```
cluster-admin  ████████████  everything, every namespace
admin          █████████     everything in one namespace, incl. RBAC
edit           ██████        change apps, not RBAC
view           ███           read only, NOT Secrets
```

| ClusterRole | Allows |
|---|---|
| `cluster-admin` | Everything |
| `admin` | Everything in a namespace, including RBAC there |
| `edit` | Change most things in a namespace, not RBAC |
| `view` | Read most things, **not Secrets** |

### People vs apps

**Definition:** people and apps both talk to the Kubernetes API, but they **prove who they are** in different ways.

- **People** log in with an **IAM role** → an **EKS access entry** maps it to a Kubernetes **group**.
- **Apps (Pods)** use a **ServiceAccount**, an identity Kubernetes gives to a Pod.
- Both get permissions the same way: **RBAC bindings**.

**Analogy 🪪:** people show their **company ID badge** (IAM); apps wear a **machine name tag** (ServiceAccount). The same security guard (RBAC) checks both.

| | People | Apps (Pods) |
|---|---|---|
| Identity | IAM role → **EKS access entry** → Kubernetes group | **ServiceAccount** |
| Kubernetes permissions | RBAC bindings to the group | RBAC bindings to the ServiceAccount |
| AWS permissions | Their IAM role | **Pod Identity** role (Step 06) |

### Why our app ServiceAccounts have NO permissions

**Definition:** **least privilege** = give only the permissions that are really needed. Our app **never talks to the Kubernetes API**, so it needs **zero**.

- **No RoleBinding** for `frontend`, `backend`, `mysql` → they can't do anything in the API.
- **`automountServiceAccountToken: false`** → Kubernetes doesn't even put an API **token** file inside the Pods.
- If an attacker breaks into the backend Pod, there is **no token to steal** and nothing it could do with one.

**Analogy 🔑:** don't leave a house key under the doormat if nobody needs it. No key = nothing to steal.

```
Default Pod                                   Our Pods
/var/run/secrets/.../token  🔑  ◄── attacker  (no token file)  ✅
 = API key inside the Pod      steals it      nothing to steal
```

| | Default | **Our setup** |
|---|---|---|
| Token file in the Pod | Yes ❌ | No ✅ |
| RBAC permissions | Whatever someone binds | None ✅ |
| Attacker in the Pod can call the API | Maybe ❌ | No ✅ |

> **Interview one-liner:** "Apps that don't use the Kubernetes API get a ServiceAccount with no RoleBinding and automountServiceAccountToken false, so there's no token to steal."

### Testing permissions without new users: impersonation

**Definition:** **impersonation** = an admin asks Kubernetes *"what would happen if **this user** tried this?"*, without logging in as them.

- You are `cluster-admin` on the bastion.
- Add `--as=<user> --as-group=<group>` to a command.
- Kubernetes answers **exactly** as it would for that user: `yes` or `no`.

```bash
kubectl auth can-i list pods -n three-tier --as=jane --as-group=dev-readonly
```

**Analogy 🎭:** a manager tries a new employee's key card at each door, to check it opens the right ones, before handing it over.

> **Interview one-liner:** "We test RBAC with `kubectl auth can-i --as --as-group`, which checks a user's permissions without needing their credentials."

### How a real developer would log in (EKS access entry)

**Definition:** an **EKS access entry** links an **IAM role** (AWS) to a **Kubernetes group** (inside the cluster).

- In a company, each developer team has an **IAM role** (often from SSO login).
- One command maps that role to a group, like we did for `bastion-admin` in Step 01.
- The RoleBindings in this step then decide what that group may do.

```
Developer ──SSO──► IAM role ──access entry──► group dev-readonly ──RoleBinding──► view in three-tier
           (AWS)                (the bridge)        (Kubernetes)
```

```bash
aws eks create-access-entry --cluster-name abhigna-prod --principal-arn arn:aws:iam::<account-id>:role/<developer-role> --kubernetes-groups dev-readonly
```

We test with **impersonation**, so we don't need to create extra IAM roles in this lab.

> **Interview one-liner:** "EKS access entries map IAM roles to Kubernetes groups; RBAC then controls what each group can do."

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

**In simple steps:** this one file creates **3 objects**.
1. **RoleBinding `dev-readonly-view`:** gives group `dev-readonly` the ready-made `view` role → they can **look** at everything in `three-tier` (not Secrets), and change nothing.
2. **Role `pod-debugger`:** our own **small** role → read Pods and logs, and port-forward. No exec, no delete, no Secrets.
3. **RoleBinding `dev-debug-pod-debugger`:** gives that role to group `dev-debug`, again **only** in `three-tier`.

```
group dev-readonly ──RoleBinding──► ClusterRole view     (built-in)  ─┐
group dev-debug    ──RoleBinding──► Role pod-debugger    (ours)      ─┴─► only in namespace three-tier
```

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

**In simple steps:**
1. The Helm loop makes **3 ServiceAccounts**: `frontend`, `backend`, `mysql`.
2. Each one is turned into a Pod's identity (`serviceAccountName`).
3. `automountServiceAccountToken: false` → **no token** file is put in the Pods.
4. We create **no RoleBinding** for them → even with a token, they could do **nothing** in the API.

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
