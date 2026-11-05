# Step 02 — The App: Create the 2 Repos and Run Locally

Before Kubernetes, see the 3 tiers working on your laptop with Docker Compose.

## About this step

| Item | Value |
|---|---|
| Where | 💻 Laptop (no AWS needed) |
| Tools | git, Docker, Docker Compose |
| Code | [three-tier-app](./three-tier-app) and [three-tier-gitops](./three-tier-gitops) |
| Result | App running at http://localhost:8081 |

## Concepts

**3-tier architecture:** an app split into 3 layers, where each layer only talks to the next one.

| Tier | Here | Talks to | Port |
|---|---|---|---|
| 1. Presentation | nginx: `index.html` + proxy `/api/*` | backend | 80 |
| 2. Application (logic) | Node.js Express API | MySQL | 8080 |
| 3. Data | MySQL 8.0 | — | 3306 |

```
browser ──► nginx :80 ──/api/*──► Node.js :8080 ──SQL──► MySQL :3306
             (static page)          (REST API)             (table: tasks)
```

### Backend API

| Endpoint | Purpose | Used by |
|---|---|---|
| `GET /api/health` | Process alive? (no DB check) | K8s **liveness** probe |
| `GET /api/ready` | DB reachable? | K8s **readiness** probe |
| `GET/POST /api/tasks`, `DELETE /api/tasks/:id` | Task list CRUD | frontend |
| `GET /metrics` | Prometheus metrics | Step 08 |

### Files in `three-tier-app`

| File | Purpose |
|---|---|
| `backend/server.js` | API + creates table `tasks` on start (retries until MySQL is up) |
| `backend/test/health.test.js` | Unit tests (run in CI, no DB needed) |
| `backend/Dockerfile` | `node:20-alpine`, `npm ci`, runs as non-root `node` user |
| `frontend/index.html` | The page (vanilla JS, calls `/api`) |
| `frontend/default.conf.template` | nginx config; `${BACKEND_URL}` is filled in from an env var at start |
| `frontend/Dockerfile` | `nginx:1.27-alpine` |
| `docker-compose.yml` | Runs all 3 tiers locally |
| `.github/workflows/ci.yml` | **Empty.** You write it in Step 06 |

---

## Lab

### 2.1 Create the 2 GitHub repos

On GitHub, create 2 **public** repos (no README, so they start empty):
- `three-tier-app`
- `three-tier-gitops`

> Public keeps Argo CD simple: no repo credentials needed.

### 2.2 Copy the code into them and push

```bash
# 💻 LAPTOP
cd ~
```
```bash
cp -r ~/k8s-eks-projects/04-three-tier-gitops/three-tier-app ~/three-tier-app
```
```bash
cp -r ~/k8s-eks-projects/04-three-tier-gitops/three-tier-gitops ~/three-tier-gitops
```

Push the app repo:

```bash
cd ~/three-tier-app
```
```bash
git init -b main && git add . && git commit -m "3-tier app: frontend, backend, compose"
```
```bash
git remote add origin git@github.com:Abhignadumpala/three-tier-app.git
```
```bash
git push -u origin main
```

Push the gitops repo the same way:

```bash
cd ~/three-tier-gitops
```
```bash
git init -b main && git add . && git commit -m "Helm chart, dev values, Argo CD app"
```
```bash
git remote add origin git@github.com:Abhignadumpala/three-tier-gitops.git
```
```bash
git push -u origin main
```

### 2.3 Run the backend tests

```bash
cd ~/three-tier-app/backend
```
```bash
npm ci
```
```bash
npm test
```

Expected: `pass 3`, `fail 0`.

### 2.4 Run all 3 tiers

```bash
cd ~/three-tier-app
```
```bash
docker compose up --build
```

Open **http://localhost:8081**, add a few tasks, then refresh the page. The tasks are still there because they're stored in MySQL.

Test the API directly (in a 2nd terminal):

```bash
curl localhost:8081/api/ready
```
```bash
curl localhost:8081/api/tasks
```

### 2.5 Stop

```bash
docker compose down
```

(`docker compose down -v` also deletes the MySQL data volume.)

---

## ✅ Check before Step 03

| Check | Expected |
|---|---|
| Both repos on GitHub | code visible |
| `npm test` | 3 passed |
| http://localhost:8081 | add/delete tasks works |
| Footer text | `backend version: local · N task(s) in MySQL` |

## Troubleshooting

| Problem | Fix |
|---|---|
| `permission denied ... docker.sock` | `sudo usermod -aG docker $USER`, then log out and back in |
| Page shows `backend/db error` | MySQL is still starting; the backend retries every 5s. Watch `docker compose logs backend` |
| Port 8081 busy | Change `"8081:80"` in `docker-compose.yml` |

## Interview one-liners

- **What is 3-tier architecture?** → Presentation, application and data layers, each scaled and secured separately. Only the frontend is public.
- **Liveness vs readiness?** → Liveness restarts a stuck container. Readiness removes the pod from the Service until it can serve (here: until the DB is reachable).
