# Step 07 — Policy Guardrails with Kyverno

[⬅ Back to the project overview](../README.md) · [⬅ Step 06](../step-06-pod-identity-secrets/README.md) · [Step 08 ➡](../step-08-istio-mtls/README.md)

## What you will build in this step

**Automatic rules** that check every Pod **before** it is created in the app namespace. A Pod that breaks a rule is refused, with a clear message.

```
kubectl / Helm / Argo CD ──► API server ──► Kyverno admission webhook (system nodes)
                                              │ checks 5 rules for namespace three-tier
                                              ├── ❌ image not from our ECR              → DENY
                                              ├── ❌ tag :latest or no tag               → DENY
                                              ├── ❌ no CPU/memory requests or limits    → DENY
                                              ├── ❌ AWS access keys in env vars         → DENY
                                              ├── ❌ app image not signed with OUR key   → DENY   (reads ECR with Pod Identity)
                                              └── ✅ all good → Pod is created
```

| Item | Value |
|---|---|
| Needs | Step 02 (signed images, your `cosign.pub`), Steps 03–06 |
| Runs on | 💻 Laptop (Terraform, Docker, VS Code) + 🖥️ Bastion |
| New AWS resources | 1 IAM role + Pod Identity association (Kyverno reads ECR) |
| Kyverno | v1.20 (chart 3.10.0), new **CEL** policy types |
| Time | ~65 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### What is Kyverno?

**Definition:** **Kyverno** is a **policy engine** for Kubernetes: it checks every new object against **your company's rules** before Kubernetes saves it.

- You `kubectl apply` a Pod → the **API server** pauses and asks Kyverno *"may I create this?"* (this is called an **admission webhook**).
- Kyverno checks the rules: right registry? no `:latest`? signed image?
- **Yes** → the Pod is created. **No** → `kubectl` shows an error and nothing is created.

```
kubectl apply ──► API server ──"may I?"──► Kyverno 🛂 ──✅──► Pod saved, starts
                                                     └─❌──► "image must come from our ECR"
```

**Analogy 🛂:** airport security. Pod Security Admission (Step 05) checks for dangerous items (root, privileged). Kyverno checks **your company's rules**: right passport (registry), a valid ticket (signature), proper luggage label (resources).

| Kyverno can | Example |
|---|---|
| **Validate** (allow / deny) | Deny `:latest` |
| **Mutate** (change on the way in) | Add a default label |
| **Generate** (create extra objects) | A NetworkPolicy for every new namespace |
| **Verify images** | Check Cosign signatures |

> **Interview one-liner:** "Kyverno is an admission controller that validates, mutates and generates Kubernetes objects and verifies image signatures, so only workloads that follow our rules can run."

### Kyverno 1.20 policy types (CEL)

**Definition:** **CEL (Common Expression Language)** is a small language for writing **true / false tests**, like `image starts with our ECR`.

Kyverno now uses **CEL**, the same language Kubernetes uses for its own built-in rules. The old `ClusterPolicy` kind is **deprecated**, so we use the new types:

| Kind | Used for | Example | In this project |
|---|---|---|---|
| `ValidatingPolicy` | Allow/deny based on the object's fields | Deny Pods with AWS key env vars | ✅ registries, latest tag, resources, AWS keys |
| `ImageValidatingPolicy` | Check image signatures / attestations | Only images signed by our CI | ✅ Cosign signature |
| `MutatingPolicy` | Change objects on the way in | Add standard labels or safe defaults | — |
| `GeneratingPolicy` | Create related objects when something appears | A default ConfigMap/NetworkPolicy in every new namespace | — |
| `DeletingPolicy` | Delete matching objects on a schedule | Remove expired test resources | — |
| `PolicyException` | **Not a policy**: exempts chosen resources from chosen policies | Allow one documented legacy app during a migration | — |

All use `apiVersion: policies.kyverno.io/v1`. Most also have a **namespaced** variant (e.g. `NamespacedValidatingPolicy`) so a team can own policies in its namespace.

**CEL in 30 seconds:**

| CEL | Means |
|---|---|
| `object.spec.containers` | The list of containers in the Pod being created |
| `.all(c, <test>)` | True only if **every** container `c` passes the test |
| `c.image.startsWith('x')` | Image name begins with `x` |
| `has(c.env)` | The field exists |
| `'cpu' in c.resources.requests` | The map has the key `cpu` |

### Autogen: rules for Pods also protect Deployments

**Definition:** **autogen** = Kyverno **automatically copies** a rule written for Pods to Deployments, StatefulSets, Jobs… (it checks their `spec.template.spec`).

- We write rules for **Pods** only.
- A bad **Deployment** is then refused **immediately**, with a clear error.
- Without autogen, the Deployment would be created but its Pods would **silently never start**.

```
Without autogen:  Deployment ✅ created ──► ReplicaSet ──► Pod ❌ refused (you see nothing, 0/2 ready)
With autogen:     Deployment ❌ refused right away with the error message ✅
```

### Pod Identity vs Kyverno: two different layers

| Layer | Controls | Question it answers |
|---|---|---|
| **Pod Identity / IRSA** (Step 06) | What an approved Pod may do **in AWS** | *"May this Pod read that bucket?"* |
| **Kyverno** (this step) | Which objects may be **created in Kubernetes**, and how they must look | *"May this Pod even run, with this image and these settings?"* |

**Analogy 🏢:** Kyverno is the **building's front door** (who may come in). Pod Identity is the **key card inside** (which rooms you may open). You need both.

**Real risk that needs both:** a developer runs a debug image from Docker Hub in `payments`, using a ServiceAccount with a powerful AWS role. Code inside that image (or a compromised package) can now use the role. Pod Identity alone can't stop it, because the Pod *is* allowed that role; Kyverno blocks the untrusted image. Neither replaces the other.

> **Key takeaway:** *Pod Identity decides what a Pod can do in AWS. Kyverno decides which workloads are allowed to run and what guardrails they must satisfy.*

### Audit vs Deny, and a safe rollout

**Definition:** **Audit** = only **report** bad Pods. **Deny** = **block** them.

**Analogy 🚦:** Audit is a **speed camera that only warns** in the first month; Deny is the **real fine**. You warn first so nobody is surprised.

| `validationActions` | What happens to a bad Pod |
|---|---|
| `[Audit]` | Created ✅, but recorded as `FAIL` in a **PolicyReport** |
| `[Deny]` | Refused ❌ with the message |

Never switch a **new** policy straight to `Deny` in production. You could break running teams. The safe order:

```
1. Audit      apply with [Audit]
2. Measure    kubectl get policyreport -A   → who would be blocked?
3. Fix        move images to ECR, pin versions/digests, remove static keys
4. Exceptions narrow PolicyException only where a fix must wait (owner, reason, expiry)
5. Staging    switch to [Deny] in a non-production cluster, test allowed AND rejected Pods
6. Promote    to production step by step, with monitoring and a rollback plan
7. Images     add signature verification (ImageValidatingPolicy + Cosign)
```

> **PolicyReports** show the **current** result for objects that exist now. They are not a permanent history log (for that: audit logs / CloudTrail).
> A **PolicyException** is a controlled bypass, not a fix. Keep it narrow and time-bound.

Task 7 practises steps 1, 2, 3 and 5.

> **Interview one-liner:** "We roll out a new policy in Audit mode, check PolicyReports, fix or add narrow exceptions, then switch to Deny in staging before production."

### What these rules can NOT do

| Limitation | So also… |
|---|---|
| A registry check doesn't prove an image is safe, scanned or signed | Scan (Step 02) and verify signatures (Task 5) |
| A tag other than `latest` can still be overwritten | ECR **immutable tags** (Step 01) or digests |
| Checking only `spec.containers` misses `initContainers` / `ephemeralContainers` | Our registry and latest-tag rules include init containers; extend the others if needed |
| Every excluded namespace is a possible bypass | We match only `three-tier`; in production, exclude as little as possible and review it |
| An env-var name check isn't a secret scanner | Keys can also hide in files, arguments or images: scan images, use Pod Identity |

### Why each rule

| Rule | Why it matters |
|---|---|
| **Only our ECR** (+ official images on ECR Public) | Random images from the internet can contain anything. ECR images are scanned and controlled |
| **No `:latest`** | You can't know which version runs, can't roll back, and nodes may run different versions |
| **Requests + memory limit** | Without them one Pod can starve the node, and HPA (Step 09) can't calculate CPU % |
| **No AWS keys in env** | Keys leak (logs, `kubectl describe`). Pods must use Pod Identity |
| **Signed with our key** | Proves the image came from our build (laptop in Step 02, CI in Step 10), not from an attacker who got push access |

### Where is the account ID?

**Definition:** **`envsubst`** is a Linux command that **fills in** `${VARIABLES}` in a file with their real values, on the fly.

- `restrict-registries.yaml` in Git contains `${ACCOUNT_ID}`, **not** your real number.
- On the bastion, `envsubst` replaces it with your account ID, then pipes the result to `kubectl apply`.
- So Git **never** holds your account ID.

```bash
envsubst '${ACCOUNT_ID}' < restrict-registries.yaml | kubectl apply -f -
```

### How does Kyverno read signatures from private ECR?

- To check a signature, Kyverno must **download** it from our **private ECR**.
- That needs ECR read access → **its own Pod Identity role** (Terraform `enable_kyverno_ecr`), limited to our 2 repositories (least privilege, like Step 06).
- In the policy, `credentials.providers: [amazon]` tells Kyverno to use those AWS credentials.

```
Kyverno ──Pod Identity role──► ECR (prod-backend, prod-frontend) ──► reads signature ──► checks with cosign.pub
```

## 1.2 The code, file by file (`platform/policies/`)

### `restrict-registries.yaml`

```yaml
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: restrict-image-registries
spec:
  validationActions: [Deny]
  matchConstraints:
    namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: three-tier
    resourceRules:
      - apiGroups: [""]
        apiVersions: [v1]
        operations: [CREATE, UPDATE]
        resources: [pods]
  variables:
    - name: containers
      expression: >-
        object.spec.containers + (has(object.spec.initContainers) ? object.spec.initContainers : [])
  validations:
    - expression: >-
        variables.containers.all(c,
          c.image.startsWith('${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/') ||
          c.image.startsWith('public.ecr.aws/docker/library/'))
      message: "Images must come from our ECR ... or public.ecr.aws/docker/library."
```

| Line | Explained |
|---|---|
| `validationActions: [Deny]` | Refuse bad Pods. (`[Audit]` = only report them: a safe way to roll out a new rule) |
| `namespaceSelector ... three-tier` | Only our app namespace. System namespaces are not touched |
| `resourceRules` | Pods, when created or updated |
| `variables.containers` | Normal containers **plus** init containers (attackers like to hide in init containers) |
| `.all(c, ... \|\| ...)` | Every container's image must start with one of the 2 allowed prefixes |
| `public.ecr.aws/docker/library/` | Official Docker images mirrored by AWS (our MySQL). No Docker Hub rate limits either |

### `disallow-latest-tag.yaml`

```yaml
  validations:
    - expression: >-
        variables.containers.all(c, c.image.contains(':') && !c.image.endsWith(':latest'))
```

No `:` → no tag (means `latest`). Ends with `:latest` → refused.

### `require-resources.yaml`

```yaml
    - expression: >-
        object.spec.containers.all(c,
          has(c.resources) && has(c.resources.requests) && has(c.resources.limits) &&
          'cpu' in c.resources.requests && 'memory' in c.resources.requests &&
          'memory' in c.resources.limits)
```

CPU **limit** is not required on purpose: CPU limits cause throttling, while memory limits protect the node from out-of-memory problems.

### `disallow-aws-keys.yaml`

```yaml
    - expression: >-
        object.spec.containers.all(c,
          !has(c.env) || c.env.all(e,
            e.name != 'AWS_ACCESS_KEY_ID' && e.name != 'AWS_SECRET_ACCESS_KEY'))
```

`!has(c.env) || ...` = "no env at all is fine; otherwise none may be named like an AWS key".

### `verify-image-signatures.yaml`

```yaml
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: verify-app-image-signatures
spec:
  validationActions: [Deny]
  failurePolicy: Fail
  webhookConfiguration:
    timeoutSeconds: 15
  matchConstraints: ...             # same as above: Pods in three-tier
  matchImageReferences:
    - glob: "*.dkr.ecr.us-east-1.amazonaws.com/prod-*"
  credentials:
    providers: [amazon]
  validationConfigurations:
    mutateDigest: false
    verifyDigest: false
    required: true
  attestors:
    - name: cosign
      cosign:
        key:
          data: |
            -----BEGIN PUBLIC KEY-----
            ...your cosign.pub...
            -----END PUBLIC KEY-----
  validations:
    - expression: >-
        images.containers.map(image, verifyImageSignatures(image, [attestors.cosign])).all(e, e > 0)
      message: "Image is not signed with our Cosign key (Step 02)."
```

| Line | Explained |
|---|---|
| `failurePolicy: Fail` | If Kyverno is down or can't check, **refuse** (safe). `Ignore` would let unchecked images in |
| `timeoutSeconds: 15` | Reading signatures from ECR takes a moment |
| `matchImageReferences` | Only **our** app repos (`prod-*`). MySQL from ECR Public is not checked here |
| `credentials.providers: [amazon]` | Log in to ECR with Kyverno's Pod Identity role |
| `mutateDigest: false` | Keep `:v1` as written. If Kyverno changed it to `@sha256:...`, Argo CD (Step 10) would see a difference and fight it |
| `required: true` | A matched image **must** pass verification |
| `attestors ... key.data` | Your **public** key. Safe to commit |
| `verifyImageSignatures(...) > 0` | At least one valid signature from our key |

### `terraform/platform_iam.tf` (Kyverno part)

An IAM role with `ecr:GetAuthorizationToken` (login) and **read-only** actions on our 2 repositories, linked by Pod Identity to `kyverno/kyverno-admission-controller`.

### `platform/k8s/policy-test-pod.yaml`

A test Pod that **passes Pod Security "restricted"**, so only Kyverno decides. The image comes from `${TEST_IMAGE}`.

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Kyverno's ECR role                     💻 terraform apply
Task 2  Install Kyverno                        🖥️
Task 3  Apply the 4 rule policies              🖥️
Task 4  Test them with bad Pods                🖥️
Task 5  Add your public key + apply signature  📝 laptop → 🖥️
Task 6  Test signatures (signed vs unsigned)   💻 + 🖥️
Task 7  Safe rollout: Audit → Deny             🖥️  (namespace policy-lab)
```

---

## Task 1 — Kyverno's ECR role

📍 **Where:** 📝 VS Code → 💻 Terminal in `05-production-eks/terraform`

▶️ **Do:** in `terraform.tfvars`:

```hcl
enable_kyverno_ecr      = true  # Step 07
```

```bash
terraform apply
```

✅ **Check:** `Plan: 3 to add` (role, role policy, Pod Identity association). Type `yes`.

---

## Task 2 — Install Kyverno

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add kyverno https://kyverno.github.io/kyverno && helm repo update
```

```bash
helm install kyverno kyverno/kyverno --version 3.10.0 -n kyverno --create-namespace
```

✅ **Check:**

```bash
kubectl get pods -n kyverno
```

> ✅ 4 controllers `Running`: `admission`, `background`, `cleanup`, `reports`.

---

## Task 3 — Apply the 4 rule policies

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks/platform/policies
```

```bash
for f in restrict-registries disallow-latest-tag require-resources disallow-aws-keys; do envsubst '${ACCOUNT_ID}' < $f.yaml | kubectl apply -f -; done
```

✅ **Check:**

```bash
kubectl get validatingpolicies
```

> ✅ 4 policies; `READY` = `true` after a few seconds.

Check your account ID was filled in (not `${ACCOUNT_ID}`):

```bash
kubectl get validatingpolicy restrict-image-registries -o jsonpath='{.spec.validations[0].message}{"\n"}'
```

---

## Task 4 — Test them with bad Pods

📍 **Where:** 🖥️ Bastion, in `platform/k8s`

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks/platform/k8s
```

**Test 1: image from Docker Hub with `:latest`**

```bash
TEST_IMAGE=nginx:latest envsubst < policy-test-pod.yaml | kubectl apply -f -
```

> ✅ `denied the request`: 2 messages, **registry** and **latest tag**.

**Test 2: official image on ECR Public, fixed tag** (allowed):

```bash
TEST_IMAGE=public.ecr.aws/docker/library/busybox:1.37 envsubst < policy-test-pod.yaml | kubectl apply -f -
```

> ✅ `pod/policy-test created`. Clean up:

```bash
kubectl delete pod policy-test -n three-tier
```

**Test 3: a Deployment without resources** (autogen checks it immediately):

```bash
kubectl create deployment no-limits -n three-tier --image=public.ecr.aws/docker/library/busybox:1.37 --dry-run=server
```

> ✅ Denied with `Every container needs resources.requests ...` (and Pod Security warnings).

✅ **Check:** the app itself still passes. Restart it and watch new Pods get created:

```bash
kubectl rollout restart deploy/frontend -n three-tier && kubectl rollout status deploy/frontend -n three-tier
```

> ✅ `successfully rolled out`

---

## Task 5 — Add your public key and apply the signature policy

📍 **Where:** 📝 VS Code on the **laptop**, then 🖥️ Bastion

▶️ **Do (💻 laptop):** print your public key:

```bash
cat ~/.cosign/cosign.pub
```

In VS Code open `05-production-eks/platform/policies/verify-image-signatures.yaml` and replace these 3 lines with **your** key, keeping the same indentation (12 spaces):

```yaml
            -----BEGIN PUBLIC KEY-----
            PASTE-THE-MIDDLE-LINES-OF-YOUR-cosign.pub-HERE
            -----END PUBLIC KEY-----
```

> A public key is safe to commit: it can only **verify**, never sign.

Commit and push:

```bash
cd ~/k8s-eks-projects && git add 05-production-eks/platform/policies/verify-image-signatures.yaml && git commit -m "Step 07: add cosign public key to signature policy" && git push
```

▶️ **Do (🖥️ bastion):**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/policies/verify-image-signatures.yaml
```

✅ **Check:**

```bash
kubectl get imagevalidatingpolicies
```

> ✅ `verify-app-image-signatures`, `READY true`.

---

## Task 6 — Test signatures: signed vs unsigned

📍 **Where:** 💻 Laptop, then 🖥️ Bastion

▶️ **Do (💻 laptop):** build an image that is **different** (new digest) and push it **without** signing:

```bash
cd ~/k8s-eks-projects/05-production-eks/app && export ECR=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com
```

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR
```

```bash
docker build --label test=unsigned -t $ECR/prod-backend:unsigned-test ./backend && docker push $ECR/prod-backend:unsigned-test
```

▶️ **Do (🖥️ bastion):**

```bash
cd ~/k8s-eks-projects/05-production-eks/platform/k8s
```

```bash
TEST_IMAGE=$ECR/prod-backend:unsigned-test envsubst < policy-test-pod.yaml | kubectl apply -f -
```

> ✅ **Denied**: `Image is not signed with our Cosign key (Step 02).`

The **signed** `v1` passes:

```bash
TEST_IMAGE=$ECR/prod-backend:v1 envsubst < policy-test-pod.yaml | kubectl apply -f -
```

> ✅ `pod/policy-test created`

```bash
kubectl delete pod policy-test -n three-tier
```

✅ **Check:** the policy report shows the app Pods passing:

```bash
kubectl get policyreports -n three-tier
```

> ✅ Rows with `PASS` counts and `FAIL 0`.

---

## Task 7 — Roll out a new policy safely: Audit → Deny

📍 **Where:** 🖥️ Bastion

**Scenario:** a team already runs a "legacy" app with a Docker Hub image, `:latest` and an AWS key in an env var. You introduce guardrails **without breaking it on day one**: Audit first, fix, then Deny. We use a separate namespace `policy-lab`, so the real app is never touched.

File: [`platform/policies/lab/policy-lab-guardrails.yaml`](../platform/policies/lab/policy-lab-guardrails.yaml): 3 rules (no AWS keys, only trusted registries, no `:latest`) in **Audit** mode, only for `policy-lab`.

▶️ **Do:** 1) the namespace and the "legacy" app that breaks all 3 rules:

```bash
kubectl create namespace policy-lab
```

```bash
kubectl run legacy-app -n policy-lab --image=busybox:latest --restart=Never --env=AWS_ACCESS_KEY_ID=fake-key-for-test --command -- sleep 3600
```

> ✅ `pod/legacy-app created`: no policy yet. The key is fake, never put a real one anywhere.

2) Apply the policy in **Audit** mode:

```bash
cd ~/k8s-eks-projects/05-production-eks/platform/policies/lab
```

```bash
envsubst '${ACCOUNT_ID}' < policy-lab-guardrails.yaml | kubectl apply -f -
```

```bash
kubectl get validatingpolicy policy-lab-guardrails
```

> ✅ `READY true`, actions `Audit`.

3) A new bad Pod is **still allowed** (Audit doesn't block):

```bash
kubectl run legacy-app-2 -n policy-lab --image=busybox:latest --restart=Never --env=AWS_ACCESS_KEY_ID=fake-key-for-test --command -- sleep 3600
```

> ✅ `pod/legacy-app-2 created`.

4) **Measure:** read the reports (wait ~30 s for the reports controller):

```bash
kubectl get policyreport -n policy-lab
```

> ✅ One row per Pod with `FAIL` > 0.

```bash
kubectl get policyreport -n policy-lab -o jsonpath='{range .items[*].results[*]}{.result}{"  "}{.message}{"\n"}{end}'
```

> ✅ `fail` with the reasons: AWS keys / registry / latest tag. Now you know **who** would break, before blocking anything.

5) **Fix** the workload: trusted registry, pinned tag, no keys:

```bash
kubectl delete pod legacy-app legacy-app-2 -n policy-lab
```

```bash
kubectl run fixed-app -n policy-lab --image=public.ecr.aws/docker/library/busybox:1.37 --restart=Never --command -- sleep 3600
```

```bash
kubectl get policyreport -n policy-lab
```

> ✅ After ~30 s: `PASS` > 0, `FAIL 0`.

6) **Enforce:** switch to Deny:

```bash
kubectl patch validatingpolicy policy-lab-guardrails --type merge -p '{"spec":{"validationActions":["Deny"]}}'
```

```bash
kubectl run legacy-app-3 -n policy-lab --image=busybox:latest --restart=Never --env=AWS_ACCESS_KEY_ID=fake-key-for-test --command -- sleep 3600
```

> ✅ `denied the request` with the 3 messages. The fixed app keeps running.

7) Clean up:

```bash
kubectl delete namespace policy-lab && kubectl delete validatingpolicy policy-lab-guardrails
```

✅ **Check:** you rolled out a policy the production way: **Audit → measure → fix → Deny**, and nothing running broke.

🎉 **Step 07 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| Signed `v1` also denied, log says `UNAUTHORIZED` / `no basic auth` | Kyverno can't log in to ECR | Task 1 applied? `aws eks list-pod-identity-associations` (laptop) must show `kyverno / kyverno-admission-controller`. Then `kubectl rollout restart deploy/kyverno-admission-controller -n kyverno` |
| Signed `v1` denied: `no matching signatures` | Wrong public key pasted, or signed with a different key | Compare with `~/.cosign/cosign.pub`. Re-check on the laptop: `cosign verify --key ~/.cosign/cosign.pub $ECR/prod-backend:v1` |
| `failed calling webhook ... context deadline exceeded` | Kyverno slow or down (`failurePolicy: Fail`) | `kubectl get pods -n kyverno`; wait, then retry |
| Policy `READY false` | CEL syntax error, or this Kyverno version doesn't know the kind/field | `kubectl describe validatingpolicy <name>`; `kubectl get crd \| grep policies.kyverno.io` |
| Policy seems to do nothing | Namespace not matched, wrong kind/operation, or it's in `Audit` | Check `namespaceSelector` and `resourceRules`; `kubectl get validatingpolicies` shows the actions; test one Pod that should pass and one that should fail |
| No PolicyReport | Reports controller not ready, or wait time | `kubectl get pods -n kyverno` (`reports` Running); wait 30–60 s |
| Message shows `${ACCOUNT_ID}` | Applied without envsubst | Re-run Task 3 |

## Interview Questions

### ⭐ Very Important

**Q1. Pod Identity and Kyverno: what does each one control?**
Pod Identity (or IRSA) controls what an approved Pod can do **in AWS**. Kyverno controls which resources are **admitted** to Kubernetes and how they're configured. You need both: a powerful role plus an untrusted image is the real risk.

**Q2. How do you introduce a new policy without breaking production?**
Audit first, read `kubectl get policyreport -A`, fix violators, use narrow time-bound PolicyExceptions where needed, test Deny in staging, then roll out to production gradually with a rollback plan.

**Q3. What Kyverno policy types exist today?**
`ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`, `ImageValidatingPolicy` and `DeletingPolicy` (CEL, `policies.kyverno.io/v1`), plus `PolicyException` for exemptions. The old `ClusterPolicy` is deprecated.

**Q4. What is a PolicyException?**
A controlled bypass for specific resources and policies, e.g. a legacy app during migration. Keep it narrow, with an owner, a reason and an expiry. It's not a substitute for fixing the workload.

**Q5. Is a "trusted registry" rule enough to trust an image?**
No. It doesn't prove the image is scanned or signed, and non-`latest` tags can still change. Add scanning, immutable tags/digests, and signature verification.

### Other Questions

**Q6. What is an admission controller?**
A plugin the API server calls before saving an object. Validating ones allow/deny, mutating ones change the object. Kyverno and PSA are admission controllers.

**Q7. Kyverno vs OPA Gatekeeper?**
Both are policy engines. Kyverno policies are Kubernetes YAML with CEL expressions, and include image verification and generation. Gatekeeper uses Rego, a separate language.

**Q8. How do you make sure only trusted images run?**
Restrict registries, forbid mutable tags, scan in CI, sign images in the pipeline, and verify signatures at admission with Kyverno (`failurePolicy: Fail`).

**Q9. What does `failurePolicy: Fail` mean and what is the risk?**
If the webhook can't answer, requests are refused: safe, but Kyverno becomes critical. Run it highly available and exclude system namespaces.

**Q10. Why no CPU limit in the policy?**
CPU limits throttle bursty apps even when the node is idle. Memory limits protect the node from out-of-memory problems; CPU requests are enough for scheduling and HPA.
