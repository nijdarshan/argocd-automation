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

### Blueprint Gaps

| Item | Detail | Section |
|------|--------|---------|
| Add SIGTRAN network segments | SS7/PSTN interconnect | 4.5 |
| Add Core-Media network | RTP media path | 4.5 |
| Add IPv6 access networks | VoWiFi requirements | 4.5 |
| Complete external endpoint data | Awaiting network team response | 4.6 |
| Environment-specific sizing multiplier | PROD vs LAB pod counts | 4.3 |
| Correct TAS DIAMRE sizing (4 → 6) | Fixed HA per site | 4.3 |
| Clarify IMC/UAG sizing formulas | Awaiting Mavenir | 4.3 |

### Mavenir Open Questions

| # | Question | Section |
|---|----------|---------|
| 1 | CMS consolidation — cmsnfv as umbrella? | 2.8 |
| 2 | MRF consolidation — dmrf_preInstall + dmrf as one chart? | 2.8 |
| 3 | CRDL instance mapping — how many ArgoCD apps per instance? | 2.8 |
| 4 | XA structure — deployment order for 3 charts? | 2.8 |
| 5 | SCEAS Chart.yaml bug — `name: agw` should be `name: sce` | 2.8 |
| 6 | Deployment order — where does CRDL fit? | 2.8 |
| 7 | Parallel deployment — which NFs are independent? | 2.8 |
| 8 | Manual approval gates — which components? | 2.8 |
| 9 | Health check definitions per component | 2.8, 6.13 |
| 10 | Secrets strategy — Vault/VSO vs pre-created | 2.8 |

### Deployment Hardening

| Item | Detail | Section |
|------|--------|---------|
| Per-component health check definitions | Beyond pod readiness — HTTP endpoints, custom checks | 6.13 |
| Auto-rollback policy defaults | Which components should default to auto_rollback: true? | 6.13 |
| Dry-run mode | Validation without Git commits or ArgoCD syncs | 6.11 |
| Deployment resumability | If Hub crashes, restart from last `deployed[]` state | 6.10 |
| Parallel batch failure handling | If one component fails in a batch, continue or stop? | 6.13 |

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

## 9.5 Known Technical Debt

| Item | Impact | Fix |
|------|--------|-----|
| PIP format typo in AGW template | Incorrect array format in generated values | Fix `["<ip>"]` to `["ip"]` |
| FTAS uses CIDR-only range | Different from standard `ipam.range` format | Use `whereabouts_range_cidr` function |
| CMS uses non-standard IPAM fields | `ipamsubnet`, `ipamrangestart` instead of `ipam.range` | CMS-specific, document as exception |
| ENUMFE pci_env casing | Lowercase vs uppercase inconsistency | Normalise to expected format |
| SCEAS Chart.yaml bug | References `name: agw` but sub-chart is `sce` | Vendor fix needed |

---

## 9.6 Team Handover Priorities

Suggested order:

1. **Read Section 1** (Architecture) — understand the full picture (30 min)
2. **Read Section 6** (Deployment/Rollback) — this is where implementation starts
3. **Prototype with Section 6.12** checklist — validate ArgoCD API, Git operations, multi-source apps
4. **Build the Hub API** (Section 7) — start with POST /deployments and GET /status
5. **Build the orchestration loop** (Section 6.5) — batch processing, approval gates
6. **Build artifact intake** (Section 3) — generic tool, can be developed in parallel
7. **Fill blueprint gaps** (Section 4.11) — SIGTRAN, Core-Media, endpoint data
8. **Standards formalisation** (Section 8) — document as you build, not after

---

*Previous: [Section 8 — Standards Alignment](08-standards-alignment.md) | Back to [Index](../README.md)*
