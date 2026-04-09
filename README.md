# VMO2 Hub — CNF Deployment Platform Handover

Vendor-agnostic orchestration platform for Cloud-Native Network Function (CNF) deployment. Vendors submit inputs once; the Hub orchestrates CIQ generation, IP allocation, config generation, GitOps deployment, and rollback.

---

## Quick Start

1. **Understand the system** — Read [Section 1: Architecture](docs/01-architecture-overview.md)
2. **Understand the deployment flow** — Read [Section 6: Deployment & Rollback](docs/06-deployment-rollback.md) then [6b: Developer Requirements](docs/06b-developer-requirements.md)
3. **See it working** — Set up the [Reference Implementation](reference-implementation/README.md) and run the 17 use cases
4. **Build the production system** — Use [6a: Commands Reference](docs/06a-deployment-commands-reference.md) for exact API calls and [6b](docs/06b-developer-requirements.md) for the 8-stage pipeline spec with acceptance criteria

---

## Documentation

| # | Section | What It Covers |
|---|---------|---------------|
| 1 | [Architecture Overview](docs/01-architecture-overview.md) | System overview, 4 phases, 5 modules, v2 architecture, infrastructure stack, key design decisions |
| 2 | [Vendor Onboarding](docs/02-vendor-onboarding.md) | CIQ inputs, Helm chart analysis, container images, IMS component inventory |
| 3 | [Artifact Intake & Promotion](docs/03-artifact-intake.md) | Helm chart transfer, container image promotion, Nexus/Quay workflows, governance |
| 4 | [Network Design & IP Allocation](docs/04-network-design-ip.md) | CIQ blueprint, Infoblox integration, network segments, IP allocation |
| 5 | [Data Models & Templates](docs/05-data-models-templates.md) | App-config template structure, 3 chart patterns, 24 support functions |
| 5a | [Values Resolution Pipeline](docs/05a-values-resolution-pipeline.md) | How templates become payloads — 5 input sources, 8-step resolution, output contract |
| 6 | [Deployment & Rollback](docs/06-deployment-rollback.md) | Architecture, state machine, sync policies, batch ordering, use cases |
| 6a | [Commands Reference](docs/06a-deployment-commands-reference.md) | Every ArgoCD API call and git command for every deployment operation |
| 6b | [Developer Requirements](docs/06b-developer-requirements.md) | 8-stage pipeline spec, GitOps structure, commit strategy, acceptance criteria, CI/CD validation |
| 7 | [API Reference](docs/07-api-reference.md) | Hub API endpoints, request/response contracts, payload schema, status enums, error codes |
| 8 | [Standards Alignment](docs/08-standards-alignment.md) | ETSI NFV and 3GPP SA5 alignment assessment, phased roadmap |
| 9 | [Future Roadmap](docs/09-future-roadmap.md) | Current state, near-term build items, mid-term hardening, long-term evolution |

---

## Schemas (Contracts)

| File | Purpose | Validates |
|------|---------|-----------|
| [app-config-schema.json](schemas/app-config-schema.json) | Template validation (pre-resolution) | Raw app-config with `{{ placeholder }}` functions and user_editable/non_editable split |
| [api-response-schema.json](schemas/api-response-schema.json) | Resolved payload (post-resolution) | Flat `values` per chart, deployment status, runtime state |
| [api-response-example.json](schemas/api-response-example.json) | IMS mid-deployment example | CMS (healthy), IMC (in_progress), CRDL (pending) with real resolved values |

```
ims-config-prod.json  --validates against-->  app-config-schema.json
        |
   (resolution pipeline - Section 5a)
        |
        v
resolved payload  --validates against-->  api-response-schema.json
```

---

## Templates (IMS Reference Data)

| File | What It Is |
|------|-----------|
| [ims-config-prod.json](templates/ims-config-prod.json) | Complete IMS app-config — 14 components, 17 charts, all placeholder functions, deployment order, approval gates |
| [ciq_blueprint.json](templates/ciq_blueprint.json) | CIQ infrastructure blueprint — 54 network definitions, pod sizing per component |
| [support-functions-guide.md](templates/support-functions-guide.md) | 24 placeholder resolver functions across 7 categories |

To onboard a new CNF (e.g., PCRF), create a new app-config template following the IMS pattern.

---

## Reference Implementation (PoC)

Working proof-of-concept that validates every deployment operation end-to-end. Hosted in the [tech stack repository](https://gitlab.o2virginmedia.com/iced/app-onboarding-v2/app-onboarding-tech-stack).

| Component | What |
|-----------|------|
| charts/ | 7 Helm charts (config, server with Rollout CRD, simulator, collector, store, dashboard, gateway) |
| orchestrator/ | deploy.sh (Day 0), usecase.sh (17 UCs), FastAPI API |
| payloads/ | nf-demo-helm.json — deployment payload driving all operations |
| nexus-argo-lab/ | Kind + ArgoCD + Nexus + Gitea + Argo Rollouts lab setup |

### 17 Use Cases Proven

| Category | Use Cases |
|----------|-----------|
| **Bootstrap** | UC1: Day 0 — generate everything from payload |
| **Values** | UC2: Version upgrade, UC3: Config change, UC4: Multi-component |
| **Chart** | UC16: Chart version upgrade, UC17: Chart version rollback |
| **Rollback** | UC5: Component rollback, UC7: Auto-rollback on failure |
| **Strategy** | UC21: Canary (future), UC22: Blue-green (future) |
| **Config** | UC20: User-editable config change |
| **Stack** | UC18: Add component, UC19: Remove component |
| **Validation** | UC14: Dry run, UC15: Status check |

---

## Architecture (v2)

```
Orchestrator --> Git (commit/push) --> ArgoCD (detects) --> K8s cluster (syncs)
Orchestrator --> ArgoCD API (sync trigger + health watch)
Orchestrator --> Hub DB (state: deployed[], component_results)
```

**Key Design Decisions:**
- Per-component atomic git commits (component-level rollback via `git revert`)
- `git revert` not `git reset` (preserves audit trail, no force push)
- App-of-Apps pattern in ArgoCD (not ApplicationSet)
- ArgoCD API only — no kubectl at runtime
- Exit-and-resume execution model (fresh process per batch, state in DB)
- `force=false` for normal deploys, `force=true` only for rollback

---

## Handover Priorities

If you're picking this up, suggested order:

1. Read Section 1 (Architecture) — understand the full picture
2. Read Section 6 (Deployment/Rollback) — this is where implementation starts
3. Run the reference implementation — validate ArgoCD API, Git operations, multi-source apps
4. Build the orchestrator from Section 6b — 8-stage pipeline with acceptance criteria
5. Build artifact intake from Section 3 — can be developed in parallel
6. Fill blueprint gaps from Section 4 — SIGTRAN, Core-Media, endpoint data

