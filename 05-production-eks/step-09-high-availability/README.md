# Step 09 — High Availability: Probes, Spreading, PDB, HPA and Karpenter

[⬅ Back to the project overview](../README.md) · [⬅ Step 08](../step-08-istio-mtls/README.md) · [Step 10 ➡](../step-10-gitops-canary/README.md)

## What you will build in this step

An app that **keeps running** when a Pod crashes, a node is drained or traffic jumps, and a cluster that **adds and removes nodes by itself** (Spot first, to save money).

```
            more traffic                         Pods don't fit                  load gone
users ───────────────────► HPA: 2 → 6 Pods ───────────────────► Karpenter: +1 Spot node ───► Karpenter removes it
                            (metrics-server: CPU %)              (in ~1 minute)                 (consolidation)

 node drained for an upgrade ──► PDB: max 1 Pod of each app down at a time ──► app never fully down
 Pods spread over AZs/nodes   ──► one AZ or node fails ──► the other copies keep serving
```

| Item | Value |
|---|---|
| Needs | Steps 03–08 |
| Runs on | 💻 Laptop (Terraform) + 🖥️ Bastion |
| New AWS resources | Karpenter IAM roles, SQS queue, EventBridge rules (cents); Spot nodes while testing |
| Time | ~60 min |

---

# Part 1 — Understand (read first)

## 1.1 Concepts

### The 5 tools of high availability

| Tool | Protects against | Already in the chart? |
|---|---|---|
| **Replicas ≥ 2** | One Pod crashing | ✅ since Step 03 |
| **Probes** (readiness, liveness) | Sending traffic to a broken Pod; a stuck process | ✅ since Step 03 |
| **Topology spread** | All copies on one node or in one AZ | ✅ since Step 03 |
| **PodDisruptionBudget (PDB)** | Maintenance (drain, upgrade) taking all copies down at once | ✅ since Step 03 |
| **HPA** | Too few Pods for the traffic | ➕ turned on in this step |
| **Karpenter** | Too few **nodes** for the Pods | ➕ installed in this step |

### Probes (recap)

| Probe | Question | If it fails |
|---|---|---|
| **readiness** | "Can you serve traffic **now**?" (backend: is MySQL reachable?) | Removed from the Service: no traffic, **no restart** |
| **liveness** | "Are you **alive**?" (backend: does `/api/health` answer?) | Container **restarted** |
| **startup** | "Have you finished starting?" (slow apps) | Liveness waits until it passes |

> Liveness must **not** check the database: if MySQL is down, restarting the backend won't fix it and only causes a restart storm.

### Topology spread

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone   # spread across AZs
    whenUnsatisfiable: ScheduleAnyway
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname        # and across nodes
    whenUnsatisfiable: ScheduleAnyway
```

| Field | Meaning |
|---|---|
| `topologyKey` | The "buckets": zones, or nodes |
| `maxSkew: 1` | Bucket counts may differ by at most 1 (2-1 is ok, 3-1 is not) |
| `ScheduleAnyway` | Prefer spreading, but still run the Pod if impossible. (`DoNotSchedule` = hard rule; Pods stay Pending) |

### PodDisruptionBudget

**Definition:** a promise for **voluntary** disruptions (node drain, upgrade, Karpenter consolidation): *"never take down more than 1 frontend Pod at a time"*.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: frontend
```

It does **not** protect against crashes or a dead node (involuntary): replicas and spreading do that.

### HPA (Horizontal Pod Autoscaler)

Adds or removes **Pods** based on usage.

```
desired = current Pods × (current CPU % ÷ target CPU %)
          2 × (120% ÷ 60%) = 4 Pods
```

| Setting | Our value |
|---|---|
| target | 60% of the CPU **request** (why requests are mandatory, Step 07) |
| min / max | 2 / 10 |
| scale-down wait | 120 s (no flapping up and down) |

HPA needs **metrics-server** (reads CPU/memory from every kubelet).

### Karpenter

Adds or removes **nodes**. It watches for Pods that are **Pending** because nothing fits, and launches the **cheapest EC2 instance** that fits them, often in under a minute.

| | Cluster Autoscaler (older) | **Karpenter** ✅ |
|---|---|---|
| Works with | Fixed node groups (one instance type each) | Any instance type, chosen per need |
| Speed | Minutes | ~1 minute |
| Spot | Separate node groups | Mix Spot + On-Demand in one NodePool |
| Removing nodes | Only empty nodes | **Consolidation**: also moves Pods to pack nodes better |

| Object | Meaning |
|---|---|
| **EC2NodeClass** | *How* to build a node: AMI, subnets, security group, IAM role, IMDS settings |
| **NodePool** | *Which* nodes: Spot/On-Demand, instance families and sizes, labels, taints, limits, when to remove |
| **NodeClaim** | One node Karpenter created (like a receipt) |

**Spot instances:** spare AWS capacity, **up to ~70–90% cheaper**, but AWS can take them back with a **2-minute warning**. Karpenter receives that warning through **SQS** (Terraform creates the queue and EventBridge rules) and drains the node in time.

### Who scales what

```
HPA        → more Pods      (needs metrics-server)
Karpenter  → more nodes     (when Pods are Pending)
Managed node groups (Step 01) → the fixed base: 2 system + 2 app nodes
```

## 1.2 The code, file by file

### `terraform/karpenter.tf`

```hcl
module "karpenter" {
  count   = var.enable_karpenter ? 1 : 0
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.31"

  cluster_name = module.eks.cluster_name

  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  queue_name                    = "Karpenter-${var.cluster_name}"
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  iam_policy_statements = [{
    sid       = "KarpenterV115Extras"
    actions   = ["ec2:DescribeCapacityReservations", "ec2:DescribeInstanceStatus",
                 "ec2:DescribePlacementGroups", "iam:ListInstanceProfiles"]
    resources = ["*"]
  }]
}
```

| Line | Explained |
|---|---|
| `//modules/karpenter` | A sub-module of the same EKS module we use in Step 01 |
| `enable_v1_permissions = true` | Permissions for Karpenter **v1.x** (we install 1.15.3) |
| `enable_pod_identity` + `create_pod_identity_association` | The controller gets its role via Pod Identity (`kube-system/karpenter`) |
| `queue_name` | The SQS queue for Spot interruption warnings. Fixed name, so `values/karpenter.yaml` can use it |
| `node_iam_role_name` | The role **new nodes** get. Fixed name, used in the EC2NodeClass. The module also creates an EKS **access entry** so these nodes can join |
| `AmazonSSMManagedInstanceCore` | Same as our managed nodes: SSM instead of SSH |
| `iam_policy_statements` | 4 read permissions Karpenter 1.15 uses that this module version doesn't include yet |

### `platform/values/karpenter.yaml`

```yaml
settings:
  clusterName: abhigna-prod
  interruptionQueue: Karpenter-abhigna-prod
serviceAccount:
  name: karpenter
replicas: 2
controller:
  env:
    - name: AWS_REGION
      value: us-east-1
  resources:
    requests: { cpu: 200m, memory: 256Mi }
    limits:   { memory: 1Gi }
```

| Line | Explained |
|---|---|
| `interruptionQueue` | Where Spot warnings arrive |
| `AWS_REGION` | Pods can't ask IMDS (hop limit 1), so we tell Karpenter the region |
| `replicas: 2` | One active leader + one standby |
| Where does it run? | No toleration → automatically on the **system** nodes. It must never run on nodes it manages itself |

### `platform/karpenter/nodepool.yaml`

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: app
spec:
  role: abhigna-prod-karpenter-node
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        kubernetes.io/role/internal-elb: "1"
        kubernetes.io/cluster/abhigna-prod: shared
  securityGroupSelectorTerms:
    - tags:
        Name: abhigna-prod-node
  metadataOptions:
    httpEndpoint: enabled
    httpTokens: required
    httpPutResponseHopLimit: 1
---
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: app
spec:
  template:
    metadata:
      labels:
        role: app
    spec:
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: app }
      taints:
        - { key: workload, value: app, effect: NoSchedule }
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot", "on-demand"] }
        - { key: kubernetes.io/arch, operator: In, values: ["amd64"] }
        - { key: karpenter.k8s.aws/instance-category, operator: In, values: ["c", "m", "r"] }
        - { key: karpenter.k8s.aws/instance-size, operator: In, values: ["large", "xlarge"] }
      expireAfter: 720h
  limits:
    cpu: "16"
    memory: 64Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
```

| Line | Explained |
|---|---|
| `role` | IAM role from Terraform |
| `alias: al2023@latest` | Latest EKS-optimized Amazon Linux 2023 image. *Production: pin a version (`al2023@v2026...`) and update on purpose* |
| `subnetSelectorTerms` | Private subnets, found by the **tags from Step 01** |
| `securityGroupSelectorTerms` | The same security group as our managed nodes (the EKS module tags it `Name = abhigna-prod-node`) |
| `metadataOptions` | IMDSv2 + hop limit 1, same protection as Step 01 |
| `labels: role: app` + `taints` | Identical to the app node group, so app Pods fit and nothing else lands there |
| `capacity-type: spot, on-demand` | Karpenter prefers Spot (cheaper) and falls back to On-Demand |
| `instance-category c, m, r` / `size large, xlarge` | Compute, general, memory families; 2–4 vCPU. More choice = better Spot availability |
| `expireAfter: 720h` | Replace every node after 30 days (fresh, patched AMI) |
| `limits` | **Cost guard**: never more than 16 vCPU / 64 GiB in total from this pool |
| `consolidationPolicy` + `consolidateAfter: 1m` | Remove empty or underused nodes after 1 minute |

### `helm/three-tier/templates/ha.yaml` (HPA part, turned on with `autoscaling.enabled=true`)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: backend
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: backend }
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target: { type: Utilization, averageUtilization: 60 }
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 120
```

When HPA is on, the chart **stops setting `replicas`** in the Deployments, so Helm/Argo CD and HPA don't fight over the number.

### `platform/k8s/loadtest.yaml` and `platform/karpenter/inflate.yaml`

| File | Does |
|---|---|
| `loadtest.yaml` | 4 busybox Pods calling `/api/tasks` in a loop → backend CPU goes up → HPA |
| `inflate.yaml` | "Empty" Pods that each reserve 1 CPU on app nodes. Scale it up → Pods don't fit → Karpenter |

---

# Part 2 — 🛠️ Hands-On Lab: Let's Start

```
Task 1  Look at spreading and PDBs               🖥️
Task 2  Karpenter's AWS parts                    💻 terraform apply
Task 3  metrics-server + HPA                     🖥️
Task 4  Load test: watch HPA add Pods            🖥️
Task 5  Install Karpenter + NodePool             🖥️
Task 6  Watch Karpenter add and remove a node    🖥️
Task 7  Drain a node: the app stays up           🖥️
```

---

## Task 1 — Look at spreading and PDBs

📍 **Where:** 🖥️ Bastion

▶️ **Do:** which node and AZ is each Pod on?

```bash
kubectl get nodes -L role,topology.kubernetes.io/zone
```

```bash
kubectl get pods -n three-tier -o wide
```

```bash
kubectl get pdb -n three-tier
```

✅ **Check:** the 2 frontend Pods are on **different** app nodes (so different AZs); same for backend. PDBs show `MAX UNAVAILABLE 1`, `ALLOWED DISRUPTIONS 1`.

---

## Task 2 — Karpenter's AWS parts

📍 **Where:** 💻 Terminal (laptop)

▶️ **Do:** Spot needs an AWS service role, created once per account (an error saying it already exists is fine):

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

In `terraform/terraform.tfvars`:

```hcl
enable_karpenter        = true  # Step 09
```

```bash
cd ~/k8s-eks-projects/05-production-eks/terraform && terraform init && terraform apply
```

> `init` downloads the Karpenter sub-module (once).

✅ **Check:** `Plan: 20 to add` (2 IAM roles, policy, attachments, access entry, Pod Identity association, SQS queue + policy, 4 EventBridge rules + 4 targets). Type `yes`.

```bash
terraform output karpenter_queue_name && terraform output karpenter_node_role_name
```

> ✅ `"Karpenter-abhigna-prod"` and `"abhigna-prod-karpenter-node"`.

---

## Task 3 — metrics-server + HPA

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
cd ~/k8s-eks-projects && git pull
```

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server && helm repo update
```

```bash
helm install metrics-server metrics-server/metrics-server --version 3.14.0 -n kube-system --wait
```

```bash
kubectl top nodes
```

> ✅ CPU and memory per node (wait 1 minute if it says `metrics not available yet`).

Turn on HPA in the chart:

```bash
cd ~/k8s-eks-projects/05-production-eks && helm upgrade three-tier ./helm/three-tier -n three-tier --reuse-values --set autoscaling.enabled=true
```

✅ **Check:**

```bash
kubectl get hpa -n three-tier
```

> ✅ `frontend` and `backend`, `TARGETS cpu: 2%/60%` (some low number), `MINPODS 2`, `MAXPODS 10`.

---

## Task 4 — Load test: watch HPA add Pods

📍 **Where:** 🖥️ Bastion (open a **second** ssh window to watch)

▶️ **Do (window 2):**

```bash
kubectl get hpa -n three-tier -w
```

▶️ **Do (window 1):**

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/k8s/loadtest.yaml
```

✅ **Check:** within 1–3 minutes backend CPU goes above 60% and `REPLICAS` goes up (2 → 4 → 6...).

```bash
kubectl get pods -n three-tier -l app=backend -o wide
```

Stop the load:

```bash
kubectl delete -f ~/k8s-eks-projects/05-production-eks/platform/k8s/loadtest.yaml
```

> ✅ About 2 minutes later (the scale-down wait), replicas go back to 2. Write down the highest number you saw: that's a real result for your resume.

---

## Task 5 — Install Karpenter + NodePool

📍 **Where:** 🖥️ Bastion

▶️ **Do:**

```bash
helm install karpenter oci://public.ecr.aws/karpenter/karpenter --version 1.15.3 -n kube-system -f ~/k8s-eks-projects/05-production-eks/platform/values/karpenter.yaml --wait
```

> `Error: ... 403 Forbidden` from public.ecr.aws? Run `helm registry logout public.ecr.aws` and retry.

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/karpenter/nodepool.yaml
```

✅ **Check:**

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
```

> ✅ 2 Pods `Running` on system nodes.

```bash
kubectl get ec2nodeclass,nodepool
```

> ✅ `ec2nodeclass/app READY True` (Karpenter found the AMI, subnets and security group) and `nodepool/app READY True`.

---

## Task 6 — Watch Karpenter add and remove a node

📍 **Where:** 🖥️ Bastion (2 windows)

▶️ **Do (window 2):**

```bash
kubectl get nodes -L role,karpenter.sh/capacity-type,node.kubernetes.io/instance-type -w
```

▶️ **Do (window 1):** ask for 4 CPUs more than the app nodes have:

```bash
kubectl create namespace loadtest --dry-run=client -o yaml | kubectl apply -f -
```

```bash
kubectl apply -f ~/k8s-eks-projects/05-production-eks/platform/karpenter/inflate.yaml && kubectl scale deploy inflate -n loadtest --replicas=4
```

```bash
kubectl get pods -n loadtest -o wide
```

> Some `inflate` Pods are `Pending`.

```bash
kubectl get nodeclaims
```

✅ **Check:** within ~1 minute a **NodeClaim** appears, then a new node with `role=app`, `CAPACITY-TYPE spot`, and the Pending Pods move to `Running` on it.

See Karpenter's decision:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=30 | grep -E "launched|registered|computed new nodeclaim"
```

Now remove the demand:

```bash
kubectl scale deploy inflate -n loadtest --replicas=0
```

> ✅ After ~1 minute (`consolidateAfter: 1m`), Karpenter **deletes** the empty node: `kubectl get nodeclaims` shows nothing.

---

## Task 7 — Drain a node: the app stays up

📍 **Where:** 🖥️ Bastion (2 windows)

**Why:** this is exactly what happens during an EKS upgrade.

▶️ **Do (window 2):** call the app every second:

```bash
URL=http://$(kubectl get ingress frontend -n three-tier -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')/api/health; while true; do date +%T; curl -s -m 2 -o /dev/null -w "%{http_code}\n" $URL; sleep 1; done
```

▶️ **Do (window 1):** pick the app node that does **not** run MySQL (MySQL has only 1 copy, see the note below):

```bash
MYSQL_NODE=$(kubectl get pod mysql-0 -n three-tier -o jsonpath='{.spec.nodeName}') && echo "mysql runs on $MYSQL_NODE"
```

```bash
NODE=$(kubectl get nodes -l role=app,eks.amazonaws.com/nodegroup -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v "$MYSQL_NODE" | head -1) && echo "draining $NODE"
```

```bash
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data
```

✅ **Check:** window 2 keeps printing **`200`**. The PDB lets only 1 Pod of each app leave at a time, and the other copy keeps serving. Karpenter may even start a Spot node for the evicted Pods.

> **Why not drain the MySQL node?** One database Pod = no HA: the app would show 503 for 1–2 minutes while `mysql-0` moves (its EBS disk can only follow it to a node in the **same AZ**; Karpenter would create one). That's why production databases use **Amazon RDS Multi-AZ**.

Bring the node back:

```bash
kubectl uncordon $NODE
```

Stop window 2 with `Ctrl+C`. Clean up:

```bash
kubectl delete namespace loadtest
```

🎉 **Step 09 is done.**

---

## Common problems

| Symptom | Why | Fix |
|---|---|---|
| HPA `TARGETS <unknown>/60%` | metrics-server not ready, or no CPU requests | Wait 1–2 min; `kubectl top pods -n three-tier` |
| EC2NodeClass `READY False` | Subnet/SG/role not found | `kubectl describe ec2nodeclass app` → Conditions |
| NodeClaim stays `Unknown`, log `AuthFailureServiceLinkedRoleCreationNotPermitted` | Spot service role missing | Task 2, first command |
| Log `UnauthorizedOperation` / `AccessDenied` | Pod Identity for Karpenter missing | Laptop: `aws eks list-pod-identity-associations --cluster-name abhigna-prod --region us-east-1` must show `kube-system / karpenter`, then `kubectl rollout restart deploy/karpenter -n kube-system` |
| New node `NotReady` / never joins | Node role access entry missing | `terraform apply` again; `aws eks list-access-entries --cluster-name abhigna-prod --region us-east-1` must include the karpenter-node role |
| `kubectl drain` waits forever | PDB blocks it (another Pod of that app isn't Ready) | Check `kubectl get pdb -n three-tier`; fix the unhealthy Pod first |
| Karpenter node doesn't go away | Some Pod without a PDB-safe home, or `inflate` still running | `kubectl get pods -A -o wide \| grep <node>` |

## Interview Questions

### Other Questions

**Q1. Readiness vs liveness probe?**
Readiness decides if a Pod gets traffic (no restart); liveness decides if the container is restarted. Don't check dependencies in liveness.

**Q2. What is a PodDisruptionBudget?**
A limit on voluntary disruptions: how many Pods of an app may be down at once during drains and upgrades. It doesn't protect against crashes.

**Q3. How does HPA calculate replicas?**
`desired = current × currentMetric / targetMetric`, based on resource requests, with stabilization windows to avoid flapping.

**Q4. Karpenter vs Cluster Autoscaler?**
Cluster Autoscaler resizes fixed node groups. Karpenter launches right-sized instances directly from Pending Pods' needs, mixes Spot and On-Demand, and consolidates underused nodes.

**Q5. How do you handle Spot interruptions?**
Karpenter receives the 2-minute interruption notice via SQS/EventBridge, cordons and drains the node, and launches a replacement. Apps need replicas, PDBs and graceful shutdown.

**Q6. How do you make an app survive an AZ failure?**
At least 2 replicas spread across AZs with topology spread constraints, a load balancer across AZs, and a Multi-AZ database (RDS).
