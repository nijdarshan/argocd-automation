# 5a. Values Resolution Pipeline

> **Audience:** Developers building the values resolution system — the process that transforms templates into deployment-ready payloads.
> **What this section covers:** How the app-config template, CIQ blueprint, IP allocations, environment configuration, and user edits are combined into the fully populated deployment payload that the orchestrator consumes.
> **Prerequisite:** Section 5 (Data Models & Template System) — documents the app-config template structure, the 24 support functions, and the placeholder syntax.
> **Downstream consumer:** Section 6 (Deployment Orchestration) — receive the output of this pipeline.

---

## 5a.1. Why This Pipeline Exists

The deployment orchestrator (Section 6) expects a **fully populated payload** — every value resolved, every placeholder replaced with a concrete value, user_editable and non_editable merged into a single `values` object per chart. The orchestrator writes these values as YAML to the GitOps repo and syncs via ArgoCD. It does not know about templates, blueprints, or support functions.

Something needs to sit between the raw template (which has `{{ placeholder }}` syntax) and the orchestrator (which needs concrete values). That something is the **values resolution pipeline**.

```
Raw App-Config Template                    Fully Populated Deployment Payload
(placeholders, split into                  (concrete values, one merged object
 user_editable / non_editable)              per chart, ready for orchestrator)
                │                                        │
                │         VALUES RESOLUTION              │
                │            PIPELINE                    │
                └───────────── ▶ ────────────────────────┘
                          THIS SECTION
```

---

## 5a.2. Input Sources

The resolution pipeline pulls data from five sources. Each source contributes different categories of values.

### 5a.2.1 App-Config Template

**What it is:** The static blueprint that defines what to deploy for a specific NF. Created during vendor onboarding (Section 2). One template per NF (e.g., `ims-config-prod.json`).

**What it contributes:**
- Chart metadata: `chart_name`, `chart_version`, `deploy_order`, `sync_wave`, `type`
- Chart patterns: which charts are umbrella (A), multi-chart sequential (B), multi-instance (C)
- Deployment config: `manual_approval`, `auto_rollback`, `sync_policy`, `strategy`, `sync_timeout`
- Field classification: which values are `user_editable` (operators can change) vs `non_editable` (system-controlled)
- Placeholder locations: which fields in `non_editable` contain `{{ function | arg1 | arg2 }}` patterns
- Helm values hierarchy: the nested JSON structure that mirrors the chart's `values.yaml`

**The template is chart-structure-aware.** It knows the Helm chart's values hierarchy because it was created by analysing the vendor's chart during onboarding. Each field in `user_editable` and `non_editable` maps to a specific field in the chart's `values.yaml`.

### 5a.2.2 CIQ Blueprint

**What it is:** The infrastructure design document. Defines all networks, traffic types, interface assignments, and pod sizing per environment. Created during network design (Section 4). One blueprint per site.

**What it contributes:**
- Network definitions: network names, IP counts, subnet sizes, traffic types
- Interface assignments: macvlan vs SRIOV, bond interfaces, NIC names
- VIP/PIP requirements: which traffic types need Virtual IPs or Physical IPs
- Consumer mappings: which sub-chart components use which network
- Pod sizing: replica counts, CPU, memory, storage per component per environment

**Example:** The placeholder `{{ replicas | MTAS | SM }}` resolves against the CIQ blueprint's pod sizing section to get the replica count for the SM sub-chart of MTAS in the target environment.

### 5a.2.3 IP Blueprint (Infoblox Allocations)

**What it is:** The actual IP addresses, VLANs, subnets, and gateways allocated by the network team in Infoblox. Retrieved via Infoblox API using tags (Section 4.7).

**What it contributes:**
- IP ranges: actual start-end ranges per network per pod type
- VIPs: Virtual IP addresses per network
- PIPs: Physical IP addresses for SRIOV/DPDK interfaces
- VLANs: VLAN IDs per network segment per site
- Gateways: default gateway IP per subnet
- Subnet prefixes: CIDR prefix lengths

**Example:** The placeholder `{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}` resolves against the IP blueprint to get `"172.16.50.2-172.16.50.4/26"` — the actual allocated IP range for the SM sub-chart on the EMX-Signalling-MTAS network.

### 5a.2.4 Environment Configuration

**What it is:** Environment-specific settings that differ between production, pre-production, and R&D. Not specific to any vendor or NF — these are platform-level decisions.

**What it contributes:**

| Category | Non-Prod | Production |
|----------|----------|------------|
| **Image registry** | Low-trust harbor/quay URL | Trusted production quay URL |
| **Pull secrets** | Dev pull secret name | Production pull secret name |
| **Storage class** | Standard/default | High-performance SSD |
| **Resource profiles** | Reduced (10% of prod sizing) | Full production sizing |
| **Log level** | DEBUG | INFO |
| **Security policy** | Relaxed | Strict |
| **Feature flags** | May have debug features enabled | Production-only features |
| **Replicas** | Minimum viable (1-2) | Full HA (sizing formula from CIQ) |

**Example:** The placeholder `{{ image_registry | MTAS | env }}` resolves to `quay-dev.vmo2.internal/vmo2-ims` in non-prod, or `quay.vmo2.internal/vmo2-ims` in production.

### 5a.2.5 User Edits (MRF Portal)

**What it is:** Values that operators modify through the MRF Portal (Hub UI). These are the `user_editable` fields from the app-config template.

**What it contributes:**
- Application-specific configuration: feature flags, VNF_TYPE, cloud profile
- Operational settings: log levels (if editable), timeouts, buffer sizes
- Enable/disable toggles: `global.secrets`, `enableNetworkPolicy`

**What it does NOT contribute:**
- Replicas (non_editable — drives IP allocation)
- IP addresses, VLANs, gateways (non_editable — from Infoblox)
- Image references (non_editable — from environment config)
- Resource limits (non_editable — from CIQ sizing)
- Namespace, storage class, pull secrets (non_editable — platform-controlled)

**Rule of thumb from Section 5:** If changing a value would break IP allocation, replica consistency, cluster sizing, or network connectivity → it's `non_editable` and comes from the blueprint, not the user.

---

## 5a.3. Resolution Process

The pipeline executes in a specific order. Each step depends on the output of the previous step.

### Step 1: Load Template

Read the app-config template for the target NF:

```
Input:  ims-config-prod.json
Output: Template object with components, charts, helm_values (user_editable + non_editable with placeholders)
```

The template defines the **structure** — which fields exist, which charts are involved, the Helm values hierarchy. At this stage, `non_editable` fields contain placeholder strings like `{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}`.

### Step 2: Load Data Sources

Fetch all data needed for resolution:

```
CIQ Blueprint:     ciq_blueprint.json (networks, pod sizing)
IP Blueprint:      Retrieved from Infoblox API via tags (app=ims, env=prod, site=slough)
Environment Config: Platform configuration for target environment
User Edits:        From MRF Portal / Hub DB (operator's saved values)
```

### Step 3: Build Resolution Context

Combine data sources into a resolution context that the support functions can query:

```json
{
  "dc_name": "slough",
  "env": "prod",
  "tenant": "IMS",
  "networks": { ... from CIQ blueprint ... },
  "ip_allocations": { ... from Infoblox ... },
  "pod_sizing": { ... from CIQ blueprint ... },
  "environment_config": {
    "image_registry": "quay.vmo2.internal/vmo2-ims",
    "pull_secret": "mav-reg",
    "storage_class": "ocs-storagecluster-ceph-rbd",
    "sizing_multiplier": 1.0
  }
}
```

### Step 4: Resolve Placeholders

For each chart in the template, process every `non_editable` field:

1. Find all `{{ function | arg1 | arg2 }}` patterns via regex
2. For each placeholder:
   a. Parse the function name and arguments
   b. Look up the function (one of 24 support functions — see Section 5.8)
   c. Execute the function with the arguments against the resolution context
   d. Replace the placeholder string with the resolved value
3. Preserve types: `replicas` resolves to an integer, `cpu_limit` to a string, `vip_array` to an array

**Resolution example:**

```
Template:     "{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}"
Function:     whereabouts_range_end
Arguments:    network_name = "EMX-Signalling-MTAS", pod_name = "SM"
Data source:  CIQ blueprint network definitions + IP blueprint allocations
Result:       "172.16.50.2-172.16.50.4/26"
Type:         string
```

**All 24 functions and their data sources are documented in Section 5.8.**

### Step 5: Merge user_editable + non_editable

For each chart, deep-merge the two objects into a single `values` object:

```
user_editable (from user edits):
{
  "global": { "secrets": false },
  "sm": { "extra_user_data": { "config": { "VNF_TYPE": "AGW" } } }
}

non_editable (resolved, from step 4):
{
  "global": { "namespace": { "name": "ims-agw-slough" } },
  "sm": { "replicas": 3, "image": "quay.vmo2.internal/vmo2-ims/mtas-sm:24.3.0" }
}

Merged values (non_editable wins on conflict):
{
  "global": {
    "secrets": false,
    "namespace": { "name": "ims-agw-slough" }
  },
  "sm": {
    "replicas": 3,
    "image": "quay.vmo2.internal/vmo2-ims/mtas-sm:24.3.0",
    "extra_user_data": { "config": { "VNF_TYPE": "AGW" } }
  }
}
```

**Merge rule:** Deep merge by key. If the same key exists in both `user_editable` and `non_editable`, `non_editable` wins. This prevents users from accidentally overriding system-controlled values like replicas or IP ranges.

### Step 6: Expand Multi-Instance Charts

For `type: "multi_instance"` charts (e.g., CRDL), the base `values` is deep-merged with each instance's `values_overrides`:

```
Base values (from step 5): { "replicaCount": 1, "image": "crdldb:6.2.0" }

Instance "crdldb-mtas" overrides: { "instanceName": "mtas", "maxMemory": "128mb" }
Instance "crdldb-ftas" overrides: { "instanceName": "ftas", "maxMemory": "64mb" }

Result:
  crdldb-mtas values: { "replicaCount": 1, "image": "crdldb:6.2.0", "instanceName": "mtas", "maxMemory": "128mb" }
  crdldb-ftas values: { "replicaCount": 1, "image": "crdldb:6.2.0", "instanceName": "ftas", "maxMemory": "64mb" }
```

### Step 7: Assemble Final Payload

Combine all resolved components into the deployment payload structure:

```json
{
  "deployment_id": "deploy-2026-03-31-001",
  "helix_id": "HELIX-12345",
  "action": "deploy",
  "environment": "prod",
  "nf": "ims",
  "is_bootstrap": false,
  "defaults": { ... },
  "deployment_order": [ ... ],
  "components": {
    "mtas": {
      "deployment_config": { ... },
      "charts": {
        "mtas": {
          "chart_name": "vmo2-ims-mtas",
          "chart_version": "1.1.0",
          "namespace": "ims-mtas",
          "values_path": "mtas/mtas",
          "values": {
            ... fully merged, fully resolved values ...
          }
        }
      }
    }
  }
}
```

**No placeholders remain.** Every `{{ ... }}` has been replaced with a concrete value. The `values` object is a flat merge of user_editable + non_editable. The payload is ready for the deployment orchestrator.

### Step 8: Store and Serve

Store the resolved payload in the Hub database, accessible via API:

```
POST /api/v1/deployments
Body: { helix_id, action, environment, nf }
Response: { deployment_id, status: "pending" }

Hub resolves the payload (steps 1-7), stores it, returns deployment_id.

GET /api/v1/deployments/{deployment_id}/payload
Response: The fully resolved payload
```

The deployment orchestrator calls `GET /payload` to retrieve the resolved payload and begins the deployment flow (Section 6).

---

## 5a.4. Chart-Structure Awareness

The resolution system must understand the Helm chart's values hierarchy to correctly:

1. **Present fields to users in the portal** — the user sees a form with the `user_editable` fields structured in the chart's hierarchy, not a flat list
2. **Validate user edits** — if a user enters a string where an integer is expected, catch it before resolution
3. **Generate correct YAML** — the merged `values` object must match the chart's expected structure exactly, or Helm rendering fails

### How the Template Captures Chart Structure

During vendor onboarding (Section 2), the automation team:

1. Takes the vendor's Helm chart `values.yaml`
2. Converts the YAML structure to JSON (1:1 mapping, lossless)
3. Classifies each field as `user_editable` or `non_editable`
4. Replaces non_editable values with support function placeholders
5. Stores the result in the app-config template

The template's `helm_values` structure is identical to the chart's `values.yaml` structure at all times:

```
Chart values.yaml (Helm)  →  converted to  →  Template (JSON with placeholders)
                              identical structure
```

This means the resolution system can:
- Show users the exact hierarchy they'd see in the chart's values.yaml
- Validate that resolved values are in the right location in the hierarchy
- Generate YAML that the chart's templates can consume without errors

### Three Chart Patterns

The resolution system handles each pattern differently:

| Pattern | Template Structure | Resolution Output |
|---------|-------------------|-------------------|
| **A: Umbrella** | One `helm_values` block with sub-chart sections | One `values` object (sub-charts controlled via `enabled` flags) |
| **B: Multi-chart sequential** | Multiple chart entries under one component, each with its own `helm_values` | One `values` object per chart |
| **C: Multi-instance** | One base `helm_values` + per-instance `values_overrides` | One `values` object per instance (base merged with overrides) |

---

## 5a.5. Resolution Failures

When a placeholder cannot be resolved, the pipeline must fail clearly — not silently produce an empty or wrong value.

| Failure | Cause | Expected Behaviour |
|---------|-------|-------------------|
| Unknown function name | Typo in template: `{{ unknwon_func \| ... }}` | Fail with: `"Unknown function 'unknwon_func' in chart 'mtas'"` |
| Wrong argument count | `{{ replicas \| MTAS }}` (missing pod_name) | Fail with: `"Function 'replicas' expects 2 args, got 1"` |
| Network not in blueprint | `{{ vlan \| NonExistent-Network \| SM }}` | Fail with: `"Network 'NonExistent-Network' not found in CIQ blueprint"` |
| IP not allocated | Network exists but Infoblox has no allocation | Fail with: `"No IP allocation for network 'EMX-Signalling-MTAS' in site 'slough'"` |
| Type mismatch | Function returns string but chart expects integer | Fail with: `"replicas resolved to '3' (string) but chart expects integer"` |
| Environment config missing | No registry URL for target environment | Fail with: `"No image_registry configured for environment 'prod'"` |

**Resolution failures must block the deployment.** An unresolved or wrongly-resolved placeholder in `values.yaml` causes Helm rendering errors or, worse, a deployment with wrong IPs, wrong replicas, or missing resources.

---

## 5a.6. Output Contract

The values resolution pipeline produces a payload that conforms to `docs/api/api-response-schema.json`. This schema is the **contract** between the resolution system and the deployment orchestrator.

### What the Orchestrator Expects

For each chart in the payload:

```json
{
  "chart_name": "vmo2-ims-mtas",
  "chart_version": "1.1.0",
  "type": "helm",
  "namespace": "ims-mtas",
  "values_path": "mtas/mtas",
  "values": {
    ... complete, merged, resolved values matching the chart's values.yaml hierarchy ...
  }
}
```

**The `values` object must be:**
- **Complete** — every field the chart needs is present (no missing keys)
- **Resolved** — no `{{ ... }}` placeholder strings remain
- **Merged** — user_editable and non_editable combined into one object
- **Correctly typed** — integers are integers, strings are strings, arrays are arrays
- **Structurally valid** — nested hierarchy matches the chart's expected `values.yaml` structure

### What the Orchestrator Does NOT Check

The orchestrator writes `values` as-is to YAML. It does not:
- Validate values against the chart schema
- Check that IP addresses are valid
- Verify replica counts are reasonable
- Confirm image references exist in the registry (that's the pre-validation stage — Section 6b Stage 2)

The resolution system is responsible for producing correct values. The orchestrator is responsible for deploying them.

---

## 5a.7. Portal Display

The MRF Portal (Hub UI) uses the template to show operators a form for editing values. The portal must:

### Show Chart Structure

Display `user_editable` fields in the correct Helm values hierarchy:

```
Global Settings
  ├── secrets: [toggle] false
  └── enableNetworkPolicy: [toggle] false

SM Configuration
  └── extra_user_data
      └── config
          ├── VNF_TYPE: [text] "AGW"
          └── CLOUD_PROFILE_ID: [text] "NFV30"
```

### Show Non-Editable as Read-Only

Display `non_editable` fields greyed out so operators can see the full picture but cannot change system-controlled values:

```
SM Configuration (read-only)
  ├── replicas: 3                          [locked — from CIQ sizing]
  ├── image: quay.vmo2.internal/...        [locked — from environment config]
  └── resources:
      ├── requests: cpu=4000m, memory=16G  [locked — from CIQ sizing]
      └── limits: cpu=4000m, memory=16G    [locked — from CIQ sizing]
```

### Show Per-Instance Values for Multi-Instance

For CRDL (Pattern C), show each instance with its overrides:

```
CRDL Instances
  ├── crdldb-mtas: instanceName=mtas, maxMemory=128mb  [editable per instance]
  ├── crdldb-ftas: instanceName=ftas, maxMemory=64mb
  └── crdldb-imc: instanceName=imc, maxMemory=64mb
```

### Diff Preview Before Deploy

Before the operator clicks Deploy, show a diff of what changed:

```
Changes to deploy:
  mtas/mtas/values.yaml:
    - version: "1.0.0"
    + version: "2.0.0"
    - sm.replicas: 3
    + sm.replicas: 5
```

This uses the dry-run capability of the deployment orchestrator (Section 6a, Section 13).

---

## 5a.8. Relationship to Deployment Orchestrator

```
┌──────────────────────────────────┐
│  VALUES RESOLUTION PIPELINE       │
│  (this section)                   │
│                                   │
│  Template + Blueprint + IPs +     │
│  Env Config + User Edits          │
│           │                       │
│           ▼                       │
│  Fully Populated Payload          │
│  (stored in Hub DB)               │
└──────────────┬───────────────────┘
               │
               │  GET /api/v1/deployments/{id}/payload
               │
               ▼
┌──────────────────────────────────┐
│  DEPLOYMENT ORCHESTRATOR          │
│  (Section 6)                  │
│                                   │
│  1. Read payload                  │
│  2. Write values.yaml to Git      │
│  3. Write Application YAMLs       │
│  4. Per-component commits         │
│  5. ArgoCD sync via API           │
│  6. Watch health                  │
│  7. Record state                  │
└──────────────────────────────────┘
```

The values resolution pipeline and the deployment orchestrator are **separate systems with a clear API boundary.** The payload schema (`docs/api/api-response-schema.json`) is the contract. Either side can be rewritten independently as long as the schema is maintained.

---

*Previous: [Section 5 — Data Models & Template System](05-data-models-templates.md) | Next: [Section 6 — Deployment & Rollback](06-deployment-rollback.md)*
