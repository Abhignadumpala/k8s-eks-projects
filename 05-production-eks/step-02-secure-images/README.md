# Step 02 — Secure Images: Build, Scan, Sign, Push

[⬅ Back to the project overview](../README.md) · [⬅ Step 01](../step-01-infrastructure/README.md) · [Step 03 ➡](../step-03-deploy-app/README.md)

> 🛠️ Something failed? See **[Troubleshooting](./TROUBLESHOOTING.md)**: every error from the real run, with why and fix.

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

```
code + base image + libraries ──► build ──► 🔍 scan ──► registry ──► ✍️ sign ──► ✅ verify ──► cluster
       (ingredients)             (cook)   (inspect)   (warehouse)   (seal)     (check seal)
```

> **Interview one-liner:** "Supply chain security means scanning images for CVEs, storing them in a private registry with immutable tags, and signing them so the cluster only runs images we built."

### The 3 tools

| Tool | What it does | Analogy |
|---|---|---|
| **Trivy** | Lists known vulnerabilities (CVEs) in an image and can fail the build | Food inspector checking the ingredients |
| **ECR** | Private image registry in your AWS account | Locked warehouse |
| **Cosign** | Signs an image with your private key; anyone with the public key can verify it | A wax seal on the box |

### ECR vs Docker Hub

**Definition:** both are **image registries** (places to store and pull container images). **ECR** is AWS's private registry inside your account; **Docker Hub** is Docker's public registry.

| | **ECR** (AWS) | **Docker Hub** |
|---|---|---|
| What | Private registry in your AWS account | Public registry run by Docker |
| Default visibility | Private | Public (private repos limited/paid) |
| Login / access | IAM roles + policies | Docker Hub username + token |
| EKS pulls images | Node IAM role, no password stored | Needs `imagePullSecret` for private images |
| Network | Same AWS region → fast, cheap | Over the internet, pull rate limits |
| Scanning | Built in (scan on push) | Docker Scout (more features paid) |
| Used for | Your company's own app images | Public base images (`node`, `nginx`, `mysql`) |

```
Docker Hub ──(FROM node / nginx)──► 💻 docker build ──► Trivy ──► push ──► ECR ──► EKS pulls
 base images                                                              our images
```

> **Interview one-liner:** "We use ECR instead of Docker Hub because it's private, IAM-controlled, and in the same region as EKS."

### CVE, severity and "fixed version"

**Definition:** a **CVE (Common Vulnerabilities and Exposures)** is a **public ID number** for one known security bug in a piece of software, e.g. `CVE-2026-31789` (a heap overflow in OpenSSL).

- Every package in an image (openssl, npm, express…) can have CVEs.
- **Trivy** lists every package in the image and checks each one against the public CVE lists.
- For each CVE it shows a **severity** and, if one exists, the **fixed version** to upgrade to.

**Analogy 🚗:** a CVE is a **car recall notice**: "model X, year Y has a brake problem, fixed in part Z". Trivy checks every part in your car against all recall notices.

| Term | Meaning |
|---|---|
| **CVE ID** | Unique name for one bug, so everyone talks about the same thing |
| **Severity** | LOW / MEDIUM / HIGH / CRITICAL: how dangerous it is |
| **Installed version** | The version inside your image |
| **Fixed version** | The version where the bug is patched: upgrade to remove the CVE |

We fail only on **HIGH or CRITICAL that have a fix** (`--ignore-unfixed`): those you can actually fix by updating. Failing on every unfixed LOW would block you forever with nothing to do.

> **Interview one-liner:** "A CVE is a public ID for a known vulnerability; we scan with Trivy and block HIGH/CRITICAL ones that have a fix. Fewer packages in the image means fewer CVEs."

### Tag vs digest

**Definition:** a **tag** is a **name you choose** for an image (`v1`). A **digest** is the image's **fingerprint**: a SHA-256 hash calculated from its exact content (`sha256:9f86d0...`).

- A tag is like a **sticky note**: someone can move it to a different image.
- A digest is **calculated** from the content: change 1 byte → a completely different digest.
- So a digest always means **one exact image**, forever.

**Analogy 🪪:** a tag is a person's **nickname** (anyone can be called "Sam"); a digest is their **fingerprint** (only one person has it).

```
Day 1: v1 → image A (good)          ← you sign "v1"
Day 2: attacker pushes image B as v1
       v1 → image B (bad) 😱         ← "v1" now means something else
Signing the digest sha256:aaa… → the signature belongs to image A forever; image B has no valid signature ✅
```

| | Example | Can it change? |
|---|---|---|
| **Tag** | `prod-backend:v1` | Normally yes (that's why ECR is set to IMMUTABLE) |
| **Digest** | `prod-backend@sha256:9f86d0...` | **Never**: it is the fingerprint of the exact image content |

We **sign the digest**, not the tag: the signature is bound to the exact bytes.

> **Interview one-liner:** "A tag is a movable name; a digest is the SHA-256 hash of the image content. We sign and deploy by digest because it always means one exact image."

### How signing works (key pair)

**Definition:** **signing** = attaching a proof that **we** built this exact image. It uses a **key pair**: a **private key** (secret, makes signatures) and a **public key** (shared, checks them).

**Analogy 🔏:** the private key is your **wax seal stamp** (only you have it); the public key is a **photo of the seal** that anyone can use to check the seal on the box is real and unbroken.

```
cosign generate-key-pair
   ├── cosign.key  🔒 PRIVATE: signs images. Never share, never commit (.gitignore blocks *.key)
   └── cosign.pub  🔓 PUBLIC: verifies signatures. Safe to share and commit
```

- **Sign:** `cosign sign --key cosign.key <image@digest>` → a signature is stored in ECR next to the image.
- **Verify:** `cosign verify --key cosign.pub <image@digest>` → ✅ only if it was signed by **your** private key and the image is unchanged.

> **Interview one-liner:** "We sign the image digest with Cosign's private key; Kyverno verifies it with the public key, so only images from our pipeline can run."

> Production teams often use **keyless** signing (GitHub's identity + Sigstore) or a key in **AWS KMS**, so no key file exists at all. We use a key file because it is the easiest way to see how signing works.

<details><summary><sub>💡 Note: does "signed" mean "scanned"?</sub></summary>

<sub>

No. **Scan** = no known vulnerabilities. **Sign** = built by us and unchanged. They're linked only because we sign **after** the scan passes, so "signed" means "passed our pipeline".

</sub>
</details>

## 1.2 The code, file by file

All app code is in [`../app`](../app).

### `app/backend/Dockerfile`

**Multi-stage build** = 2 `FROM` lines in one Dockerfile. Stage 1 **installs** (has npm), stage 2 is what we **ship** (no npm). Only what we `COPY --from=build` reaches stage 2.

| Stage | Name | Job | Shipped? |
|---|---|---|---|
| **1** | **Build stage** | Install dependencies (`npm ci`): has npm | ❌ Thrown away |
| **2** | **Runtime stage** | Run the app (`node server.js`): only node + app | ✅ Final image |

```
Build stage (tools to MAKE the app) ──COPY──► Runtime stage (only what RUNS the app) ← shipped
```

The **last `FROM`** is always the final image.

```dockerfile
# ───────────────────────────────────────────────
# Backend image: Node.js API (multi-stage build)
#   Stage 1 "build": node image WITH npm → installs libraries into /app/node_modules
#   Stage 2 "run":   plain Alpine + only the node binary → NO npm/npx/yarn/corepack
#   - only production dependencies
#   - runs as user "node" (uid 1000), never root
# ───────────────────────────────────────────────

# ---------- Stage 1: build (thrown away after the build) ----------
FROM node:24-alpine AS build

WORKDIR /app

# Copy only the package files first → this layer is cached until dependencies change
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server.js ./

# ---------- Stage 2: run (this is the image we ship) ----------
# Same Alpine version as node:24-alpine, so the copied node binary works
FROM alpine:3.24

# Security fixes + the C++ library node needs + user "node" (uid 1000)
RUN apk upgrade --no-cache \
 && apk add --no-cache libstdc++ \
 && addgroup -g 1000 node \
 && adduser -u 1000 -G node -s /sbin/nologin -D node

# Take only what the app needs from stage 1: the node binary and /app
COPY --from=build /usr/local/bin/node /usr/local/bin/node

WORKDIR /app
COPY --from=build --chown=node:node /app /app

USER node

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
```

| Line | Explained |
|---|---|
| `FROM node:24-alpine AS build` | Stage 1: Node 24 with npm, named `build` |
| `npm ci --omit=dev` | Installs exact lock-file versions, no dev tools |
| `FROM alpine:3.24` | Stage 2: plain Alpine, **no npm** (same version as the node image) |
| `apk upgrade` / `apk add libstdc++` | Security fixes + library `node` needs |
| `adduser -u 1000` | User `node`, uid 1000 (matches Helm in Step 05) |
| `COPY --from=build ...` | Take only the `node` binary and `/app` |
| `USER node` | Run as non-root |

| | Single-stage + `rm -rf npm` | Multi-stage |
|---|---|---|
| npm | Hidden in a layer, still there | Never copied |
| Size | 274 MB | **225 MB (−18%)** |
| Trivy HIGH/CRITICAL | 0 | 0 |

> Tried distroless: 1 CRITICAL + 7 HIGH (old OpenSSL) and no shell → kept Alpine (0 CVEs).

> **Interview one-liner:** "Multi-stage keeps build tools out of the runtime image: stage 1 runs `npm ci`, stage 2 copies only node and the app. Smaller image, fewer CVEs."

> **Interview one-liner:** "Stage 1 is the build stage, with the tools to install and compile. Stage 2 is the runtime stage, with only what the app needs to run. Only the runtime stage is shipped."

### `app/frontend/Dockerfile`

```dockerfile
FROM nginxinc/nginx-unprivileged:1.31-alpine
USER root
RUN apk upgrade --no-cache
USER 101
ENV BACKEND_URL=http://backend:8080
COPY default.conf.template /etc/nginx/templates/default.conf.template
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
```

| Line | Explained |
|---|---|
| `nginx-unprivileged:1.31-alpine` | Official nginx build that runs as user **101** and listens on **8080** (normal nginx needs root for port 80). `1.31` = mainline branch (gets security fixes first) |
| `USER root` → `RUN apk upgrade --no-cache` → `USER 101` | Become root only to patch Alpine packages, then switch back to the non-root nginx user |
| `BACKEND_URL` | Where `/api/` calls are forwarded. Kubernetes sets it to the backend Service |
| `templates/default.conf.template` | At start, nginx fills `${BACKEND_URL}` in and writes the real config |

**In simple steps:**
1. Start from **nginx-unprivileged**: nginx that already runs as user **101** on port **8080** (no root needed).
2. Switch to root **only** to install Alpine security fixes, then go back to user 101.
3. Set the default `BACKEND_URL` (Kubernetes overrides it with the real backend Service).
4. Copy in the **config template** and the **web page**.
5. No `CMD` line: the base image already starts nginx.

### `app/frontend/default.conf.template`

| Block | Explained |
|---|---|
| `listen 8080;` | Non-root port |
| `location /` | Serves `index.html` (the page you see) |
| `location /api/` → `proxy_pass ${BACKEND_URL}` | Sends API calls to the backend (tier 1 → tier 2) |
| `location = /healthz` | Always answers `ok`: used by Kubernetes probes and the ALB health check |

**In simple steps:**
1. When the container starts, nginx **fills in** `${BACKEND_URL}` and writes the real config file.
2. A visitor opens `/` → nginx sends back `index.html` (the page).
3. The page calls `/api/...` → nginx **forwards** it to the backend (tier 1 → tier 2).
4. `/healthz` always says `ok` → Kubernetes and the ALB use it to check nginx is alive.

```
browser ──/──────► nginx ──► index.html
browser ──/api/──► nginx ──proxy_pass──► backend:8080
ALB/kubelet ──/healthz──► nginx ──► "ok"
```

### `app/backend/server.js` (unchanged from the 04 lab)

| Endpoint | Used by | Meaning |
|---|---|---|
| `GET /api/health` | **liveness** probe | "The process is alive" (does not check the DB) |
| `GET /api/ready` | **readiness** probe | "I can reach MySQL" → 503 if not, so Kubernetes stops sending traffic |
| `GET/POST/DELETE /api/tasks` | the web page | The app itself (a task list stored in MySQL) |
| `GET /metrics` | Prometheus (Step 11) | Request counters |

**In simple steps:**
1. A small **Node.js (Express) API** that stores a **task list** in MySQL.
2. The web page calls `/api/tasks` to list, add and delete tasks.
3. Kubernetes calls `/api/health` (alive?) and `/api/ready` (can I reach MySQL?).
4. Prometheus reads `/metrics` (how many requests, which status codes).

### `app/docker-compose.yml`

Runs all 3 tiers on your laptop to test the images **before** pushing. The passwords in it are local-only test values; in EKS the passwords come from AWS Secrets Manager (Step 06).

**In simple steps:**
1. **One file** that starts all 3 containers on your laptop: frontend, backend, MySQL.
2. `docker compose up --build` **builds** the images from the Dockerfiles, then starts them on one private network.
3. You open `http://localhost:8081` and test the app **before** anything goes to AWS.
4. If it works locally, you push to ECR. If not, you fix it for free on the laptop.

```
💻 laptop: localhost:8081 ──► frontend ──► backend :8080 ──► mysql :3306   (test first, then push)
```

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

> `docker ps` = list running containers. Here it's just a test: can **you** talk to Docker without `sudo`?

Works (prints a table, maybe empty)? Go to Task 2. Permission denied? Run:

```bash
sudo usermod -aG docker $USER
```

> `usermod: group 'docker' does not exist`? Docker was installed as a **snap** (`which docker` → `/snap/bin/docker`), which doesn't create the group. Create it and restart Docker:
>
> ```bash
> sudo addgroup --system docker && sudo usermod -aG docker $USER
> ```
>
> ```bash
> sudo snap disable docker && sudo snap enable docker
> ```

Apply the new group in this terminal (asks your laptop password):

```bash
exec su -l $USER
```

> Other terminals: log out of Ubuntu and back in once. (`newgrp docker` also works if it's installed.)

| Command / part | Meaning |
|---|---|
| `sudo usermod -aG docker $USER` | Add (`-a` append, `-G` group) your user (`$USER` = your username, **capital letters**) to the group `docker` |
| `sudo addgroup --system docker` | Create the group `docker` (`--system` = a group for a service, not a person) |
| `sudo snap disable docker && sudo snap enable docker` | Stop and start the Docker snap, so its socket `/var/run/docker.sock` is created with group `docker` |
| `exec su -l $USER` | Replace this terminal's shell (`exec`) with a fresh login (`su -l`) as you, so the new group is loaded |

> **Why a group?** Docker runs as a root service. Only root and members of `docker` may use its socket.

> 📝 **In short:** no new user is created. We create the `docker` **group** and add **my existing user** to it, so I can run docker commands **without sudo**.
>
> ```
> BEFORE: groups = sri-abhi, sudo ...           → docker ps ❌ permission denied
> AFTER:  groups = sri-abhi, sudo ..., docker   → docker ps ✅ works without sudo
> ```
>
> Check your groups: `groups` (you should see `docker`).

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

| Part | Meaning |
|---|---|
| `curl -sfL <url>` | Download the file at `<url>`. `-s` silent, `-f` fail on errors (no error page saved), `-L` follow redirects |
| `\| sudo sh -s --` | Pipe the downloaded **install script** straight into `sh` (the shell) and run it as root. `-s --` = "read the script from the pipe; what follows are its arguments" |
| `-b /usr/local/bin v0.76.2` | Script arguments: put the binary in `/usr/local/bin` (a folder in your `PATH`), version `v0.76.2` (pinned) |
| `curl -sSfL -o cosign <url>` | Download the Cosign **binary** from its GitHub release and save it as `cosign`. `-S` shows an error if it fails |
| `sudo install -m 0755 cosign /usr/local/bin/cosign` | Copy it into `/usr/local/bin` with permissions `0755` (everyone may run it, only root may change it) |
| `&& rm cosign` | Only if that worked, delete the downloaded copy |

> ⚠️ Piping a script into `sudo sh` runs it as root. Do it only from the **official** source (here: Aqua Security's own repo), with a pinned version.

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

| Part | Meaning |
|---|---|
| `docker compose` | Starts several containers together from `docker-compose.yml`: frontend, backend, MySQL, with a shared network |
| `up` | Create and start them, showing their logs in this terminal |
| `--build` | Build the frontend and backend images from their Dockerfiles first |

> First run downloads MySQL and builds both images: 2–3 minutes. Wait for `backend listening on :8080` and `DB ready, table 'tasks' exists`.

Open **http://localhost:8081** in your browser and add a task.

✅ **Check:** the task appears, and the bottom line says `backend version: local · 1 task(s) in MySQL`.

Stop it: press `Ctrl+C`, then:

```bash
docker compose down
```

> `down` = stop and **remove** the containers and their network (the images stay).

---

## Task 4 — Build the images

📍 **Where:** 💻 Terminal, in `05-production-eks/app`

▶️ **Do:** save your ECR address in a variable (it contains your account ID, so it stays in your terminal, never in Git):

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

```bash
export ECR=$ACCOUNT_ID.dkr.ecr.eu-north-1.amazonaws.com
```

| Part | Meaning |
|---|---|
| `export NAME=value` | Save a variable for this terminal (and programs it starts) |
| `$(aws sts get-caller-identity --query Account --output text)` | Run the command inside `$( )` and use its output: your 12-digit AWS **account ID** |
| `$ACCOUNT_ID.dkr.ecr.eu-north-1.amazonaws.com` | Your ECR **registry** address (Step 01: one registry, many repositories) |

```bash
docker build --provenance=false -t $ECR/prod-backend:v1 ./backend
```

```bash
docker build --pull --provenance=false -t $ECR/prod-frontend:v1 ./frontend
```

| Part | Meaning |
|---|---|
| `docker build` | Build an image by following the `Dockerfile` |
| `--provenance=false` | Don't attach Docker's build-info attestation. Without it, `v1` becomes an **image index** (a list) that ECR can't scan by tag (`ScanNotFoundException`) |
| `--pull` | Always download the newest base image first, to get its security fixes |
| `-t $ECR/prod-backend:v1` | The image's name (**tag**): `<registry>/<repository>:<version>`. Naming it with the ECR address now means `docker push` knows where it goes |
| `./backend` | The **build context**: the folder whose files the Dockerfile can copy (and where it finds the `Dockerfile`) |

✅ **Check:**

```bash
docker images | grep prod-
```

> `docker images` lists images on your laptop; `| grep prod-` keeps only lines containing `prod-`.

> ✅ 2 lines: `prod-backend v1` (~265 MB on disk, ~66 MB compressed) and `prod-frontend v1` (~110 MB on disk, ~31 MB compressed).

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
| `trivy image <name>` | Scan this local image: OS packages (Alpine) **and** app libraries (npm) |

✅ **Check:** each scan ends with `Total: 0` and no error. Check the exit code:

```bash
echo $?
```

> `$?` = the exit code of the **last** command (0 = success). Run it right after the scan.

> ✅ `0` = clean. `1` = something found: read the table (library, CVE, fixed version), fix, then repeat Task 4.

> 🛠️ Scan failed? → [Troubleshooting #3 (npm CVEs)](./TROUBLESHOOTING.md#3-trivy-backend-6-high-inside-npm) · [#4 (nginx CVEs)](./TROUBLESHOOTING.md#4-trivy-frontend-5-critical--15-high)

---

## Task 6 — Push to ECR

📍 **Where:** 💻 Terminal

▶️ **Do:** log Docker in to ECR (the password is a 12-hour token from your AWS login):

```bash
aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin $ECR
```

| Part | Meaning |
|---|---|
| `aws ecr get-login-password` | Ask AWS for a temporary ECR password (valid 12 hours), using your AWS login |
| `\|` | Pass it straight to the next command, so it never appears on screen or in shell history |
| `docker login --username AWS --password-stdin $ECR` | Log Docker in to your registry. The user is always `AWS`; `--password-stdin` reads the password from the pipe |

> ✅ `Login Succeeded`

```bash
docker push $ECR/prod-backend:v1
```

```bash
docker push $ECR/prod-frontend:v1
```

> `docker push` uploads the image's layers to the repository in its name. Layers ECR already has are skipped.

✅ **Check:**

```bash
aws ecr describe-images --repository-name prod-backend --region eu-north-1 --query 'imageDetails[].imageTags' --output text
```

> `describe-images` lists the images in a repository. `--query` picks only the tags; `--output text` prints them plainly.

> ✅ `v1`

ECR also scans on push (Step 01 `scan_on_push = true`). After ~1 minute:

```bash
aws ecr describe-image-scan-findings --repository-name prod-backend --image-id imageTag=v1 --region eu-north-1 --query 'imageScanFindings.findingSeverityCounts'
```

> Reads ECR's own scan result for `prod-backend:v1` and shows only the count per severity.

> ✅ `{}` or only LOW/MEDIUM counts. That's the **second** scan, done by AWS. (No output at all = also clean: no findings.)

> 🛠️ `ScanNotFoundException`? → [Troubleshooting #5](./TROUBLESHOOTING.md#5-ecr-scannotfoundexception) · ECR shows HIGH/CRITICAL that Trivy passed? → [#6](./TROUBLESHOOTING.md#6-ecr-finds-criticalhigh-that-trivy-passed)

> 💡 **Immutable tags:** if you ever push a *different* image as `v1`, ECR refuses with `tag invalid: The image tag 'v1' already exists ... cannot be overwritten because the repository is immutable`. Every new build needs a new tag (`v2`, or the commit SHA in Step 10).

---

## Task 7 — Create your signing key

📍 **Where:** 💻 Terminal

▶️ **Do:** keep the key outside the repo, in a private folder:

```bash
mkdir -p ~/.cosign && cd ~/.cosign
```

> `mkdir -p` = create the folder (no error if it already exists). `~/.cosign` is in your home folder (the `.` hides it), **outside** the Git repo, so the private key can never be committed.

```bash
cosign generate-key-pair
```

> Creates 2 files in the current folder: `cosign.key` (private, encrypted with your password) and `cosign.pub` (public).

> It asks for a password **twice**: choose one and remember it (it protects the private key).

✅ **Check:**

```bash
ls -l ~/.cosign
```

> `ls -l` = list files with details (permissions, size, date).

> ✅ `cosign.key` (private 🔒) and `cosign.pub` (public 🔓).

```bash
cat ~/.cosign/cosign.pub
```

> `cat` prints a file's content. Only ever print the **.pub**, never the `.key`.

> You will paste this public key into the Kyverno policy in Step 07.

---

## Task 8 — Sign and verify

📍 **Where:** 💻 Terminal

**Why:** sign the exact image **digest** that is in ECR.

▶️ **Do:** get the digests:

```bash
BACKEND_DIGEST=$(aws ecr describe-images --repository-name prod-backend --image-ids imageTag=v1 --region eu-north-1 --query 'imageDetails[0].imageDigest' --output text)
```

```bash
FRONTEND_DIGEST=$(aws ecr describe-images --repository-name prod-frontend --image-ids imageTag=v1 --region eu-north-1 --query 'imageDetails[0].imageDigest' --output text)
```

| Part | Meaning |
|---|---|
| `BACKEND_DIGEST=$( ... )` | Save the command's output in a variable |
| `--image-ids imageTag=v1` | The image tagged `v1` |
| `--query 'imageDetails[0].imageDigest'` | Take only its **digest**: `sha256:...`, the fingerprint of the exact bytes |

```bash
echo $BACKEND_DIGEST $FRONTEND_DIGEST
```

> ✅ Two values starting with `sha256:`.

Log cosign in to ECR (needed with **snap** Docker, harmless otherwise):

```bash
aws ecr get-login-password --region eu-north-1 | cosign login --username AWS --password-stdin $ECR
```

> Cosign reuses Docker's login from `~/.docker/config.json`; snap Docker saves it elsewhere. Without this: `401 Unauthorized` ([Troubleshooting #7](./TROUBLESHOOTING.md#7-cosign-sign-401-unauthorized)).

Sign (it asks for your key password):

```bash
cosign sign --yes --key ~/.cosign/cosign.key $ECR/prod-backend@$BACKEND_DIGEST
```

```bash
cosign sign --yes --key ~/.cosign/cosign.key $ECR/prod-frontend@$FRONTEND_DIGEST
```

| Part | Meaning |
|---|---|
| `cosign sign` | Create a signature and store it in ECR, next to the image |
| `--key ~/.cosign/cosign.key` | Sign with **your private** key (it asks for its password) |
| `$ECR/prod-backend@$BACKEND_DIGEST` | `@sha256:...` = sign the **exact** image, not the movable tag `:v1` |

> `--yes` = don't ask "upload to the public transparency log?". The log (Rekor) stores only the signature record, not your image.

✅ **Check:** verify with the **public** key:

```bash
cosign verify --key ~/.cosign/cosign.pub $ECR/prod-backend@$BACKEND_DIGEST > /dev/null
```

| Part | Meaning |
|---|---|
| `cosign verify --key ~/.cosign/cosign.pub` | Check the signature with the **public** key (this is what Kyverno does in Step 07) |
| `> /dev/null` | Throw away the long JSON output; the important result line still shows (it goes to the error stream) |

> ✅ `Verification for ... -- The following checks were performed ... The signatures were verified against the specified public key`

🎉 **Step 02 is done.** Two scanned, signed images are in ECR.

---

## Troubleshooting

All errors (real run + common ones), each with **why** and **fix**: **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)**

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

---

## 📝 Summary: what we did in Step 02 ✅

**One line:** built 2 app images, scanned them twice (Trivy + ECR) to **0** HIGH/CRITICAL, pushed them to private ECR with immutable tags, and **signed** them with Cosign.

### Flow

```
💻 laptop
docker build ──► Trivy scan ──► docker push ──► ECR scan ──► cosign sign ──► cosign verify
  (Task 4)        (Task 5)        (Task 6)       (Task 6)      (Task 8)        (Task 8)
                  gate #1                        gate #2       private key 🔒  public key 🔓
```

- **Gate #1 (Trivy, before the push):** catches a bad image **before it reaches any registry**. If Trivy finds HIGH/CRITICAL, you don't push.
- **Gate #2 (ECR scan, after the push):** a **second opinion** from AWS with its own vulnerability database. Also covers someone pushing **without** running Trivy.
- We pushed to **ECR, not Docker Hub**. Docker Hub was only where the **base images** came from (`FROM node:...`, `FROM nginx:...`).

### Tasks

| Task | What we did | Status |
|---|---|---|
| 1 | Created the `docker` **group** (snap Docker didn't) and added my **user** to it, so docker runs **without sudo** | ✅ |
| 2 | Installed Trivy 0.76.2 + Cosign v3.1.4 | ✅ |
| 3 | Ran the app locally with `docker compose` (frontend + backend + MySQL) | ✅ |
| 4 | Built `prod-backend:v1` + `prod-frontend:v1` | ✅ |
| 5 | Scanned both images with Trivy → **0** HIGH/CRITICAL | ✅ |
| 6 | Pushed to ECR (immutable tags); ECR scan on push → **0** | ✅ |
| 7 | Created the key pair in `~/.cosign` (outside the repo) | ✅ |
| 8 | Signed both images by **digest** and verified them | ✅ |

### Result

| Image | Trivy | ECR scan | Signed |
|---|---|---|---|
| `prod-backend:v1` | 0 | 0 | ✅ |
| `prod-frontend:v1` | 0 | 0 | ✅ |

### Where each tool is used

| Tool | Where | Tasks | Job |
|---|---|---|---|
| Docker | 💻 Laptop | 3, 4, 6 | Build, run, push |
| Trivy | 💻 Laptop | 5 | Find CVEs **before** push |
| Cosign | 💻 Laptop | 7, 8 | Sign (private key), verify (public key) |
| AWS CLI | 💻 Laptop | 4, 6, 8 | Account ID, ECR login, digest |

### Troubleshooting

Errors I hit during this step and how I fixed them: **[TROUBLESHOOTING.md](./TROUBLESHOOTING.md)**

### Manual now → automatic later

| Step | Who signs / checks |
|---|---|
| 02 | **Me**, by hand on the laptop |
| 07 | **Kyverno** checks the signature with `cosign.pub`, blocks unsigned images |
| 10 | **GitHub Actions** builds → scans → pushes → signs on every push |

### Interview one-liners

- **Two scanners:** Trivy before push + ECR after push. ECR caught a CRITICAL that Trivy rated low → defence in depth.
- **Sign the digest, not the tag:** a tag can move, a digest is the exact image.
- **Smaller image = fewer CVEs:** remove tools the app doesn't need to run (npm), using a **multi-stage build** so npm never reaches the shipped image.
- **Scan before push + ECR not Docker Hub:** "We scan with Trivy before the push so a bad image never reaches the registry, and ECR scan on push is a second gate. We use ECR instead of Docker Hub because it's private, IAM-controlled, and in the same region as EKS."
