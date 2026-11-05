# Step 06 — GitHub Actions CI: Build, Scan, Push, Update Tag

Automate Step 03 and the "edit `values/dev.yaml`" part of Step 05. After this, a `git push` is all it takes to deploy.

## About this step

| Item | Value |
|---|---|
| File | `three-tier-app/.github/workflows/ci.yml` (**empty**: you write it from the example below) |
| Trigger | push to `main` that changes `frontend/**` or `backend/**` |
| Image tag | first 7 chars of the commit SHA, e.g. `a1b2c3d` |
| Cluster access from CI | **none** (Argo CD pulls) |

## Concepts

| Job | Runs | Fails the pipeline when |
|---|---|---|
| `test` | `npm ci` + `npm test` (backend) | a unit test fails |
| `build-scan-push` | build image → **Trivy** scan → push (matrix: frontend, backend) | HIGH/CRITICAL CVE with a fix available |
| `update-gitops` | clone gitops repo → `yq` set both tags → commit → push | push to gitops repo fails |

```
push to three-tier-app (main)
   │
   ├─► test ──► build-scan-push [frontend] ──┐
   │            build-scan-push [backend]  ──┼─► update-gitops ──► commit "dev: deploy a1b2c3d"
   │                                         │                          │
   │              Docker Hub ◄── push :a1b2c3d                          ▼
   │                                                    Argo CD sees the new tag → rolling update
```

`needs:` makes the jobs wait in order: no tests → no image; no image → no deploy.

### Secrets needed (three-tier-app → Settings → Secrets and variables → Actions)

| Secret | Value |
|---|---|
| `DOCKERHUB_USERNAME` | your Docker Hub user |
| `DOCKERHUB_TOKEN` | Docker Hub access token (Step 03) |
| `GITOPS_TOKEN` | GitHub **fine-grained PAT**: repo `three-tier-gitops` only, **Contents: Read and write** |

> Why a PAT? The default `GITHUB_TOKEN` can only write to the repo the workflow runs in, not to `three-tier-gitops`.

---

## Example `ci.yml` (copy into your file yourself)

```yaml
name: CI - build, scan, push, update gitops

on:
  push:
    branches: [main]
    paths:
      - "frontend/**"
      - "backend/**"
      - ".github/workflows/ci.yml"
  workflow_dispatch:

env:
  GITOPS_REPO: Abhignadumpala/three-tier-gitops

jobs:
  test:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: backend
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
          cache-dependency-path: backend/package-lock.json
      - run: npm ci
      - run: npm test

  build-scan-push:
    needs: test
    runs-on: ubuntu-latest
    strategy:
      matrix:
        service: [frontend, backend]
    steps:
      - uses: actions/checkout@v4

      - name: Short SHA tag
        run: echo "TAG=${GITHUB_SHA::7}" >> "$GITHUB_ENV"

      - uses: docker/setup-buildx-action@v3

      - uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build (load locally for scanning)
        uses: docker/build-push-action@v6
        with:
          context: ${{ matrix.service }}
          load: true
          tags: ${{ secrets.DOCKERHUB_USERNAME }}/three-tier-${{ matrix.service }}:${{ env.TAG }}
          cache-from: type=gha,scope=${{ matrix.service }}
          cache-to: type=gha,mode=max,scope=${{ matrix.service }}

      - name: Trivy image scan
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: ${{ secrets.DOCKERHUB_USERNAME }}/three-tier-${{ matrix.service }}:${{ env.TAG }}
          severity: HIGH,CRITICAL
          ignore-unfixed: true
          exit-code: "1"

      - name: Push
        run: docker push ${{ secrets.DOCKERHUB_USERNAME }}/three-tier-${{ matrix.service }}:${{ env.TAG }}

  update-gitops:
    needs: build-scan-push
    runs-on: ubuntu-latest
    steps:
      - name: Short SHA tag
        run: echo "TAG=${GITHUB_SHA::7}" >> "$GITHUB_ENV"

      - uses: actions/checkout@v4
        with:
          repository: ${{ env.GITOPS_REPO }}
          token: ${{ secrets.GITOPS_TOKEN }}
          path: gitops

      - name: Set new image tags in values/dev.yaml
        working-directory: gitops
        run: |
          yq -i '.frontend.image.tag = strenv(TAG)' values/dev.yaml
          yq -i '.backend.image.tag  = strenv(TAG)' values/dev.yaml
          git diff

      - name: Commit and push
        working-directory: gitops
        run: |
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git commit -am "dev: deploy three-tier ${TAG}" || echo "nothing to commit"
          git push
```

### Line-by-line: the important parts

| Line | Why |
|---|---|
| `paths:` | Editing only the README doesn't build images |
| `needs: test` / `needs: build-scan-push` | Order and gates: a failure stops everything after it |
| `matrix.service` | One job definition builds both images in parallel |
| `${GITHUB_SHA::7}` | Unique, traceable tag: `a1b2c3d` = that exact commit |
| `load: true`, then scan, then `docker push` | Scan **before** push, so a vulnerable image never reaches Docker Hub |
| `cache-from/to: type=gha` | Reuses layers between runs, so builds are faster |
| `ignore-unfixed: true` | Fails only on CVEs that have a fix (no endless false alarms) |
| `yq ... strenv(TAG)` | Changes only the tag line; the rest of the file is untouched |

---

## Lab

### 6.1 Add the 3 secrets

GitHub → `three-tier-app` → Settings → Secrets and variables → Actions → **New repository secret** (see the table above).

### 6.2 Write the workflow

Open `~/three-tier-app/.github/workflows/ci.yml` (empty) and type or paste the example above.

```bash
# 💻 LAPTOP
cd ~/three-tier-app
```
```bash
git add .github/workflows/ci.yml && git commit -m "CI: build, scan, push, update gitops" && git push
```

### 6.3 Watch the run

GitHub → `three-tier-app` → **Actions**. Expected: `test` ✅ → `build-scan-push (frontend)` ✅ + `(backend)` ✅ → `update-gitops` ✅

Then check:
- Docker Hub: new tag `a1b2c3d` on both images
- `three-tier-gitops` commits: `dev: deploy three-tier a1b2c3d`
- Argo CD: syncs within ~3 min, and the pods roll to the new tag

```bash
# 🖥️ BASTION
kubectl get deploy -n three-tier -o wide
```

The `IMAGES` column shows `:a1b2c3d`.

---

## ✅ Check before Step 07

| Check | Expected |
|---|---|
| Actions run | all 4 jobs green |
| Docker Hub | SHA tag present |
| gitops repo | bot commit with the new tag |
| Cluster | pods running the SHA tag |

## Troubleshooting

| Symptom | Fix |
|---|---|
| Trivy fails on HIGH/CRITICAL | Read the CVE list in the log. Usually fixed by a newer base image (`node:20-alpine` → pull latest, or bump the `nginx` tag) |
| `update-gitops`: *403 / Permission denied* | `GITOPS_TOKEN` needs **Contents: Read and write** on `three-tier-gitops` |
| `denied: requested access to the resource is denied` on push | Docker Hub token must be Read & Write; check the username secret |
| Workflow didn't start | The change wasn't under `frontend/` or `backend/`. Use **Run workflow** (workflow_dispatch) |

## Interview one-liners

- **Walk me through your pipeline.** → On push: unit tests, build, Trivy scan, push to Docker Hub tagged with the commit SHA, then CI commits the new tag to the GitOps repo and Argo CD rolls it out to EKS.
- **Why scan before push?** → So vulnerable images never reach the registry the cluster pulls from.
- **Why does CI have no kubeconfig?** → Pull-based GitOps: fewer secrets in CI and a smaller blast radius.
