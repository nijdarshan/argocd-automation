# 2. Vendor Input & Onboarding

> **Audience:** Platform engineers maintaining the Hub onboarding flow.
> **Source docs:** VMO2_Hub_CNF_Onboarding_Proposal_v0.2.md, CNF-Network-Provisioning-Presentation.md, Mavenir_Questions_Chart_Structure.md, template/App-Config-Data-Model.md
> **Visual reference:** `docs/presentation/onboarding-overview.html` + `docs/presentation/speaker-notes.md`

---

## 2.1 Why This Exists

Traditional CNF onboarding is a multi-week nightmare:

| Week | What happens |
|------|-------------|
| 1-2 | Vendor sends scattered info via emails, calls, Excel files |
| 3 | Platform team tries to figure out networking requirements |
| 4 | Platform sends incomplete requests to networking team |
| 5 | Networking team asks clarifying questions |
| 6 | Vendor changes requirements ("Oh, we also need PSTN interconnect!") |
| 7 | Networking team finally provisions |
| 8 | Deployment happens — but 2 VLANs are missing |

**Result:** 8-12 weeks, rework, frustration.

**Why it's getting worse:** VMware VNFs needed ~20 IPs. Kubernetes CNFs need 250+. Manual processes don't scale at 10x complexity.

**The Hub solution:** Vendors submit structured inputs once through a portal. Portal validation catches errors upfront. Downstream automation handles everything else. Target: **2-3 weeks** end-to-end.

---

## 2.2 What Vendors Provide

Vendors submit the following through the Resource Planning Portal (web form with dropdowns, validation, guidance):

### Required Inputs

| Input | Description | Example (IMS/Mavenir) |
|-------|-------------|-----------------------|
| **CBOM** (CNF Bill of Materials) | Complete component inventory with versions | CMS v14.15A, MRF v1.1, MTAS v1.1, etc. (14 components, 17 charts) |
| **Pod Network Types** | Network interface definitions per pod (OAM, signaling, media, management) | EMX-Signalling-MTAS, EMX-OAM-CMS, Core-Media, etc. |
| **Communications Matrix** | Pod-to-pod and external connectivity requirements (protocols, ports, directions) | SIP/5060 between MTAS↔IMC, Diameter/3868 to external PCRF |
| **Resource Requirements** | CPU, RAM, storage per pod/component | CMS: 8 vCPU, 16Gi RAM, 50Gi storage |
| **Node Affinity Rules** | Hardware requirements (DPDK-enabled NICs, GPU, specific node labels) | MTAS requires SRIOV-capable nodes |
| **Sizing & Capacity** | Subscriber counts, throughput, scaling thresholds, busy-hour formulas | 35M mobile + 5M fixed subscribers, 10K BHCA |
| **Artifact Access** | Download URLs or registry paths for Helm charts and container images | Vendor Quay registry path, chart zip download URL |

### Optional Inputs

| Input | Description |
|-------|-------------|
| **Documentation** | Deployment guides, runbooks, architecture diagrams |
| **Test Cases** | Validation scripts, health check definitions |
| **CIQ files** | Pre-existing Customer Information Questionnaires (legacy format) |
| **Feature Flags** | Which features are enabled (VoLTE, VoWiFi, PSTN interconnect, video, roaming) |
| **Site Selection** | Which DCs to deploy (PROD-1, PROD-2, R&D) |

### How Submission Works

1. Vendor accesses Resource Planning Portal via web browser (internet-accessible)
2. Fills structured form with dropdown guidance and inline validation
3. Uploads supporting documentation and artifacts
4. Submits for VMO2 review
5. Portal displays warnings/errors immediately — vendor can correct before submission
6. VMO2 validates data completeness and format compliance
7. VMO2 approves or rejects with detailed comments
8. Version history maintained for all submissions

**Key principle:** One-time structured input replaces weeks of email exchanges.

---

## 2.3 VMO2 Responsibilities During Onboarding

Once a vendor submits, VMO2 (via Hub automation + platform team) handles:

| Responsibility | Detail |
|---------------|--------|
| **Data validation** | Completeness, format compliance, cross-field consistency |
| **Security scanning** | Hash verification on artifacts, vulnerability scanning on charts/images |
| **Helm → JSON conversion** | Automation team converts vendor Helm charts to internal JSON format, applying placeholders to values |
| **Compute/IP/storage calculation** | Hub calculates infrastructure requirements from vendor-declared sizing |
| **Feedback loop** | Warnings/errors displayed in portal; approval/rejection with comments |
| **Version control** | All submissions tracked with full history |

---

## 2.4 Helm Chart Structure Expectations

This is critical context for onboarding. Every vendor chart must fit one of three patterns. Charts that don't fit are flagged for restructuring.

### Pattern A: Single Umbrella (most common)

One `Chart.yaml` with sub-charts in `charts/` directory. One ArgoCD app, one `values.yaml`.

```
ocp-mtas-nested-charts/
├── Chart.yaml           ← parent chart (one ArgoCD app)
├── values.yaml
└── charts/
    ├── tas/
    ├── vlbfe/
    ├── sipre/
    ├── diamre/
    ├── gtre/
    ├── sm/
    └── ss7re/
```

**Used by:** IMC, MTAS, FTAS, AGW, ENUMFE, MUAG, FUAG, SCEAS, LRF, CBF, LIXP (11 of 14 IMS components).

**Why we prefer this:** One ArgoCD app = one rollback unit. Sub-chart toggling via `values.yaml`. Helm handles internal ordering.

### Pattern B: Multi-Chart Sequential

Multiple independent charts deployed in strict order. Each chart = one ArgoCD app.

```
CMS_14_15A/
├── cmsplatform-9.0.14.15-v5/    ← deploy_order: 1
│   ├── Chart.yaml
│   └── values.yaml
└── cmsnfv-p_9_0_14_15_v6-01/    ← deploy_order: 2 (depends_on: cmsplatform)
    ├── Chart.yaml
    └── values.yml
```

**Used by:** CMS (cmsplatform → cmsnfv), MRF (dmrf_preinstall → dmrf).

**When this pattern is needed:** When charts have fundamentally different lifecycles or the vendor cannot consolidate them into an umbrella (e.g., pre-install PVCs/NADs that can't be Helm hooks).

### Pattern C: Multi-Instance

Same chart template deployed N times with different names and values. Each instance = one ArgoCD app.

```
CRDL/
├── crdladmin/    ← standalone, deploy once
└── crdldb/       ← deployed as: crdldb-mtas, crdldb-ftas, crdldb-imc, ...
```

**Used by:** CRDL (crdladmin + N x crdldb instances for MTAS, FTAS, IMC, MUAG, FUAG, LI).

### When a Chart Doesn't Fit

During onboarding, if vendor-delivered charts fall outside these patterns, we request restructuring:

| Problem | What We Ask the Vendor |
|---------|----------------------|
| Loose scripts/configs alongside chart | Package as Helm hooks or init containers |
| Pre-install chart that only creates PVCs/NADs/secrets | Consolidate into main chart with pre-install hooks |
| Multiple charts that should be one umbrella | Create parent Chart.yaml with sub-charts |
| Broken Chart.yaml dependencies/conditions | Fix names and conditions to match actual sub-chart dirs |

**If restructuring would break vendor logic:** We model them as Pattern B (multi-chart sequential) and document the constraint. We don't force a pattern that creates risk.

### Why Simple Structure Matters

- Fewer ArgoCD apps = simpler operations, fewer things to monitor
- Umbrella charts roll back as a unit — no partial state
- One values.yaml per component = one file to generate, one file to diff
- Hub template system maps 1:1 (component → chart → values → ArgoCD app)

---

## 2.5 Alternative Packaging Formats

Helm is the primary packaging format today. But some vendors use or are moving to alternatives:

### KPT (Kubernetes Package Tool)

Google-backed tooling where packages are plain directories of Kubernetes manifests (no templates, no Chart.yaml). Configuration is done via KRM (Kubernetes Resource Model) functions that mutate YAML in-place.

**Implications for Hub:**
- No Helm lint/package/push pipeline — instead validate KRM functions and manifest structure
- No Nexus for chart storage — packages are directories in Git
- ArgoCD supports KPT via config management plugins, but it's less mature than Helm support
- Rollback still works (git revert reverts the directory state)
- Values generation would produce KRM setter values instead of values.yaml

**Current status:** No VMO2 vendor uses KPT today. If one does, the Hub's adapter pattern (see Section 6) allows Stage 3 (config generation) to produce KPT output instead of Helm output. The commit/push/sync/rollback stages remain identical.

### Kustomize

Overlay-based configuration — base manifests + environment-specific patches.

**Implications for Hub:**
- ArgoCD has native Kustomize support
- No chart registry needed — overlays live in GitOps repo
- Hub would generate overlay patches instead of values.yaml
- Simpler for vendor-provided manifests that don't need Helm's templating power

### Raw YAML

Some vendors ship plain Kubernetes manifests with no packaging at all.

**Implications for Hub:**
- Hub would commit manifests directly to GitOps repo
- No templating — all environment-specific values baked in at generation time
- ArgoCD deploys directly from directory

**Recommendation:** Continue with Helm as default. Document KPT/Kustomize readiness in the adapter pattern so the team knows where to extend when needed.

---

## 2.6 Chart Discovery During Onboarding

When vendors upload artifacts, the Hub discovers charts automatically:

1. Vendor uploads zip to portal
2. Portal recursively scans for `Chart.yaml` files — any directory containing one is a chart
3. Reads `name` + `version` from each `Chart.yaml`
4. Cross-references against `app-config.json` — each discovered chart must match a `chart_name` + `chart_version`
5. **Match** → `helm package` + `helm push` to Nexus
6. **No match** → flag: "unknown chart found: {name}-{version}, not in app-config"
7. **Missing** → flag: "app-config expects {chart_name}-{chart_version} but not found in zip"

For version bumps (vendor ships new zip with updated versions), the portal updates `chart_version` in app-config after successful push.

---

## 2.7 Vendor Touchpoints Summary

After Phase 1 onboarding, vendor interaction drops dramatically:

| Phase | Vendor Action | Effort |
|-------|---------------|--------|
| **Phase 1: Onboarding** | Submit inputs via portal, respond to feedback, provide artifacts | Active (1-2 weeks) |
| **Phase 2: Network Design** | None | Zero |
| **Phase 3: Config Generation** | Optional: review generated values.yaml (first time only) | Minimal |
| **Phase 4: Deployment** | Optional: review health reports, support app-specific issues | Minimal |
| **Upgrades** | Submit new artifact versions via portal | Light |

---

## 2.8 Open Questions (Mavenir-Specific)

These are outstanding items specific to the IMS/Mavenir onboarding. They need resolution but the framework handles them regardless of the answer:

| # | Question | Impact |
|---|----------|--------|
| 1 | **CMS consolidation** — can cmsnfv be an umbrella wrapping cms-infra, cms1, cms2? | Reduces 3 ArgoCD apps to 1 for CMS NFV |
| 2 | **MRF consolidation** — can dmrf_preInstall and dmrf be one chart? | Reduces 2 apps to 1 for MRF |
| 3 | **CRDL instance mapping** — how many ArgoCD apps per CRDL instance? Which share crdladmin? | Determines multi-instance config in app-config |
| 4 | **XA structure** — 3 charts (xa-stack, lam_internal, lam_external) — deployment order? | Determines Pattern B ordering |
| 5 | **SCEAS Chart.yaml bug** — references `name: agw` but sub-chart is `sce` | Breaks `helm dependency build`; vendor fix needed |
| 6 | **Deployment order** — where does CRDL fit? Before or after NFs that depend on it? | Affects batch ordering in app-config |
| 7 | **Parallel deployment** — which NFs can deploy simultaneously? | Determines batch groupings |
| 8 | **Manual approval gates** — which components need approval before proceeding? | Sets `manual_approval` flags in app-config |
| 9 | **Health check definitions** — what does "healthy" mean per component? | Drives post-deployment validation |
| 10 | **Secrets strategy** — which charts use Vault/VSO vs pre-created secrets? | Affects secrets module configuration |

See `docs/Mavenir_Questions_Chart_Structure.md` for full detail on each question.

---

## 2.9 How Onboarding Feeds Into Deployment

The output of the onboarding process becomes the input to the deployment pipeline:

1. **Chart analysis** during onboarding produces the **app-config template** (Section 5) — the structure of what to deploy, with placeholders for values that vary per site/environment
2. **Chart packaging** produces Helm charts in **Nexus** — the vendor artifacts that ArgoCD pulls during deployment
3. **Network requirements** from the CIQ feed into the **CIQ blueprint** — the infrastructure data that support functions resolve against
4. **The app-config template + CIQ blueprint + IP allocations + environment config + user edits** are combined by the **values resolution pipeline** (Section 5a) to produce the fully populated deployment payload
5. The **deployment orchestrator** (Section 6) consumes the payload and deploys via ArgoCD

The onboarding process runs once per vendor/NF. The deployment pipeline runs on every deployment, upgrade, or rollback.

---

*Previous: [Section 1 — Architecture Overview](01-architecture-overview.md) | Next: [Section 3 — Artifact Intake & Promotion](03-artifact-intake.md)*
