# 04 — 3-Tier App on EKS: GitHub Actions + Helm + Argo CD (End-to-End Lab)

Deploy a **frontend + backend + MySQL** app to EKS. Every `git push` builds a new image, and Argo CD deploys it automatically.

## About this lab

| Item | Value |
|---|---|
| Goal | Full CI/CD + GitOps flow, from code push to running pods |
| App | frontend (nginx) → backend (Node.js API) → MySQL |
| CI | GitHub Actions: test, scan, build, push to Docker Hub, update image tag |
| CD | Argo CD: watches the gitops repo and syncs the Helm chart to EKS |
| Infra | Terraform: VPC + EKS + bastion (from [01-eks-terraform](../01-eks-terraform)) |
| Cluster | `abhigna-cluster`, `us-east-1` |

## Concepts

**CI (Continuous Integration):** every push automatically tests the code and builds an image.
**CD (Continuous Delivery):** every new image is automatically deployed to the cluster.
**GitOps:** Git is the single source of truth. A tool inside the cluster (Argo CD) **pulls** changes from Git. CI never touches the cluster.

| Tier | K8s kind | Why |
|---|---|---|
| frontend | Deployment + Service (LoadBalancer) | Stateless; public entry point |
| backend | Deployment + Service (ClusterIP) | Stateless; only the frontend calls it |
| mysql | StatefulSet + headless Service + PVC | Stores data; needs a stable name and its own disk |

## The 2 repos

All the code is in this folder. In [Step 02](./step-02-app-local.md) you copy each subfolder into its own GitHub repo.

| Folder → GitHub repo | Contains | Who changes it |
|---|---|---|
| [three-tier-app](./three-tier-app) → `three-tier-app` | App code, Dockerfiles, `.github/workflows/ci.yml` | Developer (you) |
| [three-tier-gitops](./three-tier-gitops) → `three-tier-gitops` | Helm chart, values per env, Argo CD Application | GitHub Actions (image tag) + you (config) |
| [monitoring](./monitoring) | `values.yaml` for kube-prometheus-stack | You (Step 08) |

```
three-tier-app/                          three-tier-gitops/
├── frontend/                            ├── charts/three-tier/
│   ├── index.html                       │   ├── Chart.yaml
│   ├── default.conf.template (nginx)    │   ├── values.yaml          (defaults)
│   └── Dockerfile                       │   └── templates/
├── backend/                             │       ├── frontend.yaml    Deployment + LB Service
│   ├── server.js                        │       ├── backend.yaml     ConfigMap + Deployment + Service
│   ├── test/health.test.js              │       ├── mysql.yaml       Secret + headless Svc + StatefulSet
│   ├── package.json / package-lock.json │       ├── storageclass.yaml  gp3
│   └── Dockerfile                       │       └── servicemonitor.yaml (Step 08)
├── docker-compose.yml   (local run)     ├── values/dev.yaml   ← CI updates image tags here
└── .github/workflows/ci.yml  (EMPTY →   └── argocd/three-tier-dev.yaml
     you write it in Step 06)
```

## End-to-end flow

```
 you: git push (three-tier-app)
        │
        ▼
 ┌──────── GitHub Actions ────────┐
 │ test → scan → docker build     │
 │ → push to Docker Hub (tag=SHA) │
 │ → commit new tag to gitops repo│
 └────────────────────────────────┘
        │ git commit
        ▼
   three-tier-gitops repo
        │ Argo CD polls / pulls
        ▼
 ┌──────── EKS: abhigna-cluster ──────────────┐
 │ Argo CD → helm template → apply             │
 │                                             │
 │ [LB] → frontend pods → backend pods → mysql-0 (PVC)
 └─────────────────────────────────────────────┘
        ▲
   browser (you)
```

## Where each command runs

```
💻 Laptop: terraform apply ──creates──► VPC + EKS cluster + worker nodes + Bastion EC2
💻 Laptop: ssh ─────────────────────────────────────────────► 🖥️ Bastion
🖥️ Bastion: kubectl / helm ─────────────────────────────────► EKS cluster
```

| Where | What runs there |
|---|---|
| 💻 Laptop | Terraform, git, Docker, browser (app, Argo CD UI, Grafana) |
| 🖥️ Bastion | kubectl, helm (already installed; has cluster access) |
| ☁️ GitHub runners | the CI pipeline: test, build, scan, push |
| ☸️ Inside EKS | Argo CD, your app pods, Prometheus/Grafana |

> The bastion is created **by** Terraform, so Terraform always runs from the laptop.

## Before you start (💻 laptop)

| Need | Check |
|---|---|
| Terraform ≥ 1.5 | `terraform -version` |
| AWS credentials | `aws sts get-caller-identity` |
| EC2 key pair `abhigna-eks-key` in **us-east-1** | `ls ~/.ssh/abhigna-eks-key.pem` |
| Docker + Docker Compose | `docker compose version` |
| Node.js 20+ (for `npm test`) | `node -v` |
| Accounts | GitHub + Docker Hub |

## Lab steps

Do one step at a time. Each step ends with a **✅ Check** before you move on.

| Step | What you do | You learn | Status |
|---|---|---|---|
| [01](./step-01-infra.md) | Terraform: EKS + EBS CSI driver (already in `eks.tf`), then install Argo CD | Infra first; storage for the DB | ⬜ |
| [02](./step-02-app-local.md) | Create the 2 GitHub repos; run the app locally with Docker Compose | What each tier does | ⬜ |
| [03](./step-03-docker-hub.md) | Dockerfiles; build and push to Docker Hub **by hand** | Images and tags | ⬜ |
| [04](./step-04-helm-manual.md) | Helm chart; `helm install` **by hand** | Deployment vs StatefulSet, Services | ⬜ |
| [05](./step-05-argocd.md) | Argo CD Application; let Argo CD deploy | GitOps, sync, self-heal | ⬜ |
| [06](./step-06-github-actions.md) | GitHub Actions CI: build, scan, push, update tag | Full automation | ⬜ |
| [07](./step-07-end-to-end.md) | Change code, watch it go live, then roll back | The whole flow working | ⬜ |
| [08](./step-08-monitoring.md) | (Extra) kube-prometheus-stack + Grafana | Monitoring the app | ⬜ |
| [09](./step-09-destroy.md) | Destroy everything | Cost control | ⬜ |

> Steps 03–04 are done **by hand on purpose**. Once you know the manual way, steps 05–06 show exactly what gets automated.

## Cost

EKS control plane + 2 worker nodes + bastion + NAT gateway + load balancers cost money **every hour**. Do the lab in one or two sittings and run step 09 when you stop.
