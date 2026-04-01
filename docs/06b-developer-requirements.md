# 6b. Developer Requirements — Deployment Orchestrator

> **Audience:** Development team building the production deployment orchestrator.
> **Scope:** WHAT to build, not HOW. Tech-stack agnostic.
> **Companion doc:** [06a — Commands Reference](06a-deployment-commands-reference.md) has the exact API calls for each operation.

---

## 1. Infrastructure Prerequisites

The orchestrator depends on these existing systems. It does not provision any of them.

| System | Purpose | Must Exist Before Orchestrator Runs |
|--------|---------|-------------------------------------|
| **GitLab** | GitOps repositories. One repo per app domain (`ims-gitops`, `pcrf-gitops`). Stores Application YAMLs and values files | Yes |
| **Nexus** | Helm chart registry. One hosted repo per tenant (`helm-ims`, `helm-pcrf`). Stores immutable versioned chart packages | Yes — charts must be pushed before deployment |
| **Quay** | Container image registry. Vendor images promoted from untrusted to trusted registry | Yes — images must exist before deployment |
| **Vault** | Stores orchestrator credentials (Git deploy key, Nexus read token, ArgoCD service account). Application secrets (Phase 2) expected to already exist in K8s namespaces | Yes — orchestrator credentials must be stored |
| **ArgoCD** | GitOps deployment engine. Installed on each OCP cluster. Repo credentials for GitLab and Nexus pre-configured | Yes |
| **Argo Rollouts** | Canary/blue-green controller. Optional — only needed when vendors provide `Rollout` CRD charts. Not currently used by any vendor | Future |

---

## 2. Input: Deployment Payload

The orchestrator receives a **fully populated** JSON payload via API. All values are resolved — no placeholders, no template functions remain. The values generation process (support functions, placeholder resolution against the CIQ blueprint) happens upstream in a separate system.

**The payload structure must conform to the schema defined in `docs/api/api-response-schema.json`.** This schema is the contract between the values generation system and the orchestrator. Any changes to the schema must be agreed by both teams.

**What the orchestrator reads from the payload:**

| Field | Where | What It Means |
|-------|-------|--------------|
| `helix_id` | Root | Tracking ticket ID — used in every commit message and DB record |
| `action` | Root | `deploy` or `rollback` |
| `environment` | Root | Target environment (`prod`, `preprod`, `rnd`) |
| `nf` | Root | Network function identifier (`ims`, `pcrf`, `ccs`) |
| `is_bootstrap` | Root | `true` if this is the first deployment (Day 0) |
| `defaults.gitops_repo` | defaults | GitLab repo URL to clone |
| `defaults.helm_registry` | defaults | Nexus URL for chart references in Application YAMLs |
| `defaults.argocd_project` | defaults | ArgoCD project name |
| `deployment_order` | Root | Array of `{component, batch}` — defines which components deploy together and in what order |
| `components.{key}.deployment_config` | Per component | `manual_approval`, `auto_rollback`, `sync_policy`, `strategy`, `sync_timeout` |
| `components.{key}.charts.{key}.chart_name` | Per chart | Helm chart name in Nexus |
| `components.{key}.charts.{key}.chart_version` | Per chart | Chart version (becomes `targetRevision` in ArgoCD Application) |
| `components.{key}.charts.{key}.namespace` | Per chart | Target K8s namespace (each component gets its own) |
| `components.{key}.charts.{key}.values_path` | Per chart | Path in GitOps repo where values.yaml is written |
| `components.{key}.charts.{key}.values` | Per chart | The actual values to write as YAML — fully resolved, ready to deploy |
| `components.{key}.charts.{key}.type` | Per chart | `helm` (standard) or `multi_instance` (same chart deployed N times) |
| `components.{key}.charts.{key}.instances` | Per chart | For `multi_instance`: per-instance namespace, values_path, and values |

---

## 2a. Authentication & Credentials

The orchestrator needs credentials for three systems. All stored in Vault and fetched at runtime — never in config files or environment variables.

### GitLab (push to GitOps repo)

| Method | Details |
|--------|---------|
| **SSH deploy key** (recommended) | Generate an SSH keypair. Add the public key as a deploy key on the GitOps repo with write access. Store the private key in Vault. The orchestrator loads the key at runtime and uses it for `git clone` / `git push` via SSH |
| **Project access token** (alternative) | Create a GitLab project access token with `write_repository` scope. Store in Vault. Clone/push via HTTPS with the token. Tokens expire — must be rotated |

### Nexus (read chart index for pre-validation)

Read-only access to check if charts exist. Basic auth with a service account:

```
Vault path: secret/data/orchestrator/nexus
Fields: username, password
Usage: curl -u "$user:$pass" "$NEXUS_URL/index.yaml"
```

### ArgoCD (sync, health, resource queries)

ArgoCD service account for API access:

```
Vault path: secret/data/orchestrator/argocd
Fields: username, password
Usage: POST /api/v1/session → get cookie token
```

Token expires after ~24 hours (ArgoCD default `server.sessionMaxAge`). The orchestrator fetches a fresh token at Stage 1 (Init) of every run — since the exit-and-resume model starts a new process per batch, the token is always fresh. No token refresh logic needed.

### ArgoCD Repo Secrets (one-time setup by platform team)

ArgoCD needs credentials to access GitLab (for reading Application YAMLs and values) and Nexus (for pulling Helm charts). These are K8s Secrets in the `argocd` namespace:

```yaml
# GitLab repo credential
apiVersion: v1
kind: Secret
metadata:
  name: gitops-repo-{nf}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://gitlab.vmo2.internal/cnf/{nf}-gitops.git
  username: {service_account}
  password: {from_vault}

# Nexus Helm repo credential
apiVersion: v1
kind: Secret
metadata:
  name: nexus-helm-{nf}
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: helm
  name: nexus-{nf}
  url: https://nexus.vmo2.internal/repository/helm-{nf}/
  username: {service_account}
  password: {from_vault}
```

These are created once per NF per cluster by the platform team. The orchestrator does not create or manage them.

### Application Secrets (Phase 2)

Secrets required by the CNF applications (database credentials, TLS certificates, license keys) are expected to already exist in the target K8s namespaces. In Phase 2, these will be automated via Vault Secrets Operator (VSO). For now, the platform team creates them manually or via existing automation before the first deployment.

---

## 3. Deployment Pipeline — 8 Stages

The orchestrator processes each deployment through 8 sequential stages. The same pipeline handles deploy, config change, and chart upgrade — the payload determines what changes.

### Execution Model: Exit-and-Resume

The orchestrator **exits after completing each batch** and resumes on the next trigger. It does not hold a long-running process across all batches.

```
Trigger → Init → Pre-Validate → Prepare → Commit+Push → Bootstrap → Sync batch 1 → Validate → Report → EXIT
                                                                                                    ↓
                                                                                         state saved to DB
                                                                                         (deployed=["cms"])

Next trigger (automatic or manual approval) →
Trigger → Init → check DB → skip deployed → Sync batch 2 → Validate → Report → EXIT
                                                                                    ↓
                                                                         deployed=["cms","imc"]
... repeats until all batches complete ...
```

**Why exit-and-resume, not long-running:**
- **Token freshness** — ArgoCD session token fetched fresh every run. No expiry risk during approval waits
- **Crash recovery** — if the process dies, next trigger picks up from `deployed[]` in DB. No orphaned state
- **Resource efficiency** — no idle process holding memory/connections during hours-long approval waits
- **Simplicity** — each run is stateless except for DB. No in-memory state to lose

**Resume logic in Stage 1 (Init):**
1. Check DB for existing `in_progress` deployment for this (environment, NF)
2. If found: load `deployed[]` from `component_results` — these components are already done
3. Skip Stages 2-5 (pre-validation, prepare, commit, bootstrap already completed)
4. Resume at Stage 6 (Sync) starting from the next undeployed batch

### Overview

| Stage | Name | What Happens | Failure Behaviour |
|-------|------|-------------|-------------------|
| 1 | **Init** | Acquire lock (or resume existing), clone GitOps repo, get fresh ArgoCD token | Reject if locked by different deployment. Resume if same deployment |
| 2 | **Pre-Validate** | Verify all prerequisites exist (charts, images, secrets, namespaces) | Fail fast with specific error. No Git changes made |
| 3 | **Prepare** | Compare payload values against Git state, write changed files | Fail if values can't be written. No Git commit yet |
| 4 | **Commit + Push** | Per-component git commits with standardized messages, single push | Fail if push rejected (conflict). No ArgoCD changes yet |
| 5 | **Bootstrap** | Day 0 only: create app-of-apps in ArgoCD, wait for app discovery | Skip for all non-Day-0 deployments |
| 6 | **Sync** | Trigger ArgoCD sync for next batch, wait healthy | Per-component: if unhealthy and auto_rollback enabled → revert |
| 7 | **Validate** | Verify all deployed components healthy via ArgoCD resource-tree | Record health report per component |
| 8 | **Report** | Update deployment record. If more batches remain → exit (next trigger resumes). If all done → release lock, emit notifications | Always runs — even on failure |

### Stage 1: Init

**Purpose:** Set up the deployment context — either new or resumed.

**New deployment:**
1. Check deployment lock — query DB for any `in_progress` deployment for this (environment, NF). If exists AND it's a different `helix_id` → reject with error
2. Create deployment record in DB: `deployment_id`, `helix_id`, `action`, `environment`, `nf`, `status: "in_progress"`, `created_at`
3. Fetch ArgoCD credentials from Vault
4. Get fresh ArgoCD session token — always fresh per run, never cached
5. Clone the GitOps repo fresh: `git clone {gitops_repo}`. Never reuse a persistent clone

**Resuming deployment** (same `helix_id` already `in_progress`):
1. Load the existing deployment record from DB
2. Read `component_results` to determine which components are already `healthy` — these are the `deployed[]` set
3. Fetch ArgoCD credentials from Vault
4. Get fresh ArgoCD session token
5. Clone the GitOps repo fresh
6. Skip to Stage 6 (Sync) — Stages 2-5 already completed on the first run. Start from the next undeployed batch

**For rollback:** Same init, but `action: "rollback"`. Also retrieve the target deployment record (the known-good state to restore to) from DB.

### Stage 2: Pre-Validate

**Purpose:** Verify everything needed for deployment exists before touching Git or ArgoCD. If anything is missing, fail with a specific error — no changes have been made.

**Checks per component:**

| Check | How | Fail Message |
|-------|-----|-------------|
| Helm chart exists in Nexus at specified version | Query Nexus REST API: `GET {nexus_url}/index.yaml`, parse for `{chart_name}` at `{chart_version}` | `"Chart {name} v{version} not found in Nexus"` |
| Container images exist in Quay | Query Quay API: `GET /api/v1/repository/{org}/{name}/tag/?specificTag={tag}` | `"Image {name}:{tag} not found in Quay"` |
| Target namespace exists on cluster | Query ArgoCD managed resources or check namespace via ArgoCD Application | `"Namespace {ns} does not exist"` |
| Deployment lock is still held | Re-check DB record hasn't been overridden | `"Deployment lock lost"` |

**Secrets:** The orchestrator expects all required K8s secrets to already exist in the target namespaces (created by VSO from Vault, or manually by the platform team). Secret automation is Phase 2. The orchestrator does not validate or create secrets — if a pod fails to start due to a missing secret, it surfaces as a health check failure in Stage 7.

**Skip pre-validation for rollback** — rollback reverts to a previously deployed state where all prerequisites already existed.

**If ANY check fails:** Record the specific failure, set deployment status to `failed`, release lock, return error. No files touched.

### Stage 3: Prepare

**Purpose:** Generate the files that need to change in the GitOps repo by comparing the payload against the current Git state.

**For each component in the payload:**

1. **Generate values.yaml** from `payload.components.{key}.charts.{key}.values`:
   - Convert the `values` JSON object to YAML
   - Compare against the current `environments/{env}/values/{values_path}/values.yaml` in the Git clone
   - If identical → mark component as `skipped` (no changes needed)
   - If different → write the new values.yaml to the working directory

2. **Generate Application YAML** (if Day 0 or chart version changed):
   - For bootstrap: generate the multi-source Application YAML from the payload template (see Section 4.1)
   - For chart upgrade: update `targetRevision` in the existing Application YAML
   - For values-only change: Application YAML stays unchanged

3. **Generate app-of-apps** (Day 0 only):
   - Create the root Application pointing at `environments/{env}/applications/`
   - Create namespace manifest listing all unique namespaces from the payload

**For multi-instance components:** Generate one Application YAML + one values.yaml per instance.

**For rollback:** Skip the above. Instead:
- Find the commit SHA to revert (from the target deployment record in DB)
- `git revert --no-edit {sha}`
- Amend commit message to rollback format

**Important:** The payload values are FULLY RESOLVED. The orchestrator writes them as-is. No placeholder resolution, no template processing, no merging of user_editable/non_editable — that happened upstream.

### Stage 4: Commit + Push

**Purpose:** Create per-component Git commits and push to the GitOps repo.

**For each component that has changes** (not skipped):

1. Stage the component's files:
   ```
   git add environments/{env}/values/{values_path}/values.yaml
   git add environments/{env}/applications/{app_name}.yaml  (if changed)
   ```
2. Commit with standardized message:
   ```
   {component}: Deploy v{version} - {HELIX_ID}
   {component}: Config update ({field}={value}) - {HELIX_ID}
   {component}: Chart upgrade {old}->{new} - {HELIX_ID}
   {component}: Rollback - {HELIX_ID}
   ```
3. Record the commit SHA for this component

**After all components committed:** Single `git push origin main`.

**If push fails** (merge conflict): The deployment fails. Another process modified the repo. Record the error, release lock, alert. The operator decides whether to retry or investigate.

**Capture diff snapshot:** Before committing, capture `git diff --staged` and store in the DB as the diff record for this deployment. This is the audit trail of exactly what changed.

### Stage 5: Bootstrap (Day 0 Only)

**Purpose:** Create the ArgoCD app-of-apps via the ArgoCD API. This is the only time the orchestrator talks to ArgoCD to create an Application — all subsequent apps are discovered automatically.

**Actions:**
1. Create app-of-apps via `POST /api/v1/applications` (see 06a Section 2.3)
2. Wait for child app discovery — poll `GET /api/v1/applications` until the expected number of apps appear
3. If not all apps discovered within timeout → fail

**Skip for all non-Day-0 deployments.** The app-of-apps already exists and auto-discovers new/removed Application YAMLs from the `applications/` directory.

### Stage 6: Sync

**Purpose:** Tell ArgoCD to apply changes for the **current batch only**. After the batch completes, the process exits. The next batch runs on the next trigger.

**Determine the current batch:**
- Read `deployed[]` from `component_results` in DB
- Find the next batch in `deployment_order` that has undeployed components
- If all batches deployed → skip to Stage 7

**For the current batch:**

1. **Sync all components in the batch** (can be parallel if multiple):
   - `GET /api/v1/applications/{app}?refresh=normal` — tell ArgoCD to re-read Git
   - `POST /api/v1/applications/{app}/sync` with `force: false` — apply changes

2. **Wait for all components in the batch to become Healthy:**
   - Poll `GET /api/v1/applications/{app}` every 5 seconds
   - Success: `.status.sync.status == "Synced"` AND `.status.health.status == "Healthy"`
   - Timeout: `deployment_config.sync_timeout` per component (default: 180 seconds)
   - Failure: `.status.health.status == "Degraded"` before timeout

3. **On component failure:**
   - Get error details from `GET /api/v1/applications/{app}/resource-tree`
   - Record error messages (image pull failure, crash loop, PVC issues, etc.)
   - If `deployment_config.auto_rollback: true`:
     - Execute component rollback (git revert → push → sync with `refresh=hard` + `force=true`)
     - Maximum 1 auto-rollback attempt per component. If rollback fails → mark as `failed`, alert
   - If `auto_rollback: false`:
     - Mark deployment as `failed`, alert, release lock. Manual intervention required

4. **After batch completes successfully:**
   - Record all components in this batch as `healthy` in `component_results`
   - Add to `deployed[]`
   - Check if more batches remain:
     - **More batches AND next batch requires `manual_approval`:** Set status to `pending_approval`, emit approval notification, **exit process**. The `PUT /api/v1/deployments/{id}/approve` endpoint triggers a new run that resumes from Init
     - **More batches, no approval needed:** **Exit process**. Immediately trigger a new run (internal queue or scheduler). The new run resumes from Init, loads `deployed[]`, and syncs the next batch
     - **No more batches:** Proceed to Stage 7 (Validate all)

**Rollback during approval gate:** If a rollback request arrives while status is `pending_approval`:
- Cancel the pending deployment (`status → cancelled`)
- Release the deployment lock
- Start a new deployment with `action: rollback` — gets its own lock, own record
- The rollback proceeds without approval gates (fast path)

**For rollback sync:** Use `refresh=hard` and `force=true` — justified for emergency recovery. No approval gates during rollback.

### Stage 7: Validate

**Purpose:** Confirm all components are healthy and record the final state.

**For each component that was deployed (not skipped):**

1. Query ArgoCD resource-tree: `GET /api/v1/applications/{app}/resource-tree`
2. Build health report:
   - `pods_ready`: count of Healthy pods / total pods
   - `services_with_endpoints`: count of Healthy services / total services
   - `errors`: any resource with `health.status != "Healthy"` — capture `kind`, `name`, `message`
3. Query live resource spec: `GET /api/v1/applications/{app}/resource?resourceName=...`
   - Confirm actual running version matches expected version
   - Confirm actual replicas match expected replicas
4. Record component result to DB: `status`, `version`, `commit_sha`, `health_report`, `deployed_at`

**Success criteria:**
- Component is healthy when ALL pods are Ready and ALL services have endpoints
- Deployment is successful when ALL components in the `deployment_order` are healthy
- When all components of an NF are healthy, the NF deployment status is `success`
- This successful deployment becomes the **last known-good state** — the rollback target for future failures

### Stage 8: Report

**Purpose:** Record batch results and either exit (more batches) or finalize (all done).

**Always runs** — even if earlier stages failed.

**If more batches remain (normal exit between batches):**
1. Update `component_results` in DB with batch results
2. Update deployment status: `in_progress` (lock held, more work to do)
3. Exit process — next trigger resumes from Stage 1 (Init)

**If all batches complete (final run):**
1. Update deployment record in DB:
   - `status`: `success`, `failed`, `rolled_back`, or `cancelled`
   - `completed_at`: timestamp
2. Release deployment lock (update DB record from `in_progress` to final status)
3. Emit notification:
   - Success → Hub notification to Helix ticket
   - Failure → alert to on-call team with error details
4. Return deployment result to the caller (API response)

**If any stage failed:**
1. Record the failure in DB with error details
2. Release deployment lock
3. Emit failure alert
4. Exit

---

## 4. ArgoCD Integration

### 4.1 Application YAML Template

Every component is an ArgoCD Application using multi-source — chart pulled from Nexus, values pulled from the GitOps repo:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {chart_key}                    # e.g., "ims-mtas"
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "{sync_wave}"
  labels:
    app.kubernetes.io/part-of: {nf}
    app.kubernetes.io/component: {component}
    app.kubernetes.io/managed-by: hub-orchestrator
spec:
  project: {argocd_project}
  sources:
    - repoURL: {helm_registry}
      chart: {chart_name}
      targetRevision: "{chart_version}"
      helm:
        valueFiles:
          - $values/environments/{env}/values/{values_path}/values.yaml
    - repoURL: {gitops_repo}
      targetRevision: main
      ref: values                      # $values reference — must match exactly
  destination:
    server: https://kubernetes.default.svc
    namespace: {namespace}             # Each component in its own namespace
```

The `$values` reference in `helm.valueFiles` points to the Git source with `ref: values`. If the ref name doesn't match, ArgoCD resolves with an empty values file and deploys with chart defaults — a silent failure.

### 4.2 App-of-Apps

One root Application per NF per environment:

- Points at `environments/{env}/applications/` directory
- `syncPolicy.automated.prune: true` — auto-discovers new Application YAMLs, auto-removes deleted ones
- Child apps have **no auto-sync** by default — the orchestrator controls when each child syncs

### 4.3 Sync Policy Generation

The orchestrator writes the `syncPolicy` into each Application YAML based on `deployment_config.sync_policy` from the payload:

| Payload Value | Generated syncPolicy | Behaviour |
|--------------|---------------------|-----------|
| `manual` (default) | `syncPolicy: {}` | Orchestrator controls all syncs. Manual `oc` commands by operators survive until next deployment |
| `auto` | `syncPolicy: {automated: {prune: true}}` | ArgoCD auto-reverts any drift within ~3 minutes. Manual `oc scale`/`oc edit` gets undone |
| `auto_self_heal` | `syncPolicy: {automated: {prune: true, selfHeal: true}}` | Reverts drift within seconds. Continuous enforcement |

**Critical operational impact:** Auto-sync and self-heal revert ANY manual changes. If an operator runs `oc scale deployment` for emergency capacity, auto-sync will undo it within minutes. The operations team must understand this. Recommend `manual` for all CNF components and `auto_self_heal` only for security-critical resources (NetworkPolicy, RBAC).

### 4.4 Sync Parameters

| Operation | refresh | force | Rationale |
|-----------|---------|-------|-----------|
| Normal deploy/upgrade/config | `normal` | `false` | Safe. Patches only changed fields. Preserves OCP admission webhook mutations (sidecars, labels, security context) |
| Rollback | `hard` | `true` | Emergency. Forces ArgoCD to re-read Git and replace resources entirely. Justified for recovery |

Using `force=true` for normal deploys causes OCP issues: admission webhooks inject sidecars/labels → ArgoCD force-replaces and removes them → webhooks re-inject → ArgoCD sees drift → infinite loop.

---

## 5. Git Operations

### 5.1 GitOps Repository Structure

```
{nf}-gitops/
├── app-of-apps.yaml                     # Root Application (created Day 0)
└── environments/
    └── {env}/
        ├── applications/                 # ArgoCD Application YAMLs
        │   ├── namespace.yaml            # All namespaces for this NF
        │   ├── {app1}.yaml              # Multi-source Application per chart
        │   ├── {app2}.yaml
        │   └── {app3}-{instance}.yaml   # Multi-instance apps
        └── values/                       # Helm values per component
            ├── {component1}/
            │   └── values.yaml
            ├── {component2}/
            │   └── values.yaml
            └── {component3}/
                ├── {instance1}/
                │   └── values.yaml       # Multi-instance values
                └── {instance2}/
                    └── values.yaml
```

One GitOps repo per app domain (`ims-gitops`, `pcrf-gitops`). Different vendors have different lifecycles and rollback boundaries.

### 5.2 Commit Messages

```
{component}: Deploy v{version} - {HELIX_ID}
{component}: Config update ({field}={value}) - {HELIX_ID}
{component}: Chart upgrade {old_ver}->{new_ver} - {HELIX_ID}
{component}: Rollback - {HELIX_ID}
```

The `HELIX_ID` in every commit message enables audit trail queries: `git log --grep="HELIX-12345"` shows everything that happened in that deployment.

### 5.5 What Changes Per Operation Type

| Operation | values.yaml | Application YAML | Commit Message |
|-----------|------------|-----------------|----------------|
| **Values upgrade** (version change) | Modified (new version) | Unchanged | `Deploy v{version}` |
| **Config change** (replicas, settings) | Modified (new values) | Unchanged | `Config update ({field}={value})` |
| **Chart version upgrade** | May be modified | Modified (`targetRevision` changes) | `Chart upgrade {old}->{new}` |
| **Day 0 bootstrap** | Created (new file) | Created (new file) | `Bootstrap: Initial deployment` |
| **Add component** | Created (new file) | Created (new file) | `Add {component}` |
| **Remove component** | Deleted | Deleted | `Remove {component}` |
| **Rollback** | Reverted (via `git revert`) | Reverted if chart version was part of the change | `Rollback` |

### 5.3 Rollback Rules

- **Always `git revert` for single-step rollback** — creates a new commit that undoes the target. Preserves full history (compliance requirement). Works with branch protection. No force push.
- **Content-based restoration for multi-step rollback** — when rolling back past multiple deployments, extract known-good content from Git history via `git show {target_sha}:path` and commit as new state. Avoids merge conflicts from chained reverts. See [06a Section 6.2a](06a-deployment-commands-reference.md).
- **Never `git reset`** — destroys history, requires force push, breaks branch protection.
- **Maximum 1 auto-rollback per component per deployment** — prevents infinite loops.
- **No approval gates during rollback** — fast path, every second matters.
- **Rollback during approval gate** — if a rollback is requested while a deployment is `pending_approval`, cancel the pending deployment first, then start the rollback as a new deployment.
- **Full stack rollback: reverse batch order** — if deploy order was CMS→IMC→MTAS, rollback order is MTAS→IMC→CMS.

### 5.4 Cross-Namespace Service References

Each component deploys to its own namespace (e.g., `ims-cms`, `ims-mtas`). When components need to communicate across namespaces, the values must use full FQDN:

```yaml
targetServer: "nf-server.nf-platform.svc.cluster.local:8000"
```

Not `nf-server.nf-platform:8000` — short names don't resolve when applications use custom DNS resolvers (nginx, envoy). Always use `.svc.cluster.local` suffix.

---

## 6. Deployment Strategies

Controlled by `deployment_config.strategy` in the payload. The strategy is a property of the Helm chart (what K8s resource it creates), not the orchestrator.

| Strategy | Helm Chart Resource | Orchestrator Action | Current Status |
|----------|-------------------|-------------------|----------------|
| `rolling` (default) | Standard K8s `Deployment` | Sync → wait healthy | **Active** — all current vendor charts use this |
| `canary` | Argo Rollouts `Rollout` CRD | Sync → wait paused → promote per step → healthy | **Future** — no vendor currently provides Rollout charts |
| `blueGreen` | Argo Rollouts `Rollout` CRD | Sync → preview created → promote → active switches | **Future** — same as canary |

For rolling deployments (the current reality), the orchestrator just syncs and waits for Healthy. Kubernetes handles the rolling update internally based on the Deployment's `strategy.rollingUpdate` settings.

When canary/blue-green becomes relevant, the orchestrator needs to handle Argo Rollouts promotion via ArgoCD's resource action API (see 06a Sections 9 and 10).

---

## 7. State Management

### 7.1 What Goes in the Database

| Table | Records | Key Fields |
|-------|---------|------------|
| `deployments` | One per deployment operation | deployment_id, helix_id, action, environment, nf, status, created_at, completed_at |
| `component_results` | One per component per deployment | deployment_id, component, status, version, commit_sha, health_report, error |
| `diffs` | One per changed component per deployment | deployment_id, component, diff_text, files_changed |

### 7.2 What Comes from ArgoCD (Query On Demand)

Do NOT store ArgoCD's live state in your database. It changes every few seconds (pod restarts, scaling, drift detection). Query ArgoCD when you need current status:

- Live health: `GET /api/v1/applications/{name}` → `.status.health.status`
- Pod-level detail: `GET /api/v1/applications/{name}/resource-tree`
- Running version/replicas: `GET /api/v1/applications/{name}/resource?resourceName=...`

### 7.3 What Comes from Git

- Full audit trail: `git log --grep="{HELIX_ID}"` → every commit in a deployment
- Rollback targets: `git log -- environments/{env}/values/{component}/` → commit SHAs per component
- Diff for any deployment: `git show {commit_sha}` → exactly what changed

### 7.4 Last Known-Good State

When all components of an NF reach Healthy after a deployment, that deployment is recorded as the **last known-good state**. This is the rollback target — if a future deployment fails, the orchestrator reverts to the commit SHAs from this record.

```sql
-- Find last successful deployment for IMS prod
SELECT deployment_id, helix_id, completed_at
FROM deployments
WHERE nf = 'ims' AND environment = 'prod' AND status = 'success'
ORDER BY completed_at DESC LIMIT 1
```

---

## 8. Helm Chart Requirements

The orchestrator does not create Helm charts — vendors provide them and the artifact intake process promotes them to Nexus. However, charts must meet these requirements for the orchestrator to work correctly:

### 8.1 Values Must Drive All Variable Configuration

Everything that changes between deployments must be in `values.yaml` — not hardcoded in templates. The orchestrator only writes `values.yaml`; it never modifies chart templates.

### 8.2 ConfigMap Checksum Annotation

If the chart uses ConfigMaps mounted into pods, the pod template must include:

```yaml
template:
  metadata:
    annotations:
      checksum/config: {{ .Values | toJson | sha256sum }}
```

Without this, updating a ConfigMap value via `values.yaml` changes the ConfigMap resource but does NOT trigger a pod restart. Pods continue using the old ConfigMap content until manually restarted. This is a **chart authoring requirement** — the orchestrator does not handle it.

### 8.3 Chart Versioning

Chart versions in Nexus are **immutable**. If a chart needs to be fixed, the version must be incremented. The orchestrator cannot overwrite an existing chart version.

### 8.4 CI/CD Validation Pipeline

After files are committed and pushed, a CI/CD pipeline (GitLab CI) validates the generated configuration before ArgoCD syncs it:

| Check | What It Does |
|-------|-------------|
| **YAML syntax** | Validates all generated files are valid YAML |
| **Helm template** | `helm template` against each chart with generated values — catches rendering errors |
| **Schema validation** | Validates values against Helm chart schema (if chart provides `values.schema.json`) |
| **NetworkPolicy lint** | Validates policy manifests are well-formed K8s resources |
| **Security scan** | Scans generated config for exposed secrets, insecure settings |
| **Diff preview** | Shows what changed vs current Git state |

Failures block the commit from reaching ArgoCD. No broken configuration reaches the cluster.

---

## 9. What the Orchestrator Does NOT Build

| Capability | Why Not | Who Owns It |
|-----------|---------|-------------|
| **Values generation** | Support function resolution, placeholder substitution, user_editable/non_editable merging — all happens upstream. The orchestrator receives the output | App-Config / Support Functions team |
| **Helm chart creation** | Vendor provides charts. Hub team packages and promotes via artifact intake | Artifact Intake team |
| **Infrastructure provisioning** | CWL cluster build, network provisioning, IP allocation — separate process that runs before deployment | Infrastructure team |
| **UI frontend** | Separate team builds Vue frontend consuming the orchestrator API via OpenAPI spec | Frontend team |
| **Artifact scanning** | Security scanning of charts and images before promotion — separate governance process | Security team |
| **CIQ generation** | Network requirements calculation from vendor inputs — feeds into values generation | CIQ / Network team |

---

## 10. API Endpoints

The orchestrator exposes a REST API. Generate an OpenAPI spec from your models — the frontend team imports it to auto-generate a typed client.

| Method | Path | Purpose | Stage |
|--------|------|---------|-------|
| `POST` | `/api/v1/deployments` | Full deployment from payload | Triggers Stages 1-8 per batch |
| `POST` | `/api/v1/deployments/component` | Single component upgrade | Stages 1-8 for one component |
| `POST` | `/api/v1/deployments/config` | Config-only change | Stages 1-8, different commit message |
| `POST` | `/api/v1/rollbacks/component` | Revert single component | Stages 1, 3 (revert), 4, 6 (hard), 7, 8 |
| `POST` | `/api/v1/rollbacks/full` | Full stack rollback | Same, reverse batch order |
| `POST` | `/api/v1/deployments/dry-run` | Preview diff without deploying | Stages 1-3 only, no commit |
| `PUT` | `/api/v1/deployments/{id}/approve` | Approve paused deployment | Triggers new run that resumes from next batch |
| `GET` | `/api/v1/status` | Full stack health | Queries ArgoCD for all apps |
| `GET` | `/api/v1/status/{app}` | Component detail (version, pods, health) | Queries ArgoCD resource-tree + live resource |
| `GET` | `/api/v1/deployments/latest` | Most recent deployment | Dashboard headline |
| `GET` | `/api/v1/deployments` | Historical deployment records | Queries DB |
| `GET` | `/api/v1/deployments/{id}` | Single deployment with results + diff | Queries DB |
| `GET` | `/api/v1/diffs` | Current uncommitted changes | `git diff` on working directory |
| `GET` | `/api/v1/health` | API health check | Liveness probe |

---

## 11. Non-Functional Requirements

| Requirement | ID | Target |
|-------------|-----|--------|
| Single component deploy (commit to healthy) | NFR-01 | < 2 minutes |
| Full NF deployment (14 components, excluding approval waits) | NFR-02 | < 30 minutes |
| Component rollback | NFR-03 | < 5 minutes |
| Full stack rollback | NFR-04 | < 15 minutes |
| Health check API response | NFR-05 | < 3 seconds |
| Concurrent deployments per (env, NF) | NFR-06 | 1 (locked) |
| Deployment history retention | NFR-07 | 90 days minimum |
| Audit trail completeness | NFR-08 | Every deploy, rollback, approval recorded in DB + Git |
| Idempotency | NFR-09 | Re-running with same payload produces no changes (skipped) |
| Resume after failure | NFR-10 | Orchestrator reads deployed[] from DB, continues from next undeployed batch |
| Exit-and-resume per batch | NFR-11 | Each batch runs as an independent process. No long-running orchestrator process across batches |

---

## 12. Acceptance Criteria

| ID | Criterion | How to Verify |
|----|-----------|--------------|
| AC-01 | Given a valid payload, the orchestrator creates per-component commits with correct message format | Inspect `git log` |
| AC-02 | Given a values change, only `values.yaml` is modified — Application YAML unchanged | Inspect `git diff` |
| AC-03 | Given a chart version change, `targetRevision` in Application YAML is updated | Inspect `git diff` |
| AC-04 | Given 3 components with changes, exactly 3 commits created, 1 push | Inspect `git log` |
| AC-05 | Given component rollback, `git revert` creates a new commit (not reset) | Inspect `git log` — revert commit visible |
| AC-06 | Given missing chart in Nexus, pre-validation fails before any Git changes | No new commits in `git log` |
| AC-07 | Given deployment failure with auto_rollback=true, component is reverted automatically | DB shows `rolled_back` status |
| AC-08 | Given deployment failure with auto_rollback=true, max 1 rollback attempt (no loop) | DB shows single rollback record |
| AC-09 | Given manual_approval=true, deployment pauses and emits approval event | DB shows `pending_approval` |
| AC-10 | Given concurrent deployment to same env/NF, second is rejected | API returns error with existing deployment_id |
| AC-11 | Given same payload re-submitted, all components show `skipped` (idempotent) | No new commits, all components skipped |
| AC-12 | Given full stack rollback, components revert in reverse deployment order | Inspect `git log` — reverse order visible |
| AC-13 | Given successful deployment, DB has deployment record + component results + diffs | Query `/api/deployments/{id}` |
| AC-14 | All ArgoCD interaction via REST API — no kubectl, no oc, no CLI | Code review |
| AC-15 | After successful deployment, NF recorded as last known-good state | Query DB for latest success |

---

*Previous: [Section 6a — Commands Reference](06a-deployment-commands-reference.md) | Next: [Section 7 — API Reference](07-api-reference.md)*
