# Step 10 — CI/CD with GitOps: GitHub Actions + Argo CD + Canary Releases

[⬅ Back to the project overview](../README.md) · [⬅ Step 09](../step-09-high-availability/README.md) · [Step 11 ➡](../step-11-observability/README.md)

## What you will build in this step

A **`git push` is all it takes to release**. CI tests, scans, signs and pushes the images; Argo CD deploys them; the new backend version goes to a **canary** first, and you **promote** it when it looks healthy.

```
git push (app code)
   │
   ▼
GitHub Actions  ── OIDC (no AWS keys) ──► IAM role "abhigna-prod-github-ci" (push to 2 ECR repos only)
   test ─► build ─► Trivy scan ─► push :a1b2c3d ─► cosign sign ─► commit "tag: a1b2c3d" to gitops/values-prod.yaml
                                                                              │
                                                    Argo CD (in the cluster) pulls Git every ~3 min
                                                                              ▼
                     frontend: rolling update          backend: Argo Rollouts canary
                                                        25% new ─► ⏸ you check ─► promote ─► 50% ─► 60 s ─► 100%
                     Kyverno checks every new Pod: our ECR ✅  fixed tag ✅  signed ✅
```

| Item | Value |
|---|---|
| Needs | Steps 02–09 |
| Runs on | 💻 Laptop (Terraform, Git, VS Code) + 🌐 GitHub + 🖥️ Bastion |
| New AWS resources | GitHub OIDC provider + 1 IAM role (free) |
| Tools | Argo CD 3.6 (chart 10.18.2), Argo Rollouts 1.10 (chart 2.43.12) |
| Time | ~90 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### CI vs CD vs GitOps

**Definition:** **CI** builds and tests your code automatically. **CD** delivers the good build to the cluster automatically. **GitOps** is a way of doing CD where **Git is the boss**: the cluster always matches what's in Git.

**Analogy 🏭:** CI is the **factory** that makes and tests the product. CD is the **delivery truck**. GitOps = the shop shelf is stocked **only** from the official order list (Git); anything else gets removed.

```
git push ──► CI (GitHub Actions): test → build → scan → push → sign ──► update tag in Git
                                                                          │
                                         Argo CD (in the cluster) pulls ◄─┘ ──► cluster matches Git ✅
```

| Term | Meaning | Our tool |
|---|---|---|
| **CI** (Continuous Integration) | Every change is tested and built automatically | GitHub Actions |
| **CD** (Continuous Delivery/Deployment) | Every good build reaches the cluster automatically | Argo CD |
| **GitOps** | Git is the **single source of truth**; a tool **in the cluster** pulls Git and makes the cluster match | Argo CD |

> **Interview one-liner:** "CI builds and tests, CD deploys; with GitOps, Git is the single source of truth and Argo CD in the cluster pulls and applies it."

### Push vs pull deployment

**Definition:** **push** = the CI pipeline **logs in to the cluster** and deploys. **Pull** = a tool **inside the cluster** watches Git and deploys **itself**.

- With push, GitHub needs the **cluster's keys**. If GitHub is hacked, so is the cluster.
- With pull, the cluster **reaches out** to Git. GitHub has **no** cluster keys at all.
- Pull also **undoes manual changes** (self-heal), because it keeps comparing with Git.

**Analogy 📦:** push = giving the courier **your house key** so they can put the parcel inside. Pull = **you collect** the parcel from the locker. Nobody else needs your key.

```
Push:  GitHub Actions ──kubectl (cluster keys 🔑 in CI ❌)──► cluster
Pull:  GitHub repo ◄──watches── Argo CD (inside cluster) ──applies──► cluster   (no keys in CI ✅)
```

| | Push (CI runs `kubectl`/`helm`) | **Pull (GitOps)** ✅ |
|---|---|---|
| Who touches the cluster | The CI runner | Argo CD, inside the cluster |
| Cluster credentials in CI | Yes, a big risk | **None** |
| Someone changes the cluster by hand | Stays changed (drift) | Argo CD **undoes** it (self-heal) |
| Rollback | Re-run an old pipeline | `git revert` |

> **Interview one-liner:** "We use pull-based GitOps: Argo CD inside the cluster pulls from Git, so CI never holds cluster credentials and manual drift is reverted."

### GitHub → AWS without keys (OIDC)

**Definition:** **OIDC (OpenID Connect)** lets GitHub give each workflow run a **signed ID token** ("I am this repo, this branch"). AWS **trusts** GitHub's signature and swaps the token for **temporary AWS credentials**.

- CI must push images to **ECR**, so it needs AWS access.
- **Old way:** store an AWS **access key** in GitHub secrets. It never expires and can leak ❌.
- **OIDC way:** no key stored. Each run gets **1-hour** credentials, only for **our repo + main branch** ✅.

**Analogy 🎟️:** instead of giving GitHub a **permanent house key**, AWS checks GitHub's **signed ID card** at the door each time and hands out a **1-hour visitor pass**.

```
1. Workflow asks GitHub for an OIDC token: "I am repo Abhignadumpala/k8s-eks-projects, branch main"
2. aws-actions/configure-aws-credentials sends it to AWS STS (AssumeRoleWithWebIdentity)
3. AWS checks the role's trust policy:  aud = sts.amazonaws.com  AND  sub = repo:...:ref:refs/heads/main
4. ✅ 1-hour credentials for "abhigna-prod-github-ci" (may push to prod-frontend / prod-backend only)
```

No AWS access key is stored in GitHub. A fork or another branch **can't** get the role.

| | Access key in GitHub secrets | **OIDC** ✅ |
|---|---|---|
| Stored in GitHub | Permanent key ❌ | Nothing ✅ |
| Expires | Never (until rotated) ❌ | 1 hour ✅ |
| Fork / other branch can use it | If leaked, anyone ❌ | No: trust policy checks repo + branch ✅ |

> **Interview one-liner:** "GitHub Actions uses OIDC to assume an AWS role with 1-hour credentials, restricted by the trust policy to our repo and main branch: no stored access keys."

### Where each secret lives

**Definition:** a **GitHub repo secret** is an encrypted value GitHub keeps for a repo; workflows can use it, but it's **hidden** in logs and never shown again.

| Secret | Where | Why |
|---|---|---|
| `AWS_ROLE_ARN` | GitHub repo secret | Which role to assume (not really secret, but keeps the account ID out of logs/code) |
| `COSIGN_PRIVATE_KEY` + `COSIGN_PASSWORD` | GitHub repo secrets | CI signs images with the **same key** as Step 02, so Kyverno accepts them |
| AWS credentials | **nowhere**: OIDC, 1 hour | — |
| Cluster credentials | **nowhere**: Argo CD pulls | — |

### Image tags = commit SHA

**Definition:** a **commit SHA** is the unique ID Git gives every commit (e.g. `a1b2c3d4…`). We use its first 7 characters as the image tag.

**Analogy 🧾:** like a **receipt number**: from the tag you can find the exact commit, and from that the exact code.

```
commit a1b2c3d ──► image prod-backend:a1b2c3d ──► running Pod
   (code)              (same ID)                  "which code is this?" → git show a1b2c3d ✅
```

Every build is tagged with the first 7 characters of the commit, e.g. `a1b2c3d`:
- unique (works with **immutable** ECR tags)
- traceable: tag → exact commit → exact code
- allowed by Kyverno (not `latest`)

### Argo CD in 4 words

**Definition:** **Argo CD** is a GitOps tool that runs **inside the cluster**, watches a Git repo, and keeps the cluster **matching** it.

**Analogy 🌡️:** a **thermostat**. You set the temperature (Git); it keeps checking the room (cluster) and fixes any difference by itself.

```
Git (desired) ──compare every 3 min──► cluster (live)
   same?  ✅ Synced
   diff?  ⚠️ OutOfSync ──► sync ──► ✅
```

| Word | Meaning |
|---|---|
| **Application** | "Deploy *this Git path* to *this namespace*" |
| **Sync** | Make the cluster match Git |
| **Prune** | Delete objects that were removed from Git |
| **Self-heal** | Undo manual changes in the cluster |

> **Interview one-liner:** "Argo CD continuously compares Git with the cluster; with automated sync, prune and self-heal, the cluster always matches Git."

### Canary with Argo Rollouts

**Definition:** a **canary release** sends a new version to a **small share** of users first. If it's healthy, you give it more; if not, you **abort** and only a few users were affected. **Argo Rollouts** adds this to Kubernetes.

- A **Rollout** object **replaces** the backend **Deployment** (same Pod template, plus a release strategy).
- It moves to the new version **step by step**: 25% → pause → 50% → 100%.
- At any step: `promote` (go on) or `abort` (back to the old version).

**Analogy 🐤:** miners took a **canary** into the mine: if the small bird was fine, the air was safe for everyone.

```
v1 ████████ 100%
   ──► v2 ██ 25%  v1 ██████ 75%   ⏸ human checks
   ──► v2 ████ 50% v1 ████ 50%    ⏸ 60 s
   ──► v2 ████████ 100% ✅        (or abort ──► v1 100%)
```

| Strategy | How | Risk |
|---|---|---|
| Rolling update (Deployment) | Replace Pods a few at a time | All users get the new version within minutes |
| Blue-green | New full copy, then switch all traffic at once | Fast rollback, double resources |
| **Canary** ✅ | A **small share** gets the new version first; promote step by step | Problems hit few users |

Our steps:

```yaml
steps:
  - setWeight: 25            # 1 of 4 Pods new
  - pause: {}                # wait for a human
  - setWeight: 50
  - pause: { duration: 60s }
  # then 100%
```

Without a traffic router, the "weight" is the **share of Pods**. (With Istio waypoints or the ALB you can split by exact %, a next step.)

Commands: `kubectl argo rollouts promote backend` (continue), `kubectl argo rollouts abort backend` (go back to stable).

> **Interview one-liner:** "We release with an Argo Rollouts canary: 25%, manual check, 50%, then 100%, and abort instantly rolls back to the stable version."

## 1.2 The code, file by file

### `terraform/github_oidc.tf`

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.enable_github_oidc && var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

data "aws_iam_policy_document" "github_ci_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}
```

| Line | Explained |
|---|---|
| `aws_iam_openid_connect_provider` | AWS trusts tokens signed by GitHub. **One per account**: set `create_github_oidc_provider = false` if it already exists |
| `aud = sts.amazonaws.com` | The token was made for AWS |
| `sub = repo:<owner>/<repo>:ref:refs/heads/main` | **Only** our repo, **only** main. Forks and feature branches get nothing |
| (role policy) | `GetAuthorizationToken` + push actions on the 2 repos only. It can't delete images, can't touch EKS |

**In simple steps:**
1. **OIDC provider:** tells AWS *"trust ID tokens signed by GitHub"* (one per AWS account).
2. **Trust policy:** the role may be used **only** with a GitHub token that is (a) made for AWS (`aud`) and (b) from **our repo, main branch** (`sub`).
3. **Role policy:** ECR login + **push** to our 2 repos only. It can't delete images and can't touch EKS.
4. Result: GitHub Actions gets **1-hour** AWS credentials, with **no keys stored** in GitHub.

```
GitHub run (repo X, main) ──signed token──► AWS STS ──checks aud + sub──► ✅ 1-hour creds (push to ECR only)
fork / other branch       ──signed token──► AWS STS ──sub doesn't match──► ❌ denied
```

### `gitops/values-prod.yaml`

```yaml
frontend:
  image:
    tag: v1          # CI changes this line
backend:
  image:
    tag: v1          # and this one
  rollout:
    enabled: true
externalSecret:
  enabled: true
mesh:
  enabled: true
autoscaling:
  enabled: true
metrics:
  serviceMonitor:
    enabled: false   # Step 11: true, with a Git commit
```

Every switch from Steps 06–09 is **written down in Git** now, not hidden in `--reuse-values`. That's the GitOps idea: the file **is** the production config.

**In simple steps:**
1. The **production settings file** that Argo CD reads (on top of the chart's `values.yaml`).
2. Turns **on** every feature from Steps 06–09: External Secret, mesh, autoscaling, Argo Rollouts canary.
3. Holds the **image tags**. CI changes only these 2 lines after each good build.
4. Want to change production? **Edit this file and push.** Argo CD does the rest.

### `platform/argocd/three-tier-app.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: three-tier
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/Abhignadumpala/k8s-eks-projects.git
    targetRevision: main
    path: 05-production-eks/helm/three-tier
    helm:
      valueFiles:
        - ../../gitops/values-prod.yaml
      parameters:
        - name: global.registry
          value: ${ACCOUNT_ID}.dkr.ecr.eu-north-1.amazonaws.com
  destination:
    server: https://kubernetes.default.svc
    namespace: three-tier
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

| Line | Explained |
|---|---|
| `repoURL` / `targetRevision: main` / `path` | Which repo, branch and folder (the Helm chart) |
| `valueFiles: ../../gitops/values-prod.yaml` | Relative to the chart folder |
| `parameters: global.registry` | Your ECR address, filled in by `envsubst` on the bastion (not in Git) |
| `destination.server` | The cluster Argo CD runs in |
| `automated` + `prune` + `selfHeal` | Sync by itself, delete removed objects, undo manual changes |

**In simple steps:**
1. Creates an Argo CD **Application** named `three-tier`.
2. **Source:** our GitHub repo, branch `main`, folder `05-production-eks/helm/three-tier` (the chart), with `values-prod.yaml`.
3. **Destination:** this same cluster, namespace `three-tier`.
4. **Your ECR address** is added as a parameter by `envsubst` on the bastion, so it's never in Git.
5. **Automated sync:** Argo CD applies changes by itself, **deletes** objects removed from Git (`prune`), and **undoes** manual changes (`selfHeal`).

```
GitHub main: helm/three-tier + values-prod.yaml ──Argo CD pulls──► cluster namespace three-tier
```

### The CI workflow: `.github/workflows/prod-eks-ci.yml`

The file exists in the repo **empty**. You type or paste this code yourself in Task 4.

```yaml
name: prod-eks CI - test, build, scan, sign, push, deploy

on:
  push:
    branches: [main]
    paths:
      - "05-production-eks/app/**"
  workflow_dispatch:

permissions:
  contents: write     # commit the new image tag to gitops/values-prod.yaml
  id-token: write     # get the GitHub OIDC token for AWS

env:
  AWS_REGION: eu-north-1
  APP_DIR: 05-production-eks/app

concurrency:
  group: prod-eks-ci
  cancel-in-progress: false

jobs:
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: 05-production-eks/app/backend
    steps:
      - uses: actions/checkout@v7
      - uses: actions/setup-node@v7
        with:
          node-version: 24
          cache: npm
          cache-dependency-path: 05-production-eks/app/backend/package-lock.json
      - run: npm ci
      - run: npm test

  build-scan-sign-push:
    needs: test
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [frontend, backend]
    steps:
      - uses: actions/checkout@v7

      - name: Image tag = short commit SHA
        run: echo "TAG=${GITHUB_SHA::7}" >> "$GITHUB_ENV"

      - name: AWS credentials via OIDC (no keys)
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Log in to ECR
        id: ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Set image name
        run: echo "IMAGE=${{ steps.ecr.outputs.registry }}/prod-${{ matrix.service }}:${TAG}" >> "$GITHUB_ENV"

      - name: Build
        run: docker build -t "$IMAGE" "${APP_DIR}/${{ matrix.service }}"

      - name: Trivy scan (fail on fixable HIGH/CRITICAL)
        uses: aquasecurity/trivy-action@v0.36.0
        with:
          image-ref: ${{ env.IMAGE }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - name: Push
        run: docker push "$IMAGE"

      - name: Install Cosign
        uses: sigstore/cosign-installer@v4
        with:
          cosign-release: v3.1.4

      - name: Sign the pushed digest
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
          COSIGN_PASSWORD: ${{ secrets.COSIGN_PASSWORD }}
        run: |
          DIGEST_REF=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")
          echo "Signing $DIGEST_REF"
          cosign sign --yes --key env://COSIGN_PRIVATE_KEY "$DIGEST_REF"

  update-gitops:
    needs: build-scan-sign-push
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7

      - name: Image tag = short commit SHA
        run: echo "TAG=${GITHUB_SHA::7}" >> "$GITHUB_ENV"

      - name: Set the new tags in gitops/values-prod.yaml
        run: |
          yq -i '.frontend.image.tag = strenv(TAG) | .backend.image.tag = strenv(TAG)' 05-production-eks/gitops/values-prod.yaml
          git diff

      - name: Commit and push
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git commit -am "prod: deploy three-tier ${TAG}"
          git push
```

| Part | Explained |
|---|---|
| `paths: 05-production-eks/app/**` | Only app code changes start a build. The bot's commit to `gitops/` doesn't start another build (no loop) |
| `permissions: id-token: write` | Needed to get the OIDC token for AWS |
| `permissions: contents: write` | Lets the built-in `GITHUB_TOKEN` push the tag commit to this repo |
| `concurrency` | Two pushes close together run one after the other, so the tag commits don't collide |
| `needs:` | Order and gates: tests fail → no image; scan fails → no push, no deploy |
| `matrix.service` | One job definition builds frontend and backend in parallel |
| `${GITHUB_SHA::7}` | Bash: first 7 characters of the commit = the tag |
| `configure-aws-credentials` + `role-to-assume` | OIDC login, no keys |
| `amazon-ecr-login` → `outputs.registry` | `<account>.dkr.ecr.eu-north-1.amazonaws.com`, read at run time |
| Trivy **before** Push | A vulnerable image never reaches ECR |
| `docker inspect ... RepoDigests` | After the push, the exact `image@sha256:...` to sign |
| `--key env://COSIGN_PRIVATE_KEY` | Cosign reads the key from the env var (from GitHub secrets, never written to disk) |
| `yq -i '... = strenv(TAG)'` | Changes **only** the 2 tag lines in the YAML |

**In simple steps:** on every push to `main` that changes app code, 3 jobs run **in order**.
1. **`test`:** run the backend unit tests. Fail → stop, no image is built.
2. **`build-scan-sign-push`** (frontend + backend in parallel):
   1. Log in to AWS with **OIDC** (no keys) and to ECR.
   2. **Build** the image, tagged with the first **7 characters of the commit** (e.g. `a1b2c3d`).
   3. **Scan** with Trivy. HIGH/CRITICAL found → stop, nothing is pushed.
   4. **Push** to ECR.
   5. **Sign** the image's **digest** with Cosign (key from GitHub secrets).
3. **`update-gitops`:** change the 2 image tags in `gitops/values-prod.yaml` and **commit** them. Argo CD sees the commit and starts the **canary**.

```
git push (app code)
   └► test ──► build ──► Trivy ──► push ECR ──► cosign sign ──► commit new tag to gitops/ ──► Argo CD ──► canary 🐤
        ❌ stop   ❌ stop if HIGH/CRITICAL
```

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  GitHub OIDC role                         💻 terraform apply
Task 2  GitHub secrets                           💻 / 🌐
Task 3  Install Argo CD + Argo Rollouts          🖥️
Task 4  Write the CI workflow                    📝 VS Code
Task 5  Hand the app over to Argo CD             🖥️
Task 6  Open the Argo CD UI                      💻 ssh tunnel + 🌐
Task 7  Release v2 as a canary                   📝 → 🌐 → 🖥️
Task 8  Self-heal and rollback                   🖥️ + 💻
```

---

## Task 1 — GitHub OIDC role

📍 **Where:** 📝 VS Code → 💻 Terminal in `05-production-eks/terraform`

▶️ **Do:** in `terraform.tfvars`:

```hcl
enable_github_oidc      = true  # Step 10
```

> Your account already has a provider for `token.actions.githubusercontent.com` (from another project)? Also add `create_github_oidc_provider = false`.

```bash
terraform apply
```

✅ **Check:** `Plan: 3 to add` (OIDC provider, role, role policy). Type `yes`.

```bash
terraform output -raw github_ci_role_arn; echo
```

> ✅ `arn:aws:iam::<account-id>:role/abhigna-prod-github-ci`. Keep this terminal open.

---

## Task 2 — GitHub secrets

📍 **Where:** 🌐 GitHub → your repo `k8s-eks-projects` → **Settings → Secrets and variables → Actions → New repository secret**

▶️ **Do:** create 3 secrets:

| Name | Value |
|---|---|
| `AWS_ROLE_ARN` | The ARN from Task 1 |
| `COSIGN_PRIVATE_KEY` | The **whole** content of `~/.cosign/cosign.key` (print it with `cat ~/.cosign/cosign.key`, copy everything including the BEGIN/END lines) |
| `COSIGN_PASSWORD` | The password you chose in Step 02, Task 7 |

> Alternative with the GitHub CLI (no copy-paste of the key on screen):
> `gh secret set COSIGN_PRIVATE_KEY < ~/.cosign/cosign.key`
> `gh secret set AWS_ROLE_ARN --body "$(terraform output -raw github_ci_role_arn)"`
> `gh secret set COSIGN_PASSWORD` (it asks for the value)

✅ **Check:** the Actions secrets page lists the 3 names (values are hidden).

---

## Task 3 — Install Argo CD and Argo Rollouts

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add argo https://argoproj.github.io/argo-helm && helm repo update
```

```bash
helm install argocd argo/argo-cd --version 10.18.2 -n argocd --create-namespace -f ~/k8s-eks-projects/05-production-eks/platform/values/argo-cd.yaml --wait
```

```bash
helm install argo-rollouts argo/argo-rollouts --version 2.43.12 -n argo-rollouts --create-namespace --wait
```

The `kubectl argo rollouts` plugin:

```bash
curl -sSLo kubectl-argo-rollouts https://github.com/argoproj/argo-rollouts/releases/download/v1.10.2/kubectl-argo-rollouts-linux-amd64 && sudo install -m 0755 kubectl-argo-rollouts /usr/local/bin/ && rm kubectl-argo-rollouts
```

✅ **Check:**

```bash
kubectl get pods -n argocd && kubectl get pods -n argo-rollouts && kubectl argo rollouts version
```

> ✅ All Argo CD Pods `Running` (server, repo-server, application-controller, redis, applicationset); the rollouts controller `Running`; plugin `v1.10.2`.

---

## Task 4 — Write the CI workflow

📍 **Where:** 📝 VS Code on the laptop

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

Open **`.github/workflows/prod-eks-ci.yml`** (empty) and type or paste the workflow from Part 1.2. Save.

```bash
git add .github/workflows/prod-eks-ci.yml && git commit -m "CI: prod-eks test, scan, sign, push, gitops" && git push
```

> This commit doesn't change `05-production-eks/app/**`, so it doesn't start a build yet. That's expected.

✅ **Check:** GitHub → **Actions** tab lists the workflow **"prod-eks CI - test, build, scan, sign, push, deploy"**.

---

## Task 5 — Hand the app over to Argo CD

📍 **Where:** 🖥️ Bastion

**Why:** until now Helm (by hand) managed the app. From now on **Git + Argo CD** does.

▶️ **Do:** create the Application (your registry is filled in by envsubst):

```bash
envsubst '${ACCOUNT_ID}' < ~/k8s-eks-projects/05-production-eks/platform/argocd/three-tier-app.yaml | kubectl apply -f -
```

Watch it sync (1–2 minutes):

```bash
kubectl get application three-tier -n argocd -w
```

> ✅ `SYNC STATUS Synced`, `HEALTH STATUS Healthy`. `Ctrl+C`.

Argo CD created the **Rollout** for the backend. The old Helm **Deployment** is still there (Argo CD only deletes what *it* created), so remove it, and Helm's record of the release:

```bash
kubectl argo rollouts get rollout backend -n three-tier
```

> ✅ `Status: ✔ Healthy`. Then:

```bash
kubectl delete deployment backend -n three-tier
```

```bash
kubectl delete secret -n three-tier -l owner=helm,name=three-tier
```

> Deleting Helm's release secret does **not** delete any app object; it only means "Helm no longer owns this".

✅ **Check:**

```bash
kubectl get rollout,deploy,hpa -n three-tier
```

> ✅ `rollout/backend`, `deployment/frontend` (no backend Deployment), and the backend HPA now points to the Rollout. The app still works in the browser.

---

## Task 6 — Open the Argo CD UI

📍 **Where:** 🖥️ Bastion + 💻 a second laptop terminal + 🌐 browser

▶️ **Do (🖥️ bastion):** the admin password (generated at install):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

> Leave it running.

▶️ **Do (💻 laptop, new terminal):** an SSH **tunnel**: your laptop's port 8080 → the bastion's port 8080:

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform && ssh -i ~/.ssh/abhigna-eks-key.pem -N -L 8080:localhost:8080 ubuntu@$(terraform output -raw bastion_public_ip)
```

> `terraform output` doesn't list `bastion_public_ip`? Use the IP from `terraform output -raw bastion_ssh_command`.

Open **https://localhost:8080** (accept the self-signed certificate warning). User `admin`, the password from above.

✅ **Check:** the `three-tier` app card is green: **Synced / Healthy**. Click it to see every object as a tree.

> Why a tunnel and not a public LoadBalancer? The Argo CD UI can change production. It should never be on the internet.

---

## Task 7 — Release v2 as a canary

📍 **Where:** 📝 VS Code → 🌐 GitHub → 🖥️ Bastion

▶️ **Do (📝 laptop):** make a visible change. In `05-production-eks/app/frontend/index.html`, change the page title text (for example add `v2`). Then:

```bash
cd ~/k8s-eks-projects && git add 05-production-eks/app && git commit -m "app: v2 title" && git push
```

▶️ **Do (🌐):** GitHub → **Actions** → watch the run: `test` ✅ → `build-scan-sign-push (frontend)` ✅ + `(backend)` ✅ → `update-gitops` ✅ (~4 minutes).

Then the repo has a new bot commit: **`prod: deploy three-tier a1b2c3d`**.

▶️ **Do (🖥️ bastion):** watch Argo Rollouts (Argo CD picks up the commit within ~3 minutes):

```bash
kubectl argo rollouts get rollout backend -n three-tier --watch
```

> ✅ The canary starts: `Step: 1/4`, `SetWeight: 25`, then **`Status: ॥ Paused`**: 1 Pod runs the new tag, the rest run `v1`.

Check the new version answers. Run it a few times; some answers say the new tag, most say `v1`:

```bash
for i in 1 2 3 4 5 6; do kubectl exec -n three-tier deploy/frontend -- wget -qO- http://backend:8080/api/health; echo; done
```

Happy? **Promote** (in another window):

```bash
kubectl argo rollouts promote backend -n three-tier
```

✅ **Check:** the rollout goes to 50%, waits 60 s, then 100%: `Status: ✔ Healthy`, all Pods on the new tag. The browser shows your v2 title. And Kyverno let the CI-built images in because they're **signed by CI** with your key.

---

## Task 8 — Self-heal and rollback

📍 **Where:** 🖥️ Bastion, 💻 Laptop

▶️ **Do: self-heal.** Break the config by hand:

```bash
kubectl patch configmap backend-config -n three-tier --type merge -p '{"data":{"DB_NAME":"wrong"}}'
```

```bash
kubectl get configmap backend-config -n three-tier -o jsonpath='{.data.DB_NAME}{"\n"}'
```

> Shows `wrong`... wait ~1 minute (or click **Refresh** in the UI) and run it again:

> ✅ Back to `tasksdb`. **Git wins**: Argo CD undid the manual change.

▶️ **Do: rollback with Git.** On the laptop, undo the bot's deploy commit:

```bash
cd ~/k8s-eks-projects && git pull && git log --oneline -3
```

```bash
git revert --no-edit $(git log --format=%h -1 --grep "prod: deploy three-tier")
```

```bash
git push
```

✅ **Check:** within ~3 minutes Argo CD syncs the old tags; the backend canary starts again with the old version (promote it). **Rollback = a Git commit**, fully recorded in history.

> Emergency stop during a canary: `kubectl argo rollouts abort backend -n three-tier` puts 100% back on the stable version immediately.

🎉 **Step 10 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust conditions don't match | Workflow must run on `main` in `Abhignadumpala/k8s-eks-projects`; `id-token: write` permission set; `AWS_ROLE_ARN` correct |
| `EntityAlreadyExists ... oidc-provider` on apply | Provider exists in the account | `create_github_oidc_provider = false` |
| Trivy step fails | HIGH/CRITICAL CVE with a fix | Read the table; update the base image tag in the Dockerfile |
| `update-gitops`: `Permission ... denied to github-actions[bot]` | Workflow permissions read-only | Repo **Settings → Actions → General → Workflow permissions → Read and write**, or keep `permissions: contents: write` in the file |
| Argo CD `ComparisonError ... values-prod.yaml` | Path wrong | `valueFiles` is relative to the chart: `../../gitops/values-prod.yaml` |
| New Pods denied: `Image is not signed` | CI signed with a different key | `COSIGN_PRIVATE_KEY` must be **your** Step 02 key (matching the public key in the Kyverno policy) |
| Rollout stuck `Paused` | That's the design | `kubectl argo rollouts promote backend -n three-tier` |
| Two backend versions forever | Old Helm Deployment still there | Task 5: `kubectl delete deployment backend -n three-tier` |

## Interview Questions

### Other Questions

**Q1. Walk me through your CI/CD pipeline.**
On push to main: unit tests, image build, Trivy scan, push to ECR tagged with the commit SHA, Cosign signing, then CI commits the new tag to the GitOps values file. Argo CD syncs it to EKS; the backend goes out as a canary and is promoted after checks. Kyverno only admits signed images from our ECR.

**Q2. Why GitOps instead of `kubectl apply` from CI?**
No cluster credentials in CI, Git as the audit log, drift is corrected automatically, and rollback is `git revert`.

**Q3. How does GitHub Actions access AWS without keys?**
OIDC: GitHub issues a signed token per run; IAM trusts GitHub's provider and checks `aud` and `sub` (repo + branch) before giving 1-hour credentials for a least-privilege role.

**Q4. Canary vs blue-green vs rolling?**
Rolling replaces Pods gradually; blue-green switches all traffic between two full versions; canary sends a small share first and increases it step by step with checks.

**Q5. What do prune and self-heal do in Argo CD?**
Prune deletes cluster objects removed from Git; self-heal reverts manual changes so the cluster always matches Git.

**Q6. Why tag images with the commit SHA?**
It's unique (needed with immutable tags), traceable to the exact code, and never ambiguous like `latest`.
