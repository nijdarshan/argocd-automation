# 7a. Deployment Operations Reference

> **Audience:** Developers implementing the production deployment orchestrator.
> **Scope:** Every operation the orchestrator performs, with exact API calls and expected responses. Production environment only — OCP clusters, GitLab, Nexus, ArgoCD.
> **Protocol:** All cluster interaction goes through ArgoCD REST API. No `kubectl`, no `oc`, no CLI tools at runtime.

---

## Variables Used Throughout

```
ARGOCD_URL    = ArgoCD server URL (e.g., https://argocd.apps.ocp.vmo2.internal)
GITOPS_REPO   = GitOps repository URL (e.g., https://gitlab.vmo2.internal/cnf/ims-gitops.git)
HELM_REGISTRY = Nexus Helm repository (e.g., https://nexus.vmo2.internal/repository/helm-ims/)
TOKEN         = ArgoCD session token (obtained in Section 1)
HELIX_ID      = Deployment tracking ticket (e.g., HELIX-12345)
```

---

## 1. Authentication

ArgoCD authenticates via session cookies. The token must be refreshed before each deployment sequence — tokens expire silently after approximately 60 minutes.

**Request:**
```bash
curl -sk "$ARGOCD_URL/api/v1/session" \
  -H "Content-Type: application/json" \
  -d '{"username":"<service_account>","password":"<from_vault>"}'
```

**Response:**
```json
{"token": "eyJhbGciOiJIUzI1NiIs..."}
```

**Usage in all subsequent calls:**
```
-H "Cookie: argocd.token=$TOKEN"
```

**Credential management:** Service account credentials stored in Vault. The orchestrator fetches them at runtime — never in config files or environment variables.

**Important:** Get a fresh token at the start of each deployment operation. Do not cache tokens across deployments — a deployment that takes longer than 60 minutes will fail silently with 401 responses.

---

## 2. Bootstrap (Day 0 — First Deployment)

The first-ever deployment for an NF on an environment. Creates the entire GitOps structure from the deployment payload.

### 2.1 What the Orchestrator Generates

From the fully populated payload, the orchestrator produces three categories of files in the GitOps repo:

**App-of-Apps** — the root ArgoCD Application that discovers all child applications:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {nf}-{env}
  namespace: argocd
spec:
  project: {argocd_project}
  source:
    repoURL: {gitops_repo}
    path: environments/{env}/applications
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true    # auto-discovers new apps, auto-removes deleted apps
```

**Application YAMLs** — one per chart (or per instance for multi-instance). Uses ArgoCD multi-source: chart from Nexus, values from Git:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {chart_key}
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
    - repoURL: {helm_registry}              # Chart from Nexus
      chart: {chart_name}
      targetRevision: "{chart_version}"
      helm:
        valueFiles:
          - $values/environments/{env}/values/{values_path}/values.yaml
    - repoURL: {gitops_repo}                # Values from GitLab
      targetRevision: main
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: {namespace}                   # Each component in its own namespace
```

For `type: "multi_instance"` components: one Application YAML per instance, each with its own `values_path` and `namespace`.

**Values files** — one per chart/instance. The payload's `values` object converted from JSON to YAML:

```yaml
# environments/{env}/values/{component}/values.yaml
replicaCount: 2
version: "1.0.0"
image:
  repository: quay.vmo2.internal/vmo2-ims
  tag: "mtas-sm:24.3.0"
resources:
  requests:
    cpu: "4000m"
    memory: "16G"
```

### 2.2 Git Commit and Push

All generated files are committed as a single bootstrap commit:

```bash
git add -A
git commit -m "Bootstrap: Initial deployment - {HELIX_ID}"
git push origin main
```

### 2.3 Create App-of-Apps in ArgoCD

The app-of-apps is the only resource created directly in ArgoCD. All subsequent apps are discovered automatically.

**Request:**
```bash
curl -sk -X POST "$ARGOCD_URL/api/v1/applications" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "metadata": {"name": "{nf}-{env}", "namespace": "argocd"},
    "spec": {
      "project": "{argocd_project}",
      "source": {
        "repoURL": "{gitops_repo}",
        "path": "environments/{env}/applications",
        "targetRevision": "main"
      },
      "destination": {"server": "https://kubernetes.default.svc"},
      "syncPolicy": {"automated": {"prune": true}}
    }
  }'
```

**Expected response:** HTTP 200 with the created Application object.

### 2.4 Wait for Child App Discovery

The app-of-apps auto-syncs and discovers the Application YAMLs in the `applications/` directory. Poll until all expected apps appear:

**Request:**
```bash
curl -sk "$ARGOCD_URL/api/v1/applications" \
  -H "Cookie: argocd.token=$TOKEN"
```

**Parse:** Count items matching the NF label:
```
.items[] | select(.metadata.labels["app.kubernetes.io/part-of"] == "{nf}") | .metadata.name
```

**Wait condition:** Number of discovered apps equals number of expected apps from the payload.

### 2.5 Sync Components in Batch Order

For each batch in `payload.deployment_order` (ascending batch number):

1. All components in the same batch can sync in parallel
2. Wait for all components in the batch to become Healthy before proceeding to the next batch
3. If the next batch's component has `manual_approval: true`, pause and emit an approval event

**Sync request (per component):**
```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}?refresh=normal" \
  -H "Cookie: argocd.token=$TOKEN"
```
Wait 1 second, then:
```bash
curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/sync" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prune": true, "strategy": {"apply": {"force": false}}}'
```

**Wait for healthy (per component):**
Poll every 5 seconds until timeout:
```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}" \
  -H "Cookie: argocd.token=$TOKEN"
```

**Success condition:**
```
.status.sync.status == "Synced" AND .status.health.status == "Healthy"
```

**Timeout:** Use `deployment_config.sync_timeout` per component (e.g., 180 seconds).

**Failure condition:**
```
.status.health.status == "Degraded"
```
On failure, check error details (see Section 14) and apply auto-rollback if configured (see Section 8).

### 2.6 Record State

After each component reaches Healthy:

```
Record to DB: {
  deployment_id, helix_id, component, status: "healthy",
  version, commit_sha, health_report, deployed_at
}
```

After all components healthy:

```
Update deployment record: status = "success", completed_at = now()
```

This becomes the **last known-good state** for this NF. If all components of an NF are healthy, the NF deployment status is `success`.

---

## 3. Values Upgrade (Version Change)

A component's application version changes. Only `values.yaml` is modified — the Helm chart in Nexus stays the same.

### 3.1 What Changes

The orchestrator compares the new payload's `values` against the current `values.yaml` in Git. Example diff:

```diff
-version: "1.0.0"
+version: "2.0.0"
```

This is the most common deployment operation. The Helm chart stays at the same version — only the values that the chart consumes change.

### 3.2 Operations

1. **Update values.yaml** — write the new values from the payload
2. **Git commit:**
   ```
   {component}: Deploy v{version} - {HELIX_ID}
   ```
3. **Git push**
4. **ArgoCD sync:**
   ```bash
   # Refresh (detect Git changes)
   curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}?refresh=normal" \
     -H "Cookie: argocd.token=$TOKEN"

   # Sync (apply changes)
   curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/sync" \
     -H "Cookie: argocd.token=$TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"prune": true, "strategy": {"apply": {"force": false}}}'
   ```
5. **Wait healthy** — poll `.status.health.status` until `Healthy` or timeout
6. **Record state** — component result + deployment status to DB

### 3.3 What Kubernetes Does

When ArgoCD syncs the new values, Helm re-renders the templates with updated values. If the pod template changes (version env var, image tag, replicas), Kubernetes performs a rolling update. Old pods are terminated gracefully after new pods pass readiness checks.

---

## 4. Chart Version Upgrade

A vendor ships a new Helm chart version. The `targetRevision` in the ArgoCD Application YAML changes.

### 4.1 What Changes

```diff
# In the Application YAML:
-      targetRevision: "1.0.0"
+      targetRevision: "2.0.0"
```

The `values.yaml` may also change (new chart may have new fields), but the critical change is the chart version.

### 4.2 Operations

1. **Update Application YAML** — change `targetRevision` to the new chart version
2. **Update values.yaml** — if the payload includes new values for this chart version
3. **Git commit:**
   ```
   {component}: Chart upgrade {old_ver}->{new_ver} - {HELIX_ID}
   ```
4. **Git push**
5. **ArgoCD sync** — same as Section 3.2 step 4. ArgoCD detects the `targetRevision` change, fetches the new chart from Nexus, renders with values, and applies.
6. **Wait healthy**
7. **Record state**

### 4.3 Pre-Validation

Before committing the chart upgrade, verify the new chart exists in Nexus:

```bash
curl -s "$HELM_REGISTRY/index.yaml" -u "$NEXUS_USER:$NEXUS_PASS"
```

Parse the YAML to confirm `{chart_name}` at version `{chart_version}` exists. Abort if the chart is not found — do not commit a targetRevision that references a non-existent chart.

---

## 5. Config-Only Change

A value changes that does not constitute a version upgrade — replicas, resource limits, feature toggles, scrape intervals, etc.

### 5.1 What Changes

```diff
-replicaCount: 2
+replicaCount: 3
```

Or nested changes:
```diff
 config:
   features:
-    alerting: false
+    alerting: true
```

### 5.2 Operations

Same as Section 3, with a different commit message:

```
{component}: Config update (replicaCount=3) - {HELIX_ID}
```

The orchestrator should include a human-readable description of what changed in the commit message. This aids audit trail review.

---

## 6. Component Rollback

Revert a single component to its previous state by reversing the last Git commit that touched its files.

### 6.1 Identify the Commit to Revert

Find the most recent commit that modified this component's values or Application YAML:

```bash
git log --oneline -- environments/{env}/values/{component}/ | head -1
```

This returns the SHA of the commit to revert.

### 6.2 Revert

```bash
git revert --no-edit {commit_sha}
git commit --amend -m "{component}: Rollback - {HELIX_ID}"
git push origin main
```

**Why `git revert` not `git reset`:**
- Preserves the full audit trail (compliance requirement)
- No force push needed
- Works with branch protection rules
- ArgoCD sees the revert as a normal commit and syncs

### 6.3 Sync with Rollback Strategy

Rollback uses `refresh=hard` and `force=true` — justified because this is emergency recovery and we need ArgoCD to immediately apply the reverted state:

```bash
# Hard refresh — force ArgoCD to re-read Git immediately
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}?refresh=hard" \
  -H "Cookie: argocd.token=$TOKEN"
```
Wait 3 seconds, then:
```bash
# Sync with force — replace resources, not patch
curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/sync" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"prune": true, "strategy": {"apply": {"force": true}}}'
```

### 6.4 Verify and Record

1. Wait until healthy (same polling as Section 2.5)
2. Record component result: `status: "rolled_back"`, `commit_sha: {revert_sha}`
3. Update the original deployment record: `status: "rolled_back"`
4. The previous successful deployment becomes the current known-good state again

---

## 7. Full Stack Rollback

Revert all components changed since a target deployment to restore the entire NF to a known-good state.

### 7.1 Identify What to Revert

Query the deployment database for the target known-good deployment (by helix_id). Get the list of components and their commit SHAs from the target deployment record.

Then identify all commits since that deployment:

```bash
git log --oneline {target_sha}..HEAD -- environments/{env}/
```

### 7.2 Revert in Reverse Batch Order

Components are reverted in **reverse deployment order** to respect dependencies. If deployment order was CMS → IMC → MTAS, rollback order is MTAS → IMC → CMS.

For each component (reverse order):

1. `git revert --no-edit {component_commit_sha}`
2. Amend commit message: `{component}: Rollback to {target_helix_id} - {HELIX_ID}`
3. `git push origin main`
4. Sync with rollback strategy (Section 6.3)
5. Wait healthy
6. Record component result

**No manual approval gates during rollback.** Rollback is a fast path — every second matters.

### 7.3 Record Final State

After all components are reverted:

1. Update deployment record: `status: "rolled_back"`
2. The target deployment is now the current known-good state
3. Emit notification: rollback complete, NF restored to `{target_helix_id}`

---

## 8. Auto-Rollback on Health Failure

When a component fails health checks after sync and `deployment_config.auto_rollback: true`.

### 8.1 Detect Failure

After sync, if health polling reaches the timeout without becoming Healthy:

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}" \
  -H "Cookie: argocd.token=$TOKEN"
```

If `.status.health.status` is `Degraded` or still `Progressing` after timeout:

### 8.2 Get Error Details

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}/resource-tree" \
  -H "Cookie: argocd.token=$TOKEN"
```

Parse unhealthy resources:
```
.nodes[] | select(.health.status != "Healthy" and .health.message != null)
  → {kind, name, message}
```

Common errors from resource-tree:

| Error | Resource | Meaning |
|-------|----------|---------|
| `"failed to pull and unpack image..."` | Pod | Image doesn't exist in registry or credentials are wrong |
| `"back-off restarting failed container"` | Pod | Application crashes on startup (CrashLoopBackOff) |
| `"unbound PersistentVolumeClaim"` | Pod | Storage not provisioned or claim doesn't match |
| `"Waiting for rollout to finish..."` | Deployment/Rollout | Rollout stuck — new pods not becoming Ready |
| `"Readiness probe failed"` | Pod | Application started but doesn't respond on health endpoint |
| `"OOMKilled"` | Pod | Container exceeded memory limit |

### 8.3 Trigger Auto-Rollback

If `deployment_config.auto_rollback: true`:

1. Record the failure: `component_result.status = "unhealthy"`, `error = {error_messages}`
2. Execute component rollback (Section 6)
3. **Maximum 1 auto-rollback attempt per component per deployment** — if the rollback itself fails, mark the deployment as `failed` and emit an alert. Do not loop.

### 8.4 Record State

```
Component result: status = "rolled_back" (if rollback succeeded)
                  status = "failed" (if rollback also failed)
Deployment: status = "rolled_back" or "failed"
```

Emit notification with error details and outcome.

---

## 9. Canary Deployment (Future)

> **Note:** No vendor currently provides charts with Argo Rollouts `Rollout` CRD. IMS (Mavenir) uses standard `Deployment` resources. This section documents the capability for future use when vendors adopt Rollout CRDs or when the Hub team wraps vendor charts with Rollout support. The infrastructure is ready (Argo Rollouts can be installed on OCP), but the chart-level changes have not been made.

Requires Argo Rollouts controller installed on the cluster. The Helm chart uses `Rollout` CRD instead of `Deployment`.

### 9.1 How It Works

The `Rollout` CRD defines canary steps in the Helm chart (controlled by values):

```yaml
# In values.yaml
strategy: canary
canary:
  steps:
    - weight: 20    # 20% traffic to new version
      pause: -1     # manual promotion (wait for operator)
    - weight: 50
      pause: -1
    - weight: 100
      pause: 0      # auto-complete
```

When the orchestrator syncs the Rollout with a new version:
1. Argo Rollouts creates new pods (canary) alongside old pods (stable)
2. Traffic is split according to the weight (if service mesh is configured) or K8s Service round-robins
3. Rollout **pauses** at each step waiting for promotion
4. Operator verifies the canary is healthy, then the orchestrator promotes

### 9.2 Operations

1. **Update values.yaml** with new version
2. **Commit + push + sync** (same as Section 3)
3. **Wait for rollout to pause** — poll ArgoCD until the Rollout resource shows `Paused`:

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}/resource?resourceName={rollout_name}&kind=Rollout&namespace={namespace}&group=argoproj.io&version=v1alpha1" \
  -H "Cookie: argocd.token=$TOKEN"
```

Parse: `.manifest | fromjson | .status.phase` — should be `"Paused"`

4. **Promote to next step** — patch the Rollout CRD via ArgoCD's resource action API:

```bash
curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/resource/actions?resourceName={rollout_name}&kind=Rollout&namespace={namespace}&group=argoproj.io&version=v1alpha1" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "promote"}'
```

If the ArgoCD resource action API does not support `promote`, use the K8s API directly via ArgoCD's patch capability:

```bash
curl -sk -X PATCH "$ARGOCD_URL/api/v1/applications/{app_name}/resource?resourceName={rollout_name}&kind=Rollout&namespace={namespace}&group=argoproj.io&version=v1alpha1&patchType=merge" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"status": {"pauseConditions": null}}'
```

5. **Repeat** for each canary step until the Rollout reaches `phase: Healthy`
6. **Record state** — include canary steps completed, final traffic split

### 9.3 Canary Abort

If the canary fails health checks at any step:

```bash
# Abort the rollout (Argo Rollouts reverts to stable)
curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/resource/actions?resourceName={rollout_name}&kind=Rollout&namespace={namespace}&group=argoproj.io&version=v1alpha1" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "abort"}'
```

Then `git revert` the values change to restore Git to the stable version.

---

## 10. Blue-Green Deployment (Future)

> **Note:** Same as Section 9 — no vendor currently provides blue-green capable charts. Documented for future readiness. The orchestrator and ArgoCD API calls are proven in the PoC but not yet applicable to production IMS deployments.

Similar to canary but uses two full sets of pods — active (old) and preview (new). Traffic switches atomically on promotion.

### 10.1 How It Works

The Helm chart's Rollout CRD uses `blueGreen` strategy:

```yaml
strategy: blueGreen
```

The chart creates two Services: `{name}` (active, receives production traffic) and `{name}-preview` (preview, for testing). On promotion, the active selector switches to the new pods.

### 10.2 Operations

1. **Update values.yaml** with new version
2. **Commit + push + sync**
3. **Wait for preview** — Argo Rollouts creates new pods and points the preview Service at them. The active Service still points at old pods.

Poll the Rollout resource:
```
.status.phase == "Paused"  → preview is ready, waiting for promotion
```

4. **Verify preview** — the operator (or automated tests) hit the preview Service to confirm the new version works

5. **Promote** — switch active traffic to the new version:
```bash
curl -sk -X POST "$ARGOCD_URL/api/v1/applications/{app_name}/resource/actions?resourceName={rollout_name}&kind=Rollout&namespace={namespace}&group=argoproj.io&version=v1alpha1" \
  -H "Cookie: argocd.token=$TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"action": "promote"}'
```

6. **Record state** — active version updated, old pods terminated

### 10.3 Instant Rollback

Before promotion: just abort. Old pods are still active.
After promotion: Argo Rollouts keeps the old ReplicaSet scaled down. A `git revert` + sync reverts to the previous version instantly.

---

## 11. Add New Component

A new component is added to an existing NF deployment.

### 11.1 Operations

1. **Generate new Application YAML** from the payload (same template as Section 2.1)
2. **Generate new values.yaml**
3. **Commit:**
   ```
   git add environments/{env}/applications/{new_app}.yaml
   git add environments/{env}/values/{component}/values.yaml
   git commit -m "Add {component} - {HELIX_ID}"
   git push origin main
   ```
4. **App-of-apps auto-discovers** — because the root app has `syncPolicy.automated.prune: true`, it detects the new Application YAML in the `applications/` directory and creates the ArgoCD Application
5. **Sync the new app** (same as Section 2.5)
6. **Wait healthy + record state**

---

## 12. Remove Component

A component is decommissioned from the NF.

### 12.1 Operations

1. **Remove files from Git:**
   ```bash
   git rm environments/{env}/applications/{app_name}.yaml
   git rm -r environments/{env}/values/{component}/
   git commit -m "Remove {component} - {HELIX_ID}"
   git push origin main
   ```
2. **App-of-apps prunes** — auto-sync with `prune: true` detects the deleted Application YAML and removes the ArgoCD Application. ArgoCD's cascade deletion removes all K8s resources (pods, services, configmaps) managed by that application.

The orchestrator does not need to make any ArgoCD API calls. The removal is Git-driven — commit the deletion and the auto-sync handles everything.

3. **Record state** — component removed, deployment record updated

---

## 13. Dry Run (Diff Preview)

Show what would change without modifying Git or the cluster.

### 13.1 Operations

1. Generate the new values from the payload
2. Compare against current Git state:
   ```bash
   # Stage changes locally
   git add -A
   # Show diff
   git diff --staged --stat    # files that would change
   git diff --staged           # line-by-line diff
   # Revert (no commit)
   git reset HEAD
   git checkout -- .
   ```
3. Return the diff to the caller — the orchestrator shows what would be committed without actually committing

### 13.2 Response

```json
{
  "component": "platform/server",
  "version": "2.0.0",
  "would_change": ["environments/dev/values/platform/server/values.yaml"],
  "diff": "--- a/...\n+++ b/...\n@@ ... @@\n-version: 1.0.0\n+version: 2.0.0",
  "committed": false
}
```

---

## 14. Health Check (Detailed)

Get comprehensive health information from ArgoCD — pod status, service endpoints, error messages. All from one API call.

### 14.1 All Apps Summary

```bash
curl -sk "$ARGOCD_URL/api/v1/applications" \
  -H "Cookie: argocd.token=$TOKEN"
```

Parse:
```
.items[] | {
  name: .metadata.name,
  sync: .status.sync.status,      # Synced, OutOfSync, Unknown
  health: .status.health.status,  # Healthy, Progressing, Degraded, Missing
  revision: .status.sync.revision
}
```

### 14.2 Single App — Pod-Level Detail

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}/resource-tree" \
  -H "Cookie: argocd.token=$TOKEN"
```

Parse for health report:
```
pods_ready: count(.nodes[] | select(.kind=="Pod" and .health.status=="Healthy"))
            / count(.nodes[] | select(.kind=="Pod"))

services_ready: count(.nodes[] | select(.kind=="Service" and .health.status=="Healthy"))
                / count(.nodes[] | select(.kind=="Service"))

errors: .nodes[] | select(.health.status != "Healthy" and .health.message != null)
        → [{kind, name, message}]
```

This single API call gives you everything — pod names, pod health, service health, deployment rollout status, error messages. No need for separate API calls per resource.

### 14.3 ArgoCD Tracks All Resource Types

ArgoCD monitors the health of every resource in the Application — not just Pods:

| Resource | How ArgoCD Checks Health |
|----------|------------------------|
| Deployment / Rollout | All desired replicas ready |
| Pod | Running + Ready (readiness probe passing) |
| Service | Has endpoints (pods backing it) |
| ConfigMap / Secret | Always Healthy (no runtime state) |
| PVC | Bound to a PersistentVolume |
| NetworkPolicy | Always Healthy (applied = done) |
| CRDs (VaultStaticSecret, etc.) | Reads `.status.conditions` if they follow K8s convention |

If ANY resource is unhealthy, the Application's `health.status` reflects it.

---

## 15. Live Resource Query

Get the actual running version, replicas, and image from ArgoCD — without direct cluster access.

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}/resource?resourceName={resource_name}&kind=Deployment&namespace={namespace}&group=apps&version=v1" \
  -H "Cookie: argocd.token=$TOKEN"
```

**Response contains `.manifest`** — the live K8s resource as JSON string. Parse it:

```
.manifest | fromjson | {
  replicas: .spec.replicas,
  image: .spec.template.spec.containers[0].image,
  version: (.spec.template.spec.containers[0].env[] | select(.name=="APP_VERSION") | .value)
}
```

For Rollout CRD: use `kind=Rollout&group=argoproj.io&version=v1alpha1`.

This returns the **live cluster state**, not what Git says. Use it to verify that a deployment actually applied, or to show current state to the operator.

---

## 16. State Recording

Every deployment operation must maintain a complete record.

### 16.1 Deployment Record

Created at the start of every operation:

```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "helix_id": "HELIX-12345",
  "action": "deploy",
  "environment": "prod",
  "nf": "ims",
  "status": "in_progress",
  "components": ["cms", "imc", "mtas"],
  "created_at": "2026-03-31T10:00:00Z"
}
```

### 16.2 Component Result

Recorded after each component sync completes:

```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "component": "mtas",
  "status": "healthy",
  "version": "2.0.0",
  "commit_sha": "abc123",
  "health_report": {
    "pods_ready": "6/6",
    "services_with_endpoints": "3/3",
    "errors": []
  },
  "deployed_at": "2026-03-31T10:05:00Z"
}
```

### 16.3 Diff Snapshot

Captured before each commit:

```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "component": "mtas",
  "diff_text": "--- a/values.yaml\n+++ b/values.yaml\n...",
  "files_changed": ["environments/prod/values/mtas/values.yaml"]
}
```

### 16.4 Success Criteria

- **Component healthy:** `status.health.status == "Healthy"` in ArgoCD
- **Deployment successful:** ALL components in `deployment_order` are healthy
- **NF status:** When all components of an NF are healthy after a deployment, the NF deployment status is `success`. This is recorded as the **last known-good state** — the rollback target for future failures.

### 16.5 Status Lifecycle

```
Deployment: pending → in_progress → success / failed / rolled_back / cancelled
Component:  pending → in_progress → healthy / unhealthy / rolled_back / skipped
```

---

## 17. Sync Strategy Reference

The `force` and `refresh` parameters on ArgoCD sync calls have specific meanings:

| Parameter | Value | When to Use | What It Does |
|-----------|-------|-------------|-------------|
| `refresh` | `normal` | All normal operations | Nudges ArgoCD to check Git for changes |
| `refresh` | `hard` | Rollback only | Clears ArgoCD's manifest cache, forces complete re-read from Git and Helm registry |
| `force` | `false` | All normal operations | Strategic merge patch — only changed fields are updated. Preserves any additions from admission webhooks (sidecars, labels) |
| `force` | `true` | Rollback only | Full resource replacement — overwrites everything with what's in Git. Justified for emergency recovery |

**Normal deploy/upgrade/config:**
```json
{"prune": true, "strategy": {"apply": {"force": false}}}
```

**Rollback:**
```json
{"prune": true, "strategy": {"apply": {"force": true}}}
```

**Why `force=false` for normal operations:** OCP admission webhooks may inject sidecars, security contexts, labels, or annotations into pods. `force=true` wipes these additions on every sync, causing a loop: ArgoCD replaces → webhook re-adds → ArgoCD sees drift. `force=false` patches only what changed, leaving webhook additions intact.

---

---

## 18. Deployment Lock

Only one deployment per (environment, NF) at a time. The orchestrator checks and acquires the lock before starting.

### 18.1 Check Lock

Before starting any deployment:

```sql
SELECT deployment_id, status, created_at
FROM deployments
WHERE nf = '{nf}' AND environment = '{env}' AND status = 'in_progress'
```

If a record exists with `status = 'in_progress'`: reject the new deployment with a clear error including the existing deployment_id and who started it.

### 18.2 Acquire Lock

```sql
INSERT INTO deployments (deployment_id, helix_id, action, environment, nf, status, created_at)
VALUES ('{id}', '{helix}', '{action}', '{env}', '{nf}', 'in_progress', NOW())
```

### 18.3 Release Lock

On completion (success, failure, rollback, or cancel):

```sql
UPDATE deployments SET status = '{final_status}', completed_at = NOW()
WHERE deployment_id = '{id}'
```

### 18.4 Safety Net

Add a TTL check — if a deployment has been `in_progress` for more than 4 hours, consider it stuck. The orchestrator should alert and allow a new deployment to override it.

---

## 19. ConfigMap Rollout Trigger

When a values change updates a ConfigMap but NOT the pod template spec (e.g., changing a feature flag that's mounted as a ConfigMap), Kubernetes does NOT restart the pods — the old ConfigMap content stays in the running pods.

### Solution: Checksum Annotation

Helm charts should include a checksum of config-dependent values in the pod template annotation:

```yaml
template:
  metadata:
    annotations:
      checksum/config: {{ .Values | toJson | sha256sum }}
```

When any value changes, the checksum changes, Kubernetes sees a new pod spec, and triggers a rolling restart. This is a **Helm chart design requirement** — the orchestrator doesn't handle it, but should document it for chart authors.

---

## 20. ArgoCD API Gotchas

Discovered during testing. Critical for production implementation.

### 20.1 resourceName vs name

The live resource query requires `resourceName` as a parameter, NOT `name`:

```
# Correct:
GET /api/v1/applications/{app}/resource?resourceName={resource}&kind=Deployment&...

# Wrong (returns error):
GET /api/v1/applications/{app}/resource?name={resource}&kind=Deployment&...
```

### 20.2 Reconciliation Interval

ArgoCD reconciles every 3 minutes by default (`timeout.reconciliation` in argocd-cm). This means:

- After `git push`, ArgoCD may take up to 3 minutes to detect the change (without explicit `refresh`)
- The orchestrator calls `refresh=normal` after push to trigger immediate detection — don't rely on the 3-minute cycle
- Manual `oc` commands by operators survive until the next orchestrator sync (manual sync policy) or until the next reconciliation (auto sync policy)

### 20.3 Managed Resources

To list all K8s resources managed by an ArgoCD Application:

```bash
curl -sk "$ARGOCD_URL/api/v1/applications/{app_name}/managed-resources" \
  -H "Cookie: argocd.token=$TOKEN"
```

Returns: `{items: [{group, kind, name, namespace}]}` — every ConfigMap, Service, Deployment, Secret, etc. managed by this app.

### 20.4 Multi-Source $values Reference

In multi-source Applications, the `$values` reference in `helm.valueFiles` points to the Git source defined with `ref: values`. The `ref` name must match exactly. If the Git source doesn't have `ref: values`, the values file path won't resolve and ArgoCD will fail silently with an empty values file.

---

*Previous: [Section 7 — Deployment & Rollback Design](07-deployment-rollback.md) | Next: [Section 7b — Developer Requirements](07b-developer-requirements.md)*
