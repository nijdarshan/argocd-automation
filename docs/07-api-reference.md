# 7. API Reference

> **Audience:** Developers building the orchestrator API and frontend teams consuming it.
> **Schema:** `docs/api/api-response-schema.json` (JSON Schema draft-07)
> **Example:** `docs/api/api-response-example.json` (mid-deployment response with real resolved data)
> **Commands:** [Section 6a](06a-deployment-commands-reference.md) has exact curl commands for every ArgoCD API call.

---

## 7.1 Two APIs

The deployment system has two separate APIs:

| API | Purpose | Consumers |
|-----|---------|-----------|
| **Hub Orchestrator API** | Trigger deployments, query status, approve gates, view history | Hub UI, Vue frontend, CLI tools, external integrations |
| **ArgoCD REST API** | Sync applications, watch health, query live resources | Orchestrator only (internal — never exposed to frontend) |

The frontend calls the Hub Orchestrator API. The orchestrator calls ArgoCD internally. The frontend never talks to ArgoCD directly.

---

## 7.2 Authentication

The Hub Orchestrator API uses token-based authentication. All requests must include an `Authorization` header:

```
Authorization: Bearer <hub_api_token>
```

| Concern | Implementation |
|---------|---------------|
| **Token issuance** | Tokens issued by the Hub identity provider (Keycloak or equivalent SSO). Service accounts for automation, user tokens for portal |
| **Token format** | JWT with `sub` (user/service), `roles` (operator, viewer, admin), `exp` (expiry) |
| **RBAC** | `operator` — can trigger deployments, approve gates, rollback. `viewer` — read-only status/history. `admin` — manage config, override locks |
| **Service-to-service** | Internal services (values resolution pipeline, CI/CD) use service account tokens with scoped permissions |
| **ArgoCD auth** | The orchestrator authenticates to ArgoCD independently using `Cookie: argocd.token=<session_token>` (see [Section 6a](06a-deployment-commands-reference.md) Section 1). This is internal — never exposed to frontend |

Token rotation and revocation follow the organisation's standard SSO policy. The Hub API does not manage credentials directly.

---

## 7.3 Hub Orchestrator API — Endpoints

All endpoints use the `/api/v1/` prefix. Version the API path when breaking changes are introduced.

| Method | Path | Purpose | When Called |
|--------|------|---------|------------|
| `POST` | `/api/v1/deployments` | Full deployment from payload | New deployment triggered via Hub UI or automation |
| `POST` | `/api/v1/deployments/component` | Single component upgrade | Version change for one component |
| `POST` | `/api/v1/deployments/config` | Config-only change | Replicas, feature flags, settings change |
| `POST` | `/api/v1/rollbacks/component` | Revert single component | Component health failure or manual rollback |
| `POST` | `/api/v1/rollbacks/full` | Full stack rollback | Revert entire NF to known-good state |
| `POST` | `/api/v1/deployments/dry-run` | Preview diff without deploying | Operator wants to see what would change before committing |
| `PUT` | `/api/v1/deployments/{id}/approve` | Approve paused deployment | Operator verifies component health, continues to next batch |
| `GET` | `/api/v1/status` | Full stack health | Frontend polls every few seconds for live dashboard |
| `GET` | `/api/v1/status/{app}` | Component detail | Click into a component for version, replicas, pods, errors |
| `GET` | `/api/v1/deployments` | Deployment history | View past deployments, filter by NF/environment |
| `GET` | `/api/v1/deployments/latest` | Most recent deployment | Dashboard headline — what's currently deployed |
| `GET` | `/api/v1/deployments/{id}` | Single deployment with results + diff | Drill into a specific deployment for audit |
| `GET` | `/api/v1/diffs` | Current uncommitted changes | Preview what's staged in the GitOps working directory |
| `GET` | `/api/v1/git-log` | Git commit history as structured data | Audit trail — every commit with component, version, HELIX ID |
| `GET` | `/api/v1/health` | API health check | Load balancer / liveness probe |

---

## 7.3a Request/Response Contracts

### POST /api/v1/deployments — Full Deployment

**Request (202 Accepted):**
```json
{
  "helix_id": "HELIX-12345",
  "action": "deploy",
  "environment": "prod",
  "nf": "ims",
  "is_bootstrap": false,
  "payload": { "...full resolved payload per schema..." }
}
```

**Response:**
```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "helix_id": "HELIX-12345",
  "status": "in_progress",
  "message": "Deployment created. Orchestration starting with batch 1."
}
```

### POST /api/v1/deployments/component — Single Component

**Request:**
```json
{
  "helix_id": "HELIX-12346",
  "environment": "prod",
  "nf": "ims",
  "component": "mtas",
  "chart": "mtas",
  "version": "24.4.0",
  "values": { "replicaCount": 3, "version": "24.4.0", "image": {"tag": "mtas-sm:24.4.0"} }
}
```

**Response (same shape as full deployment):**
```json
{
  "deployment_id": "deploy-2026-03-31-002",
  "helix_id": "HELIX-12346",
  "status": "in_progress",
  "message": "Component deployment started for mtas."
}
```

### POST /api/v1/deployments/config — Config Change

**Request:**
```json
{
  "helix_id": "HELIX-12347",
  "environment": "prod",
  "nf": "ims",
  "component": "mtas",
  "chart": "mtas",
  "values": { "replicaCount": 4 }
}
```

**Response:** Same shape as above. Only changed fields in `values` — the orchestrator deep-merges with existing values in Git.

### POST /api/v1/rollbacks/component — Component Rollback

**Request:**
```json
{
  "helix_id": "HELIX-12348",
  "environment": "prod",
  "nf": "ims",
  "component": "mtas",
  "target_deployment_id": "deploy-2026-03-30-005"
}
```

If `target_deployment_id` is omitted, rolls back to the most recent commit (single-step revert). If provided, uses content-based restoration to the target state (see [Section 6a Section 6.2a](06a-deployment-commands-reference.md)).

**Response:**
```json
{
  "deployment_id": "deploy-2026-03-31-003",
  "helix_id": "HELIX-12348",
  "status": "in_progress",
  "message": "Rollback started for mtas to deploy-2026-03-30-005."
}
```

### PUT /api/v1/deployments/{id}/approve — Approval Gate

**Request:**
```json
{
  "approved": true,
  "approved_by": "operator@vmo2.co.uk",
  "comment": "CMS arbitrator election verified. Proceeding."
}
```

**Response:**
```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "status": "in_progress",
  "message": "Approval accepted. Resuming deployment from batch 2."
}
```

To reject (cancel the deployment):
```json
{ "approved": false, "comment": "Issue found in CMS replication." }
```
Response: `{ "status": "cancelled", "message": "Deployment cancelled by operator." }`

### GET /api/v1/deployments/{id} — Deployment Detail

**Response:** Returns the full deployment record as defined in `api-response-schema.json` — payload + runtime state. See Section 7.5 for payload structure and Section 7.8 for runtime structure.

### POST /api/v1/deployments (Bootstrap — Day 0)

Same as full deployment, but with `"is_bootstrap": true` and the full payload including ALL components. The orchestrator generates app-of-apps, namespace manifest, all Application YAMLs, and all values files in a single bootstrap commit.

---

## 7.4 Error Response Format

All error responses follow a consistent structure:

```json
{
  "error": {
    "code": "DEPLOYMENT_IN_PROGRESS",
    "message": "Deployment deploy-2026-03-26-001 is in progress for ims/prod. Cannot start another.",
    "details": {
      "existing_deployment_id": "deploy-2026-03-26-001",
      "helix_id": "HELIX-12345"
    }
  }
}
```

| HTTP Status | Error Code | When |
|-------------|-----------|------|
| `400` | `INVALID_PAYLOAD` | Payload fails JSON Schema validation |
| `400` | `MISSING_FIELD` | Required field absent |
| `404` | `DEPLOYMENT_NOT_FOUND` | `deployment_id` does not exist |
| `404` | `COMPONENT_NOT_FOUND` | Component not in payload |
| `409` | `DEPLOYMENT_IN_PROGRESS` | Another deployment is running for this (environment, NF) |
| `409` | `APPROVAL_NOT_PENDING` | Approve called but no gate is active |
| `422` | `PREREQUISITE_FAILED` | Pre-validation failed (chart not in Nexus, image missing, namespace absent) |
| `500` | `GIT_OPERATION_FAILED` | Clone, commit, or push failed |
| `500` | `ARGOCD_UNREACHABLE` | Cannot connect to ArgoCD API |
| `504` | `SYNC_TIMEOUT` | ArgoCD sync exceeded `sync_timeout` |

All `4xx` errors are safe to retry after fixing the input. `5xx` errors indicate infrastructure issues — check ArgoCD and GitLab connectivity before retrying.

---

## 7.5 Deployment Payload Schema

The payload is the **contract between the values generation system and the orchestrator**. Changes to this schema must be agreed by both teams.

### Top-Level Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `deployment_id` | string | Yes | Unique identifier for this deployment |
| `helix_id` | string | Yes | Tracking ticket ID — appears in every commit message and DB record |
| `action` | enum | Yes | `deploy` or `rollback` |
| `environment` | string | Yes | Target environment (`prod`, `preprod`, `rnd`) |
| `nf` | string | Yes | Network function identifier (`ims`, `pcrf`, `ccs`) |
| `is_bootstrap` | boolean | No | `true` for first-ever deployment (Day 0). Creates app-of-apps |
| `status` | enum | Read-only | Set by orchestrator: `pending`, `in_progress`, `success`, `failed`, `rolled_back`, `cancelled` |
| `created_at` | datetime | Read-only | Set by orchestrator |
| `completed_at` | datetime | Read-only | Set by orchestrator |

### Defaults Block

| Field | Type | Description |
|-------|------|-------------|
| `defaults.gitops_repo` | string | GitLab repository URL for the GitOps repo |
| `defaults.gitops_branch` | string | Branch to commit to (usually `main`) |
| `defaults.helm_registry` | string | Nexus Helm repository URL |
| `defaults.argocd_project` | string | ArgoCD project name |

### Deployment Order

Array of `{component, batch}` that defines sequencing:

```json
"deployment_order": [
  { "component": "cms", "batch": 1 },
  { "component": "imc", "batch": 2 },
  { "component": "mtas", "batch": 3 },
  { "component": "ftas", "batch": 3 },
  { "component": "agw", "batch": 4 }
]
```

- Batches execute sequentially (batch 1 before batch 2)
- Components within the same batch deploy in parallel
- Each batch waits for all its components to become Healthy before the next batch starts

### Component Definition

```json
"components": {
  "{component_key}": {
    "display_name": "Human-readable name",
    "deployment_config": {
      "manual_approval": false,
      "approval_message": "Verify before proceeding",
      "auto_rollback": true,
      "sync_policy": "manual",
      "strategy": "rolling",
      "sync_timeout": "180s"
    },
    "depends_on": ["other_component"],
    "charts": { ... }
  }
}
```

### Deployment Config Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `manual_approval` | boolean | `false` | Pause after this component is healthy, wait for operator approval via `PUT /api/v1/deployments/{id}/approve` |
| `approval_message` | string | `""` | Message shown to operator when approval is required |
| `auto_rollback` | boolean | `false` | Automatically revert this component if health check fails. Max 1 attempt (no loops) |
| `sync_policy` | enum | `"manual"` | ArgoCD sync policy: `manual` (orchestrator controls sync), `auto` (ArgoCD auto-syncs on Git change), `auto_self_heal` (continuous enforcement) |
| `strategy` | enum | `"rolling"` | Deployment strategy: `rolling` (current — standard K8s Deployment), `canary` (future — Argo Rollouts), `blueGreen` (future — Argo Rollouts) |
| `sync_timeout` | string | `"180s"` | Maximum time to wait for ArgoCD sync + health check |

### Chart Definition

```json
"charts": {
  "{chart_key}": {
    "display_name": "Human-readable name",
    "chart_name": "vmo2-ims-mtas",
    "chart_version": "1.1.0",
    "deploy_order": 6,
    "sync_wave": "-4",
    "type": "helm",
    "namespace": "ims-mtas",
    "values_path": "mtas/mtas",
    "depends_on": ["cmsplatform"],
    "values": { ... }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `chart_name` | string | Helm chart name in Nexus |
| `chart_version` | string | Chart version — becomes `targetRevision` in ArgoCD Application YAML |
| `deploy_order` | integer | Global ordering across all charts (unique) |
| `sync_wave` | string | ArgoCD sync-wave annotation for intra-batch ordering |
| `type` | enum | `helm` (standard) or `multi_instance` (same chart deployed N times) |
| `namespace` | string | **Authoritative** target K8s namespace for this chart's ArgoCD Application destination. This is the namespace used in the generated Application YAML. Component-level namespace in the schema is informational (may differ for multi-chart components where sub-charts deploy to the same namespace) |
| `values_path` | string | Path in GitOps repo: `environments/{env}/values/{values_path}/values.yaml` |
| `depends_on` | array | Intra-component chart ordering (e.g., cmsplatform before cmsnfv) |
| `values` | object | **Fully resolved** Helm values — written as YAML to GitOps repo. No placeholders |

### Multi-Instance Charts

For `type: "multi_instance"`, an `instances` object defines per-instance configuration:

```json
"instances": {
  "crdldb-mtas": {
    "namespace": "ims-crdl",
    "values_path": "crdl/crdldb-mtas",
    "values": {
      "instanceName": "mtas",
      "replicaCount": 1
    }
  },
  "crdldb-ftas": { ... },
  "crdldb-imc": { ... }
}
```

Each instance becomes a separate ArgoCD Application, referencing the same Nexus chart but with its own `values.yaml`.

---

## 7.6 Status Enums

### Deployment Status

| Status | Condition |
|--------|-----------|
| `pending` | Created but orchestration not started |
| `in_progress` | At least one component being deployed |
| `pending_approval` | Deployment paused at an approval gate — waiting for operator to approve via PUT /approve |
| `success` | All components healthy — this deployment becomes the last known-good state |
| `failed` | Any component unhealthy, auto-rollback not enabled or also failed |
| `rolled_back` | Auto-rollback triggered and completed |
| `cancelled` | Manually cancelled by operator |

### Component Status

| Status | Meaning |
|--------|---------|
| `pending` | Not yet processed |
| `in_progress` | Generating config / committing / syncing |
| `synced` | ArgoCD sync complete, health check pending |
| `healthy` | All health checks passed (pods Ready, services have endpoints) |
| `unhealthy` | Health checks failed (see error details in health_report) |
| `rolled_back` | Reverted to previous commit |
| `skipped` | Values unchanged — no commit needed |

### Component Status Aggregation

Component status is derived from its charts:

| Condition | Derived Status |
|-----------|---------------|
| All charts `healthy` | Component `healthy` |
| Any chart `in_progress` or `synced` | Component `in_progress` |
| Any chart `unhealthy` (none in_progress) | Component `unhealthy` |
| All charts `pending` | Component `pending` |
| All charts `rolled_back` | Component `rolled_back` |

### Deployment Status Derivation

| Condition | Derived Status |
|-----------|---------------|
| All components `healthy` | Deployment `success` |
| Any component `in_progress` | Deployment `in_progress` |
| Any component `unhealthy` (no auto-rollback) | Deployment `failed` |
| Auto-rollback completed | Deployment `rolled_back` |

---

## 7.7 Status Lifecycle

```
Deployment:
  pending → in_progress → pending_approval → in_progress (resumed) → success
                       → failed → rolled_back
                       → cancelled

Component:
  pending → in_progress → synced → healthy
                                 → unhealthy → rolled_back
                       → skipped
```

---

## 7.8 Runtime State

The runtime block is updated throughout the deployment lifecycle. The frontend polls this for live progress.

```json
{
  "runtime": {
    "deployed": ["cms", "imc"],
    "current": "mtas",
    "pending_approval": false,
    "component_results": {
      "cms": {
        "status": "healthy",
        "commit_sha": "abc123",
        "version": "14.15A",
        "deployed_at": "2026-03-31T10:35:00Z",
        "health_report": {
          "pods_ready": "4/4",
          "services_with_endpoints": "2/2",
          "errors": []
        }
      },
      "imc": {
        "status": "healthy",
        "commit_sha": "def456",
        "version": "11.0.29",
        "deployed_at": "2026-03-31T10:42:00Z",
        "health_report": {
          "pods_ready": "6/6",
          "services_with_endpoints": "3/3",
          "errors": []
        }
      },
      "mtas": {
        "status": "in_progress"
      }
    }
  }
}
```

| Field | Purpose |
|-------|---------|
| `deployed[]` | Components successfully deployed so far. Used for resume-after-failure |
| `current` | Component currently being processed |
| `pending_approval` | `true` when deployment is paused at an approval gate |
| `component_results.{key}.commit_sha` | Git SHA — needed for rollback (`git revert <sha>`) |
| `component_results.{key}.health_report` | Pod/service health at deployment time |
| `component_results.{key}.errors` | ArgoCD resource-tree error messages (image pull, crash, PVC issues) |

---

## 7.9 Deployment Lock

Only one deployment per (environment, NF) at a time.

| Endpoint | Purpose |
|----------|---------|
| `GET /api/v1/deployments?nf={nf}&environment={env}&status=in_progress` | Check if lock exists |
| `POST /api/v1/deployments` | Automatically acquires lock (creates `in_progress` record) |
| Completion (any status) | Automatically releases lock (updates record to final status) |

If a deployment is already `in_progress` for the same (environment, NF), the API returns an error with the existing `deployment_id` and `helix_id`.

Safety net: if a deployment has been `in_progress` for more than 4 hours, consider it stuck. Alert and allow override.

---

## 7.10 Diff Response

Preview what would change before committing:

```json
{
  "component": "platform/server",
  "version": "2.0.0",
  "would_change": [
    "environments/dev/values/platform/server/values.yaml"
  ],
  "diff": "--- a/values.yaml\n+++ b/values.yaml\n@@ -1,2 +1,2 @@\n-version: 1.0.0\n+version: 2.0.0",
  "commit_message": "platform/server: Deploy v2.0.0 - HELIX-12345",
  "committed": false
}
```

Used by the dry-run endpoint and before actual deployments for operator review.

---

## 7.11 Schema Files

| File | Purpose |
|------|---------|
| `docs/api/api-response-schema.json` | JSON Schema (draft-07) — formal validation of the deployment payload |
| `docs/api/api-response-example.json` | Real-world mid-deployment example with CMS, IMC, CRDL — shows resolved values |
| `docs/api/API-Data-Model.md` | Human-readable API documentation (original) |

The schema is the contract between the values generation system and the orchestrator. Both teams must agree on changes. The orchestrator validates incoming payloads against this schema before processing.

---

## 7.12 OpenAPI Specification

The orchestrator API should auto-generate an OpenAPI 3.0 specification from its models. The frontend team imports this spec to generate a typed API client:

```
Orchestrator API → /openapi.json → Frontend team runs code generator → TypeScript client
```

The auto-generated spec ensures the frontend client stays in sync with the API — no manual documentation to maintain.

---

## 7.13 Notifications

The orchestrator emits notifications at key lifecycle events. The notification mechanism is pluggable — implementations may use webhooks, message queues, or direct API calls depending on the consuming system.

| Event | When | Payload |
|-------|------|---------|
| `deployment.started` | Orchestration begins | `deployment_id`, `helix_id`, `nf`, `environment` |
| `deployment.completed` | All components healthy | `deployment_id`, `status: success`, component summary |
| `deployment.failed` | Any component unhealthy (no auto-rollback) | `deployment_id`, `status: failed`, failed component, error |
| `deployment.rolled_back` | Auto-rollback completed | `deployment_id`, `status: rolled_back`, component, revert SHA |
| `approval.required` | Deployment paused at gate | `deployment_id`, `component`, `approval_message` |
| `component.healthy` | Component passes health check | `deployment_id`, `component`, `version`, `health_report` |
| `component.unhealthy` | Component fails health check | `deployment_id`, `component`, `error`, `resource_tree` |

**Initial implementation:** Log-based — all events written to structured logs (JSON) with correlation via `deployment_id` and `helix_id`. Consuming systems query logs or subscribe to log streams.

**Future:** Webhook subscriptions (`POST /api/v1/webhooks`) where external systems register callback URLs for specific event types. See Section 9 (Future Roadmap) for details.

---

*Previous: [Section 6b — Developer Requirements](06b-developer-requirements.md) | Next: [Section 8 — Standards Alignment](08-standards-alignment.md)*
