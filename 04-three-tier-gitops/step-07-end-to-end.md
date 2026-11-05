# Step 07 — End-to-End Test: Code Change → Live → Rollback

The payoff: one code change goes all the way to production pods with no manual steps, and you roll it back with Git.

## About this step

| Item | Value |
|---|---|
| Where | 💻 Laptop (code), browser (watch), 🖥️ bastion (verify) |
| Rollback method | `git revert` in **three-tier-gitops** |

## Concepts

**Rolling update:** new pods start → become Ready → old pods are removed. No downtime.
**GitOps rollback:** the gitops repo history *is* the deploy history. Reverting a tag commit = deploying the old version.

| Rollback way | Command | Note |
|---|---|---|
| ✅ Git revert (GitOps) | `git revert <commit>` in gitops repo | Recorded in Git, survives the next sync |
| Argo CD UI → History → Rollback | click | Works only if auto-sync is off; Git still says the new tag |
| ❌ `kubectl rollout undo` | — | `selfHeal` puts the new tag right back |

---

## Lab

### 7.1 Make a visible change

In `~/three-tier-app/frontend/index.html`, change:

```html
<h1>Task List</h1>
```

to:

```html
<h1>Task List v2 🚀</h1>
```

```bash
# 💻 LAPTOP
cd ~/three-tier-app
```
```bash
git commit -am "frontend: v2 title" && git push
```

### 7.2 Follow it through the pipeline

| Where | What you see | Time |
|---|---|---|
| GitHub Actions | 4 jobs green | ~3–5 min |
| three-tier-gitops commits | `dev: deploy three-tier <sha>` | right after |
| Argo CD UI | OutOfSync → Syncing → Synced | ≤ 3 min |
| Pods | new pods start, old ones terminate | ~30 s |

```bash
# 🖥️ BASTION
kubectl get pods -n three-tier -w
```

Refresh the browser: the title shows **v2 🚀**, and the footer shows `backend version: <sha>`.

> 📝 For your resume, write down the real time from `git push` to the page changing.

### 7.3 Break something on purpose (failed pipeline)

Make a test fail. In `backend/test/health.test.js`, change `"ok"` to `"broken"`. Commit and push.

Expected: `test` ❌, and nothing after it runs. The cluster keeps running the last good version. Revert your change and push again.

### 7.4 Roll back the v2 deploy with Git

```bash
# 💻 LAPTOP
cd ~/three-tier-gitops && git pull
```
```bash
git log --oneline -5
```
```bash
git revert --no-edit <sha-of-the-v2-deploy-commit>
```
```bash
git push
```

Argo CD syncs and the pods go back to the previous tag. The browser title is `Task List` again.

> The code repo still contains v2. The next CI run deploys it again. In real life you'd also fix or revert the code.

---

## ✅ Check before Step 08

| Check | Expected |
|---|---|
| Code push → live page changed | no manual commands |
| Failing test | pipeline stopped, cluster unchanged |
| `git revert` in gitops | old version back |

## Interview one-liners

- **How do you roll back?** → `git revert` the tag commit in the GitOps repo, and Argo CD syncs the previous image. Every rollback is audited in Git.
- **How do you get zero-downtime deploys?** → Rolling update + readiness probes: old pods keep serving until new pods are Ready.
