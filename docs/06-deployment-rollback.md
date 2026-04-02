# 6. Deployment & Rollback — Deep Dive

> **Audience:** Platform engineers and developers working on the deployment orchestrator.
> **What this section covers:** Architecture, state machine, design decisions, and the overall deployment flow. This is the **DESIGN document** — it explains WHY decisions were made and HOW the system works at a conceptual level.
> **For implementation:** [Section 6a](06a-deployment-commands-reference.md) has every ArgoCD API call and git command. [Section 6b](06b-developer-requirements.md) has the 8-stage pipeline specification and acceptance criteria.
> **Important:** All cluster interaction is via the ArgoCD REST API. No `kubectl` or `oc` commands are used at runtime. The orchestrator receives a fully populated payload from the values resolution pipeline (Section 5a) — it does not resolve templates or placeholders.
>
> **Reading guide for Section 6 suite:**
> | Document | Purpose | When to read |
> |----------|---------|-------------|
> | **Section 6** (this doc) | Design rationale, architecture, state model, sync policies, secrets, use cases | Understanding the system |
> | **[Section 6a](06a-deployment-commands-reference.md)** | Exact curl commands and git operations for every use case | Building the orchestrator |
> | **[Section 6b](06b-developer-requirements.md)** | 8-stage pipeline spec, acceptance criteria, NFRs | Planning and scoping work |

---

## 6.1 Architecture (v2 — No Pipeline Service)

The Service Orchestrator (Hub) commits directly to GitOps and watches ArgoCD. No intermediate pipeline service.

```
┌─────────────────────────────────────────────────────┐
│                   SERVICE ORCHESTRATOR               │
│                                                      │
│   1. Receive deployment request (Helix ID)           │
│   2. Resolve app-config → payload                    │
│   3. For each batch:                                 │
│      a. Generate values.yaml + Application YAML      │
│      b. git commit + push to GitOps                  │
│      c. Trigger ArgoCD sync via API                  │
│      d. Watch sync/health status via ArgoCD API      │
│      e. Report results to Hub DB                     │
│      f. Check approval gates                         │
│   4. Finalize deployment record                      │
│                                                      │
└──────┬──────────────┬──────────────┬─────────────────┘
       │              │              │
    commits        watches       reads/writes
       │              │              │
       ▼              ▼              ▼
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ GitOps   │  │ ArgoCD   │  │ Hub DB   │
  │ Repo     │  │          │  │          │
  └──────────┘  └────┬─────┘  └──────────┘
                     │
                   syncs
                     ▼
               ┌──────────┐
               │ OCP      │
               │ Cluster  │
               └──────────┘
```

---

## 6.2 Hub API Schema

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/deployments` | Create deployment (resolve template, start orchestration) |
| `GET` | `/api/v1/deployments/{id}` | Full response: payload + runtime |
| `GET` | `/api/v1/deployments/{id}/payload` | Resolved payload only |
| `GET` | `/api/v1/deployments/{id}/status` | Runtime block only (UI polling) |
| `PUT` | `/api/v1/deployments/{id}/status` | Update per-chart status (internal callback) |
| `PUT` | `/api/v1/deployments/{id}/approve` | Manual approval gate |

### POST /deployments — Create

```bash
curl -X POST https://hub.vmo2.internal/api/v1/deployments \
  -H "Content-Type: application/json" \
  -d '{
    "helix_id": "HELIX-12345",
    "action": "deploy",
    "environment": "prod",
    "nf": "ims"
  }'
```

**Response:**
```json
{
  "deployment_id": "deploy-2026-03-26-001",
  "status": "pending",
  "message": "Deployment created. Orchestration starting."
}
```

**What happens internally:**
1. Load `app-config.json` for the target NF
2. Resolve all placeholders against CIQ blueprint + IP JSON
3. Deep-merge `user_editable` + resolved `non_editable` → flat `values` per chart
4. Expand multi-instance charts (one `values` per instance)
5. Store resolved payload + initialize runtime in Hub DB
6. Begin orchestration loop

### POST /deployments — Rollback

```bash
curl -X POST https://hub.vmo2.internal/api/v1/deployments \
  -H "Content-Type: application/json" \
  -d '{
    "helix_id": "HELIX-12350",
    "action": "rollback",
    "environment": "prod",
    "nf": "ims",
    "rollback_scope": "component",
    "rollback_component": "mtas",
    "rollback_target_helix": "HELIX-12340"
  }'
```

For full-stack rollback, set `"rollback_scope": "full"` and omit `rollback_component`.

### PUT /status — Internal Status Update

Called by the orchestrator after each chart sync/validate cycle:

```bash
curl -X PUT https://hub.vmo2.internal/api/v1/deployments/deploy-2026-03-26-001/status \
  -H "Content-Type: application/json" \
  -d '{
    "component": "imc",
    "chart": "imc",
    "status": "healthy",
    "commit_sha": "a1b2c3d4e5f6",
    "sync_status": "Synced",
    "health_report": {
      "pods_ready": "6/6",
      "services_with_endpoints": "3/3",
      "version_match": true
    },
    "error": null
  }'
```

For multi-instance charts, `chart` uses the instance key (e.g., `"crdldb-mtas"`).

### PUT /approve — Manual Approval

```bash
curl -X PUT https://hub.vmo2.internal/api/v1/deployments/deploy-2026-03-26-001/approve \
  -H "Content-Type: application/json" \
  -d '{
    "approved_by": "darsh@vmo2.co.uk",
    "notes": "CMS replication verified, proceeding."
  }'
```

### GET /status — Poll Runtime State

```bash
curl https://hub.vmo2.internal/api/v1/deployments/deploy-2026-03-26-001/status
```

**Response:**
```json
{
  "deployment_id": "deploy-2026-03-26-001",
  "status": "in_progress",
  "deployed": ["cms", "imc"],
  "current": "mtas",
  "pending_approval": false,
  "component_results": {
    "cms": {
      "status": "healthy",
      "commit_sha": "abc123",
      "deployed_at": "2026-03-26T10:35:00Z",
      "charts": {
        "cmsplatform": { "status": "healthy", "synced_at": "2026-03-26T10:32:00Z" },
        "cmsnfv": { "status": "healthy", "synced_at": "2026-03-26T10:35:00Z" }
      }
    },
    "imc": {
      "status": "healthy",
      "commit_sha": "def456",
      "deployed_at": "2026-03-26T10:42:00Z",
      "charts": {
        "imc": {
          "status": "healthy",
          "synced_at": "2026-03-26T10:42:00Z",
          "health_report": { "pods_ready": "6/6", "services_with_endpoints": "3/3" }
        }
      }
    },
    "mtas": { "status": "in_progress" }
  }
}
```

---

## 6.3 State Machine

### Deployment Status

```
pending ──► in_progress ──► pending_approval ──► in_progress (resumed) ──► success
                         ──► failed ──► rolled_back
                         ──► cancelled
```

| Status | Condition |
|--------|-----------|
| `pending` | Created but orchestration not started |
| `in_progress` | At least one component being deployed |
| `success` | All components healthy |
| `failed` | Any component unhealthy, no auto-rollback or auto-rollback also failed |
| `rolled_back` | Auto-rollback triggered and completed |
| `cancelled` | Manually cancelled by user |

### Chart Status

```
pending ──► in_progress ──► synced ──► healthy
                                   ──► unhealthy ──► rolled_back
                         ──► skipped
```

| Status | Meaning |
|--------|---------|
| `pending` | Not yet processed |
| `in_progress` | Generating config / committing / syncing |
| `synced` | ArgoCD sync complete, awaiting health check |
| `healthy` | All health checks passed |
| `unhealthy` | Health checks failed |
| `rolled_back` | Reverted to previous commit |
| `skipped` | Not changed in this deployment |

### Component Status Aggregation

Component status derives from its charts:
- All charts `healthy` → component `healthy`
- Any chart `in_progress` or `synced` → component `in_progress`
- Any chart `unhealthy` (none in_progress) → component `unhealthy`
- All charts `pending` → component `pending`
- All charts `rolled_back` → component `rolled_back`

---

## 6.4 Deployment Flow — Step by Step

### Pre-Validation

Before touching Git, verify prerequisites for each component:

```bash
# Check chart exists in Nexus
curl -s "https://secure-nexus.vmo2.internal/service/rest/v1/search?repository=helm-ims&name=vmo2-ims-mtas&version=1.1.0" \
  | jq '.items | length'
# Expected: > 0

# Check images exist in Quay
curl -s -H "Cookie: argocd.token=$TOKEN" \
  "https://quay.vmo2.internal/api/v1/repository/vmo2-ims/mtas-sm/tag/?specificTag=24.3.0" \
  | jq '.tags | length'
# Expected: > 0

# Check secrets in Vault
vault kv get secret/data/ims/prod/mtas/db-credentials
# Expected: data returned
# (Phase 2 — for Phase 1, secrets are expected to already exist in K8s namespaces.
#  The orchestrator does not validate secrets — see Section 6b Stage 2.)

# Check namespace exists (via ArgoCD or K8s API at pre-validation)
# Namespace creation is handled by the namespace.yaml manifest in the app-of-apps
```

**Fail fast:** If any prerequisite is missing, abort before any Git changes.

### Generate Config

For each chart in the component, produce two files:

**1. ArgoCD Application YAML** (multi-source pattern):

```yaml
# environments/prod/applications/ims-mtas.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ims-mtas
  annotations:
    argocd.argoproj.io/sync-wave: "-4"
spec:
  project: ims-prod
  sources:
    - repoURL: https://secure-nexus.vmo2.internal/repository/helm-ims
      chart: vmo2-ims-mtas
      targetRevision: "1.1.0"
      helm:
        valueFiles:
          - $values/environments/prod/values/mtas/mtas/values.yaml
    - repoURL: https://gitlab.vmo2.internal/cnf/ims-gitops.git
      targetRevision: main
      ref: values
  destination:
    namespace: ims-mtas-slough
```

The `$values` ref tells ArgoCD to resolve the values path from the GitOps repo (second source), while pulling the chart from Nexus (first source).

**2. values.yaml** — resolved JSON → YAML:

```yaml
# environments/prod/values/mtas/mtas/values.yaml
global:
  namespace:
    name: ims-mtas-slough
  image:
    repository: quay.vmo2.internal/vmo2-ims
sm:
  replicas: 3
  image: "mtas-sm:24.3.0"
  cmsIPAddresses: ["10.69.96.4", "10.69.96.5"]
```

### Git Commit + Push

```bash
# Per-component atomic commit
cd /path/to/ims-gitops

# Stage files for this component
git add environments/prod/values/mtas/mtas/values.yaml
git add environments/prod/applications/ims-mtas.yaml

# Commit with standardized message
git commit -m "MTAS: Deploy v1.1.0 - HELIX-12345"

# Push (after all charts in this component are committed)
git push origin main
```

**Commit message format:**
- Deploy: `"{COMPONENT}: Deploy v{version} - HELIX-{id}"`
- Config update: `"{COMPONENT}: Config update - HELIX-{id}"`
- Rollback: `"{COMPONENT}: Rollback to HELIX-{target} - HELIX-{new}"`

### ArgoCD Sync — Actual API Calls

After pushing to Git, trigger ArgoCD to sync this component:

**Refresh the application** (detect Git changes):

```bash
curl -X GET "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas?refresh=normal" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN"
```

**Trigger sync:**

```bash
curl -X POST "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas/sync" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "prune": true,
    "strategy": {
      "apply": {
        "force": false
      }
    }
  }'
```

For emergency rollback, set `"force": true` to force-apply even if resources are out of sync.

**Poll sync status:**

```bash
# Poll until status.sync.status == "Synced" or timeout
while true; do
  STATUS=$(curl -s "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
    | jq -r '.status.sync.status')

  HEALTH=$(curl -s "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas" \
    -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
    | jq -r '.status.health.status')

  echo "Sync: $STATUS, Health: $HEALTH"

  if [ "$STATUS" = "Synced" ] && [ "$HEALTH" = "Healthy" ]; then
    echo "Component healthy"
    break
  elif [ "$HEALTH" = "Degraded" ] || [ "$HEALTH" = "Missing" ]; then
    echo "Component unhealthy"
    break
  fi

  sleep 10
done
```

**Get resource tree** (pod-level status):

```bash
curl -s "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas/resource-tree" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
  | jq '.nodes[] | select(.kind == "Pod") | {name: .name, health: .health.status}'
```

**Example response:**
```json
{"name": "mtas-sm-0", "health": "Healthy"}
{"name": "mtas-sm-1", "health": "Healthy"}
{"name": "mtas-sm-2", "health": "Healthy"}
{"name": "mtas-vlbfe-0", "health": "Healthy"}
```

### Health Validation

After ArgoCD reports Synced + Healthy:

```bash
# Health validation via ArgoCD resource-tree API (see Section 6a Section 14)
# GET /api/v1/applications/{name}/resource-tree
# Parse .nodes[] for kind=Pod (check health.status=Healthy)
# and kind=Service/Endpoints (check addresses exist)

# Health report structure
HEALTH_REPORT='{
  "pods_ready": "6/6",
  "services_with_endpoints": "3/3",
  "version_match": true
}'
```

### Report Back to Hub

```bash
curl -X PUT "https://hub.vmo2.internal/api/v1/deployments/$DEPLOYMENT_ID/status" \
  -H "Content-Type: application/json" \
  -d "{
    \"component\": \"mtas\",
    \"chart\": \"mtas\",
    \"status\": \"healthy\",
    \"commit_sha\": \"$(git rev-parse HEAD)\",
    \"sync_status\": \"Synced\",
    \"health_report\": $HEALTH_REPORT,
    \"error\": null
  }"
```

---

## 6.4a ArgoCD Sync Policy (Per-Component, From App-Config)

The ArgoCD sync policy controls what happens when the live cluster state drifts from Git. This is **configured per component in the app-config** — not a global setting.

### Three Sync Modes

| Mode | ArgoCD Config | Behaviour | When to Use |
|------|--------------|-----------|-------------|
| **Manual** (default) | `syncPolicy: {}` | Orchestrator controls all syncs. Drift shows as OutOfSync but is NOT auto-corrected. Emergency `oc` commands (manual cluster access — not the orchestrator) survive until next deployment | Most CNF components — operator controls when changes apply |
| **Auto-sync** | `syncPolicy: { automated: { prune: true } }` | ArgoCD reverts any drift within ~3 minutes (reconciliation interval). Manual `oc scale` or `oc edit` (manual cluster access — not the orchestrator) gets undone | Infrastructure components (networking, config) that must always match Git |
| **Auto-sync + Self-heal** | `syncPolicy: { automated: { prune: true, selfHeal: true } }` | ArgoCD reverts drift within seconds, not minutes. Continuous enforcement | Critical components where any manual change is dangerous (security policies, RBAC) |

### App-Config Configuration

```json
{
  "deployment_config": {
    "manual_approval": true,
    "auto_rollback": false,
    "sync_policy": "manual",
    "sync_timeout": "180s"
  }
}
```

`sync_policy` values: `"manual"` | `"auto"` | `"auto_self_heal"`

The orchestrator generates the ArgoCD Application YAML with the appropriate syncPolicy based on this field.

### Impact on Operations

| Scenario | Manual Sync | Auto-Sync | Auto + Self-Heal |
|----------|-------------|-----------|-----------------|
| Engineer runs `oc scale deployment` (manual cluster access — not the orchestrator) | Stays. Shows OutOfSync in ArgoCD | **Reverted in ~3 min** | **Reverted in seconds** |
| Engineer runs `oc edit deployment` (manual cluster access — not the orchestrator) | Stays until next deploy | **Reverted in ~3 min** | **Reverted in seconds** |
| Engineer runs `oc delete pod` (manual cluster access — not the orchestrator) | K8s recreates pod (ReplicaSet). ArgoCD not involved | Same | Same |
| HPA changes replicas | Stays. OutOfSync shown | **Reverted — conflicts with HPA** | **Reverted — conflicts with HPA** |
| Admission webhook adds labels | Stays | ArgoCD detects diff, may cause sync loop | Sync loop risk |

### Recommendations for IMS

| Component | Sync Policy | Reason |
|-----------|-------------|--------|
| CMS | manual | Complex stateful component, needs operator control |
| MTAS, FTAS, IMC | manual | Active call handling, upgrades need controlled rollout |
| CRDL | manual | Database — never auto-sync, operator verifies cluster health |
| AGW, ENUMFE | manual | Traffic-facing, operator controls when to apply changes |
| Network Policies | auto_self_heal | Security-critical, must always match Git |
| MRF | manual | Media processing, vendor may need pre-configuration |

### Key Points for Handover

1. **Manual sync is the safe default** — the orchestrator explicitly triggers sync when ready
2. **Auto-sync reverts emergency hotfixes** — if a component uses auto-sync, any `oc` command the engineer runs manually on the cluster gets undone within 3 minutes. The team must understand this
3. **HPA and auto-sync conflict** — if using HPA for autoscaling, the component MUST use manual sync, or configure ArgoCD `ignoreDifferences` for the replicas field
4. **The 3-minute interval is configurable** — `timeout.reconciliation` in argocd-cm ConfigMap. Can be reduced (more responsive) or increased (less API server load)

---

## 6.5 Orchestration Loop

The Hub drives the full deployment using the batch system:

```
for each batch in deployment_order (ascending):
  for each component in batch (parallel if > 1):
    1. Pre-validate (chart in Nexus, images in Quay, secrets in Vault, namespace)
    2. Generate values.yaml + Application YAML
    3. Git commit + push
    4. ArgoCD sync via API
    5. Poll ArgoCD until Synced + Healthy (or timeout)
    6. Validate health (pods, services, endpoints)
    7. Update Hub DB: component_results, add to deployed[]

  wait for all components in batch to complete

  if next batch's component has manual_approval: true:
    set pending_approval = true
    pause — wait for PUT /approve
    on approval: continue to next batch

  if any component unhealthy:
    if auto_rollback = true:
      trigger rollback for that component (see 6.6)
    else:
      mark deployment as FAILED
      stop
```

### Batch Processing (IMS)

```
Batch 1: [cms]           → single component, manual_approval after
Batch 2: [imc]           → single component
Batch 3: [mtas, ftas]    → parallel (2 concurrent syncs)
Batch 4: [agw, enumfe]   → parallel
Batch 5: [sceas, lrf]    → parallel
Batch 6: [muag, fuag]    → parallel
Batch 7: [crdl]          → single component, manual_approval after
Batch 8: [cbf, lixp]     → parallel
Batch 9: [mrf]           → single component
```

### Deployment Lock

Only one deployment per (environment, NF) at a time. Prevents concurrent modifications to the same GitOps repo.

```bash
# Acquire lock (Hub DB)
# Key: "deploy-lock:prod:ims"
# Value: deployment_id
# TTL: 4 hours (safety net, released explicitly on completion)

# Reject concurrent request
# "Deployment deploy-2026-03-26-001 is in progress for ims/prod. Cannot start another."
```

### App-of-Apps Bootstrap (Day 0 Only)

On first-ever deployment, after the first component is committed and pushed:

```bash
# Create app-of-apps via ArgoCD API (see Section 6a Section 2)
# POST /api/v1/applications with the app-of-apps spec
curl -sk -X POST "$ARGOCD_URL/api/v1/applications" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
  -H "Content-Type: application/json" \
  -d @environments/prod/app-of-apps.json

# Verify it was created
curl -s "https://argocd.site.vmo2.internal/api/v1/applications/ims-prod-apps" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
  | jq '.status.health.status'
```

The app-of-apps is a pointer to the `applications/` directory. It auto-discovers all Application YAMLs. **Never rolled back** — it's infrastructure, not deployment state.

---

## 6.6 Rollback Flow

### Component Rollback

Revert a single component to a known-good state:

```bash
# 1. Look up the target deployment record
TARGET=$(curl -s "https://hub.vmo2.internal/api/v1/deployments?helix_id=HELIX-12340" \
  | jq -r '.component_results.mtas.commit_sha')
# TARGET = "abc123" (the known-good commit)

# 2. Find which commit to revert (the bad one)
BAD_SHA=$(curl -s "https://hub.vmo2.internal/api/v1/deployments?helix_id=HELIX-12345" \
  | jq -r '.component_results.mtas.commit_sha')
# BAD_SHA = "def456"

# 3. Git revert (not reset — preserves history)
cd /path/to/ims-gitops
git revert --no-edit $BAD_SHA

# This creates a new commit that undoes def456
# Commit message auto-generated: "Revert 'MTAS: Deploy v1.1.0 - HELIX-12345'"
# We amend to our format:
git commit --amend -m "MTAS: Rollback to HELIX-12340 - HELIX-12350"

# 4. Push
git push origin main

# 5. Force sync in ArgoCD (faster recovery)
curl -X POST "https://argocd.site.vmo2.internal/api/v1/applications/ims-mtas/sync" \
  -H "Cookie: argocd.token=$ARGOCD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prune": true, "strategy": {"apply": {"force": true}}}'

# 6. Validate rollback health
# Same health checks as deploy (pods ready, services have endpoints)
# Additionally verify version matches the target deployment's version

# 7. Report rollback result
curl -X PUT "https://hub.vmo2.internal/api/v1/deployments/$ROLLBACK_DEPLOYMENT_ID/status" \
  -d '{"component": "mtas", "chart": "mtas", "status": "rolled_back", ...}'
```

**Why `git revert` not `git reset`:**
- Preserves full history (compliance/audit requirement)
- No `--force` push needed
- Works with branch protection
- ArgoCD auto-detects the revert commit

**What gets reverted** (git revert handles all scenarios automatically):

| Scenario | Original Commit Contents | Revert Undoes |
|----------|------------------------|---------------|
| Config change gone wrong | `values.yaml` only | `values.yaml` only |
| Chart version rollback | `application.yaml` (targetRevision) | `application.yaml` |
| Full upgrade rollback | Both files | Both files |

### Full Stack Rollback

Revert all components in **reverse deployment order**:

```
Hub: components changed since HELIX-12340 = [imc, mtas, agw]
Hub: revert order = [agw, mtas, imc]  (reverse)

Step 1: git revert $AGW_SHA    → push → sync → healthy
Step 2: git revert $MTAS_SHA   → push → sync → healthy
Step 3: git revert $IMC_SHA    → push → sync → healthy

All reverted → finalize
```

**No manual approvals during rollback** by default (fast path). Rollback should be quick.

### Auto-Rollback

When a component fails health checks and `auto_rollback: true`:

```
Orchestrator: mtas health check failed (pods_ready: 4/6)
Orchestrator: auto_rollback=true for mtas
Orchestrator: git revert $MTAS_SHA → push → sync → validate
  If healthy: mark mtas as rolled_back, continue with remaining components
  If unhealthy: mark deployment as FAILED (do NOT loop — max 1 auto-rollback attempt)
```

**Loop prevention:** Maximum one auto-rollback attempt per component per deployment. If the rollback itself fails, the deployment is marked FAILED and alerts fire.

---

## 6.7 Secrets Management

### Vault Path Convention

```
secret/data/{app}/{env}/{component}/{secret-name}
```

Example: `secret/data/ims/prod/mtas/db-credentials`

### Pre-Deployment Verification

```bash
# Check all required secrets exist
for SECRET in db-credentials tls-cert license-key; do
  vault kv get "secret/data/ims/prod/mtas/$SECRET" > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "MISSING: ims/prod/mtas/$SECRET"
    exit 1
  fi
done
```

### VSO (VaultStaticSecret) Sync to K8s

Vault Secrets Operator syncs secrets to Kubernetes Secrets in the target namespace:

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata:
  name: mtas-db-credentials
  namespace: ims-mtas-slough
spec:
  type: kv-v2
  mount: secret
  path: data/ims/prod/mtas/db-credentials
  destination:
    name: mtas-db-credentials
    create: true
  refreshAfter: 30s
```

**Pre-deployment check:** Verify VSO has synced the secret to the namespace:

```bash
# Verify VSO has synced the secret (pre-deployment validation)
# This check runs during pre-validation stage — see Section 6b Stage 2
# Secret existence is confirmed via the ArgoCD managed resource query or
# pre-provisioning verification outside the deployment orchestrator
```

### Secret Rotation

- Update secret in Vault → VSO auto-syncs within `refreshAfter` interval
- No pod restart needed if app watches K8s Secret for changes
- If app needs restart: rolling restart after VSO sync confirmed

---

## 6.8 Runtime State Model

The Hub DB stores the complete deployment state:

```json
{
  "deployment_id": "deploy-2026-03-26-001",
  "helix_id": "HELIX-12345",
  "action": "deploy",
  "environment": "prod",
  "nf": "ims",
  "status": "in_progress",
  "is_bootstrap": false,
  "created_at": "2026-03-26T10:00:00Z",

  "payload": { "..." : "resolved app-config (see Section 5)" },

  "runtime": {
    "deployed": ["cms", "imc"],
    "current": "mtas",
    "pending_approval": false,
    "component_results": {
      "cms": {
        "status": "healthy",
        "commit_sha": "abc123",
        "deployed_at": "2026-03-26T10:35:00Z",
        "charts": {
          "cmsplatform": {
            "status": "healthy",
            "synced_at": "2026-03-26T10:32:00Z",
            "health_report": { "pods_ready": "4/4", "services_with_endpoints": "2/2" }
          },
          "cmsnfv": {
            "status": "healthy",
            "synced_at": "2026-03-26T10:35:00Z",
            "health_report": { "pods_ready": "6/6", "services_with_endpoints": "3/3" }
          }
        }
      },
      "imc": { "status": "healthy", "commit_sha": "def456", "..." : "..." },
      "mtas": { "status": "in_progress" },
      "ftas": { "status": "pending" },
      "agw": { "status": "pending" }
    }
  }
}
```

### Key Fields

| Field | Purpose |
|-------|---------|
| `runtime.deployed[]` | Components successfully deployed so far. Drives "what's next" logic |
| `runtime.current` | Component currently being processed |
| `runtime.pending_approval` | True when Hub is paused waiting for manual approval |
| `runtime.component_results.{}.commit_sha` | Git SHA — needed for rollback |
| `runtime.component_results.{}.charts.{}.health_report` | Pod/service health at deployment time |

---

## 6.9 Use Cases

### Day 0 — Fresh Deployment

```
Hub: deployed=[], components_order=[cms, imc, mtas, ..., mrf]

Batch 1: cms
  → pre-validate (charts, images, secrets, namespace)
  → generate cmsplatform + cmsnfv (Application YAMLs + values)
  → commit "CMS: Deploy v14.15A - HELIX-12345" → push
  → bootstrap: create app-of-apps via ArgoCD API (one-time, see Section 6a Section 2)
  → argocd sync cmsplatform → healthy ✓
  → argocd sync cmsnfv → healthy ✓
  → report to Hub: cms=healthy
  Hub: deployed=["cms"]. manual_approval=true → PAUSE
  Hub UI: "CMS deployed. Verify arbitrator election and replication."
  User approves.

Batch 2: imc
  → generate + commit + push + sync → healthy
  Hub: deployed=["cms", "imc"]. auto-trigger batch 3.

Batch 3: mtas + ftas (parallel)
  → two concurrent: generate + commit + push + sync
  → both healthy
  Hub: deployed=["cms", "imc", "mtas", "ftas"]. Continue.

... batches 4-9 ...

Batch 9: mrf
  → generate + commit + push + sync → healthy
  Hub: deployed=[all 14] → FINALIZE → status=SUCCESS
```

### Upgrade Single Component

```
Hub: payload has IMC chart_version changed from 1.15.0 to 1.16.0

  → pre-validate (new chart version in Nexus, new images in Quay)
  → generate new Application YAML (targetRevision: "1.16.0") + new values.yaml
  → commit "IMC: Deploy v1.16.0 - HELIX-12346" → push
  → sync → healthy ✓
  Hub: FINALIZE → status=SUCCESS
```

### Config Change (No Version Bump)

```
Hub: IMC sm.replicas changed from 3 to 5

  → generate new values.yaml only (Application YAML unchanged)
  → commit "IMC: Config update - HELIX-12347" → push
  → sync → healthy ✓ (new pods come up)
  Hub: FINALIZE → status=SUCCESS
```

### Health Check Failure with Auto-Rollback

```
Batch 2: imc → healthy ✓
Batch 3: mtas → UNHEALTHY (pods_ready: 4/6)

Hub: auto_rollback=true for mtas
Hub: git revert $MTAS_SHA → push → sync → validate
  → rolled_back, previous version healthy (pods_ready: 6/6)

Hub: mtas=rolled_back, imc=still upgraded
Hub: FINALIZE → status=rolled_back, alert sent
```

---

## 6.10 Failure Handling

| Failure Point | Side Effects | Recovery |
|---------------|-------------|----------|
| **Pre-validate fails** (missing chart/image/secret) | None (no commit) | Fix prerequisite, re-trigger |
| **Config generation fails** | None (no commit) | Fix template/payload, re-trigger |
| **Git commit/push fails** | Local commit only | Re-trigger (idempotent — same content = same result) |
| **ArgoCD sync fails** | Commit pushed, app OutOfSync | Re-trigger sync or rollback |
| **Health check fails** | Component running but unhealthy | Auto-rollback (if enabled) or manual intervention |
| **Hub crashes mid-deployment** | State persisted in DB | Hub restarts, reads `deployed[]`, continues from where it left off |
| **ArgoCD unreachable** | Commit pushed, can't sync | Retry with backoff. ArgoCD will eventually see the Git change |

### Atomicity Guarantees

- **No Git changes on validation failure.** If pre-validate or config generation fails, nothing is committed
- **Per-component commits.** If component 3 fails, components 1-2 are already committed and healthy. No rollback of successful components unless explicitly requested
- **Idempotent re-trigger.** Same inputs → same config → same commit content. Git detects no-change and skips

---

## 6.11 Performance Targets

See Section 6b, requirement NFR-01 through NFR-10 for production performance targets. The targets in Section 6b are the specification that the development team builds to.

---

## 6.12 Testing / Prototyping Checklist

Use this to validate the flow end-to-end before handing to a developer:

### 1. Git Operations
- [ ] Create a test GitOps repo with the directory structure from Section 6b Section 5.1
- [ ] Write a values.yaml and Application YAML manually
- [ ] Commit with the standardized message format
- [ ] Push and verify ArgoCD detects the change

### 2. ArgoCD API
- [ ] Get an ArgoCD API token: `argocd account generate-token`
- [ ] Create a test Application via ArgoCD API: `POST /api/v1/applications`
- [ ] Trigger sync via API: `POST /api/v1/applications/{name}/sync`
- [ ] Poll status: `GET /api/v1/applications/{name}` → check `.status.sync.status` and `.status.health.status`
- [ ] Get resource tree: `GET /api/v1/applications/{name}/resource-tree` → check pod health
- [ ] Force sync: `POST /sync` with `strategy.apply.force: true`

### 3. Rollback
- [ ] Deploy a test component (commit + sync)
- [ ] Change values (commit + sync again)
- [ ] `git revert HEAD` → push → verify ArgoCD syncs back to previous state
- [ ] Verify `git log` shows the revert commit (history preserved)

### 4. Multi-Source Application
- [ ] Create an Application with `sources[]` (chart from Nexus + values from Git)
- [ ] Verify ArgoCD resolves `$values` ref correctly
- [ ] Update values only (no chart change) → verify sync picks up value changes

### 5. Hub API Mock
- [ ] Stand up a simple REST API (Flask/Express/whatever)
- [ ] Implement POST /deployments, GET /status, PUT /status, PUT /approve
- [ ] Wire up the orchestration loop: resolve → commit → sync → validate → report
- [ ] Test manual approval gate (pause + resume)

### 6. End-to-End
- [ ] Deploy 2-3 test components in batch order
- [ ] Verify per-component commits in git log
- [ ] Trigger a rollback of one component
- [ ] Verify other components unaffected
- [ ] Test auto-rollback (intentionally deploy broken config)

---

## 6.13 Design Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Health checks use ArgoCD resource-tree** — pod readiness + service endpoints. Custom application-level checks (e.g., CMS arbitrator election) are a future enhancement | ArgoCD already aggregates health status. Resource-tree gives pod-level detail. Custom checks add complexity — defer until a vendor requires it |
| 2 | **Auto-rollback defaults to false** — opt-in per component via `deployment_config.auto_rollback`. Recommended: `true` for stateless components (AGW, ENUMFE), `false` for stateful (CMS, CRDL) | Stateful components need manual verification before rollback (data consistency, replication state). Stateless components are safe to auto-revert |
| 3 | **Rollback does not cascade dependencies** — only the failed component is reverted. If IMC depends on MTAS and MTAS is rolled back, IMC is flagged in the deployment report but not automatically rolled back | Cascading rollback is dangerous — it could take down healthy components. The operator decides whether dependents need action |
| 4 | **Rollback IS the emergency fast path** — no approval gates, uses `force=true` + `refresh=hard`, skips health check timeout (immediate sync) | Already designed this way. No separate "emergency mode" needed |
| 5 | **Sync timeout is configurable per component** — default 180s, overridden via `deployment_config.sync_timeout`. CMS uses 20m, simple components use 3m | Complex components (CMS with HA arbitrator, CRDL with DB cluster) need more time. Simple components should fail fast |
| 6 | **Partial batch failure halts the deployment** — successful components in the batch remain deployed, failed components are marked, deployment status is `failed`, lock is released. Operator decides next step (fix and retry, or rollback) | Proceeding to the next batch with a failed component risks cascading issues. Conservative default — can be relaxed per-batch if needed |
| 7 | **DB failure mid-deployment** — orchestrator continues the current batch (ArgoCD sync is independent of DB), logs to local file as fallback, retries DB write on completion. If DB is still down at Stage 8, deployment completes but state must be reconciled manually | Deployment should not fail because of a monitoring system outage. ArgoCD is the source of truth for live state — DB is the audit record |

---

*Previous: [Section 5a — Values Resolution Pipeline](05a-values-resolution-pipeline.md) | Next: [Section 6a — Commands Reference](06a-deployment-commands-reference.md) → [Section 6b — Developer Requirements](06b-developer-requirements.md) → [Section 7 — API Reference](07-api-reference.md)*
