# Production-Grade EKS Project (Beginner Friendly, Step by Step)

Build a **production-style Kubernetes cluster on AWS (EKS)** and deploy a 3-tier app on it: **frontend → backend → MySQL**.
Every step explains **what** you are doing and **why**, so you can follow it even if this is your first EKS project.

## About this project

| Item | Value |
|---|---|
| Goal | Build a **production-grade** EKS cluster and app: highly available, secure, monitored, automated |
| App | frontend (nginx) → backend (Node.js API) → MySQL database |
| Cloud | AWS, region `us-east-1` (N. Virginia), spread across 3 Availability Zones |
| Kubernetes | Amazon EKS, version **1.36** |
| Infra tool | Terraform (infrastructure as code) |
| Level | Beginner → intermediate. You should know basic Linux commands and what a container is |
| Cost | About **$0.63 per hour** while the cluster is running. Destroy it when you stop (Step 12) |

## The roadmap (12 steps)

| # | Step | What you do | Topic you learn |
|---|---|---|---|
| 01 | **[Infrastructure](./step-01-infrastructure/README.md)** | Create the network, EKS cluster, worker nodes and image registry with Terraform | VPC, EKS, node groups, taints, add-ons |
| 02 | Secure images | Build images, scan them, sign them, push to ECR | Supply chain security (Trivy, Cosign) |
| 03 | RBAC + ServiceAccounts | Give people and apps only the permissions they need | RBAC, ServiceAccounts |
| 04 | Pod hardening | Run containers as non-root with minimal privileges | securityContext, Pod Security Standards |
| 05 | Pod Identity | Backend reads the DB password from AWS Secrets Manager, with no keys in code | EKS Pod Identity |
| 06 | Policy guardrails | Block images not from ECR, `:latest` tags, hard-coded keys, unsigned images | Kyverno |
| 07 | Service mesh | Encrypt traffic between services and allow only frontend → backend → db | Istio mTLS |
| 08 | High availability | App keeps running when a Pod, a node or a whole AZ fails | Probes, HPA, PDB, topology spread |
| 09 | GitOps + canary | Git push → Argo CD deploys → new version goes to 10% of users first | Argo CD, Argo Rollouts |
| 10 | Observability | Metrics, dashboards and request tracing | Prometheus, Grafana, OpenTelemetry |
| 11 | Break & fix | Break the app on purpose and fix it | CrashLoopBackOff, ImagePullBackOff, 502/503 |
| 12 | Clean up | Delete everything so you stop paying | `terraform destroy` |

> Each step has its **own folder** with a full guide: concepts, every piece of code explained, commands and checks.
> Click a step name above to open it. New steps are added one by one.

## Folder layout

```
05-production-eks/
├── README.md                    ← you are here (project overview)
├── terraform/                   ← the production infrastructure code (Terraform)
└── step-01-infrastructure/
    └── README.md                ← Step 01 guide: what, why, code explained, commands
```

## Where each command runs

You use **two machines**:

```
💻 Your laptop
   │  terraform, aws cli   → creates everything in AWS
   │
   │  ssh (with your .pem key)
   ▼
🖥️ Bastion (a small EC2 created by Terraform)
   │  kubectl, helm        → already installed for you
   ▼
☸️ EKS cluster
```

| Where | What runs there |
|---|---|
| 💻 Laptop | `terraform`, `aws`, `git`, `docker` |
| 🖥️ Bastion | `kubectl`, `helm` (it has access to the cluster) |

---

## Start here

👉 **[Step 01 — Infrastructure](./step-01-infrastructure/README.md)**

