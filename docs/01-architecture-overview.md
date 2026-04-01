# 1. Architecture & System Overview

> **Audience:** Platform engineers maintaining and evolving the VMO2 Hub.
> **Source docs:** Architecture_Overview.md, VMO2_Hub_CNF_Onboarding_Proposal_v0.2.md, VMO2_Hub_Deployment_Orchestration.md, presentation/deployment-journey-v2.html

---

## 1.1 What is the VMO2 Hub?

The VMO2 Hub is a **vendor-agnostic orchestration platform** that automates Cloud-Native Network Function (CNF) deployment for Virgin Media O2. It replaces manual spreadsheet/email-based coordination with structured automation.

**The problem it solves:** Traditional CNF onboarding relies on back-and-forth emails, Excel CIQs, manual Helm editing, and multi-team coordination. VMware-era VNFs needed ~20 IPs; Kubernetes CNFs need 250+. The manual process doesn't scale.

**What the Hub does:** Vendors submit structured inputs once through a portal. The Hub orchestrates everything downstream — CIQ generation, IP allocation coordination, Helm values generation, GitOps-based deployment, health validation, and rollback.

---

## 1.2 Three Actors

Every interaction in the system involves three parties:

| Actor | Role | Touchpoints |
|-------|------|-------------|
| **Vendor** (Nokia, Mavenir, etc.) | Provides CNF software, Helm charts, container images, sizing data, network requirements | Primarily Phase 1 (submit inputs). Optional review in Phases 3-4 |
| **VMO2 Hub** | Orchestrates the entire lifecycle — CIQ generation, config generation, deployment, rollback | All phases. Central automation engine |
| **VMO2 Network / Infra / Security** | Provisions infrastructure, validates sizing, manages Infoblox IPAM, runs CI/CD | Phase 1 (validate/approve), Phase 2 (provision), Phase 3 (CI/CD validation) |

**Key insight:** Vendors interact primarily in Phase 1. Phases 2-4 are largely automated by the Hub.

---

## 1.3 Four Phases

The onboarding lifecycle is split into four sequential phases:

```
Phase 1                Phase 2                Phase 3              Phase 4
Vendor Input  ───────► Network Design  ─────► Config Gen  ────────► Deploy & Validate
& Onboarding           & IP Allocation        & GitOps Commit       & Rollback

Vendor submits         Hub generates CIQ      Hub merges inputs    ArgoCD deploys
CIQ, Helm charts,     Network team provisions + network data →     per-component,
container images       VLANs/IPs in Infoblox  values.yaml + netpol health checks,
via portal             Hub retrieves via API   Commits to GitLab    auto-rollback
```

Each phase is covered in detail in its own handover section (Sections 2, 4, 5a, 6).

---

## 1.4 Five Automation Modules

The Hub's automation is implemented as five discrete modules:

| Module | Purpose | Depth in Handover |
|--------|---------|-------------------|
| **Artifact Intake — Helm Charts** | Discover, validate, lint, scan, push vendor charts to Nexus | Section 3 (generic standalone tool) |
| **Artifact Intake — Container Images** | Discover, validate, scan, re-tag, push vendor images to Quay | Section 3 (generic standalone tool) |
| **Secrets Setup** | Create/verify secrets in Vault, validate VSO sync to K8s | Phase 2 — for Phase 1, secrets expected to exist in K8s namespaces (see Section 6b, Section 2a) |
| **Deployment Pipeline** | Per-component GitOps deployment via ArgoCD | Section 6 (deep dive) |
| **Rollback** | Git revert-based rollback — component or full-stack | Section 6 (deep dive) |

---

## 1.5 Architecture (v2 — Agreed Direction)

The agreed architecture removes the intermediate Pipeline service. The Service Orchestrator commits directly to GitOps and watches ArgoCD for status.

```
┌──────────────────────────────────┐
│       SERVICE ORCHESTRATOR       │  Stateful, API-driven
│  (Hub — deployment lifecycle)    │  Owns sequencing, approvals, state
└──────┬──────────────┬────────────┘
       │              │
    commits        watches
       │              │
       ▼              ▼
┌──────────┐    ┌──────────┐
│  GitOps  │───►│  ArgoCD  │         detects changes, syncs
│   Repo   │    │          │
└──────────┘    └────┬─────┘
                     │
                   syncs
                     │
                     ▼
               ┌──────────┐
               │   OCP    │          OpenShift / Kubernetes
               │ Cluster  │          Target environment
               └──────────┘

  Supporting Services:
  ┌──────────┐  ┌──────────┐  ┌──────────┐
  │ Hub DB   │  │ Nexus /  │  │  Vault   │
  │ (state)  │  │ Quay     │  │(secrets) │
  └──────────┘  └──────────┘  └──────────┘
```

**Data flows:**
1. **Orchestrator → GitOps Repo:** Commits per-component values.yaml + ArgoCD Application manifests
2. **GitOps → ArgoCD:** ArgoCD detects Git changes
3. **ArgoCD → OCP Cluster:** Syncs workloads (network policies first, then pods)
4. **Orchestrator → ArgoCD:** Watches sync/health status via ArgoCD API
5. **Orchestrator ↔ Hub DB:** Reads/writes deployment state (deployed[], current, pending_approval)
6. **Nexus/Quay → GitOps:** Chart references used in Application manifests

**Why v2 (no pipeline)?** Fewer services, fewer network hops, simpler debugging. The Orchestrator is already stateful — having it own the Git commit step removes an unnecessary indirection.

> **Visual reference:** Open `docs/presentation/deployment-journey-v2.html` for the interactive architecture diagram. Speaker notes at `docs/presentation/speaker-notes.md`.

---

## 1.6 Infrastructure Stack

### Control Zone

Centralized platform services with connectivity to all environments (prod, pre-prod, test, R&D):

| Service | Role | Key Detail |
|---------|------|------------|
| **GitLab** | GitOps repositories | One repo per app domain (e.g., `ims-gitops/`, `pcrf-gitops/`) |
| **Nexus** | Helm chart registry | Single repo, all environments. Immutable versions. Isolation via version pinning |
| **Quay** | Container image registry | Dual-instance (vendor untrusted → VMO2 trusted). OCI-based promotion |
| **Vault** | Secrets management | Hierarchical paths: `secret/data/{app}/{env}/{component}/{secret}`. VSO syncs to K8s |
| **ArgoCD** | GitOps deployment | App-of-Apps pattern (not ApplicationSet). Sync-waves for ordering |

### Target Infrastructure

| Component | Role |
|-----------|------|
| **Infoblox IPAM** | Authoritative source for IPs, VLANs, subnets, gateways. Hub retrieves via API using tags |
| **OpenShift (OCP) Clusters** | Target Kubernetes environments (prod/pre-prod/test/R&D) |
| **Multus CNI** | Enables pods to have multiple network interfaces (OAM, signaling, media on separate VLANs) |

---

## 1.7 Key Design Decisions

These decisions are foundational. Changing any of them has broad impact.

| Decision | Choice | Rationale |
|----------|--------|-----------|
| **GitOps repo strategy** | One repo per app domain | Different vendors, lifecycles, rollback isolation. Not per-component (too granular) or monorepo (bloat) |
| **Helm repo strategy** | Single Nexus repo, all environments | Charts are immutable versioned artifacts. Version pinning provides isolation, not repo separation |
| **ArgoCD pattern** | App-of-Apps (not ApplicationSet) | Per-component rollback, sync-wave support, better debugging. Only 7-14 components, not 50+ clusters |
| **Commit strategy** | Per-component atomic commits | Enables component-level rollback via `git revert <sha>` |
| **Rollback approach** | `git revert` (not `git reset`) | Preserves audit trail (compliance). No force push. Works with branch protection |
| **Values source of truth** | Hub (never edit values.yaml directly) | Blueprint + MRF Portal → Hub API → values.yaml → Git. Git stores generated output |
| **Architecture** | v2 — Orchestrator commits directly | No intermediate pipeline service. Simpler, fewer hops |
| **Helm multi-source** | Chart from Nexus + values from Git | Separates vendor artifacts from operational configuration. ArgoCD Application references both sources |
| **ArgoCD API-only** | All cluster interaction via ArgoCD REST API | No `kubectl`, no `oc` at runtime. ArgoCD handles K8s operations internally. Enables the orchestrator to run anywhere with network access to ArgoCD |
| **Per-component namespaces** | Each component in its own namespace | Isolation, RBAC, resource quotas. Cross-namespace references use full FQDN (`service.namespace.svc.cluster.local:port`) |
| **Sync policy per component** | Configurable: manual / auto / auto+self-heal | Most CNF components use manual (orchestrator controls sync). Infrastructure components may use auto. Configured in app-config `deployment_config.sync_policy` |
| **Deployment strategies** | Rolling (current), Canary/Blue-Green (future via Argo Rollouts) | Strategy is a chart-level concern (Deployment vs Rollout CRD), not orchestrator logic. Configured in `deployment_config.strategy` |
| **Values resolution boundary** | Resolution pipeline and orchestrator are separate systems | Resolution produces the fully populated payload (Section 5a). Orchestrator consumes it (Section 6). API schema is the contract between them |

**When to reconsider:**
- ApplicationSet: if targeting 50+ clusters with same deployment
- Monorepo: if cross-app atomic deployments become necessary
- Pipeline reintroduction: if Orchestrator needs to run in a different network zone than GitLab

---

## 1.8 IMS Reference Implementation

The first (and current) implementation is for **IMS (IP Multimedia Subsystem)** provided by **Mavenir**:

- **14 components**, **17 Helm charts**, deployed in **9 batches**
- Three chart patterns used: Umbrella (most), Standalone (CMS cmsnfv, MRF), Multi-instance (CRDL)
- Deployment order: CMS → IMC → MTAS+FTAS → AGW+ENUMFE → SCEAS+LRF → MUAG+FUAG → CRDL → CBF+LIXP → MRF
- Manual approval gates after CMS and CRDL
- Auto-rollback configurable per component

The system is designed to be **vendor-agnostic** — the same framework supports future CNFs (PCRF, CCS, etc.) by loading a different app-config template.

---

## 1.9 Adjacent Capabilities (Not in Scope for Deep Dive)

These are related systems that interact with the Hub but are documented/owned separately:

### CWL Cluster Build
Blueprint-driven OpenShift workload cluster provisioning (14-step process). Integrates Arista CVP ZTP for networking, HPE iLO ZTP for servers, Infoblox for DNS, Vault for secrets. The CWL process produces the target cluster that CNFs deploy onto. See `docs/VMO2_Hub_CWL_Build.md`.

### Security Scanning
Three-layer strategy under evaluation:
- **GitLab Security** (pre-deploy, offline-capable) — immediate win, already deployed
- **Aptori** (API security testing, needs limited egress) — strongest for business logic flaws
- **Qualys** (runtime/infrastructure scanning, needs cloud sync) — covers K8s nodes, network devices

See `docs/aptori-vs-gitlab-vs-qualys.md` for comparison and `docs/security-scanning-email-draft.md` for decision framework.

### Standards Alignment
The Hub aligns conceptually with ETSI NFV MANO and 3GPP SA5 management standards. It already performs their functions but using Kubernetes-native, GitOps-native patterns rather than traditional MANO architecture. Near-term focus is formalizing internal contracts and state machines, not building ETSI-facing APIs. See Section 8 of this handover.

---

## 1.10 Current State

| Area | Status |
|------|--------|
| **MRF Portal (sizing)** | v1 live |
| **Service Orchestration Portal** | Getting started |
| **Deployment/Rollback automation** | Designed and validated — 8-stage pipeline, 17 use cases proven, ArgoCD API commands documented (Section 6a), developer requirements specified (Section 6b). Reference implementation available |
| **Values resolution pipeline** | Designed — 24 support functions documented (Section 5), resolution process specified (Section 5a). Implementation required |
| **Artifact intake** | Designed, planned as generic standalone tool (Section 3) |
| **CIQ generation** | Designed |
| **IMS app-config template** | Complete (`ims-config-prod.json`) |
| **CIQ blueprint** | Complete (`ciq_blueprint.json`) |
| **Support functions** | 24 functions defined and documented |
| **Canary/Blue-Green** | Infrastructure ready (Argo Rollouts). No vendor currently provides Rollout CRD charts. Orchestrator commands documented for future use |
| **Deployment state DB** | Schema designed, reference implementation available. Production team to implement in MariaDB |

---

## 1.11 Architectural Principles

These principles guide all design decisions:

1. **Single Source of Truth** — GitLab for configurations. Infoblox for network allocations. Hub orchestrates between them.
2. **Security-First** — Network policies deployed before pods. Secrets via Vault. Artifacts scanned before promotion.
3. **Vendor-Agnostic** — Same framework for any CNF with Helm charts. Vendor-specific logic lives in app-config templates, not code.
4. **Minimal User Input** — Paths/conventions pre-agreed. Users select NF + version. System auto-discovers artifacts.
5. **API-Driven** — All integrations use REST APIs. The deployment orchestrator interacts with clusters exclusively through the ArgoCD REST API — no `kubectl`, no `oc`, no CLI tools at runtime. Git operations are the only non-HTTP protocol (subprocess calls to `git`).
6. **Audit Trail** — Git history is the compliance record. `git revert` (not reset) preserves full history. Every deployment, rollback, and approval is recorded in the deployment database with helix_id correlation.
7. **Environment Agnostic** — Same process across prod, pre-prod, test, R&D. Hub templates per environment.
8. **Separation of Concerns** — Vendors provide what. Hub generates how. Network team provisions where. ArgoCD deploys when.

---

*Next: [Section 2 — Vendor Input & Onboarding](02-vendor-onboarding.md)*
