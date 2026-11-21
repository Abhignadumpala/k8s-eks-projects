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
| Time | ~45 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### What is Kyverno?

**Definition:** a **policy engine** for Kubernetes. It runs as an **admission webhook**: the API server asks Kyverno *"may I create this?"* before saving anything.

**Analogy 🛂:** airport security. Pod Security Admission (Step 05) checks for dangerous items (root, privileged). Kyverno checks **your company's rules**: right passport (registry), a valid ticket (signature), proper luggage label (resources).

| Kyverno can | Example |
|---|---|
| **Validate** (allow / deny) | Deny `:latest` |
| **Mutate** (change on the way in) | Add a default label |
| **Generate** (create extra objects) | A NetworkPolicy for every new namespace |
| **Verify images** | Check Cosign signatures |

### Kyverno 1.20 policy types (CEL)

Kyverno now uses **CEL** (Common Expression Language), the same language Kubernetes uses for its own built-in rules. The old `ClusterPolicy` kind is **deprecated**, so we use the new types:

| Kind | Used for | Our policies |
|---|---|---|
| `ValidatingPolicy` | Allow/deny based on the object's fields | registries, latest tag, resources, AWS keys |
| `ImageValidatingPolicy` | Check image signatures / attestations | Cosign signature |

**CEL in 30 seconds:**

| CEL | Means |
|---|---|
| `object.spec.containers` | The list of containers in the Pod being created |
| `.all(c, <test>)` | True only if **every** container `c` passes the test |
| `c.image.startsWith('x')` | Image name begins with `x` |
| `has(c.env)` | The field exists |
| `'cpu' in c.resources.requests` | The map has the key `cpu` |

### Autogen: rules for Pods also protect Deployments

We write rules for **Pods**. Kyverno automatically creates matching rules for Deployments, StatefulSets and so on (it looks at `spec.template.spec`). A bad Deployment is refused **immediately**, instead of creating a Deployment whose Pods silently never start.

### Why each rule

| Rule | Why it matters |
|---|---|
| **Only our ECR** (+ official images on ECR Public) | Random images from the internet can contain anything. ECR images are scanned and controlled |
| **No `:latest`** | You can't know which version runs, can't roll back, and nodes may run different versions |
| **Requests + memory limit** | Without them one Pod can starve the node, and HPA (Step 09) can't calculate CPU % |
| **No AWS keys in env** | Keys leak (logs, `kubectl describe`). Pods must use Pod Identity |
| **Signed with our key** | Proves the image came from our build (laptop in Step 02, CI in Step 10), not from an attacker who got push access |

### Where is the account ID?

`restrict-registries.yaml` contains `${ACCOUNT_ID}`. You apply it with **`envsubst`**, which replaces the variable with your value on the bastion. So Git never holds your account ID.

```bash
envsubst '${ACCOUNT_ID}' < restrict-registries.yaml | kubectl apply -f -
```

### How does Kyverno read signatures from private ECR?

It needs ECR read access → **its own Pod Identity role** (Terraform `enable_kyverno_ecr`), limited to our 2 repositories. In the policy, `credentials.providers: [amazon]` tells Kyverno to use the AWS credentials.

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

🎉 **Step 07 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| Signed `v1` also denied, log says `UNAUTHORIZED` / `no basic auth` | Kyverno can't log in to ECR | Task 1 applied? `aws eks list-pod-identity-associations` (laptop) must show `kyverno / kyverno-admission-controller`. Then `kubectl rollout restart deploy/kyverno-admission-controller -n kyverno` |
| Signed `v1` denied: `no matching signatures` | Wrong public key pasted, or signed with a different key | Compare with `~/.cosign/cosign.pub`. Re-check on the laptop: `cosign verify --key ~/.cosign/cosign.pub $ECR/prod-backend:v1` |
| `failed calling webhook ... context deadline exceeded` | Kyverno slow or down (`failurePolicy: Fail`) | `kubectl get pods -n kyverno`; wait, then retry |
| Policy `READY false` | CEL syntax error | `kubectl describe validatingpolicy <name>` |
| Message shows `${ACCOUNT_ID}` | Applied without envsubst | Re-run Task 3 |
| Want to roll out a new rule safely | — | Use `validationActions: [Audit]` first, check `kubectl get policyreports`, then switch to `[Deny]` |

## Interview Questions

### Other Questions

**Q1. What is an admission controller?**
A plugin the API server calls before saving an object. Validating ones allow/deny, mutating ones change the object. Kyverno and PSA are admission controllers.

**Q2. Kyverno vs OPA Gatekeeper?**
Both are policy engines. Kyverno policies are Kubernetes YAML with CEL expressions, and include image verification and generation. Gatekeeper uses Rego, a separate language.

**Q3. How do you make sure only trusted images run?**
Restrict registries, forbid mutable tags, scan in CI, sign images in the pipeline, and verify signatures at admission with Kyverno (`failurePolicy: Fail`).

**Q4. What does `failurePolicy: Fail` mean and what is the risk?**
If the webhook can't answer, requests are refused: safe, but Kyverno becomes critical. Run it highly available and exclude system namespaces.

**Q5. How do you introduce a new policy without breaking production?**
Start in Audit mode, read the policy reports, fix violators, then switch to Deny.

**Q6. Why no CPU limit in the policy?**
CPU limits throttle bursty apps even when the node is idle. Memory limits protect the node from out-of-memory problems; CPU requests are enough for scheduling and HPA.
