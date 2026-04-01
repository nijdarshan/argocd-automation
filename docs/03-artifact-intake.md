# 3. Artifact Intake & Promotion

> **Audience:** Platform engineers building or consuming the artifact intake tooling.
> **Source docs:** VMO2_Helm_Chart_Promotion.md, VMO2_Helm_Chart_Promotion_OCI.md, VMO2_Hub_Developer_Handoff_Modules.md, VMO2_Hub_Module_Requirements.md
> **Design intent:** This is a **generic standalone tool** — reusable by any team, not coupled to the Hub's service orchestration.

> **Scope note:** Sections 3.1–3.12 and 3.14–3.15 describe the **near-term deliverable** — the artifact transfer and promotion tool that must be built to support Day 0 deployments. Section 3.13 describes **future scope** — governance UI, policy engine, and vulnerability tracking that will mature over time. Items marked *(future)* within near-term sections are stretch goals, not blockers.

---

## 3.1 What This Tool Does

Moves artifacts (Helm charts and container images) from untrusted vendor sources to trusted internal registries, with validation and scanning at every step.

```
Untrusted Source          Validation Gate           Trusted Destination
─────────────────    ──────────────────────    ──────────────────────────
Vendor Quay (OCI)    │ Package integrity   │    VMO2 Quay (dual-target)
Vendor Helm repo     │ Chart.yaml checks   │    VMO2 Nexus (dual-target)
Vendor .tgz files    │ Dependency resolve   │
Direct OCI refs      │ Helm lint           │    ┌─── Target A ───┐
                     │ Secrets detection   │    │                 │
                     │ Vuln scan (images)  │    │   Both must     │
                     │ Policy enforcement  │    │   have it for   │
                     └─────────────────────┘    │   "promoted"    │
                                                │                 │
                                                └─── Target B ───┘
```

**Why standalone?** Any team that receives vendor software and needs to gate it into trusted registries has this problem. The tool doesn't need to know about CNFs, IMS, or the Hub — it operates on registry paths, policy profiles, and tenant identifiers.

---

## 3.2 Infrastructure Topology

### Helm Charts: Four Nexus Instances (Two Mirrored Pairs)

```
EXTERNAL                    INTERNAL INSECURE              INTERNAL SECURE
(vendor-hosted)             (staging/test)                 (trusted, ArgoCD source)
                         ┌──────────────────┐          ┌──────────────────┐
  Vendor Helm Repo  ──►  │ Insecure Nexus A │  ─────►  │ Secure Nexus A   │
  Vendor OCI Reg    ──►  │ Insecure Nexus B │  ─────►  │ Secure Nexus B   │
  Direct .tgz URLs  ──►  └──────────────────┘          └──────────────────┘
                           (Import writes      (Promote writes
                            to both)             to both)
```

- **No built-in replication** between mirrored instances. The tool is responsible for dual-target writes.
- A chart is only "imported" when it exists on both insecure instances.
- A chart is only "promoted" when it exists on both secure instances.

### Helm Charts: Quay OCI (Alternative Topology)

Some NFs use Quay OCI registries instead of Nexus:

```
SOURCE QUAY                                    TARGET QUAY
(vendor-managed, untrusted)                    (VMO2-controlled, trusted)
┌──────────────────┐                        ┌──────────────────┐
│ Source Quay A     │  ───── promote ─────►  │ Target Quay A    │
│ Source Quay B     │                        │ Target Quay B    │
└──────────────────┘                        └──────────────────┘
  (read from primary,                         (write to both,
   fallback to secondary)                      both = promoted)
```

Organisation and repo structure mirrors across all instances:
```
helm-charts/ims
helm-charts/pcrf
helm-charts/ccs
```

### Container Images: Vendor Registry → VMO2 Quay

```
Vendor Image Registry     Scan + Validate        VMO2 Secure Quay
(insecure/untrusted)      ─────────────────      (trusted)
  ├── image-a:v1.0   ──►  Trivy/Clair scan  ──►  ├── image-a:v1.0
  ├── image-b:v2.1   ──►  Manifest check    ──►  ├── image-b:v2.1
  └── image-c:v1.3   ──►  Re-tag to VMO2    ──►  └── image-c:v1.3
```

---

## 3.3 Two Flows for Helm Charts

The tool supports two distinct flows. The flow is auto-detected from the source URL.

### Flow 1: Import (External → Internal Insecure)

Downloads charts from a vendor-hosted registry on the internet into the internal insecure Nexus staging area.

| Aspect | Detail |
|--------|--------|
| **Source** | External Helm repo, OCI registry, or direct .tgz URL |
| **Destination** | Both insecure Nexus instances |
| **Constraint** | External → Secure is **not allowed**. Tool fails immediately if attempted |
| **Credentials** | Fetched from Vault at `<registry-host>/<tenant>` |

### Flow 2: Promote (Internal Insecure → Internal Secure)

Moves validated charts from the staging area to the trusted registries that ArgoCD consumes.

| Aspect | Detail |
|--------|--------|
| **Source** | Insecure Nexus (primary, fallback to secondary) |
| **Destination** | Both secure Nexus instances |
| **Constraint** | Only insecure → secure. Tool validates this at init |
| **Credentials** | Fetched from Vault at `<registry-host>/<tenant>` |

### Flow Detection

The tool checks the source URL hostname against a configured array of internal domains:
- **Match** → Promote flow
- **No match** → Import flow

---

## 3.4 Input (Minimal by Design)

### Helm Chart Transfer

| Input | Required | Description |
|-------|----------|-------------|
| **Source** | Yes | Single URL **or** a list of URLs (see below). Auto-detected type per URL |
| **Destination URL** | Yes | Base URL of destination Nexus. Tenant is appended automatically |
| **Tenant/Team** | Yes | NF name or team name (e.g., `ims`, `pcrf`, `auto`). Dropdown selection |

**No other user input.** Everything else is derived from convention or fetched from Vault.

### Multi-URL / List Input

Users can provide a **list of URLs with explicit tags** instead of a single source. This covers the common case where a vendor delivers a manifest of specific chart references:

```json
{
  "source": [
    "oci://vendor-quay.example.com/helm-charts/ims/ims-mtas:1.1.0",
    "oci://vendor-quay.example.com/helm-charts/ims/ims-cms:14.15.0",
    "oci://vendor-quay.example.com/helm-charts/ims/ims-agw:1.1.0"
  ],
  "destination": "https://insecure-nexus",
  "tenant": "ims"
}
```

**Behavior with lists:**
- Each URL is processed independently (type detection per URL)
- All URLs must target the same tenant (validated at init)
- Batch processing — failures on one URL don't block the rest
- Mixed URL types are allowed (some OCI, some .tgz, some repo URLs)
- Useful when vendors provide a release manifest or delivery note with exact artifact references

### Source URL Type Detection

| URL Pattern | Detected As | Behavior |
|-------------|-------------|----------|
| `oci://host/org/chart:version` | OCI single chart with tag | Transfer that exact version |
| `oci://host/org/chart` (no tag) | OCI single chart, latest | Query tags, transfer latest |
| `oci://host/org` (namespace) | OCI namespace | Catalog API discovery, latest of each |
| `*.tgz` | Direct download | Single chart at embedded version |
| Internal hostname + no repo path | Internal Nexus base | Locate repo by tenant, latest of each |
| Internal hostname + repo path | Internal Nexus repo | Query that repo, latest of each |
| Otherwise | Helm repository | Fetch index.yaml, latest of each |

### Helm Chart Promotion (Quay OCI)

| Input | Required | Description |
|-------|----------|-------------|
| **NF Identifier** | Yes | Determines repo path: `helm-charts/<nf>` |
| **Chart Name** | No | If provided, only this chart. Otherwise all charts |
| **Chart Version** | No | If provided (with chart name), that exact version. Otherwise latest unpromoted |

### Container Image Intake

| Input | Required | Description |
|-------|----------|-------------|
| **Vendor image repo path** | Yes | Source registry path (insecure/untrusted) |
| **Secure Quay endpoint** | Yes | Destination registry |
| **App domain metadata** | Yes | App name, environment, repo path mapping |
| **Policy profile** | Yes | Scan rules and vulnerability thresholds |

---

## 3.5 Helm Chart Transfer Workflow

Five stages, identical structure for both Import and Promote:

### Stage 1: Initialization

1. Classify source as internal or external (hostname against internal domains config)
2. Validate source/destination combination (external → secure = fail immediately)
3. Detect source type from URL pattern
4. For internal Nexus base URLs: locate repo by tenant via Nexus REST API
5. Construct destination path: `<dest-base-url>/<tenant>`
6. Fetch credentials from Vault: `<registry-host>/<tenant>`
7. Verify destination repository exists on each target instance
8. **Fail fast** on: missing credentials, missing repo, invalid URL combination

### Stage 2: Discovery

1. Query source for available charts and versions (method depends on source type)
2. Query destination for already-transferred charts
3. Compute delta: source charts not yet on **both** destination instances
4. For specific chart/version requests: filter to only that; skip if already present

### Stage 3: Download

1. Download each candidate `.tgz` to temp directory
2. Compute and record SHA256 hash of each file
3. Retry failed downloads up to 3 times
4. Failed downloads: mark as failed, continue with remaining charts

### Stage 4: Validation

Run in order. Any failure rejects the chart:

| Check | What It Does | Failure |
|-------|-------------|---------|
| **Package integrity** | Valid gzip tar, single top-level dir matching chart name | Reject |
| **Chart.yaml** | `name` matches `<nf>-<component>` convention, valid SemVer `version`, `apiVersion` present | Reject |
| **Required files** | `values.yaml` exists, `templates/` exists and non-empty | Reject |
| **Dependencies** | All declared deps have corresponding sub-charts in `charts/` | Reject |
| **Helm lint** | `helm lint` against extracted chart. Errors reject, warnings captured | Reject on error |
| **Secrets detection** | Scan for private key headers, base64 credential blocks, literal secret values | Reject |

### Stage 5: Upload

1. Upload each validated `.tgz` to **both** destination instances
2. Verify success on each target via API query
3. Retry failed uploads up to 3 times per target
4. Chart is only "fully transferred" when confirmed on both targets
5. If one target fails after retries: mark as **partially promoted** with which target failed

---

## 3.6 Quay OCI Promotion Workflow

For NFs using Quay OCI instead of Nexus:

### Stage 1: Discovery

1. Query Source Quay primary `helm-charts/<nf>` for available tags (OCI tags API). Fallback to secondary if unreachable
2. Query **both** Target Quay instances for already-promoted tags
3. Compute delta: charts in source not on both targets
4. Filter by specific chart/version if requested

### Stage 2: Pull

1. `helm pull oci://<source-quay>/helm-charts/<nf>/<chart-name> --version <version>`
2. Fallback to secondary source if primary fails
3. Record SHA256 hash
4. Retry up to 3 times

### Stage 3: Validation

Same checks as Nexus workflow (package integrity, Chart.yaml, required files, dependencies, helm lint, secrets detection).

**Additional OCI-specific check:** Chart name must match `<nf>-<component>` and NF prefix must match the selected NF identifier.

### Stage 4: Push

1. `helm push <chart>.tgz oci://<target-quay>/helm-charts/<nf>` to **both** targets
2. Verify via OCI tags API on each target
3. Retry up to 3 times per target
4. Fully promoted = confirmed on both targets

---

## 3.7 Container Image Intake Workflow

### Flow

1. **Enumerate** — discover all images and tags under vendor repo path
2. **Pull & validate** — pull images, validate manifests and layers, check architecture compatibility (amd64, arm64)
3. **Scan** — vulnerability scanning (Trivy, Clair), enforce policy thresholds (fail on critical/high CVEs)
4. **Re-tag** — apply VMO2 internal naming conventions
5. **Push** — push to secure Quay
6. **Verify** — confirm pull by tag and digest
7. **Report** — generate intake report and audit record

### Validation Rules

| Check | Failure |
|-------|---------|
| Invalid image manifest | Reject |
| Vulnerability scan failure (above threshold) | Reject (or quarantine if policy allows) |
| Digest mismatch (source vs destination) | Reject |
| Missing architecture support | Warn or reject per policy |

### Additional Capabilities

> **Near-term vs future:** Resume and parallel scanning are near-term requirements. Layer dedup is a nice-to-have. SBOM generation and quarantine workflow are future scope (depend on the policy engine in Section 3.13).

| Capability | Detail | Scope |
|-----------|--------|-------|
| **Resume** | Interrupted transfers resume without re-transferring completed images | Near-term |
| **Parallel scanning** | Multiple images scanned concurrently | Near-term |
| **Layer deduplication** | Shared base layers not re-uploaded | Near-term (nice-to-have) |
| **SBOM generation** | Software Bill of Materials per image | Future |
| **Quarantine workflow** | Images with vulnerabilities held pending review rather than outright rejected | Future (requires policy engine) |

### Performance Target

Typical IMS release (20-50 images): within 60 minutes.

---

## 3.8 Credentials & Configuration

### Vault Integration

All credentials fetched from Vault at runtime. No credentials in environment variables, config files, or user input.

| Registry | Vault Path Pattern | Access |
|----------|--------------------|--------|
| External source | `<registry-host>/<tenant>` | Read-only |
| Insecure Nexus (both) | `<insecure-nexus-host>/<tenant>` | Read/write |
| Secure Nexus (both) | `<secure-nexus-host>/<tenant>` | Write |
| Source Quay | `<source-quay>/helm-charts` | Read-only (robot account) |
| Target Quay | `<target-quay>/helm-charts` | Write (robot account) |

### Infrastructure Needed Per Tenant

| Item | Count | Notes |
|------|-------|-------|
| Helm hosted repos on all 4 Nexus instances | 4 per tenant | e.g., `helm-ims` on all 4 |
| Service account (one per tenant, access across all instances) | 1 per tenant | e.g., `svc-helm-ims` |
| Vault credential entries | 1 per Nexus instance per tenant | Following `<env>/<dc>/nexus/<url>/<tenant>` |
| Firewall rules: CZ runners ↔ all Nexus instances | HTTPS/443 | One-time setup |

### Current Tenants

| Repo Name | Scope |
|-----------|-------|
| `helm-ims` | IMS charts (Mavenir) |
| `helm-udb` | UDB charts |
| `helm-pcf` | PCF charts |
| `helm-ccs` | CCS charts |
| `helm-auto` | Automation / internal tooling (priority: needed first for dev/test) |

Tracked under infrastructure ticket **ICEDDE-38861**.

---

## 3.9 Naming Conventions

### Helm Charts (OCI)

Chart `name` field in `Chart.yaml` must follow:
```
<nf>-<component>
```
Examples: `ims-mtas`, `ims-cmsplatform`, `pcrf-gateway`.

**Why:** Prevents collisions across NFs. Makes scope visible in Quay, Helm CLI, ArgoCD, and audit logs.

### Chart Packaging

- Must be `.tgz` produced by `helm package`. No `.zip`, raw directories, or other formats
- Filename follows Helm convention: `<chart-name>-<version>.tgz`
- Pushed to source via `helm push <chart>.tgz oci://<source-quay>/helm-charts/<nf>`

### Chart Structure Requirements

1. `Chart.yaml`: valid `name`, `version` (SemVer), `apiVersion`
2. `appVersion`: free-form (vendor's own release identifier)
3. `values.yaml` must exist
4. `templates/` must exist and not be empty
5. All declared dependencies present in `charts/` directory
6. No hardcoded secrets, credentials, or environment-specific configuration

### Container Images

Re-tagged to VMO2 internal naming conventions before push. Original vendor tags preserved as metadata.

---

## 3.10 Idempotency & Error Handling

### Idempotency Guarantees

| Scenario | Behavior |
|----------|----------|
| Re-run with same inputs | Skips already-transferred charts/images. No duplicates. No errors |
| Chart exists on Target A but not Target B (prior partial failure) | Pushes to Target B only |
| Version already promoted | Skipped. Versions are immutable — vendor must increment to fix. This immutability is critical: the deployment orchestrator references charts by exact version in ArgoCD `targetRevision`. A chart version must always produce the same output |
| Empty source repo | Completes successfully with zero charts processed. Not an error |

### Error Handling

| Scenario | Behavior |
|----------|----------|
| **Validation failure** (one chart in batch) | Failed chart rejected. Remaining charts still processed. Overall status: PARTIAL |
| **Source unreachable** (primary) | Fallback to secondary. If both unreachable: fail at discovery |
| **Target unreachable** (one of pair) | Push to reachable target. Mark as partially promoted. Re-run fixes gap |
| **Both targets unreachable** | Fail at upload |
| **External → Secure attempted** | Fail immediately at initialization |
| **Missing Vault credentials** | Fail immediately at initialization |
| **Missing destination repo** | Fail immediately at initialization |
| **OCI catalog API unavailable** | Fail with clear error: "provide individual chart URLs instead" |
| **NF prefix mismatch** | Chart in `helm-charts/pcrf` named `ims-agw` fails validation |

### Retry Policy

- Downloads: up to 3 retries with backoff
- Uploads: up to 3 retries per target with backoff
- Transient network errors: retried. Auth failures: not retried

---

## 3.11 Promotion Scenarios (Quick Reference)

### Nexus: Import

| Scenario | Source | Result |
|----------|--------|--------|
| Import all from Helm repo | External repo URL | Latest of each → both insecure |
| Import all from OCI namespace | OCI namespace URL | Catalog discovery → both insecure |
| Import one chart (OCI + tag) | `oci://host/chart:v1.0` | Exact version → both insecure |
| Import one chart (direct .tgz) | `https://host/chart-1.0.tgz` | That file → both insecure |
| Import from list (mixed) | Array of OCI/tgz URLs | Each URL processed independently → both insecure |

### Nexus: Promote

| Scenario | Source | Result |
|----------|--------|--------|
| Promote all (base URL) | `https://insecure-nexus` | Locate repo by tenant, latest unpromoted → both secure |
| Promote all (repo URL) | `https://insecure-nexus/repo/helm-ims` | Latest unpromoted → both secure |
| Promote one chart | `https://insecure-nexus/.../chart-1.0.tgz` | That chart → both secure |

### Quay OCI: Promote

| Scenario | Input | Result |
|----------|-------|--------|
| Promote all | NF only | All unpromoted → both targets |
| Promote one chart | NF + chart name | Latest unpromoted version → both targets |
| Promote exact version | NF + chart + version | That version → both targets |

---

## 3.12 Reporting & Observability

Every execution produces:

### Transfer/Promotion Record
```json
{
  "execution_id": "transfer-2026-03-15-001",
  "flow": "promote",
  "tenant": "ims",
  "source": "https://insecure-nexus/repository/helm-ims",
  "targets": ["secure-nexus-a", "secure-nexus-b"],
  "timestamp": "2026-03-15T14:32:00Z",
  "status": "SUCCESS",
  "charts_processed": 7,
  "charts_promoted": 6,
  "charts_skipped": 1,
  "charts_failed": 0
}
```

### Per-Chart Report
```json
{
  "chart_name": "ims-mtas",
  "chart_version": "1.1.0",
  "sha256": "abc123...",
  "validation": {
    "package_integrity": "pass",
    "chart_yaml": "pass",
    "dependencies": "pass",
    "helm_lint": "pass (2 warnings)",
    "secrets_scan": "pass"
  },
  "promotion_status": "promoted",
  "target_a": "confirmed",
  "target_b": "confirmed"
}
```

### Metrics

- Charts/images: processed, passed, failed, promoted, skipped
- Execution time per stage
- Registry availability (source primary/secondary, target A/B)

### Logs

- Source path, chart/image name, version, digest, target URL
- All operations logged for audit and troubleshooting
- **Never logs secret values** (images module)

### Alerts

- Scan failures, publish failures, validation failures above threshold
- Partial promotion (one target missing)
- Source/target unreachability

---

## Near-Term vs Future Scope

**Everything above this line (Sections 3.1–3.12) is the near-term deliverable.** It describes the artifact transfer and promotion tool — Helm chart intake, container image intake, Nexus/Quay dual-target writes, validation, idempotency, error handling, and reporting. This is what must be built to support Day 0 CNF deployments.

**Everything below this line (Section 3.13) is future scope.** It describes the governance layer that will mature over time — policy engine, vulnerability management UI, Aptori integration, and audit trail enhancements. These are not blockers for initial deployment but represent the long-term vision for artifact governance at VMO2.

**Sections 3.14–3.15 (after 3.13) return to near-term scope** — performance targets and tenant onboarding.

---

## 3.13 Security Scanning & Vulnerability Management *(Future Scope)*

This is the long-term vision for making artifact intake a fully governed, audit-controlled workflow across VMO2 — not just for CNFs.

### Current State

- **Helm lint + secrets detection** run locally during validation (Stage 4)
- Scan results and promotion records written to a **GitLab audit repo** per execution
- No centralized vulnerability tracking, no approval workflow, no policy exclusions

### Near-Term Extension: Audit Trail in GitLab / Hub DB

Every intake execution already produces per-chart and per-image reports (Section 3.12). These should be persisted as structured records:

| Storage | What | Why |
|---------|------|-----|
| **GitLab audit repo** | Per-execution YAML/JSON report (chart name, version, SHA256, scan results, pass/fail, timestamps) | Git history = immutable audit trail. Easy to diff between runs. Teams already use GitLab |
| **Hub DB** | Structured records with queryable fields (tenant, chart, version, status, scan findings) | Powers the UI, enables policy queries ("show me all charts with unresolved findings for IMS") |

Both destinations are written to on every execution. GitLab is the compliance record; Hub DB is the operational view.

### Mid-Term: Policy Engine & Exclusions

Not every scan finding is actionable. Vendors ship charts with known low-severity CVEs that have been reviewed and accepted. The tool needs a policy layer:

```
┌─────────────────────────────────────────────────────┐
│                   POLICY ENGINE                      │
│                                                      │
│  Rules (per tenant, inheritable):                    │
│  ┌───────────────────────────────────────────────┐  │
│  │ • Severity thresholds (block critical/high,   │  │
│  │   warn medium, ignore low)                     │  │
│  │ • CVE exclusions with expiry + justification  │  │
│  │   ("CVE-2025-1234 accepted until 2026-06-01,  │  │
│  │    vendor fix in v1.2")                        │  │
│  │ • Package exclusions (known false positives)  │  │
│  │ • Lint rule overrides (per tenant)            │  │
│  │ • Auto-approve if no new findings since       │  │
│  │   last approved version                       │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  On next scan:                                       │
│  • Excluded findings → suppressed (not shown)        │
│  • Expired exclusions → re-surfaced automatically    │
│  • New findings → flagged for review                 │
│  • No new findings → eligible for auto-approval      │
└─────────────────────────────────────────────────────┘
```

Policies stored in Git (auditable, reviewable via MR) and loaded by the tool at runtime.

### Long-Term: Artifact Governance UI *(Vision Only — No Implementation Required Now)*

This is a **generic VMO2-wide tool** — not just for the Hub team. The UI should be clean, fast, and useful for any team receiving vendor software. Vision:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ARTIFACT GOVERNANCE                                          VMO2  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─ INTAKE PIPELINE ──────────────────────────────────────────────┐ │
│  │                                                                 │ │
│  │   Source         Validate       Scan          Approve    Push   │ │
│  │   ●─────────────●──────────────●─────────────●─────────●       │ │
│  │   vendor reg    lint, deps     CVE, secrets  policy     dual   │ │
│  │                 structure      compliance    gate       target │ │
│  │                                                                 │ │
│  └─────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌─ TENANT: IMS ──────────────────────┐  ┌─ RECENT ACTIVITY ──────┐│
│  │                                     │  │                         ││
│  │  Charts      7 promoted  0 pending  │  │  ims-mtas v1.1.0       ││
│  │  Images     42 promoted  3 pending  │  │  ✓ promoted 2h ago     ││
│  │  Findings    2 open  14 excluded    │  │                         ││
│  │  Last intake 2026-03-25 14:32       │  │  ims-agw v1.1.0        ││
│  │                                     │  │  ⚠ 1 finding — review  ││
│  │  [Run Intake]  [View Findings]      │  │                         ││
│  └─────────────────────────────────────┘  │  pcrf-gw v2.0.1        ││
│                                            │  ✓ promoted 1d ago     ││
│  ┌─ FINDINGS REQUIRING ACTION ────────┐  └─────────────────────────┘│
│  │                                     │                             │
│  │  ● CVE-2026-4521  HIGH             │  ┌─ POLICY ───────────────┐│
│  │    ims-agw v1.1.0 / openssl 3.1.2  │  │                         ││
│  │    [Exclude with reason] [Block]    │  │  6 exclusions active   ││
│  │                                     │  │  2 expiring < 30 days  ││
│  │  ● CVE-2026-3890  MEDIUM           │  │  Last policy MR: #427  ││
│  │    ims-mrf v1.1.0 / libcurl 8.4    │  │                         ││
│  │    Auto-excluded (matches policy)   │  │  [Edit Policy]         ││
│  │                                     │  └─────────────────────────┘│
│  └─────────────────────────────────────┘                             │
│                                                                      │
│  ┌─ AUDIT LOG ────────────────────────────────────────────────────┐ │
│  │  2026-03-25 14:32  intake-ims-007  7 charts  6 promoted       │ │
│  │  2026-03-25 14:30  intake-ims-007  42 images  39 promoted     │ │
│  │  2026-03-24 09:15  intake-pcrf-003  3 charts  3 promoted      │ │
│  │  [View full audit trail in GitLab →]                           │ │
│  └────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

**Key UX principles:**
- **Pipeline-as-a-visual** — users see exactly where their artifacts are in the intake flow
- **Findings front and center** — open findings are the first thing you see, with one-click actions (exclude with reason, block, approve)
- **Per-tenant dashboards** — each team sees their own artifacts, findings, policies
- **Policy as code** — exclusions and thresholds managed via Git MRs, rendered in the UI for quick reference
- **Audit trail always visible** — link to GitLab repo for full history, summary in the UI
- **Zero-finding auto-approval** — if a new version has no new findings compared to the last approved version, it can auto-promote (configurable per tenant)

### Aptori Integration (If Approved by Infra)

VMO2 is evaluating **Aptori** for API-focused security testing. If deployed in the Control Zone (see `docs/aptori-control-zone-request.md` for the PoC spec and `docs/aptori-infra-summary.md` for infrastructure requirements):

- Aptori would handle **deep API security scanning** (business logic flaws, auth bypass, injection) — capabilities that Helm lint and Trivy don't cover
- The Artifact Governance UI would pull Aptori scan results alongside Helm/image scan results — one unified view
- Aptori findings would feed into the same policy engine (exclusions, thresholds, approvals)
- This avoids building a second vulnerability management platform — Aptori already has scan orchestration and finding management

**Decision status:** Aptori deployment is an infra team decision. The artifact intake tool should be designed to **consume scan results from external scanners** (Aptori, Qualys, GitLab Security, Trivy) rather than running scans itself beyond the basic lint/secrets checks. This keeps the tool focused on intake/promotion and lets specialist scanning tools do what they're good at.

### Scanning Architecture Summary

```
                    Built-in (Stage 4)           External Scanners
                    ─────────────────            ──────────────────
Helm Charts:        helm lint                    Aptori (API testing)
                    secrets detection            GitLab SAST
                    dependency check             Trivy (template analysis)

Container Images:   manifest validation          Trivy / Clair (CVE scan)
                    digest verification          Qualys (runtime)
                    architecture check           SBOM generation

                              │                           │
                              └──────────┬────────────────┘
                                         ▼
                              ┌─────────────────────┐
                              │  Policy Engine       │
                              │  (thresholds,        │
                              │   exclusions,        │
                              │   auto-approve)      │
                              └──────────┬──────────┘
                                         ▼
                              ┌─────────────────────┐
                              │  Governance UI       │
                              │  (findings, actions, │
                              │   audit trail)       │
                              └─────────────────────┘
```

---

*The following sections return to near-term deliverable scope.*

---

## 3.14 Performance Targets

| Workload | Target Time |
|----------|-------------|
| Typical IMS Helm release (7 charts) | < 15 minutes |
| Typical IMS container images (20-50 images) | < 60 minutes |
| Single chart promotion | < 2 minutes |

All operations support parallel processing where independent (parallel validation, parallel image scanning).

---

## 3.15 Extending to New Tenants

Adding a new tenant (e.g., a new NF or internal team):

1. Create `helm-<tenant>` repos on all 4 Nexus instances
2. Create service account `svc-helm-<tenant>` with access across all 4 instances
3. Store credentials in Vault at `<env>/<dc>/nexus/<url>/helm-<tenant>`
4. Add tenant to the tool's dropdown/enum configuration
5. Vendor pushes charts to source registry under `helm-charts/<tenant>`
6. Run Import → Promote. No code changes needed.

The Governance UI auto-discovers new tenants from configuration — no UI changes needed.

---

*Previous: [Section 2 — Vendor Onboarding](02-vendor-onboarding.md) | Next: [Section 4 — Network Design & IP Allocation](04-network-design-ip.md)*
