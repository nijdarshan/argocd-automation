# ArgoCD Automation — Deployment Orchestration PoC

A proof-of-concept for automated GitOps deployment orchestration of containerised applications using ArgoCD, Helm, and Git. Built CNF (Cloud-Native Network Function) onboarding platform but designed to be vendor-agnostic and applicable to any Helm-based application stack.

---

## What This Demonstrates

This PoC proves the end-to-end deployment orchestration flow:

1. **Payload-driven deployment** — A JSON payload defines what to deploy. The orchestrator generates all ArgoCD Application YAMLs and Helm values files from this payload. No hand-crafted YAML.

2. **Helm multi-source** — Charts pulled from Nexus (Helm registry), values pulled from Git (GitOps repo). Separation of vendor artifacts from operational configuration.

3. **Per-component commits** — Each component gets its own Git commit with a standardised message format. Enables component-level rollback via `git revert`.

4. **Batched deployment with approval gates** — Components deploy in configurable batch order. Manual approval gates pause the deployment between batches.

5. **ArgoCD API-only** — All cluster interaction goes through the ArgoCD REST API. No `kubectl`, no `oc`, no CLI tools at runtime.

6. **Rollback** — Component and full-stack rollback via `git revert`. History preserved, no force push.

7. **Auto-rollback** — Detect unhealthy components via ArgoCD resource-tree API, automatically revert on failure.

8. **Canary and blue-green** — Deployment strategies via Argo Rollouts (future capability, proven in PoC).

9. **State tracking** — Every deployment recorded in a database with component results, health reports, and Git diffs.

### Architecture

```
Deployment Payload (JSON)
        │
        ▼
┌──────────────────────────┐
│    ORCHESTRATOR           │
│                           │
│  1. Clone GitOps repo     │
│  2. Generate values.yaml  │
│  3. Generate App YAMLs    │
│  4. Git commit + push     │
│  5. ArgoCD sync (API)     │
│  6. Watch health (API)    │
│  7. Record state (DB)     │
└──────┬──────────┬─────────┘
       │          │
    Git push   ArgoCD API
       │          │
       ▼          ▼
┌──────────┐  ┌──────────┐
│  GitLab  │  │  ArgoCD  │──► K8s Cluster
│ (Gitea)  │  │          │
└──────────┘  └──────────┘
                   │
              ┌────┴────┐
              │  Nexus  │  (Helm charts)
              └─────────┘
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Docker | 20.10+ | Container runtime for Kind and Nexus |
| Kind | 0.20+ | Local Kubernetes cluster |
| kubectl | 1.28+ | Kubernetes client (for initial setup only — orchestrator uses API) |
| Helm | 3.14+ | Chart packaging and pushing to Nexus |
| ArgoCD CLI | 2.10+ | Initial setup and debugging |
| Python | 3.12 | FastAPI orchestrator API |
| jq | 1.7+ | JSON parsing in shell scripts |
| Git | 2.40+ | Version control |

### Lab Infrastructure (provided by nexus-argo-lab)

This PoC depends on a local Kubernetes lab environment. Set it up first:

```bash
# Clone and run the lab setup
git clone https://github.com/nijdarshan/nexus-argo-lab.git
cd nexus-argo-lab/nexus-argo-lab
./setup.sh
```

This creates:
- **Kind cluster** — 3 nodes (1 control plane, 2 workers), K8s v1.29.0
- **ArgoCD** — GitOps deployment engine, accessible at `https://localhost:30443`
- **Nexus** — Helm chart registry, accessible at `http://localhost:8081`
- **Nginx Ingress** — Ingress controller for service routing

---

## Setup Guide

After the lab infrastructure is running, set up the additional components needed for this PoC.

### Step 1: Install Gitea (In-Cluster Git Server)

Gitea simulates GitLab in the local environment. ArgoCD watches Gitea for Git changes.

```bash
helm repo add gitea-charts https://dl.gitea.com/charts/
helm install gitea gitea-charts/gitea -n gitea --create-namespace \
  --set service.http.type=NodePort \
  --set service.http.nodePort=30030 \
  --set gitea.admin.username=gitea_admin \
  --set gitea.admin.password=gitea_admin \
  --set persistence.size=1Gi \
  --set postgresql-ha.enabled=false \
  --set postgresql.enabled=true \
  --set redis-cluster.enabled=false \
  --set redis.enabled=true \
  --set gitea.config.server.ROOT_URL=http://localhost:3000 \
  --set gitea.config.server.HTTP_PORT=3000

# Wait for Gitea to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=gitea -n gitea --timeout=180s

# Port-forward for local access (run in background)
kubectl port-forward svc/gitea-http -n gitea 3000:3000 &

# Create the GitOps repository
curl -s -X POST "http://localhost:3000/api/v1/user/repos" \
  -H "Content-Type: application/json" \
  -u "gitea_admin:gitea_admin" \
  -d '{"name": "nf-demo-gitops", "auto_init": true, "default_branch": "main"}'
```

**Access:** `http://localhost:3000` — gitea_admin / gitea_admin

### Step 2: Install Argo Rollouts

Required for canary and blue-green deployment use cases.

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
kubectl wait --for=condition=available deployment/argo-rollouts -n argo-rollouts --timeout=60s
```

### Step 3: Register Repositories in ArgoCD

ArgoCD needs credentials to access Gitea (Git) and Nexus (Helm charts).

```bash
# Git repository (Gitea)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: gitea-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: http://gitea-http.gitea.svc:3000/gitea_admin/nf-demo-gitops.git
  username: gitea_admin
  password: gitea_admin
EOF

# Helm repository (Nexus)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: nexus-helm-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: nexus-helm
  url: http://host.docker.internal:8081/repository/helm-hosted/
  username: admin
  password: admin123
EOF
```

### Step 4: Package and Push Helm Charts to Nexus

The PoC includes 7 Helm charts. Package and push all of them:

```bash
cd argocd-automation

for chart in charts/*/; do
  helm lint "$chart"
  helm package "$chart" -d /tmp/nf-packages/
done

for pkg in /tmp/nf-packages/*.tgz; do
  curl -u "admin:admin123" "http://localhost:8081/repository/helm-hosted/" \
    --upload-file "$pkg"
done
```

Verify charts are in Nexus:

```bash
curl -s -u "admin:admin123" "http://localhost:8081/repository/helm-hosted/index.yaml" \
  | grep "^  nf-"
```

### Step 5: Install Python Dependencies

```bash
cd orchestrator
python3.12 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

---

## Helm Charts

The PoC includes 7 Helm charts that form a monitoring and traffic simulation stack. Each chart demonstrates a different deployment pattern.

| Chart | Version | Image | Pattern | What It Does |
|-------|---------|-------|---------|-------------|
| **nf-config** | 1.0.0 | nginx:alpine | Standard | Nginx serving configuration JSON. Demonstrates config change via values |
| **nf-server** | 2.1.0 | python:3.12-alpine | Rollout CRD | Python HTTP server with Prometheus metrics. Reports version, chart version, image, strategy, replicas via `/health` endpoint. Uses Argo Rollouts `Rollout` instead of `Deployment` — supports rolling, canary, and blue-green strategies |
| **nf-simulator** | 1.0.0 | curlimages/curl | Standard | Traffic generator. Configurable burst size and quiet period via values |
| **nf-collector** | 1.0.0 | prom/prometheus:v2.51.0 | Standard | Prometheus scraping nf-server metrics. Configurable scrape targets and retention via values |
| **nf-store** | 1.0.0 | redis:7.2-alpine | Multi-instance | Redis deployed 3 times (cache, sessions, events) from the same chart with different values. Demonstrates Pattern C (multi-instance) |
| **nf-dashboard** | 1.0.0 | grafana/grafana:11.0.0 | Standard | Grafana with pre-configured Prometheus datasource and traffic monitor dashboard |
| **nf-gateway** | 1.9.2 | nginx:alpine | Standard | API gateway with landing page. Proxies to all services across namespaces. Landing page shows live deployment status with version, chart, image, replicas, strategy, and canary traffic split detection |

### Chart Design Principles

- **Static code in `files/`** — Python server code, Grafana dashboard JSON, and the landing page HTML are stored in the chart's `files/` directory and loaded via `.Files.Get`. This avoids Helm template parsing conflicts (e.g., Python `{}` vs Helm `{{ }}`).
- **Values drive all variable configuration** — Everything that changes between deployments (version, replicas, image tag, feature flags) is in `values.yaml`. Chart templates never hardcode environment-specific values.
- **Checksum annotation** — Pod templates include a `checksum/config` annotation that changes when values change, triggering a rolling restart even for ConfigMap-only changes.

---

## Deployment Payload

The orchestrator is driven by a JSON payload that defines the complete deployment — components, charts, versions, values, batch order, and deployment configuration.

**Location:** `payloads/nf-demo-helm.json`

### Structure Overview

```json
{
  "deployment_id": "deploy-helm-001",
  "helix_id": "HELIX-HELM-001",
  "action": "deploy",
  "environment": "dev",
  "nf": "nf-demo",
  "is_bootstrap": true,

  "defaults": {
    "gitops_repo": "...",
    "helm_registry": "...",
    "argocd_project": "default"
  },

  "deployment_order": [
    { "component": "platform", "batch": 1 },
    { "component": "simulator", "batch": 2 },
    { "component": "collector", "batch": 3 },
    { "component": "store", "batch": 3 },
    { "component": "dashboard", "batch": 4 },
    { "component": "gateway", "batch": 5 }
  ],

  "components": {
    "platform": {
      "deployment_config": {
        "manual_approval": true,
        "auto_rollback": false,
        "sync_policy": "manual",
        "strategy": "rolling"
      },
      "charts": {
        "nf-server": {
          "chart_name": "nf-server",
          "chart_version": "2.1.0",
          "type": "helm",
          "namespace": "nf-platform",
          "values_path": "platform/server",
          "values": {
            "replicaCount": 2,
            "version": "1.0.0",
            "strategy": "rolling",
            "image": { "repository": "python", "tag": "3.12-alpine" }
          }
        }
      }
    }
  }
}
```

**Key fields:**

| Field | Purpose |
|-------|---------|
| `deployment_order` | Batched sequencing — batch 1 deploys first, batch 3 components deploy in parallel |
| `deployment_config.manual_approval` | Pause after this component for operator verification |
| `deployment_config.auto_rollback` | Automatically revert if health check fails |
| `deployment_config.sync_policy` | ArgoCD sync policy: `manual` (default), `auto`, `auto_self_heal` |
| `chart_version` | Helm chart version in Nexus — becomes `targetRevision` in ArgoCD Application |
| `values` | Fully resolved values — written as YAML to the GitOps repo |
| `type: "multi_instance"` | Same chart deployed N times with different values (e.g., Redis x3) |
| `namespace` | Each component in its own namespace (IMS pattern) |

---

## Use Case Runner

The `usecase.sh` script tests every deployment operation against the live lab environment.

### Run All Use Cases

```bash
cd orchestrator
./usecase.sh all
```

This runs 17 use cases sequentially with an approval gate between each step. The operator verifies the result (ArgoCD UI, landing page, API) before pressing ENTER to continue.

### Individual Use Cases

```bash
./usecase.sh          # Show menu
./usecase.sh uc1      # Run single use case
./usecase.sh reset    # Reset to v1.0.0, 2 replicas
./usecase.sh status   # Show all pods, ArgoCD apps, access URLs
```

### Use Case Catalogue

| Category | UC | Description | What Changes in Git |
|----------|-----|-------------|-------------------|
| **Bootstrap** | UC1 | Day 0 — generate everything from payload JSON | App-of-apps + 9 Application YAMLs + 9 values files |
| **Values** | UC2 | Single component version upgrade (v1 to v2) | `values.yaml` version field |
| | UC3 | Config-only change (replicas 2 to 3) | `values.yaml` replicaCount field |
| | UC4 | Multi-component upgrade (config + server) | 2 per-component commits, same HELIX ID |
| **Chart** | UC16 | Helm chart version upgrade | `targetRevision` in Application YAML |
| | UC17 | Helm chart version rollback | Revert Application YAML commit |
| **Rollback** | UC5 | Component rollback (revert last change) | `git revert` of values.yaml commit |
| | UC7 | Auto-rollback (deploy broken image, detect, revert) | Deploy broken + auto revert commits |
| **Strategy** | UC21 | Canary deployment with manual promotion (future) | `strategy: canary` in values + version bump |
| | UC22 | Blue-green deployment (future) | `strategy: blueGreen` in values + version bump |
| **Config** | UC20 | User-editable config (simulator burst size) | `burstSize` in simulator + gateway values |
| **Stack** | UC18 | Add new component to running stack | New Application YAML + values |
| | UC19 | Remove component from stack | Delete Application YAML |
| **Validation** | UC14 | Dry run — show diff without committing | No Git changes |
| | UC15 | Status — show state + git history | No changes |

### What to Verify at Each Step

| Check | URL | What to Look For |
|-------|-----|-----------------|
| ArgoCD UI | `https://localhost:30443` | All apps green (Synced/Healthy) |
| Landing page | `http://localhost:8084` | Version, chart, image, strategy, replicas, canary traffic split |
| API status | `http://localhost:9000/api/status` | All components Healthy with pod counts |
| API deployments | `http://localhost:9000/api/deployments` | Deployment records with status |
| NF Server health | `http://localhost:8000/health` | Version, chart_version, strategy, replicas |

---

## FastAPI Orchestrator

The `orchestrator/api/` directory contains a Python FastAPI application that wraps the deployment operations as a REST API. This is a reference implementation — the production team may rewrite it in any language.

### Start the API

```bash
cd orchestrator
source .venv/bin/activate
uvicorn api.app:app --port 9000
```

### Endpoints

**OpenAPI docs:** `http://localhost:9000/docs` — interactive Swagger UI with try-it-out for every endpoint.

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/deploy/component` | Deploy a component to a new version |
| `POST` | `/api/deploy/config` | Config-only change (replicas, settings) |
| `POST` | `/api/rollback/component` | Rollback a component |
| `POST` | `/api/dry-run` | Preview diff without deploying |
| `POST` | `/api/approve` | Approve a paused deployment |
| `GET` | `/api/status` | Full stack health (from ArgoCD) |
| `GET` | `/api/status/{app}` | Component detail — version, replicas, pods, health |
| `GET` | `/api/deployments` | Deployment history (from DB) |
| `GET` | `/api/deployments/{id}` | Single deployment with results + diff |
| `GET` | `/api/diff` | Current uncommitted changes in Git |
| `GET` | `/api/history` | Git log as structured JSON |
| `GET` | `/api/health` | API health check |

### Example: Deploy v2.0.0

```bash
curl -X POST http://localhost:9000/api/deploy/component \
  -H "Content-Type: application/json" \
  -d '{
    "component": "platform/server",
    "version": "2.0.0",
    "helix_id": "HELIX-001"
  }'
```

Response:
```json
{
  "status": "healthy",
  "component": "platform/server",
  "version": "2.0.0",
  "commit_sha": "abc123...",
  "health": "Healthy",
  "health_report": {
    "pods_ready": "2/2",
    "services_with_endpoints": "1/1",
    "errors": []
  }
}
```

### Architecture

```
FastAPI App
├── api/
│   ├── app.py              ← Entry point, CORS, startup (DB init, ArgoCD auth, Git clone)
│   ├── config.py           ← Connection details (ArgoCD URL, Gitea, Nexus)
│   ├── routes/
│   │   ├── deploy.py       ← POST /api/deploy/*, /api/dry-run
│   │   └── status.py       ← GET /api/status/*, POST /api/rollback/*, /api/deployments/*
│   ├── services/
│   │   ├── argocd.py       ← ArgoCD REST API client (async httpx)
│   │   ├── git.py          ← Git operations (subprocess: commit, push, revert, diff)
│   │   ├── deployment.py   ← Core orchestration logic (compare, stage, sync, validate)
│   │   └── db.py           ← SQLite state storage (deployment records, component results, diffs)
│   └── models/
│       ├── common.py       ← Shared enums (HealthStatus, SyncStatus, ComponentHealth)
│       ├── deploy.py       ← Request/response schemas for deployment operations
│       └── status.py       ← Request/response schemas for status and rollback
```

### Database

SQLite for the PoC — 3 tables:

| Table | Purpose |
|-------|---------|
| `deployments` | One record per deployment operation (deploy, rollback, config change) |
| `component_results` | One record per component per deployment (status, version, SHA, health report) |
| `diffs` | Git diff snapshot per component per deployment |

For production: swap to `Hub DB` by changing the connection string. The raw SQL is standard enough to work on both.

---

## Landing Page

The gateway chart includes a landing page at `http://localhost:8084` that shows live deployment status.

### What It Shows

- **NF Server card** — version, Helm chart version, container image, deployment strategy, replicas, request count
- **Canary detection** — during canary rollout, the page hits the server 15 times (K8s Service round-robins between pods), detects multiple versions, and shows:
  - Traffic split bar with percentages per version
  - Pod chips showing each pod with its version (colour-coded)
  - Stable vs canary pod count
- **All other components** — NF Config, Grafana, Prometheus, Redis, Simulator with live status
- **Quick links** — ArgoCD, API docs, Gitea, Nexus

### How It Works

The landing page is static HTML served by the gateway nginx. It uses JavaScript `fetch()` to call nginx proxy endpoints (`/proxy/server`, `/proxy/config`, etc.) which reverse-proxy to services in other namespaces. No CORS issues because everything goes through the same nginx origin.

Cross-namespace proxy routes use full FQDNs (`service.namespace.svc.cluster.local:port`) with nginx `resolver` directive and `set $variable` pattern for runtime DNS resolution.

---

## Known Issues (Local Dev / Kind Only)

These issues are specific to the local Kind environment and do NOT apply to production OCP deployments.

| Issue | Cause | Workaround |
|-------|-------|-----------|
| ArgoCD Helm chart cache | ArgoCD repo-server caches Helm chart tarballs. New chart versions from Nexus may not be picked up | Restart ArgoCD repo-server pod: `kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server`. In production: not needed — ArgoCD handles targetRevision changes natively |
| Port-forwards dying | `kubectl port-forward` processes terminate when pods restart | Restart port-forwards. In production: use OCP Routes, no port-forward needed |
| ArgoCD session expiry | Session tokens expire after approximately 60 minutes | Script re-authenticates before each operation. In production: same pattern — fresh token per deployment sequence |
| Cross-namespace DNS | Short service names (`svc.namespace`) don't resolve in nginx when using `resolver` directive with `set $variable` | Use full FQDN: `svc.namespace.svc.cluster.local:port`. Applies to production too |
| Nexus chart immutability | Cannot overwrite a chart version in Nexus | By design — same in production. Bump version to publish updated chart |
| ArgoCD finalizers blocking deletion | Deleting ArgoCD apps hangs due to cleanup finalizers | Remove finalizers first: `kubectl patch application {name} -n argocd -p '{"metadata":{"finalizers":null}}' --type merge`. In production: never delete the app-of-apps |

---

## File Structure

```
argocd-automation/
│
├── README.md                              ← This file
│
├── charts/                                ← Helm charts (pushed to Nexus)
│   ├── nf-config/                         ← Config server (nginx)
│   ├── nf-server/                         ← NF server (Python + Rollout CRD)
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   ├── templates/deployment.yaml
│   │   └── files/server.py               ← Static Python code (avoids Helm {{ }} conflicts)
│   ├── nf-simulator/                      ← Traffic generator (curl)
│   ├── nf-collector/                      ← Prometheus
│   ├── nf-store/                          ← Redis (multi-instance)
│   ├── nf-dashboard/                      ← Grafana
│   │   └── files/nf-monitor.json         ← Dashboard JSON
│   └── nf-gateway/                        ← API gateway + landing page
│       └── files/index.html              ← Landing page HTML
│
├── orchestrator/                          ← Deployment orchestration
│   ├── deploy.sh                          ← Shell orchestrator (Day 0 bootstrap from payload)
│   ├── usecase.sh                         ← Use case runner (17 UCs with approval gates)
│   ├── requirements.txt                   ← Python dependencies
│   ├── deployments.db                     ← SQLite state database (created at runtime)
│   └── api/                               ← FastAPI application
│       ├── app.py                         ← Entry point
│       ├── config.py                      ← Configuration
│       ├── models/                        ← Pydantic request/response schemas
│       ├── routes/                        ← HTTP endpoint handlers
│       └── services/                      ← Business logic (ArgoCD, Git, DB, Deployment)
│
├── payloads/                              ← Deployment payload definitions
│   ├── nf-demo-helm.json                 ← Full payload for Helm multi-source deployment
│   └── nf-demo-deploy.json              ← Original payload (directory mode, superseded)
│
├── docs/                                  ← Documentation
│   └── handover/
│       ├── 07a-deployment-commands-reference.md  ← Every API call for every operation
│       └── 07b-developer-requirements.md         ← What to build for production
│
└── server.yaml, prometheus.yaml, ...      ← Original raw YAML demo (pre-Helm, for reference only)
```

---

## Access URLs (After Setup)

| Service | URL | Credentials |
|---------|-----|-------------|
| ArgoCD UI | `https://localhost:30443` | admin / `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Nexus | `http://localhost:8081` | admin / admin123 |
| Gitea | `http://localhost:3000` | gitea_admin / gitea_admin (needs `kubectl port-forward svc/gitea-http -n gitea 3000:3000 &`) |
| FastAPI docs | `http://localhost:9000/docs` | None (start with `uvicorn api.app:app --port 9000`) |
| Landing page | `http://localhost:8084` | None (needs `kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &`) |
| NF Server | `http://localhost:8000/health` | None (needs `kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &`) |
| Grafana | `http://localhost:3001` | admin / admin123 (needs `kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &`) |
| Prometheus | `http://localhost:9090` | None (needs `kubectl port-forward svc/prometheus -n nf-collector 9090:9090 &`) |

### Quick Start (After Setup)

```bash
# Start all port-forwards
kubectl port-forward svc/gitea-http -n gitea 3000:3000 &
kubectl port-forward svc/nf-gateway -n nf-gateway 8084:80 &
kubectl port-forward svc/nf-server -n nf-platform 8000:8000 &
kubectl port-forward svc/grafana -n nf-dashboard 3001:3000 &
kubectl port-forward svc/prometheus -n nf-collector 9090:9090 &

# Start FastAPI
cd orchestrator && source .venv/bin/activate
uvicorn api.app:app --port 9000 &

# Run all use cases
./usecase.sh all
```

---

## Related Documentation

| Document | Location | Purpose |
|----------|----------|---------|
| Commands Reference | `docs/handover/07a-deployment-commands-reference.md` | Every ArgoCD API call and git command for each deployment operation |
| Developer Requirements | `docs/handover/07b-developer-requirements.md` | What to build for production — 8-stage pipeline, acceptance criteria |
| Deployment Design | `docs/handover/07-deployment-rollback.md` | Architecture, state machine, design decisions |
| API Schema | `docs/api/api-response-schema.json` | JSON Schema for the deployment payload |
| Full Handover | `docs/INDEX.md` | Complete documentation index (10+ sections) |
| Lab Setup | [nexus-argo-lab](https://github.com/nijdarshan/nexus-argo-lab) | Kind + ArgoCD + Nexus bootstrap |

---

## Contributing

This is a proof-of-concept for handover.
