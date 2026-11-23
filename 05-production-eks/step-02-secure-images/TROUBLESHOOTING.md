# Step 02 — Troubleshooting

[⬅ Back to the Step 02 guide](./README.md)

Every problem from the **real run (22 Nov 2026)**, plus other common errors. Each one: **Error → Why → Fix**.

| # | Problem | Task |
|---|---|---|
| 1 | [`group 'docker' does not exist`](#1-group-docker-does-not-exist) | 1 |
| 2 | [Laptop froze on the first `compose up --build`](#2-laptop-froze-on-the-first-compose-up---build) | 3 |
| 3 | [Trivy: backend 6 HIGH inside npm](#3-trivy-backend-6-high-inside-npm) | 5 |
| 4 | [Trivy: frontend 5 CRITICAL + 15 HIGH](#4-trivy-frontend-5-critical--15-high) | 5 |
| 5 | [ECR: `ScanNotFoundException`](#5-ecr-scannotfoundexception) | 6 |
| 6 | [ECR finds CRITICAL/HIGH that Trivy passed](#6-ecr-finds-criticalhigh-that-trivy-passed) | 6 |
| 7 | [`cosign sign`: `401 Unauthorized`](#7-cosign-sign-401-unauthorized) | 8 |
| — | [Other common errors](#other-common-errors) | — |

---

## 1. `group 'docker' does not exist`

**Error** (Task 1, `sudo usermod -aG docker $USER`):
```
usermod: group 'docker' does not exist
```

**Why:** Docker was installed as a **snap** (`which docker` → `/snap/bin/docker`). Snap doesn't create the `docker` group.

**Fix:** create the group, add your user, restart the snap, reload your groups:

```bash
sudo addgroup --system docker && sudo usermod -aG docker $USER
```

```bash
sudo snap disable docker && sudo snap enable docker
```

```bash
exec su -l $USER
```

> No new user is created: we create the `docker` **group** and add **your existing user** to it, so docker runs **without sudo**. Check with `groups`.

---

## 2. Laptop froze on the first `compose up --build`

**Why:** the first run downloads MySQL and builds both images at the same time: heavy for the laptop.

**Fix:** hard reboot, then run it again (cached layers make it fast). Restart snap Docker with:

```bash
sudo snap restart docker
```

> Snap Docker has no `docker.service`, so `systemctl restart docker` doesn't work.

---

## 3. Trivy: backend 6 HIGH inside npm

**Error** (Task 5):
```
usr/local/lib/node_modules/npm/node_modules/brace-expansion   HIGH  (2)
usr/local/lib/node_modules/npm/node_modules/undici            HIGH  (4)
```

**Why:** the CVEs are in **npm itself**, which comes inside `node:24-alpine`. My app's libraries (`app/node_modules`) were clean. npm is only needed to **install** packages; the app **runs** with `node` alone.

**Fix:** delete npm, npx, yarn and corepack after `npm ci` (in `app/backend/Dockerfile`, before `USER node`):

```dockerfile
RUN rm -rf /usr/local/lib/node_modules /opt/yarn-* /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/corepack
```

**Better fix (now in the Dockerfile):** a **multi-stage build**. Stage 1 runs `npm ci`; stage 2 (`alpine:3.24`) copies only the `node` binary and `/app`, so npm is never in the shipped image. 0 HIGH/CRITICAL, 274 MB → 225 MB.

**Result:** backend Trivy → `0`.

> Lesson: fewer tools in the image = fewer CVEs.

---

## 4. Trivy: frontend 5 CRITICAL + 15 HIGH

**Error** (Task 5): CVEs in `nginx 1.30.6`, `curl`, `brotli-libs`.

**Why:** the newest `nginx-unprivileged:1.30-alpine` still had nginx **1.30.6**; the fix needs **1.30.7**, not released as an image yet. Some Alpine packages were also old.

| Tried | Result |
|---|---|
| `docker build --pull` (newest `1.30-alpine`) | ❌ still 20 |
| + `apk upgrade` | ❌ still 6 (nginx itself) |
| **`1.31-alpine` (mainline 1.31.7) + `apk upgrade`** | ✅ **0**, page loads, runs as uid 101 |

**Fix** (`app/frontend/Dockerfile`):

```dockerfile
FROM nginxinc/nginx-unprivileged:1.31-alpine

USER root
RUN apk upgrade --no-cache
USER 101
```

**Result:** frontend Trivy → `0`.

---

## 5. ECR: `ScanNotFoundException`

**Error** (Task 6):
```
ScanNotFoundException: Image scan does not exist for the image with '{imageDigest:'null', imageTag:'v1'}'
```

**Why:** Docker 29 pushed `v1` as an **image index** (a list pointing to the real image + a build-info attestation). ECR scans only the real image inside, not the list, so a scan "by tag" finds nothing.

**Fix:** build without the attestation, so `v1` is a plain image:

```bash
docker build --provenance=false -t $ECR/prod-backend:v1 ./backend
```

> Empty output from `describe-image-scan-findings` = scan **complete with 0 findings** (clean).

---

## 6. ECR finds CRITICAL/HIGH that Trivy passed

**Error** (Task 6, ECR scan of backend): `CRITICAL: 1, HIGH: 4` (zlib `1.3.2-r1`, openssl `3.5.9-r0`), but Trivy said `0`.

**Why:** both found the **same CVEs**, but rate them differently:

| CVE in | Trivy (Alpine's rating) | ECR (NVD's rating) | Fixed in |
|---|---|---|---|
| zlib | MEDIUM | **CRITICAL** | `1.4-r0` |
| openssl | LOW / MEDIUM | HIGH | `3.5.9-r1` |

Our Trivy gate blocks only HIGH/CRITICAL, so it let them through.

**Fix:**

1. Add to `app/backend/Dockerfile`, right after `FROM`:
   ```dockerfile
   RUN apk upgrade --no-cache
   ```
2. `v1` is **immutable**, so it can't be overwritten. Nothing used it yet, so re-create the empty repos (💻 in `terraform`):
   ```bash
   terraform destroy -target=aws_ecr_repository.app
   ```
   ```bash
   terraform apply -target=aws_ecr_repository.app
   ```
3. Rebuild (Task 4), scan (Task 5), push (Task 6).

**Result:** ECR scan `0` for both images.

> 💡 In a real company you **don't delete** a pushed tag: push the fix as `v2`.
> Lesson: two scanners (Trivy before push + ECR after push) catch more than one = **defence in depth**.

---

## 7. `cosign sign`: `401 Unauthorized`

**Error** (Task 8):
```
GET https://<account>.dkr.ecr.us-east-1.amazonaws.com/v2/prod-backend/manifests/sha256:...: unexpected status code 401 Unauthorized
```

**Why:** cosign reuses Docker's login from `~/.docker/config.json`. **Snap Docker** saves it in `~/snap/docker/current/.docker/config.json`, so cosign had no login.

**Fix:** log cosign in to ECR itself:

```bash
aws ecr get-login-password --region us-east-1 | cosign login --username AWS --password-stdin $ECR
```

> Also happens after **12 hours** (the ECR token expires): run it again.

---

## Other common errors

| Error | Why | Fix |
|---|---|---|
| `permission denied ... docker.sock` | User not in the `docker` group | Task 1 (and [#1](#1-group-docker-does-not-exist) for snap Docker) |
| `no basic auth credentials` / `denied` on push | Docker not logged in to ECR, or the 12-hour token expired | Repeat the `docker login` in Task 6 |
| `name unknown: The repository with name 'prod-backend' does not exist` | ECR repos don't exist (destroyed) | `terraform apply -target=aws_ecr_repository.app` (in `terraform`) |
| `tag invalid ... already exists` | IMMUTABLE tags: `v1` is taken by a different image | Use a new tag: `v2` |
| Trivy `exit code 1` | HIGH/CRITICAL CVE with a fix | Rebuild with `--pull` (newer base); see [#3](#3-trivy-backend-6-high-inside-npm), [#4](#4-trivy-frontend-5-critical--15-high) |
| `$ECR` is empty / `invalid reference format` | New terminal: variables are gone | `export ECR=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com` |
| `cosign sign` error about an existing tag `sha256-....sig` | Signing the same digest twice in an IMMUTABLE repo (old signature format) | It is already signed: run `cosign verify` |

---

[⬅ Back to the Step 02 guide](./README.md)
