# 5. Data Models & Template System

> **Audience:** Platform engineers working on the app-config templates, support functions, and portal resolution logic.
> **Source docs:** template/App-Config-Data-Model.md, template/Support-Functions-Guide_v1.1.md, template/dev-message-nested-json.md, ims-config-prod.json
> **Key files:** `ims-config-prod.json` (IMS template), `ciq_blueprint.json` (infrastructure blueprint)

---

## 5.1 Two Core Data Models

The template system has two data models that work together:

| Model | File | What It Contains | Who Edits It |
|-------|------|-----------------|-------------|
| **App-Config** | `ims-config-prod.json` | Chart metadata, deployment ordering, Helm values with placeholders, orchestration config | Automation team (onboarding) |
| **CIQ Blueprint** | `ciq_blueprint.json` | Network segments, IP counts, pod sizing, VLAN/subnet/gateway data per site | Automation team + network team |

```
App-Config Template                CIQ Blueprint
(what to deploy)                   (infrastructure design)
┌──────────────────┐              ┌───────────────────┐
│ Chart metadata   │              │ Networks (54)     │
│ Deployment order │              │ Traffic types     │
│ Helm values with │──resolves──► │ Pod sizing        │
│ {{ placeholders}}│  against     │ VLANs, subnets    │
│ Orchestration    │              │ Per-environment   │
└──────────────────┘              └───────────────────┘
         │                                 │
         └────────── merge ────────────────┘
                      │
                      ▼
              Resolved values.yaml
              (ready for deployment)
```

**Separation principle:** The app-config defines *what* to deploy (chart structure, values hierarchy, deployment order). The blueprint defines *where* and *how much* (IPs, VLANs, replicas, sizing). Placeholders in the app-config are resolved against the blueprint at deployment time.

---

## 5.2 App-Config Schema Structure

Defined in `app-config-schema.json` (JSON Schema draft-07).

```
root
 ├── metadata
 │    ├── nf, vendor, platform, schema_version
 │    ├── total_components, total_charts
 │    └── created, last_updated
 │
 ├── defaults
 │    ├── helm_registry, image_registry, pull_secret
 │    ├── storage_class, service_account_prefix, node_selector
 │    └── gitops_repo, gitops_branch, argocd_project, argocd_app_of_apps
 │
 ├── deployment_order[]
 │    └── { component, batch }
 │
 └── components{}
      └── [component_key]
           ├── display_name, namespace, description
           ├── deployment_config
           │    ├── manual_approval, approval_message
           │    ├── health_check { type, timeout, custom_script }
           │    ├── auto_rollback
           │    └── sync_timeout
           ├── depends_on[]
           ├── charts{}
           │    └── [chart_key]
           │         ├── chart_name, chart_version
           │         ├── deploy_order, sync_wave, type
           │         ├── sub_charts{}    (Pattern A only)
           │         ├── instances{}     (Pattern C only)
           │         ├── depends_on[]    (intra-component ordering)
           │         └── helm_values
           │              ├── user_editable{}  (nested JSON)
           │              └── non_editable{}   (nested JSON + placeholders)
           ├── images{}
           └── secrets{}
```

### Key Design Rules

- **Chart = atomic ArgoCD unit.** Each chart entry → one ArgoCD Application + one `values.yaml`
- **Component = atomic deployment/rollback unit.** All charts in a component are committed in one git commit. Rollback reverts the entire component
- **Nested JSON for helm_values.** Both `user_editable` and `non_editable` use nested JSON that mirrors the Helm `values.yaml` hierarchy exactly. At deployment time they are deep-merged by key (`non_editable` wins on conflict)
- **Two-level ordering.** `deployment_order` at root defines component sequence and batch groups. `deploy_order` per chart defines global chart ordering
- **Batch groups.** Components with the same `batch` number deploy in parallel. Each still gets its own commit and ArgoCD sync
- **Inheritance.** Charts inherit `helm_registry`, `image_registry` from `defaults`. Override per-chart only when different

---

## 5.3 Three Chart Patterns

Every vendor chart must fit one of three patterns (covered in detail in Section 2.4). Here's how they appear in app-config:

### Pattern A: Single Umbrella

```json
{
  "mtas": {
    "charts": {
      "mtas": {
        "chart_name": "vmo2-ims-mtas",
        "chart_version": "1.1.0",
        "type": "umbrella",
        "sub_charts": {
          "tas": { "enabled": true },
          "vlbfe": { "enabled": true },
          "sipre": { "enabled": true },
          "diamre": { "enabled": true },
          "sm": { "enabled": true }
        },
        "helm_values": { ... }
      }
    }
  }
}
```

One chart → one ArgoCD app → `ims-mtas`. Sub-charts toggled via `enabled` flags.

### Pattern B: Multi-Chart Sequential

```json
{
  "cms": {
    "charts": {
      "cmsplatform": {
        "chart_name": "vmo2-ims-cmsplatform",
        "chart_version": "9.0.14.15-v5",
        "type": "standalone",
        "deploy_order": 1,
        "sync_wave": -5,
        "helm_values": { ... }
      },
      "cmsnfv": {
        "chart_name": "vmo2-ims-cmsnfv",
        "chart_version": "9.0.14.15-v6",
        "type": "standalone",
        "deploy_order": 2,
        "depends_on": ["cmsplatform"],
        "sync_wave": -4,
        "helm_values": { ... }
      }
    }
  }
}
```

Two charts → two ArgoCD apps → `ims-cmsplatform`, `ims-cmsnfv`. Ordering via `depends_on` + `deploy_order`.

### Pattern C: Multi-Instance

```json
{
  "crdl": {
    "charts": {
      "crdladmin": {
        "chart_name": "vmo2-ims-crdladmin",
        "type": "standalone",
        "helm_values": { ... }
      },
      "crdldb": {
        "chart_name": "vmo2-ims-crdldb",
        "type": "multi_instance",
        "instances": {
          "crdldb-mtas": { "helm_values": { ... } },
          "crdldb-ftas": { "helm_values": { ... } },
          "crdldb-imc": { "helm_values": { ... } }
        }
      }
    }
  }
}
```

One chart template → N ArgoCD apps → `ims-crdldb-mtas`, `ims-crdldb-ftas`, etc. Adding a new instance = adding an entry to `instances`, not republishing the chart.

### ArgoCD Mapping (Full IMS)

```
Component    chart_key        type             ArgoCD app(s)
─────────    ─────────        ────             ─────────────
cms          cmsplatform      umbrella         ims-cmsplatform
             cmsnfv           standalone       ims-cmsnfv
imc          imc              umbrella         ims-imc
mtas         mtas             umbrella         ims-mtas
ftas         ftas             umbrella         ims-ftas
agw          agw              umbrella         ims-agw
enumfe       enumfe           umbrella         ims-enumfe
muag         muag             umbrella         ims-muag
fuag         fuag             umbrella         ims-fuag
sceas        sceas            umbrella         ims-sceas
lrf          lrf              umbrella         ims-lrf
crdl         crdladmin        standalone       ims-crdladmin
             crdldb           multi_instance   ims-crdldb-mtas
                                               ims-crdldb-ftas
                                               ims-crdldb-imc
                                               ims-crdldb-enumfe
                                               ... (10 instances)
cbf          cbf              umbrella         ims-cbf
lixp         lixp             umbrella         ims-lixp
mrf          dmrf_preinstall  standalone       ims-dmrf-preinstall
             dmrf             standalone       ims-dmrf
```

14 components, 17 charts, ~27 ArgoCD Applications.

---

## 5.4 Deployment Ordering

### Batch System

Components are grouped into batches. Batches execute sequentially; components within a batch deploy in parallel.

```json
{
  "deployment_order": [
    { "component": "cms",    "batch": 1 },
    { "component": "imc",    "batch": 2 },
    { "component": "mtas",   "batch": 3 },
    { "component": "ftas",   "batch": 3 },
    { "component": "agw",    "batch": 4 },
    { "component": "enumfe", "batch": 4 },
    { "component": "sceas",  "batch": 5 },
    { "component": "lrf",    "batch": 5 },
    { "component": "muag",   "batch": 6 },
    { "component": "fuag",   "batch": 6 },
    { "component": "crdl",   "batch": 7 },
    { "component": "cbf",    "batch": 8 },
    { "component": "lixp",   "batch": 8 },
    { "component": "mrf",    "batch": 9 }
  ]
}
```

**IMS deployment order visualized:**
```
Batch 1: CMS ─────────────────────────────────────────────► (manual approval)
Batch 2: IMC ─────────────────────────────────────────────►
Batch 3: MTAS ──────┐ parallel ┌──────────────────────────►
         FTAS ──────┘          └──────────────────────────►
Batch 4: AGW ───────┐ parallel ┌──────────────────────────►
         ENUMFE ────┘          └──────────────────────────►
Batch 5: SCEAS ─────┐ parallel ┌──────────────────────────►
         LRF ───────┘          └──────────────────────────►
Batch 6: MUAG ──────┐ parallel ┌──────────────────────────►
         FUAG ──────┘          └──────────────────────────►
Batch 7: CRDL ────────────────────────────────────────────►
Batch 8: CBF ───────┐ parallel ┌──────────────────────────►
         LIXP ──────┘          └──────────────────────────►
Batch 9: MRF ─────────────────────────────────────────────►
```

### Intra-Component Ordering

Within a component, charts are ordered by `deploy_order` and `depends_on`:

- CMS: `cmsplatform` (deploy_order 1, sync_wave -5) → `cmsnfv` (deploy_order 2, sync_wave -4, depends_on: cmsplatform)
- MRF: `dmrf_preinstall` → `dmrf`

### Sync Waves

ArgoCD sync-waves control ordering within a single sync operation. Lower values deploy first. Used for intra-component chart ordering:

| Component | Chart | sync_wave |
|-----------|-------|-----------|
| CMS | cmsplatform | -5 |
| CMS | cmsnfv | -4 |

---

## 5.5 Deployment Config

Lives at the component level. Controls how the Hub orchestrates each component.

```json
{
  "deployment_config": {
    "manual_approval": true,
    "approval_message": "CMS deployed. Verify replication before proceeding.",
    "health_check": {
      "type": "pod_readiness",
      "timeout": "15m",
      "custom_script": null
    },
    "auto_rollback": false,
    "sync_timeout": "20m"
  }
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `manual_approval` | boolean | `false` | Hub pauses after this component is healthy, waits for user approval |
| `approval_message` | string | `""` | Shown in Hub UI when awaiting approval |
| `health_check.type` | enum | `"pod_readiness"` | `pod_readiness` or `custom` |
| `health_check.timeout` | string | `"10m"` | Max wait for health checks to pass |
| `health_check.custom_script` | string/null | `null` | Script path for custom checks |
| `auto_rollback` | boolean | `false` | Auto-trigger rollback if health check fails |
| `sync_timeout` | string | `"180s"` | Max wait for ArgoCD sync |

---

## 5.6 Helm Values: user_editable vs non_editable

Every chart has two value objects that are deep-merged at deployment time.

### non_editable (Locked)

Values that affect infrastructure, sizing, or network design. Users cannot change these. Contains placeholders resolved from the blueprint.

**Rule of thumb:** If changing it would break IP allocation, replica consistency, cluster sizing, or network connectivity → **non_editable**.

| Category | Fields | Why Locked |
|----------|--------|------------|
| **Replicas** | `replicas` for any pod | Replicas drive IP count. Changing without updating IP allocation breaks deployment |
| **IPs & ranges** | `ipam.range`, `ipamsubnet`, `ipam_range_*`, `networking.ipPools[].addresses` | Allocated by Infoblox IPAM |
| **Network metadata** | `vlan`, `gateway`, `prefix`, `master` | From network design |
| **Platform** | `namespace`, `image_registry`, `pull_secret`, `storage_class`, `image` | Set by portal from context |
| **Resource limits** | `resources.limits`, `resources.requests` | Part of cluster sizing |
| **SRIOV** | `sriov_pool`, `pci_env` | Tied to hardware and network design |

### user_editable (Unlocked)

Values that don't affect infrastructure. Users can tune these in the portal.

- Application-specific config (feature flags, log levels, VNF_TYPE)
- Environment variables not related to IPs, ports, or networks
- Timeouts, retry counts, buffer sizes

### Merge Behavior

```
user_editable + non_editable  →  deep-merge by key  →  final values.yaml
                                 (non_editable wins on conflict)
```

If the same key exists in both, `non_editable` wins — users cannot accidentally override locked fields.

### Why Nested JSON (Not Flat Dot-Path)

**Before (flat — discontinued):**
```json
{
  "global.secrets": false,
  "sm.resources.limits.cpu": "4000m"
}
```

**After (nested — current):**
```json
{
  "global": { "secrets": false },
  "sm": { "resources": { "limits": { "cpu": "4000m" } } }
}
```

**Why the change:**
- JSON structure is identical to YAML at every stage (YAML → JSON → resolved → YAML). No dot-path parsing needed
- Deep-merge by key is straightforward
- All parts of the Support Functions Guide already used nested JSON; the flat format was inconsistent

---

## 5.7 Placeholder System

### Syntax

```
{{ function_name | arg1 | arg2 }}
```

- **function_name**: The resolver to call
- **arg1**: Usually `network_name` (blueprint name, e.g., `EMX-Signalling-MTAS`)
- **arg2**: Usually `pod_name` (e.g., `SM`, `VLB`) or `component`

**Important:** Use blueprint network names (e.g., `EMX-Signalling-MTAS`), **not** YAML CNI names (e.g., `macvlan-tas-app-emx`).

### Portal Context (Injected at Resolution)

These are not in the placeholder — the portal injects them:

| Context | Example | Used By |
|---------|---------|---------|
| `dc_name` | `slough` | `namespace`, `storage_class`, `vlan`, `gateway`, `prefix` |
| `env` | `prod`, `preprod`, `rnd` | `image_registry`, `pull_secret` |
| `tenant` | `IMS` | `pull_secret` |

### Resolution Flow

1. Portal reads `helm_values.non_editable` for each chart
2. Finds all `{{ ... }}` patterns via regex: `\{\{\s*(\w+)\s*\|\s*([^|]+)\s*(?:\|\s*([^|]+))?\s*\}\}`
3. Resolves each using function + args + portal context + CIQ blueprint + IP JSON
4. Replaces placeholder with resolved value (preserving type: string, number, or array)
5. Deep-merges resolved `non_editable` with `user_editable`
6. Returns final JSON via API — no placeholders remain

---

## 5.8 Support Functions Reference (All 24)

### Whereabouts IPAM (5 functions)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `whereabouts_range_end` | network_name, pod_name | IP range `"start-end/mask"` | `"172.16.50.2-172.16.50.4/26"` |
| `whereabouts_range_cidr` | network_name | CIDR range | `"10.x.x.247/24"` |
| `ipam_subnet` | network_name | Subnet CIDR | `"10.69.96.0/24"` |
| `ipam_range_start` | network_name, pod_name | First IP in range | `"10.69.96.2"` |
| `ipam_range_end` | network_name, pod_name | Last IP in range | `"10.69.96.3"` |

**Used in:** `ipam.range`, `ipamsubnet`, `ipamrangestart`, `ipamrangeend`

### IP Pools (2 functions)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `vip_array` | network_name, pod_name | VIP addresses (array) | `["172.16.50.30"]` |
| `pip_array` | network_name, pod_name | Physical IPs for SRIOV (array, scales with replicas) | `["172.16.50.28","172.16.50.29"]` |

**Used in:** `networking.ipPools[].addresses`

### Network Metadata (3 functions)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `vlan` | network_name, pod_name | VLAN ID (integer) | `3200` |
| `gateway_str` | network_name, pod_name | Gateway IP (string) | `"10.69.96.1"` |
| `prefix` | network_name, pod_name | Subnet prefix length (integer) | `22` |

**Used in:** `master` (bond interface), `GATEWAY`, `PREFIX`

### SRIOV (2 functions)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `sriov_pool` | network_name, nic | SRIOV resource pool name | `sriov_dpdk_agw1_vlb_ens5f1_gre_tunnel` |
| `pci_env` | network_name, nic | PCI device env var name | `PCIDEVICE_OPENSHIFT_IO_SRIOV_DPDK_...` |

**Used in:** `resources.limits["openshift.io/<pool>"]`, VLB `env.fpeth*`

### Cross-Component (1 function)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `component_ips` | component, network_name | IP addresses of another component (array) | `["10.69.96.4","10.69.96.5"]` |

**Used in:** `sm.cmsIPAddresses` (MTAS needs CMS IPs on OAM network)

### Platform (5 functions)

| Function | Args | Returns | Example |
|----------|------|---------|---------|
| `namespace` | dc_name, nf_type | Namespace name | `"ims-mtas-slough"` |
| `image_registry` | nf_type, env | Registry URL | `"quay.vmo2.internal/ims"` |
| `pull_secret` | tenant, env | Pull secret name | `"mav-reg"` |
| `storage_class` | dc_name, nf_type | Storage class | `"ocs-storagecluster-ceph-rbd"` |
| `image` | pod_name, nf_type | Full image reference | `"quay.io/nokia/mtas-sm:24.3.0-123"` |

### Sizing (6 functions)

| Function | Args | Returns | Data Source |
|----------|------|---------|-------------|
| `replicas` | component, pod_name | Replica count (integer) | CIQ blueprint pod counts |
| `cpu_request` | component, pod_name | CPU request (string) | CIQ blueprint |
| `cpu_limit` | component, pod_name | CPU limit (string) | CIQ blueprint |
| `memory_request` | component, pod_name | Memory request (string) | CIQ blueprint |
| `memory_limit` | component, pod_name | Memory limit (string) | CIQ blueprint |
| `storage_size` | component, volume_name | Storage size (string) | CIQ blueprint |

### Combined Example

A realistic MTAS SM pod showing multiple function categories together:

**Template (with placeholders):**
```json
{
  "sm": {
    "replicas": "{{ replicas | MTAS | SM }}",
    "image": "{{ image | SM | MTAS }}",
    "resources": {
      "requests": {
        "cpu": "{{ cpu_request | MTAS | SM }}",
        "memory": "{{ memory_request | MTAS | SM }}"
      },
      "limits": {
        "cpu": "{{ cpu_limit | MTAS | SM }}",
        "memory": "{{ memory_limit | MTAS | SM }}"
      }
    },
    "cmsIPAddresses": "{{ component_ips | CMS | oam-External }}",
    "volumes": {
      "sm-storage": {
        "class": "{{ storage_class | dc_name | MTAS }}",
        "resources": {
          "requests": { "storage": "{{ storage_size | MTAS | sm-storage }}" }
        }
      }
    }
  }
}
```

**Resolved (for Slough prod, 40M subs):**
```json
{
  "sm": {
    "replicas": 3,
    "image": "quay.io/nokia/mtas-sm:24.3.0-123",
    "resources": {
      "requests": { "cpu": "4000m", "memory": "16G" },
      "limits": { "cpu": "4000m", "memory": "16G" }
    },
    "cmsIPAddresses": ["10.69.96.4", "10.69.96.5"],
    "volumes": {
      "sm-storage": {
        "class": "ocs-storagecluster-ceph-rbd",
        "resources": {
          "requests": { "storage": "31G" }
        }
      }
    }
  }
}
```

All values come from the CIQ blueprint — changing the site or environment resolves different values without touching the template.

---

## 5.9 Function Resolution Logic

Each function resolves against specific data sources:

| Function | Lookup Key | Data Source |
|----------|-----------|-------------|
| `whereabouts_range_end` | network_name, pod_name | `blueprint.rnd.network[]` + replica count |
| `vip_array`, `pip_array` | network_name, pod_name | IP JSON (from Infoblox / app onboarding) |
| `vlan`, `gateway_str`, `prefix` | network_name, dc_name | `blueprint.site.networks[]` |
| `namespace` | dc_name, nf_type | Constructed: `ims-{nf_type_lower}-{dc_name}` |
| `image_registry` | nf_type, env | Config: registry URL per env |
| `pull_secret` | tenant, env | Config: secret name per tenant/env |
| `component_ips` | component, network_name | IP JSON for that component on that network |
| `replicas`, `cpu_*`, `memory_*`, `storage_size` | component, pod_name/volume | CIQ blueprint pod/resource sizing |
| `sriov_pool`, `pci_env` | network_name, nic | Constructed from naming convention |

---

## 5.10 Validation Rules

Enforced by the onboarding portal when a blueprint is created or imported.

### Structural

| Rule | Error |
|------|-------|
| Every `deployment_order[].component` must exist in `components` | `Unknown component '{x}' in deployment_order` |
| Every component must appear exactly once in `deployment_order` | `Component '{x}' missing from deployment_order` |
| `deploy_order` must be unique across all charts in all components | `Duplicate deploy_order {n}` |
| `depends_on` (component-level) must reference existing components | `Unknown dependency '{x}'` |
| `depends_on` (chart-level) must reference charts within same component | `Chart dependency '{x}' not found in component '{y}'` |
| No circular dependencies | `Circular dependency detected: {cycle}` |

### Type-Consistency

| Rule | Error |
|------|-------|
| `type: "umbrella"` must have `sub_charts` | `Umbrella chart '{x}' missing sub_charts` |
| `type: "multi_instance"` must have `instances` | `Multi-instance chart '{x}' missing instances` |
| `type: "standalone"` must not have `sub_charts` or `instances` | `Standalone chart '{x}' has unexpected sub_charts/instances` |
| Every chart must have `chart_name` and `chart_version` | `Chart '{x}' missing required field '{f}'` |

### Batch Safety

| Rule | Error |
|------|-------|
| Same-batch components must not depend on each other | `Batch {n} conflict: '{a}' depends on '{b}' but both in batch {n}` |
| Components in batch N must not depend on batch M where M > N | `'{a}' (batch {n}) depends on '{b}' (batch {m}) which deploys later` |

### Placeholder

| Rule | Error |
|------|-------|
| All `{{ function | ... }}` must use a known function name | `Unknown placeholder function '{f}'` |
| Arg count must match function signature | `Function '{f}' expects {n} args, got {m}` |
| Network names in placeholders must exist in CIQ blueprint | `Unknown network '{n}' in placeholder` |

---

## 5.11 Known Inconsistencies

| Issue | Location | Resolution |
|-------|----------|------------|
| PIP format typo | AGW: `["<172.x.x.4","172.x.x.5>"]` | Output must be `["ip1","ip2"]` (no angle brackets) |
| FTAS uses CIDR-only range | `range: "<10.x.x.247/24>"` | Use `whereabouts_range_cidr` (single-arg) |
| CMS uses non-standard IPAM fields | `ipamsubnet`, `ipamrangestart`, `ipamrangeend` | Different from standard `ipam.range` — CMS-specific |
| ENUMFE pci_env casing | Lowercase `sriov_dpdk` | Normalize to expected `SRIOV_DPDK` format |

---

## 5.12 GitOps Repo Structure

For the generated GitOps repository structure after deployment, see Section 6b Section 5.1. The values resolution pipeline (Section 5a) produces the values files, and the deployment orchestrator (Section 6) writes them into this structure along with the ArgoCD Application YAMLs.


---

## 5.13 Payload Boundary

The app-config template system (this section) and the deployment orchestrator (Section 6) are **separate systems with a clear boundary:**

- **This section** defines the TEMPLATE — chart structure, placeholders, editable/non_editable classification
- **Section 5a** defines the RESOLUTION — how templates become fully populated payloads
- **Section 6** defines the DEPLOYMENT — how payloads become running workloads on the cluster

The deployment orchestrator receives a **fully populated payload** where all placeholders are resolved and user_editable + non_editable are merged. The orchestrator does not know about templates, support functions, or blueprints — it just writes the `values` object as YAML and syncs via ArgoCD.

The payload schema (`docs/api/api-response-schema.json`) is the **contract** between the resolution system and the orchestrator. Changes must be agreed by both teams.

---

## 5.14 Helm Chart Requirement: ConfigMap Checksum

Charts that mount ConfigMaps must include a checksum annotation in the pod template to trigger rolling restarts on config changes. See [Section 6b Section 8.2](06b-developer-requirements.md) for the full requirement and rationale.

---

*Previous: [Section 4 — Network Design & IP Allocation](04-network-design-ip.md) | Next: [Section 5a — Values Resolution Pipeline](05a-values-resolution-pipeline.md)*
