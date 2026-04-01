# 8. Standards Alignment (ETSI NFV & 3GPP SA5)

> **Audience:** Platform engineers who need to understand how the Hub relates to telco standards. This section is a **reference for positioning and compliance conversations** — it is not required reading for building the deployment pipeline. Read it when you need to justify architectural choices to standards-aware stakeholders.
> **Source docs:** VMO2_Hub_Standards_Alignment.md, ETSI_NFV.md, 3GPP_SA5.md
> **Key message:** The Hub already does what these standards describe. The gap is formalisation, not capability.

---

## 8.1 Summary

The VMO2 Hub is a Kubernetes-native, GitOps-native platform that performs the functions ETSI NFV MANO and 3GPP SA5 standards describe — orchestration, lifecycle management, resource coordination, governance, assurance — but using cloud-native patterns rather than traditional MANO architecture.

| Standard | Aligned | Alignable (needs formalisation) | Scoped Out |
|----------|---------|--------------------------------|------------|
| **ETSI NFV** | MANO coverage, resource/network orchestration, policy/governance | Descriptors, LCM state machine, operation records, assurance normalisation | SOL 005 APIs, multi-VIM |
| **3GPP SA5** | Provisioning flow, security/governance, audit trails | LCM catalog, service contracts, information model mapping, event taxonomy | Full MnS/NRM scope |

**Correct scoping language:** *"Aligned with relevant ETSI NFV and 3GPP SA5 provisioning and LCM concepts"* — not "fully compliant."

---

## 8.2 What's Aligned (Already Works)

| Capability | Standards Concept | Hub Implementation |
|-----------|------------------|-------------------|
| End-to-end orchestration | ETSI NFVO + VNFM | Hub orchestrates from sizing through deployment |
| Resource coordination | ETSI VIM, 3GPP resource provisioning | Capacity checks, IP/VLAN allocation, Infoblox integration |
| Lifecycle management | ETSI VNF LCM, 3GPP LCM | Onboard → deploy → validate → rollback |
| Governance & policy | 3GPP security controls | RBAC, approval gates, policy-driven validation |
| Audit trails | 3GPP governance | Git history (immutable), deployment records, approval logs |
| Vendor-agnostic onboarding | ETSI package onboarding | App-config template system, artifact intake |

---

## 8.3 What Needs Formalisation (Works, Not Documented to Standard)

These are not missing capabilities — the Hub already does them. They need formal documentation and vocabulary mapping.

### Blueprint as Canonical Object

ETSI defines VNFD (VNF Descriptor) and NSD (Network Service Descriptor) as formal onboarding objects. The Hub has `app-config.json` + `ciq_blueprint.json` which serve the same purpose but aren't documented as a canonical model.

**Action:** Document the app-config as the Hub's equivalent of VNFD/NSD. Map fields to ETSI concepts.

### LCM State Machine

ETSI defines explicit lifecycle states (INSTANTIATED, NOT_INSTANTIATED) and operations (Instantiate, Terminate, Scale, Heal, Update). The Hub has deploy/rollback with health states but no formal state machine.

**Action:** Document the state machine (Section 6.3 is a start). Add SCALE and HEAL as future operations. Add TERMINATE for decommissioning.

### Operation Records

ETSI tracks each LCM operation as a first-class "operation occurrence" object with state, timestamps, and audit trail. The Hub has deployment records but they're not structured to ETSI's vocabulary.

**Action:** Map deployment records to operation occurrence concepts. Add structured event records.

### Event Taxonomy

3GPP SA5 defines notification/subscription models for lifecycle events. The Hub generates reports and health outputs but has no formal event taxonomy.

**Action:** Define event types (deployment.started, component.healthy, component.failed, approval.requested, rollback.triggered) with structured schemas.

### Service Contracts

3GPP SA5 expects each management service to have defined inputs, outputs, state, and error models. Hub modules have these implicitly but they're not published as formal contracts.

**Action:** Publish per-module contracts (already partially done in Section 6 API reference).

---

## 8.4 What's Intentionally Scoped Out

| Capability | Why Scoped Out |
|-----------|---------------|
| **ETSI SOL 005 APIs** | No external system needs to call the Hub via ETSI REST APIs today. UI + CI/CD driven. Will add read-only northbound APIs if integration requires it |
| **Multi-VIM abstraction** | Hub is Kubernetes-exclusive by design. No VMware/OpenStack. This is a strength (simplicity) not a gap |
| **Full 3GPP SA5 scope** | Hub covers CNF onboarding and deployment, not full network management (fault management, performance management, configuration management beyond CNFs) |
| **SCALE/HEAL operations** | Not implemented yet. Design space exists (adapter pattern). Future phase |

---

## 8.5 Hub vs Traditional MANO (OSM Benchmark)

| Dimension | Hub | Traditional MANO (e.g., OSM) |
|-----------|-----|------------------------------|
| **Infrastructure depth** | Stronger — ZTP, BIOS, firmware, full network allocation | Weaker — assumes infrastructure exists |
| **Audit trail** | Stronger — Git history is immutable compliance record | Basic logging |
| **Vendor handling** | Stronger — no repackaging, vendor-agnostic templates | Requires ETSI-format packages |
| **Rollback precision** | Stronger — per-component git revert | Application-level only |
| **Governance** | Stronger — approval gates, policy engine, RBAC | Basic RBAC |
| **Standards API compliance** | Weaker — no SOL 005 APIs | Out-of-box ETSI APIs |
| **Multi-VIM support** | None (K8s only, by design) | OpenStack, VMware, K8s |
| **Formal descriptor model** | Weaker — app-config is equivalent but not ETSI-mapped | VNFD/NSD based |

---

## 8.6 Phased Roadmap

### Phase 1: Formalise (Current)
Document existing behaviour without building new capability:
- Blueprint as canonical object model
- LCM state machine definition — the deployment status lifecycle is defined in Section 7.7 (`pending → in_progress → success/failed/rolled_back/cancelled`). This maps to ETSI operation occurrence states. Future operations (SCALE, HEAL, TERMINATE) follow the same state machine pattern
- Operation record schema — the deployment database schema (Section 6b Section 7) records every operation with component results, health reports, and diffs. This is the foundation for ETSI-style operation occurrence records
- Event taxonomy — the deployment orchestrator emits events at every state transition (deployment started, component healthy, approval required, rollback triggered). These map to 3GPP SA5 notification concepts
- Provenance metadata storage
- Security controls documentation against SA5

### Phase 2: Normalise (Near-term)
Standardise vocabulary and internal contracts:
- Internal service contracts per module
- Vocabulary normalisation (map Hub states to ETSI/3GPP states)
- Structured assurance outputs
- Standards-facing field mapping
- TERMINATE lifecycle operation

### Phase 3: Extend (Future, Only If Needed)
New capability driven by operational integration need:
- Read-only northbound APIs (start with deployment status, inventory)
- SCALE/HEAL operations
- Event subscription model (webhook-based)

---

## 8.7 Detailed Assessments

For full detail on each standard area, see:
- `docs/VMO2_Hub_Standards_Alignment.md` — unified assessment with phased roadmap
- `docs/ETSI_NFV.md` — 10 functional areas assessed against ETSI IFA/SOL
- `docs/3GPP_SA5.md` — 8 functional areas assessed against 3GPP SA5

---

*Previous: [Section 7 — API Reference](07-api-reference.md) | Next: [Section 9 — Future Roadmap & Open Items](09-future-roadmap.md)*
