# Step 02 — Secure Images: Build, Scan, Sign, Push

[⬅ Back to the project overview](../README.md) · [⬅ Step 01](../step-01-infrastructure/README.md) · [Step 03 ➡](../step-03-deploy-app/README.md)

## What you will build in this step

The two app images (frontend and backend), **checked for known vulnerabilities**, **signed** with your own key, and stored in your **private ECR**.

```
💻 Laptop
  app/frontend, app/backend (code)
        │ docker build
        ▼
  image on your laptop ──► Trivy scan ──► ❌ HIGH/CRITICAL with a fix? → stop, fix the base image
        │ ✅ clean
        │ docker push
        ▼
  ECR (private)  prod-frontend:v1   prod-backend:v1     (tags can never be overwritten)
        │ cosign sign (your private key)
        ▼
  signature stored next to the image in ECR  ──►  Step 07: Kyverno lets only signed images run
```

| Item | Value |
|---|---|
| Runs on | 💻 Laptop only (no cluster needed, **free** except a few cents of ECR storage) |
| Tools | Docker, Trivy (scanner), Cosign (signing), AWS CLI |
| Output | `prod-frontend:v1` and `prod-backend:v1` in ECR, both signed |
| Time | ~45 min |

This guide has 2 parts:

| Part | What you do |
|---|---|
| **Part 1 — Understand** | What supply chain security is, and every file explained |
| **Part 2 — 🛠️ Hands-On Lab** | Build, scan, push and sign, task by task |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### What is "supply chain security"?

**Definition:** protecting everything that goes **into** your running app: your code, the base image, the libraries, the build, and the registry.

Think of a **restaurant 🍽️**: the cooking can be perfect, but if the vegetables arrive rotten (vulnerable base image) or someone swaps the delivery on the way (tampered image), the customer still gets sick. Supply chain security checks the ingredients **and** seals the delivery box.

| Risk | Example | Our protection |
|---|---|---|
| Known vulnerabilities (CVEs) in the base image or libraries | An old OpenSSL in the image | **Trivy** scan before push + ECR scan on push |
| Someone overwrites a tag | `v1` silently replaced with a bad image | ECR **immutable tags** (Step 01) |
| Image built or changed by someone else | Attacker pushes a look-alike image | **Cosign** signature, checked by Kyverno (Step 07) |
| Too much inside the image | Shell tools, compilers, dev libraries | Small Alpine base, only production dependencies |
| Container runs as root | A bug gives the attacker root | Images run as a normal user (`node`, `nginx` uid 101) |

### The 3 tools

| Tool | What it does | Analogy |
|---|---|---|
| **Trivy** | Lists known vulnerabilities (CVEs) in an image and can fail the build | Food inspector checking the ingredients |
| **ECR** | Private image registry in your AWS account | Locked warehouse |
| **Cosign** | Signs an image with your private key; anyone with the public key can verify it | A wax seal on the box |

### CVE, severity and "fixed version"

**CVE** = a public ID for one known security bug, e.g. `CVE-2026-12345`.
Trivy gives each one a **severity** (LOW, MEDIUM, HIGH, CRITICAL) and says if a **fixed version** exists.

We fail only on **HIGH or CRITICAL that have a fix** (`--ignore-unfixed`): those you can actually fix by updating. Failing on every unfixed LOW would block you forever with nothing to do.

### Tag vs digest

| | Example | Can it change? |
|---|---|---|
| **Tag** | `prod-backend:v1` | Normally yes (that's why ECR is set to IMMUTABLE) |
| **Digest** | `prod-backend@sha256:9f86d0...` | **Never**: it is the fingerprint of the exact image content |

We **sign the digest**, not the tag: the signature is bound to the exact bytes.

### How signing works (key pair)

```
cosign generate-key-pair
   ├── cosign.key  🔒 PRIVATE: signs images. Never share, never commit (.gitignore blocks *.key)
   └── cosign.pub  🔓 PUBLIC: verifies signatures. Safe to share and commit
```

- **Sign:** `cosign sign --key cosign.key <image@digest>` → a signature is stored in ECR next to the image.
- **Verify:** `cosign verify --key cosign.pub <image@digest>` → ✅ only if it was signed by **your** private key and the image is unchanged.

> Production teams often use **keyless** signing (GitHub's identity + Sigstore) or a key in **AWS KMS**, so no key file exists at all. We use a key file because it is the easiest way to see how signing works.

### Does "signed" mean "scanned and safe"?

**No, not by itself.** Scanning and signing answer **different questions**:

| | Trivy scan | Cosign signature |
|---|---|---|
| Question it answers | *Does this image have known vulnerabilities?* | *Who made this image, and has it been changed since?* |
| Proves | No HIGH/CRITICAL CVEs with a fix, **today** | It came from **us** (our private key) and is **byte-for-byte unchanged** |
| Analogy | A health check-up 🩺 | A sealed envelope with your signature ✉️ |

A signature alone says nothing about vulnerabilities. Anyone with the key could sign a bad image.

**The link between them is the order we do things in:**

```
build ──► scan ──► ❌ fails? stop, never signed
                └─► ✅ passes ──► push ──► sign
```

We **only sign images that passed the scan**. So in our setup, a signature means: *"this exact image was built by us and passed our checks."* When Kyverno (Step 07) allows only signed images, it blocks anything that **skipped** our pipeline: an image someone pushed by hand, or one that was tampered with.

> ⚠️ A signed image can still become vulnerable later, when a new CVE is found next month. That's why ECR keeps scanning stored images, and why we rebuild regularly.

## 1.2 The code, file by file

All app code is in [`../app`](../app).

### `app/backend/Dockerfile`

```dockerfile
FROM node:24-alpine

WORKDIR /app

# Copy only the package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY server.js ./

USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
```

| Line | Explained |
|---|---|
| `FROM node:24-alpine` | Node.js **24 LTS** (supported until 2028) on **Alpine** Linux: a tiny base = fewer packages = fewer CVEs |
| `COPY package.json package-lock.json ./` | Dependencies first: Docker caches this layer, so rebuilding after a code change is fast |
| `npm ci --omit=dev` | Installs **exactly** the versions in the lock file, **without** test/dev tools |
| `npm cache clean --force` | Removes the download cache: smaller image |
| `USER node` | Runs as user `node` (uid 1000), **not root** |
| `EXPOSE 8080` | Port above 1024: a non-root user is allowed to open it |

### `app/frontend/Dockerfile`

```dockerfile
FROM nginxinc/nginx-unprivileged:1.30-alpine
ENV BACKEND_URL=http://backend:8080
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
```

| Line | Explained |
|---|---|
| `nginx-unprivileged:1.30-alpine` | Official nginx build that runs as user **101** and listens on **8080** (normal nginx needs root for port 80). `1.30` = current stable branch |
| `BACKEND_URL` | Where `/api/` calls are forwarded. Kubernetes sets it to the backend Service |
| `templates/default.conf.template` | At start, nginx fills `${BACKEND_URL}` in and writes the real config |

### `app/frontend/default.conf.template`

| Block | Explained |
|---|---|
| `listen 8080;` | Non-root port |
| `location /` | Serves `index.html` (the page you see) |
| `location /api/` → `proxy_pass ${BACKEND_URL}` | Sends API calls to the backend (tier 1 → tier 2) |
| `location = /healthz` | Always answers `ok`: used by Kubernetes probes and the ALB health check |

### `app/backend/server.js` (unchanged from the 04 lab)

| Endpoint | Used by | Meaning |
|---|---|---|
| `GET /api/health` | **liveness** probe | "The process is alive" (does not check the DB) |
| `GET /api/ready` | **readiness** probe | "I can reach MySQL" → 503 if not, so Kubernetes stops sending traffic |
| `GET/POST/DELETE /api/tasks` | the web page | The app itself (a task list stored in MySQL) |
| `GET /metrics` | Prometheus (Step 11) | Request counters |

### `app/docker-compose.yml`

Runs all 3 tiers on your laptop to test the images **before** pushing. The passwords in it are local-only test values; in EKS the passwords come from AWS Secrets Manager (Step 06).

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

| Label | Meaning |
|---|---|
| 📍 **Where** | Which window |
| 💻 **Terminal** | On your laptop |
| ▶️ **Do** | One command box at a time: copy, paste, Enter |
| ✅ **Check** | How to know it worked |

```
Task 1  Docker works without sudo       💻
Task 2  Install Trivy and Cosign        💻
Task 3  Test the app locally            💻
Task 4  Build the images                💻
Task 5  Scan with Trivy                 💻
Task 6  Push to ECR                     💻   (ECR exists only while Step 01 is applied)
Task 7  Create your signing key         💻
Task 8  Sign and verify                 💻
```

> ⚠️ **ECR is created by Terraform in Step 01.** Tasks 6–8 need it: run `terraform apply` (Step 01, Task 6) first if you destroyed it.
> After `terraform destroy`, the repositories (and your images) are deleted (`force_delete = true`), so you repeat Tasks 4–8 next time. That takes 5 minutes.

---

## Task 1 — Docker works without sudo

📍 **Where:** 💻 Terminal

**Why:** if `docker` says `permission denied ... docker.sock`, your user is not in the `docker` group.

▶️ **Do:**

```bash
docker ps
```

Works (prints a table, maybe empty)? Go to Task 2. Permission denied? Run:

```bash
sudo usermod -aG docker $USER
```

```bash
newgrp docker
```

> `newgrp` applies the new group in this terminal. In other terminals: log out and back in once.

✅ **Check:** `docker ps` prints a table header without errors.

---

## Task 2 — Install Trivy and Cosign

📍 **Where:** 💻 Terminal

▶️ **Do:** Trivy (official install script, into `/usr/local/bin`):

```bash
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin v0.76.2
```

Cosign:

```bash
curl -sSfL -o cosign https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-amd64
```

```bash
sudo install -m 0755 cosign /usr/local/bin/cosign && rm cosign
```

✅ **Check:**

```bash
trivy --version && cosign version
```

> ✅ `Version: 0.76.2` and `GitVersion: v3.1.4`.

---

## Task 3 — Test the app locally

📍 **Where:** 💻 Terminal

**Why:** find mistakes on your laptop (free, fast) before they reach AWS.

▶️ **Do:**

```bash
cd ~/k8s-eks-projects/05-production-eks/app
```

```bash
docker compose up --build
```

> First run downloads MySQL and builds both images: 2–3 minutes. Wait for `backend listening on :8080` and `DB ready, table 'tasks' exists`.

Open **http://localhost:8081** in your browser and add a task.

✅ **Check:** the task appears, and the bottom line says `backend version: local · 1 task(s) in MySQL`.

Stop it: press `Ctrl+C`, then:

```bash
docker compose down
```

---

## Task 4 — Build the images

📍 **Where:** 💻 Terminal, in `05-production-eks/app`

▶️ **Do:** save your ECR address in a variable (it contains your account ID, so it stays in your terminal, never in Git):

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

```bash
export ECR=$ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com
```

```bash
docker build -t $ECR/prod-backend:v1 ./backend
```

```bash
docker build -t $ECR/prod-frontend:v1 ./frontend
```

✅ **Check:**

```bash
docker images | grep prod-
```

> ✅ 2 lines: `prod-backend v1` (~170 MB) and `prod-frontend v1` (~50 MB).

---

## Task 5 — Scan with Trivy

📍 **Where:** 💻 Terminal

**Why:** never push an image with a known HIGH/CRITICAL bug that already has a fix.

▶️ **Do:**

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $ECR/prod-backend:v1
```

```bash
trivy image --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 $ECR/prod-frontend:v1
```

| Flag | Meaning |
|---|---|
| `--severity HIGH,CRITICAL` | Only show the serious ones |
| `--ignore-unfixed` | Skip CVEs with no fixed version yet (nothing you can do) |
| `--exit-code 1` | Return "failed" if any are found. In CI this **stops the pipeline** (Step 10) |

✅ **Check:** each scan ends with `Total: 0` and no error. Check the exit code:

```bash
echo $?
```

> ✅ `0` = clean. `1` = something found: read the table (library, CVE, fixed version). Usually the fix is to rebuild with a newer base image: `docker pull node:24-alpine` (or `nginxinc/nginx-unprivileged:1.30-alpine`), then repeat Task 4.

---

## Task 6 — Push to ECR

📍 **Where:** 💻 Terminal

▶️ **Do:** log Docker in to ECR (the password is a 12-hour token from your AWS login):

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR
```

> ✅ `Login Succeeded`

```bash
docker push $ECR/prod-backend:v1
```

```bash
docker push $ECR/prod-frontend:v1
```

✅ **Check:**

```bash
aws ecr describe-images --repository-name prod-backend --region us-east-1 --query 'imageDetails[].imageTags' --output text
```

> ✅ `v1`

ECR also scans on push (Step 01 `scan_on_push = true`). After ~1 minute:

```bash
aws ecr describe-image-scan-findings --repository-name prod-backend --image-id imageTag=v1 --region us-east-1 --query 'imageScanFindings.findingSeverityCounts'
```

> ✅ `{}` or only LOW/MEDIUM counts. That's the **second** scan, done by AWS.

> 💡 **Immutable tags:** if you ever push a *different* image as `v1`, ECR refuses with `tag invalid: The image tag 'v1' already exists ... cannot be overwritten because the repository is immutable`. Every new build needs a new tag (`v2`, or the commit SHA in Step 10).

---

## Task 7 — Create your signing key

📍 **Where:** 💻 Terminal

▶️ **Do:** keep the key outside the repo, in a private folder:

```bash
mkdir -p ~/.cosign && cd ~/.cosign
```

```bash
cosign generate-key-pair
```

> It asks for a password **twice**: choose one and remember it (it protects the private key).

✅ **Check:**

```bash
ls -l ~/.cosign
```

> ✅ `cosign.key` (private 🔒) and `cosign.pub` (public 🔓).

```bash
cat ~/.cosign/cosign.pub
```

> You will paste this public key into the Kyverno policy in Step 07.

---

## Task 8 — Sign and verify

📍 **Where:** 💻 Terminal

**Why:** sign the exact image **digest** that is in ECR.

▶️ **Do:** get the digests:

```bash
BACKEND_DIGEST=$(aws ecr describe-images --repository-name prod-backend --image-ids imageTag=v1 --region us-east-1 --query 'imageDetails[0].imageDigest' --output text)
```

```bash
FRONTEND_DIGEST=$(aws ecr describe-images --repository-name prod-frontend --image-ids imageTag=v1 --region us-east-1 --query 'imageDetails[0].imageDigest' --output text)
```

```bash
echo $BACKEND_DIGEST $FRONTEND_DIGEST
```

> ✅ Two values starting with `sha256:`.

Sign (it asks for your key password):

```bash
cosign sign --yes --key ~/.cosign/cosign.key $ECR/prod-backend@$BACKEND_DIGEST
```

```bash
cosign sign --yes --key ~/.cosign/cosign.key $ECR/prod-frontend@$FRONTEND_DIGEST
```

> `--yes` = don't ask "upload to the public transparency log?". The log (Rekor) stores only the signature record, not your image.

✅ **Check:** verify with the **public** key:

```bash
cosign verify --key ~/.cosign/cosign.pub $ECR/prod-backend@$BACKEND_DIGEST > /dev/null
```

> ✅ `Verification for ... -- The following checks were performed ... The signatures were verified against the specified public key`

🎉 **Step 02 is done.** Two scanned, signed images are in ECR.

---

## Common problems

| Error | Why | Fix |
|---|---|---|
| `permission denied ... docker.sock` | User not in the `docker` group | Task 1 |
| `no basic auth credentials` / `denied` on push | Docker not logged in to ECR, or the 12-hour token expired | Repeat the `docker login` command in Task 6 |
| `name unknown: The repository with name 'prod-backend' does not exist` | Step 01 infrastructure is destroyed | `terraform apply` (Step 01) |
| `tag invalid ... already exists` | IMMUTABLE tags: `v1` is taken by a different image | Use a new tag: `v2` |
| Trivy `exit code 1` | HIGH/CRITICAL CVE with a fix | `docker pull` the newer base image, rebuild (Task 4) |
| `cosign: ... UNAUTHORIZED` | Cosign uses Docker's login | Repeat the `docker login` (Task 6) |
| `cosign sign` error about an existing tag `sha256-....sig` | Signing the same digest twice in an IMMUTABLE repo (old signature format) | It is already signed: run `cosign verify` |

## Interview Questions

### Other Questions

**Q1. What is software supply chain security?**
Protecting everything that goes into the running app: code, dependencies, base image, build and registry. We scan for CVEs, use minimal non-root images, immutable tags, and sign images so the cluster runs only what our pipeline built.

**Q2. Why sign the digest and not the tag?**
A tag is a movable name; a digest is the content's fingerprint. Signing the digest proves exactly which bytes were approved.

**Q3. Why `--ignore-unfixed`?**
To fail only on vulnerabilities we can fix now. Unfixed ones are tracked, not used to block every build.

**Q4. Trivy and ECR scan-on-push: why both?**
Trivy runs **before** push, so bad images never reach the registry. ECR scans what is stored, and the results stay visible in AWS.

**Q5. What is the difference between Cosign key-based and keyless signing?**
Key-based uses a key pair you manage. Keyless uses a short-lived certificate tied to an identity (e.g. the GitHub Actions workflow) through Sigstore, so there is no long-lived key to leak.

**Q6. How do you keep images small and safe?**
Small base (Alpine/distroless), production dependencies only, a non-root user, cache-friendly layer order, and regular rebuilds to pick up patched base images.

**Q7. Does a signed image mean it has no vulnerabilities?**
No. A signature proves **who** built the image and that it is **unchanged**; a scan checks for **vulnerabilities**. They become linked only because the pipeline signs **after** the scan passes, so "signed" means "passed our pipeline". New CVEs can still appear later, so registries keep rescanning.
