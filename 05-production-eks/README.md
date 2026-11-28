# Production-Grade EKS Project (Beginner Friendly, Step by Step)

Build a **production-style Kubernetes platform on AWS (EKS)** and run a 3-tier app on it: **frontend → backend → MySQL**.
Every step explains **what** you are doing and **why**, with every piece of code explained, so you can follow it even if this is your first EKS project.

## About this project

| Item | Value |
|---|---|
| Goal | Build a **production-grade** EKS platform and app: secure, highly available, autoscaled, monitored, deployed with GitOps |
| App | frontend (nginx) → backend (Node.js API) → MySQL database |
| Cloud | AWS, region `eu-north-1` (Stockholm), spread across 3 Availability Zones |
| Kubernetes | Amazon EKS, version **1.36** |
| Tools | Terraform, Helm, Trivy, Cosign, Kyverno, Istio (ambient), External Secrets, Karpenter, Argo CD, Argo Rollouts, GitHub Actions, Prometheus, Grafana |
| Level | Beginner → intermediate. You should know basic Linux commands and what a container is |
| Cost | About **$0.63 per hour** while the cluster runs (+ a little for the ALB and Spot tests). **Destroy it every time you stop** |

## The roadmap (13 steps)

| # | Step | What you do | Topic you learn |
|---|---|---|---|
| 01 | **[Infrastructure](./step-01-infrastructure/README.md)** | Network, EKS cluster, 2 node groups, bastion, ECR, all with Terraform | VPC, EKS, node groups, taints, IMDS, add-ons |
| 02 | **[Secure images](./step-02-secure-images/README.md)** · [🛠️ Troubleshooting](./step-02-secure-images/TROUBLESHOOTING.md) | Build, scan, push and sign the app images | Supply chain security: Trivy, ECR, Cosign |
| 03 | **[Deploy the app](./step-03-deploy-app/README.md)** | Install the app with Helm, a load balancer and a database disk | Helm, AWS Load Balancer Controller, ALB, EBS |
| 04 | **[RBAC + ServiceAccounts](./step-04-rbac/README.md)** | Give people and apps only the permissions they need | RBAC, access entries, ServiceAccounts |
| 05 | **[Pod hardening](./step-05-pod-hardening/README.md)** | Prove containers run non-root, read-only, with no extra powers | securityContext, Pod Security Standards |
| 06 | **[Pod Identity + secrets](./step-06-pod-identity-secrets/README.md)** | DB passwords from AWS Secrets Manager, no keys anywhere; prove least privilege with an S3-reader Pod | EKS Pod Identity (Terraform + CLI), IRSA, External Secrets |
| 07 | **[Policy guardrails](./step-07-kyverno/README.md)** | Block untrusted registries, `:latest`, missing limits, AWS keys, unsigned images; roll out a policy safely (Audit → Deny) | Kyverno (CEL policies), PolicyReports |
| 08 | **[Service mesh](./step-08-istio-mtls/README.md)** | Encrypt traffic and allow only frontend → backend → db | Istio ambient, mTLS, AuthorizationPolicy |
| 09 | **[High availability](./step-09-high-availability/README.md)** | Survive Pod/node failures, scale Pods and nodes automatically | Probes, spread, PDB, HPA, Karpenter, Spot |
| 10 | **[GitOps + canary](./step-10-gitops-canary/README.md)** | `git push` → CI builds and signs → Argo CD deploys → canary release | GitHub Actions OIDC, Argo CD, Argo Rollouts |
| 11 | **[Observability](./step-11-observability/README.md)** | Metrics, dashboards and alerts that really fire | Prometheus, Grafana, Alertmanager |
| 12 | **[Break & fix](./step-12-break-and-fix/README.md)** | Break the app 5 ways and debug it like on-call | Troubleshooting method |
| 13 | **[Clean up](./step-13-cleanup/README.md)** | Delete everything in the right order | Cost control |

> Each step has its **own folder** with a full guide: **Part 1 Understand** (concepts + every file explained) and **Part 2 🛠️ Hands-On Lab** (task by task, with a ✅ check after each).

## Folder layout

```
05-production-eks/
├── README.md                      ← you are here (project overview)
├── terraform/                     ← all AWS infrastructure (Terraform)
│   ├── *.tf (Step 01)             network, EKS, node groups, bastion, ECR
│   ├── platform_*.tf, karpenter.tf, github_oidc.tf, iam/
│   │                              ← IAM roles etc. for Steps 03–10, turned on by switches in terraform.tfvars
│   └── terraform.tfvars           ← the only Terraform file you edit
├── app/                           ← the 3-tier app source (frontend, backend, docker-compose)
├── helm/three-tier/               ← the production Helm chart for the app
├── gitops/values-prod.yaml        ← production settings Argo CD deploys (CI updates image tags here)
├── platform/
│   ├── values/                    ← Helm values for every platform tool
│   ├── policies/                  ← Kyverno policies
│   ├── karpenter/                 ← NodePool + test workload
│   ├── argocd/                    ← the Argo CD Application
│   ├── k8s/                       ← namespace, RBAC, secret store, alerts, test Pods
│   └── rebuild.sh                 ← reinstall everything after a destroy
└── step-01-... step-13-.../README.md   ← the guides
```

The CI workflow is at the repo root: `.github/workflows/prod-eks-ci.yml` (you write it in Step 10).

## Where each command runs

```
💻 Your laptop
   │  terraform, aws cli, git, docker, trivy, cosign
   │
   │  ssh (with your .pem key)
   ▼
🖥️ Bastion (EC2 created by Terraform, in a public subnet)
   │  kubectl, helm (cluster-admin through its IAM role)
   ▼
☸️ EKS cluster (private worker nodes)
```

| Where | What runs there |
|---|---|
| 💻 Laptop | `terraform`, `aws`, `git`, `docker`, `trivy`, `cosign`, VS Code |
| 🖥️ Bastion | `kubectl`, `helm`, `kubectl argo rollouts` |
| 🌐 GitHub | Actions (CI), repo secrets |

## Your cost plan

| Running | Approx. per hour |
|---|---|
| Steps 01–08 (cluster, 5 EC2, NAT) | ~$0.63 |
| + ALB (from Step 03) | +$0.025 |
| + Spot nodes during Step 09 tests | +$0.02–0.05 each, minutes only |

**Rule:** work in one sitting, then **destroy**. Leaving it on overnight costs ~$15.

## Coming back after a destroy

Your `terraform.tfvars` keeps the switches you turned on, so the next `terraform apply` recreates **all** AWS parts at once. Then:

| # | Where | Do |
|---|---|---|
| 1 | 💻 | `cd ~/k8s-eks-projects/05-production-eks/terraform && terraform apply` (~20 min) |
| 2 | 💻 | Images are gone (ECR was deleted). Finished Step 10? GitHub → **Actions → prod-eks CI → Run workflow**. Otherwise repeat [Step 02](./step-02-secure-images/README.md) Tasks 4–8 (5 min) |
| 3 | 🖥️ | ssh to the bastion, then: `git clone https://github.com/Abhignadumpala/k8s-eks-projects.git ~/k8s-eks-projects` and the 2 `~/.bashrc` lines from [Step 03 Task 2](./step-03-deploy-app/README.md#task-2--get-the-code-on-the-bastion) |
| 4 | 🖥️ | `bash ~/k8s-eks-projects/05-production-eks/platform/rebuild.sh <last step you finished>` (e.g. `9`) |
| 5 | 🖥️ | `kubectl get pods -A` → all Running. Continue with your next step |

> The database starts empty each time (new disk, and from Step 06 new random passwords). That's expected for a lab.

## Results to record for your resume

As you go, write down **your real numbers**:

| Step | Record |
|---|---|
| 01 | Resources created (`Plan: 82 to add`), time to create the cluster |
| 02 | Trivy findings before/after a base image update; image sizes |
| 07 | Which bad deployments the policies blocked |
| 09 | HPA: from 2 to **N** Pods under load; Karpenter: seconds from Pending to a Spot node running; app stayed `200` during a node drain |
| 10 | Pipeline duration; push → live in **N** minutes; canary promote/rollback |
| 11 | Alert fired after **N** minutes of the DB outage |

---

## Start here

👉 **[Step 01 — Infrastructure](./step-01-infrastructure/README.md)**
