# How-to: CI/CD for The Store

Step-by-step guide to reproduce the CI/CD pipeline (GitHub Actions + GHCR + Helm + Kind) from scratch and to use it.

```
PR ──► CI (lint + tests + image build, x5 in parallel) ──► merge allowed only if green
merge to main ──► CD: build + push images :<sha> to GHCR
                      └─► self-hosted runner: pull, kind load, helm upgrade --atomic, smoke test
```

| Piece | Where |
|-------|-------|
| CI workflow | `.github/workflows/ci.yml` |
| CD workflow | `.github/workflows/cd.yml` |
| Helm chart (5 services) | `chart/` |
| Images | `ghcr.io/<owner>/the-store-<service>:<commit sha>` |
| Cluster | Kind cluster `the-store`, namespace `the-store`, release `the-store` |

Services: `catalog` (Go), `cart` (Java; deployed in the cluster as `carts`), `orders` (Java), `ui` (Java), `checkout` (Node.js).

## 1. Prerequisites

A Linux machine that will host both the Kind cluster and the self-hosted runner, with:

- Docker (running; your user can run `docker ps`)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) (tested with v0.27.0)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) (tested with v1.32)
- [helm](https://helm.sh/docs/intro/install/) v3 (tested with v3.17)
- [GitHub CLI `gh`](https://cli.github.com/) (only for the demo commands)
- Host ports **80** and **443** free
- Several GB of free disk (cluster ~1.5 GB plus image build cache)

A GitHub repository with the contents of this project (fork or push it to your own account).

## 2. Create the Kind cluster (once)

The cluster must be named `the-store`; `cd.yml` looks for it by that name. Do **not** use `./local.sh create-cluster` (it deploys the old static manifest).

```bash
cat <<'EOF' | kind create cluster --name the-store --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - {containerPort: 80, hostPort: 80, protocol: TCP}
  - {containerPort: 443, hostPort: 443, protocol: TCP}
EOF

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.1/deploy/static/provider/kind/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=300s
```

Check: `kind get clusters` lists `the-store`, and `kubectl --context kind-the-store get nodes` shows the node `Ready`.

## 3. Self-hosted runner

A GitHub-hosted runner is ephemeral and cannot reach a Kind cluster that only listens on the local machine (`127.0.0.1:<port>`). The CD `deploy` job therefore runs on a runner installed on the same machine as the cluster. The runner only makes outbound HTTPS/443 connections to GitHub; no inbound ports are exposed.

1. In the repo: **Settings → Actions → Runners → New self-hosted runner → Linux x64**.
2. Run the download and `./config.sh --url <repo-url> --token <TOKEN>` commands shown there. Keep the default labels (the workflow uses `runs-on: [self-hosted, linux]`).
3. Create/extend the runner folder's `.env` so the runner finds the tools (adjust to where you installed them):

   ```
   PATH=/home/<user>/.local/bin:/usr/local/bin:/usr/bin:/bin
   ```

4. Start it, either in a terminal or as a service:

   ```bash
   ./run.sh                                   # foreground
   # or
   sudo ./svc.sh install && sudo ./svc.sh start
   ```

5. Verify as the user that runs the runner:

   ```bash
   docker ps
   kind get clusters
   kubectl --context kind-the-store get nodes
   helm version
   ```

## 4. Registry (GHCR) and secrets

No secrets need to be created. Both workflows authenticate to GHCR with the automatic `GITHUB_TOKEN`:

- `publish` job: `docker/login-action` with `packages: write`.
- `deploy` job: `docker login ghcr.io` on the runner with `packages: read`, then `docker pull`.

The first CD run creates the five packages (`the-store-catalog`, `-cart`, `-orders`, `-checkout`, `-ui`), private and linked to the repo. If the deploy job's `docker pull` fails with "denied", open each package's settings and connect it to the repository (or give the repo Read access).

The only `.env` file in the setup is the runner's `PATH` file from step 3; it is not committed.

## 5. Branch protection

CI check names only appear after the workflow has run once, so open a first PR (any small change) before this step.

**Settings → Rules → Rulesets** (or **Branches → Branch protection**) for `main`:

- Require a pull request before merging
- Require status checks to pass: `catalog`, `cart`, `orders`, `ui`, `checkout`

From now on a failing job blocks the merge.

## 6. How the pipeline works

### CI (`ci.yml`), on every pull request to `main`

One matrix job per service, run in parallel (`fail-fast: false`, so every failure is reported). A new push to the PR cancels the previous run.

| Service | Stack | Lint | Tests |
|---------|-------|------|-------|
| catalog | Go | `gofmt` + `go vet` | `go test ./...` |
| cart, orders, ui | Java 21 | `checkstyle:check` | `./mvnw test` |
| checkout | Node 24 | `eslint` | `yarn test:integration` (jest + Testcontainers) |

Every job finishes with a `docker build` of the service image (not pushed, GHA layer cache).

Note: `JAVA_TOOL_OPTIONS=-Dapi.version=1.44` is set for the Java tests because Testcontainers 1.21 otherwise defaults to a Docker API version that Docker 29 on the runner rejects. The cart tests also need dummy AWS credentials for the DynamoDB Local test.

### CD (`cd.yml`), on every push to `main` that touches `src/`, `chart/` or `cd.yml` (or manually)

1. **publish** (GitHub-hosted, matrix x5): build each image and push it to GHCR tagged with the commit SHA.
2. **deploy** (self-hosted runner):
   1. check that the Kind cluster `the-store` exists;
   2. log in to GHCR, `docker pull` the five `:<sha>` images and `kind load docker-image` them into the cluster;
   3. `helm upgrade --install the-store ./chart --set image.registry=ghcr.io/<owner>/ --set image.tag=$GITHUB_SHA --atomic --timeout 5m`;
   4. print `helm history`;
   5. smoke test: `curl -fsS http://localhost/health/<svc>` for the five services (with retries).

`--atomic` makes Helm wait until the new pods are Ready and roll back automatically if they do not become Ready within the timeout.

### Helm chart (`chart/`)

One `deployment.yaml` / `service.yaml` template is rendered for each entry in `services:` in `values.yaml`. Per service you can set `replicas`, `resources`, `config` (environment variables), `healthPath` and the probe delay. Global values: `image.registry`, `image.prefix`, `image.tag`, `rollingUpdate`.

`rollingUpdate.maxUnavailable` must stay `0`: with a single replica and `maxUnavailable: 1`, Helm would consider the release ready immediately and never detect a broken rollout.

Health routes: the ingress exposes `/health/<svc>` and rewrites it to the real endpoint of each service (`/health` for catalog and checkout, `/actuator/health/readiness` for carts, orders and ui). `ui` is also served at `/`.

Useful local commands:

```bash
helm lint ./chart
helm template the-store ./chart | less
helm list -n the-store
helm history the-store -n the-store
```

## 7. Using it: the three demo flows

### Use case 1: a PR triggers CI and a failure blocks the merge

```bash
git switch -c demo/ci
echo 'var demoVersion = "v2"' >> src/catalog/main.go     # badly formatted on purpose
git commit -am "demo: break gofmt"
git push -u origin demo/ci
gh pr create --base main --fill
gh pr checks --watch            # catalog fails, the merge button is blocked
```

Fix and push again:

```bash
gofmt -w src/catalog/main.go
git commit -am "fix: gofmt" && git push
gh pr checks --watch            # 5/5 green
gh pr merge --merge --delete-branch
```

### Use case 2: merge to `main` deploys a new release

```bash
gh run watch                    # CD: publish x5, then "Deploy to Kind" on the runner
git switch main && git pull
git rev-parse HEAD              # commit SHA = image tag
helm history the-store -n the-store --max 3
kubectl get deploy -n the-store -o wide      # IMAGES column ends in the SHA
for s in catalog carts orders checkout ui; do curl -fsS localhost/health/$s; echo; done
```

The store itself is at <http://localhost>.

### Use case 3: broken deploy and rollback

Manual rollback:

```bash
helm upgrade the-store ./chart -n the-store --reuse-values --set image.tag=does-not-exist
kubectl get pods -n the-store -w    # new pods: ErrImagePull / ImagePullBackOff; old pods keep serving
curl localhost/health/ui            # still 200

helm history the-store -n the-store --max 3
helm rollback the-store -n the-store --wait   # back to the previous good revision
kubectl get pods -n the-store
```

Automatic rollback (same upgrade with `--atomic`; this is what CD does):

```bash
helm upgrade the-store ./chart -n the-store --reuse-values \
  --set image.tag=does-not-exist --atomic --timeout 60s
# fails after ~60 s and Helm rolls back by itself
helm history the-store -n the-store --max 4
```

## 8. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| Deploy job stays "Waiting for a runner" | The runner is not running. Start `./run.sh` (or the service) on the cluster machine. |
| `kind: command not found` / `helm: command not found` in the deploy job | The runner's `.env` lacks the tools' directory in `PATH`; fix it and restart the runner. |
| `docker pull ... denied` | Package not linked to the repo; see step 4. |
| `Kind cluster 'the-store' not found` | The cluster has another name or was deleted; recreate it (step 2). |
| Smoke test fails right after a deploy | `carts` can return 503 for a few seconds; the `curl` retries (10 x 3 s). If it persists, check `kubectl get pods -n the-store` and `kubectl describe pod`. |
| Port 80/443 already in use when creating the cluster | Stop whatever uses them (another cluster, web server). |
| Disk fills up | Build the images one at a time and prune: `docker builder prune -a -f`. |
| Testcontainers: "client version 1.32 is too old" | Keep `JAVA_TOOL_OPTIONS=-Dapi.version=1.44` in `ci.yml`. |

## 9. Tear down

```bash
kind delete cluster --name the-store
# stop the runner (Ctrl+C or: sudo ./svc.sh stop && sudo ./svc.sh uninstall)
# remove it from GitHub: Settings -> Actions -> Runners -> Remove
```

The original local-only flow (`./local.sh`, `dist/kubernetes.yaml`) is kept for reference but is no longer used by the pipeline.
