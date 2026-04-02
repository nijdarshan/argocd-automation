# 9. Future Roadmap & Open Items

> **Audience:** Platform engineers and leadership understanding what's next.
> **Source:** Open items collected from all handover sections + source documentation.

---

## 9.1 Current State Summary

| Area | Status |
|------|--------|
| MRF Portal (sizing) | v1 live |
| Service Orchestration Portal | Getting started |
| App-config template (IMS) | Complete (`ims-config-prod.json`) |
| CIQ blueprint (IMS) | Complete (`ciq_blueprint.json`) |
| Support functions | 24 functions defined and documented (Section 5) |
| Values resolution pipeline | Process designed and documented (Section 5a). Implementation required |
| Deployment/rollback automation | Validated — 8-stage pipeline, 17 use cases, ArgoCD API commands, developer requirements (Sections 6, 6a, 6b). Reference implementation available in [argocd-automation](https://github.com/nijdarshan/argocd-automation) |
| Deployment state DB | Schema designed with 3 tables (deployments, component_results, diffs). Reference implementation in SQLite. Production: MariaDB |
| Canary/Blue-Green | Infrastructure ready (Argo Rollouts). Orchestrator commands documented. Awaiting vendor charts with Rollout CRD |
| Artifact intake design | Implementation-ready specs, generic standalone tool (Section 3) |
| Helm chart promotion | OCI + Nexus workflows designed (Section 3) |
| CWL cluster build | Blueprint-driven, 14-step process designed |
| Security scanning | Evaluation complete (GitLab/Aptori/Qualys), decision pending |

---

## 9.2 Near-Term: Build & Ship

Things that need implementation now to get the first end-to-end deployment working.

### Deployment Orchestrator (Priority 1)

The deployment flow has been fully designed and validated. The development team implements the production orchestrator using Section 6b (Developer Requirements) as the specification and Section 6a (Commands Reference) as the API call reference.

| Item | Detail | Reference |
|------|--------|-----------|
| 8-stage deployment pipeline | Init → pre-validate → prepare → commit → bootstrap → sync → validate → report | 6b Section 3 |
| ArgoCD REST API integration | Sync, health watch, resource-tree, live resource query — all via HTTP, no kubectl | 6a Sections 2-17 |
| Git operations | Clone per trigger, per-component commits, git revert for rollback, single push | 6b Section 5 |
| Deployment state DB | MariaDB — deployment records, component results, diffs. Schema in 6b Section 7 | 6b Section 7 |
| Deployment lock | One per (environment, NF). SQL-based with TTL safety net | 6a Section 18 |
| Approval gates | Configurable per component via `deployment_config.manual_approval` | 6b Section 3 Stage 6 |
| Auto-rollback | Max 1 attempt per component. git revert + hard refresh + force sync | 6a Section 8 |
| Helm multi-source | Application YAMLs: chart from Nexus + values from Git | 6b Section 4.1 |

### Values Resolution Pipeline (Priority 1 — parallel with orchestrator)

The system that transforms templates into fully populated payloads. Must be built alongside the orchestrator.

| Item | Detail | Reference |
|------|--------|-----------|
| Placeholder resolution engine | 24 support functions resolving against CIQ blueprint + IP allocations | 5, 5a |
| User-editable / non-editable merge | Deep merge with non_editable winning on conflict | 5a Section 3 Step 5 |
| Multi-instance expansion | Base values + per-instance overrides | 5a Section 3 Step 6 |
| Chart-structure-aware portal | Show users editable fields in correct Helm hierarchy | 5a Section 7 |
| Environment config | Registry URLs, resource profiles, trust levels per environment | 5a Section 2.4 |
| Payload storage + API | Store resolved payload in Hub DB, serve via API for orchestrator | 5a Section 3 Step 8 |

### Artifact Intake Tool (Priority 2)

| Item | Detail | Section |
|------|--------|---------|
| Helm chart transfer (Import + Promote) | Nexus 4-instance dual-write, validation, idempotency | 3.5 |
| Quay OCI promotion | Source → Target Quay, dual-target | 3.6 |
| Container image intake | Scan, re-tag, push to Quay | 3.7 |
| Multi-URL list input | Accept array of OCI refs with tags | 3.4 |
| Infrastructure setup (ICEDDE-38861) | Nexus repos, service accounts, Vault creds, firewall rules | 3.8 |

### Secrets Setup (Phase 2)

Application secrets are expected to already exist in target K8s namespaces for Phase 1. Secrets automation is Phase 2.

| Item | Detail | Section |
|------|--------|---------|
| Vault secret creation/verification | Per-component, hierarchical paths | 6.7 |
| VSO sync validation | Confirm VaultStaticSecret → K8s Secret | 6.7 |
| Secret rotation without disruption | Update Vault → VSO auto-syncs → no pod restart needed if app watches Secret | 6.7 |

---

## 9.3 Mid-Term: Harden & Extend

Once the core flow works end-to-end.

### Artifact Governance UI

| Item | Detail | Section |
|------|--------|---------|
| Intake pipeline visualisation | Source → validate → scan → approve → push | 3.13 |
| Per-tenant dashboards | Charts/images promoted, findings, last intake | 3.13 |
| Policy engine | Severity thresholds, CVE exclusions with expiry, auto-approve | 3.13 |
| Vulnerability tracking | Findings stored in Hub DB, linked to GitLab audit repo | 3.13 |
| Audit trail UI | Link to GitLab repo for full history | 3.13 |

### Deployment Hardening

| Item | Detail | Section |
|------|--------|---------|
| Per-component custom health checks | Default is pod readiness (decided in 6.13). Future: application-level checks (HTTP endpoints, CMS arbitrator election) when a vendor requires it | 6.13 |
| Dry-run mode | Validation without Git commits or ArgoCD syncs | 6.11 |
| Deployment resumability | If Hub crashes, restart from last `deployed[]` state | 6.10 |

---

## 9.4 Long-Term: Platform Evolution

### ZTP for Network Provisioning

Replace manual network team provisioning with API-driven allocation:

```
Current:  Hub → CIQ → Network Team (manual) → Infoblox → Hub retrieves
Future:   Hub → Infoblox API directly → Network Team approves → Hub retrieves
```

Supernets and VLAN pools pre-allocated per site; Hub slices as needed. Reduces Phase 2 from days to minutes. See Section 4.7.

### Non-Helm Deployment Support

Adapter pattern is designed for this (Section 6b):

| Format | What Changes | What Stays |
|--------|-------------|-----------|
| **KPT** | Config generation produces KRM setter values instead of values.yaml | Git commit, ArgoCD sync, rollback |
| **Kustomize** | Generate overlay patches instead of values.yaml | Git commit, ArgoCD sync, rollback |
| **Raw YAML** | Commit manifests directly | Git commit, ArgoCD sync, rollback |

No vendor uses KPT today. Build the adapter when the first vendor requires it.

### SCALE / HEAL Operations

ETSI-aligned lifecycle operations not yet implemented:

- **SCALE** — change replica count for a component (could be: update replicas in app-config → re-deploy)
- **HEAL** — recover unhealthy component (could be: pod restart, rollback to last healthy, or re-sync)

Both fit naturally into the existing orchestration loop.

### Read-Only Northbound APIs

If external systems (NOC tools, dashboards, ITSM) need to query deployment state:

- `GET /api/v1/nfs` — list all NFs and their current deployment status
- `GET /api/v1/nfs/{nf}/components` — component inventory with versions
- `GET /api/v1/nfs/{nf}/deployments` — deployment history

Start read-only. Add write operations only when a consuming system requires it.

### Aptori Security Scanning

If infra approves Aptori deployment in the Control Zone:
- API-focused security testing integrated into artifact governance
- Findings feed into the policy engine alongside Helm/image scans
- See Section 3.13 and `docs/aptori-control-zone-request.md`

### Standards Formalisation

Phased approach from Section 8.6:
1. **Formalise** — document existing behaviour as canonical models
2. **Normalise** — map vocabulary to ETSI/3GPP
3. **Extend** — expose northbound APIs only when operationally needed

### ApplicationSet Reconsideration

Current decision: App-of-Apps (not ApplicationSet) because we have 7-14 components, not 50+ clusters. **Reconsider if:**
- Targeting 50+ clusters with same deployment
- Vendor explicitly requires ApplicationSet
- ArgoCD community improves ApplicationSet debugging and sync-wave support

---

## 9.5 AI Integration

AI augments the platform where manual interpretation is the bottleneck — reading vendor artifacts, generating templates, diagnosing failures. Rule-based logic handles everything deterministic (placeholder resolution, git operations, ArgoCD API, schema validation, batch sequencing).

### Phase 1 — Onboarding Acceleration

| Capability | What AI Does | Current State |
|-----------|-------------|--------------|
| **App-config template generation** | AI reads a new NF's Helm charts + CIQ blueprint + the IMS app-config as a reference → generates the app-config template for the new NF (deployment_order, deployment_config, chart structure, values with placeholders) | Fully manual. Engineer reads every chart, maps values, builds the template by hand. Most time-consuming step in onboarding a new NF |
| **Helm chart analysis on vendor intake** | AI reads vendor's `values.yaml`, `Chart.yaml`, and templates → produces: configurable values inventory, container images pulled, namespaces/resources created, network interfaces (Multus annotations), mapping to app-config template structure | Fully manual. Engineer reverse-engineers each chart to understand what it deploys and what values drive it |

These two capabilities eliminate the biggest manual bottleneck: understanding vendor Helm charts and translating them into the Hub's data model. For IMS (17 charts), this took weeks. With AI, onboarding a new NF (e.g., PCRF, CCS) should take days.

### Phase 2 — Operations

| Capability | What AI Does | Current State |
|-----------|-------------|--------------|
| **CIQ blueprint generation from vendor spreadsheets** | AI reads vendor Excel/CSV (sizing, network requirements, IP counts) → produces `ciq_blueprint.json` structure (networks, pods, traffic types) | Rule-based transformation exists but requires manual mapping when vendor format changes |
| **Deployment failure diagnosis** | AI reads ArgoCD resource-tree, pod events, and deployed values → explains the root cause in plain language (e.g., "image tag mismatch: pushed as `mtas-sm-24.3.0` but values reference `mtas-sm:24.3.0`") | Manual — engineer reads ArgoCD UI, kubectl events, cross-references values |

### Where AI Does NOT Apply

- **Placeholder resolution** — rule-based, 24 deterministic support functions
- **Git operations** — `git commit`, `git revert`, `git push` are mechanical
- **ArgoCD API calls** — fixed HTTP calls, no interpretation needed
- **Schema validation** — JSON Schema handles this
- **Batch ordering and sync** — defined in payload, executed deterministically

---

## 9.6 Known Technical Debt

| Area | Item | Impact | Fix |
|------|------|--------|-----|
| **Onboarding** | App-config template creation is fully manual | Onboarding a new NF takes weeks | AI-assisted generation (Section 9.5 Phase 1) |
| **Onboarding** | No automated validation that app-config covers all chart values | Missing values surface at deploy time, not onboarding time | Schema-based completeness check against Helm chart values.schema.json |
| **Resolution** | Support functions assume consistent vendor IPAM field naming | Vendor-specific exceptions (CMS, FTAS) require custom handling | Normalise IPAM fields at intake or add vendor-specific adapters |
| **Deployment** | Health checks are pod-readiness only | No application-level health validation (e.g., CMS arbitrator election, DB replication) | Define per-component custom health checks in deployment_config |
| **Deployment** | Partial batch failure policy not enforced | Operator must decide manually whether to continue or stop | Implement configurable policy: fail-fast vs continue-on-error per batch |
| **Rollback** | Multi-step rollback (past >1 deployment) requires content-based restoration | More complex than single-step git revert | Documented in 6a Section 6.2a but needs testing with real IMS data |
| **Secrets** | Application secrets expected to pre-exist (Phase 1) | Manual secret creation before first deployment | Automate via Vault + VSO in Phase 2 |

---

## 9.7 Team Handover Priorities

Suggested order:

1. **Read Section 1** (Architecture) — understand the full picture
2. **Read Section 6** (Deployment/Rollback) — this is where implementation starts
3. **Prototype with Section 6.12** checklist — validate ArgoCD API, Git operations, multi-source apps
4. **Build the Hub API** (Section 7) — start with POST /deployments and GET /status
5. **Build the orchestration loop** (Section 6.5) — batch processing, approval gates
6. **Build artifact intake** (Section 3) — generic tool, can be developed in parallel
7. **Fill blueprint gaps** (Section 4.11) — SIGTRAN, Core-Media, endpoint data
8. **Standards formalisation** (Section 8) — document as you build, not after

---

*Previous: [Section 8 — Standards Alignment](08-standards-alignment.md) | Back to [Index](../README.md)*
