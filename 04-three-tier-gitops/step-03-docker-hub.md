# Step 03 — Build and Push Images to Docker Hub (by hand)

Do by hand what CI will do later, so you know every command CI runs.

## About this step

| Item | Value |
|---|---|
| Where | 💻 Laptop |
| Registry | Docker Hub (`docker.io/<your-user>/...`) |
| Images | `three-tier-frontend:v1`, `three-tier-backend:v1` |

## Concepts

**Image:** a packaged app (code + runtime + OS libraries).
**Registry:** a store for images (Docker Hub, ECR). K8s nodes **pull** images from it.
**Tag:** a version label on an image. `v1` here; CI will use the **git commit SHA**.

```
docker build ──► local image ──docker push──► Docker Hub ──pull──► EKS nodes
  <user>/three-tier-backend:v1
```

| Tag style | Example | Good for |
|---|---|---|
| Manual version | `v1` | Learning (this step) |
| Git SHA | `a1b2c3d` | CI: every build is unique and traceable to a commit |
| `latest` | `latest` | ❌ Never deploy it: K8s / Argo CD can't see that anything changed |

---

## Lab

### 3.1 Create a Docker Hub access token

Docker Hub → **Account settings → Personal access tokens → Generate** (Read & Write). Copy it.

> The same token goes into GitHub Secrets in Step 06.

```bash
# 💻 LAPTOP
docker login -u <your-dockerhub-user>
```

Paste the token as the password.

### 3.2 Set your username once

```bash
export DH_USER=<your-dockerhub-user>
```

### 3.3 Build and push the backend

```bash
cd ~/three-tier-app/backend
```
```bash
docker build -t $DH_USER/three-tier-backend:v1 .
```
```bash
docker push $DH_USER/three-tier-backend:v1
```

### 3.4 Build and push the frontend

```bash
cd ~/three-tier-app/frontend
```
```bash
docker build -t $DH_USER/three-tier-frontend:v1 .
```
```bash
docker push $DH_USER/three-tier-frontend:v1
```

### 3.5 Put your username in the gitops repo

Replace `YOUR_DOCKERHUB_USERNAME` in **2 files**:
- `charts/three-tier/values.yaml`
- `values/dev.yaml`

```bash
cd ~/three-tier-gitops
```
```bash
sed -i "s/YOUR_DOCKERHUB_USERNAME/$DH_USER/g" charts/three-tier/values.yaml values/dev.yaml
```
```bash
grep -rn "repository:" charts values
```
```bash
git commit -am "Use my Docker Hub images" && git push
```

---

## ✅ Check before Step 04

| Check | Expected |
|---|---|
| hub.docker.com → Repositories | `three-tier-frontend` and `three-tier-backend`, tag `v1` |
| Repos are **public** on Docker Hub | yes (otherwise see `imagePullSecret` in `values.yaml`) |
| `grep YOUR_DOCKERHUB` in gitops repo | no results |

## Interview one-liners

- **Why copy `package.json` before the code in the Dockerfile?** → Layer caching: `npm ci` re-runs only when dependencies change, so builds are faster.
- **Why not deploy `latest`?** → No version to roll back to, and the Deployment spec doesn't change, so nothing redeploys.
