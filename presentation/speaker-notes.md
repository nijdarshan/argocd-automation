# Speaker Notes — CNF Onboarding & Deployment Journey

Navigation: Arrow Right / Space to advance. R to restart (onboarding only). Arrow Left to go back (deployment only).

---

## Part 1: CNF Onboarding — Pre-Deployment

Open `onboarding-overview.html`. Press Arrow Right to step through.

### Step 0 — Column Headers

> "Before we get into the actual deployment, I want to walk through what happens before that — the onboarding process. There are three main actors: the **Vendor** who provides the CNF software, **VMO2 Hub** which is our orchestration platform, and **VMO2 Network / Infra / Security** who own infrastructure, Infoblox, and CI/CD."

### Step 1 — Phase 1: Vendor submits, Hub converts

> "The vendor submits their inputs — the CIQ (Customer Installation Questionnaire), their Helm charts, and container images. The **automation team** takes the Helm charts and converts them to our internal JSON format — applying placeholders to values. They also calculate the compute, IP, and storage requirements based on what the vendor has declared."

### Step 2 — Phase 1: Infra validates, shared responsibility

> "This then goes to the Network and Security teams who validate and approve the compute, storage, and IP sizing. If anything needs adjusting, feedback goes back to the vendor. This is a **shared responsibility** across all three parties — vendor has to provide accurate data, Hub processes it, and Infra/Security validates it."

### Step 3 — Phase 2: Hub provisions infrastructure

> "Once inputs are approved, the Hub interacts with **Infoblox** to slice subnets from supernets that have been allocated by the IP team. It also tags assets — servers, IP ranges, storage — and builds the workload cluster. This is largely automated through our platform."

### Step 4 — Phase 2: Infra validates provisioning

> "The Network/Infra team then validates what's been provisioned — confirming the network, compute, and storage are correct and the cluster is ready. IPs, VLANs, and cluster confirmation flow back to the Hub. This whole phase is **automated and validated** — we provision through APIs and the infra team confirms."

### Step 5 — Phase 3: Configuration generation

> "Now the Hub merges the vendor inputs with the network data to generate the actual `values.yaml` files and NetworkPolicy definitions. **Support functions** are applied at this stage — things like storage class resolution, IP range formatting, namespace construction. These are set up once per app. The generated config is committed to GitLab, where the CI/CD pipeline runs syntax and security validation."

### Step 6 — Footer

> "And that takes us to Phase 4 — the actual deployment, which I'll walk through next."

---

## Part 2: Deployment Journey

Open `deployment-journey.html`. Use Deploy/Rollback tabs at the top. Arrow Right/Left to navigate scenes.

### DEPLOY FLOW

#### Scene 1 — Architecture Overview

> "Here's the architecture. The **Service Orchestrator** (Hub) sits at the top — it's stateful, API-driven, and owns the deployment lifecycle. When a deployment starts, it triggers the **Pipeline**, which is stateless and runs per-component. The Pipeline commits to the **GitOps Repo** (our source of truth), ArgoCD detects changes and syncs to the **OCP Cluster**. The Pipeline reports status back to the **Hub Database**, which feeds back into the Orchestrator. **Nexus/Quay** stores charts and images."

#### Scene 2 — Deployment Request

> "Everything starts with a Helix ticket. When we receive a deployment request, the Service Orchestrator creates a deployment record in the database with status `pending`. This is our starting state — nothing is deployed yet."

#### Scene 3 — App-Config Resolution

> "Before deploying, the Hub resolves all placeholders in the app-config. For example, `{{ ip_range | CMS | oam }}` becomes the actual IP range `10.224.1.0/28` — pulled from the CIQ and Infoblox data we set up in onboarding. Same for namespace construction — `{{ dc_name | namespace | CMS }}` becomes `ims-cms-slough`. Replicas, storage sizes, everything gets resolved to concrete values."

#### Scene 4 — CMS Deploy (Pipeline to Cluster)

> "Now the actual deployment. CMS is batch 1 — it deploys first. CMS uses a **sequential chart pattern** — `cmsplatform` deploys first (sync_wave -5), and once it's healthy, `cmsnfv` deploys (sync_wave -4). The Pipeline generates the files, commits to GitOps, ArgoCD syncs, and pods come up on the OCP cluster. You can see the status transitioning: pending → syncing → healthy, one chart at a time."

#### Scene 5 — CMS Healthy → Approval Required

> "Once the CMS batch completes and all charts are healthy, the Pipeline reports back to the Hub. Here's where it gets interesting — the Hub checks the `app-config` and sees that CMS has `manual_approval: true` in its deployment_config. So it sets `pending_approval` to `true` in the runtime state. The deployment is now **paused**. This is important because some components need manual XML configuration or validation before we continue."

#### Scene 6 — Manual Approval Gate

> "This is what the paused state looks like. CMS is healthy on the left, but the next component (IMC) is waiting. The operator has to explicitly approve to continue. The message tells them what to do — 'Configure XML files before proceeding.' When they approve, `pending_approval` flips back to false and the deployment continues."

*Click the "Approve & Continue" button to demonstrate.*

#### Scene 7 — Batch Deployment (MTAS + FTAS)

> "Some components deploy in **parallel**. MTAS and FTAS are in the same batch (batch 3), so the Hub spins up two pipelines simultaneously. Each follows the same flow — commit to GitOps, ArgoCD syncs, health check. They both report back to the Hub DB independently. This is how we speed up deployments when components are independent."

#### Scene 8 — All Complete — SUCCESS

> "Once every component is healthy — all 14 of them — the deployment status changes to `success`. CMS, IMC, MTAS, FTAS, AGW, ENUMFE, SCEAS, LRF, MUAG, FUAG, CRDL, CBF, LIXP, MRF — all green. The Helix ticket gets updated and we're done."

---

### ROLLBACK FLOW

*Click the "Rollback" tab at the top.*

#### Scene 1 — Failure Detected

> "Now let's look at what happens when things go wrong. Here, IMC health check fails — only 4 out of 6 pods are ready. The Pipeline reports this back to the Hub API, which records `imc.status: unhealthy` in the database. Notice CMS is still healthy (it deployed before IMC), and MTAS hasn't started yet."

#### Scene 2 — Rollback Decision

> "The Service Orchestrator checks the deployment_config for IMC — specifically the `auto_rollback` flag. If it's `true`, rollback is automatic, no human intervention. If it's `false`, a human decides. In our case it's automatic."

#### Scene 3 — Git Revert

> "The Pipeline runs in rollback mode. It issues a `git revert` of the IMC commit in the GitOps repo. This is the beauty of GitOps — rollback is just another commit. The reverted state restores the previous known-good version."

#### Scene 4 — ArgoCD Sync + Validate

> "ArgoCD detects the revert commit, syncs the cluster back to the previous state. The cluster transitions from 'Redeploying' to 'Previous version running'. Then the Pipeline runs a health check to confirm the rollback was successful — pods_ready: 6/6. The result: IMC is `rolled_back` and the previous version is healthy."

#### Scene 5 — Full-Stack Rollback

> "In some scenarios, you need a full-stack rollback — every component rolled back in **reverse deployment order**. MRF first (it was deployed last), then LIXP, CBF, CRDL, all the way back to CMS. Each one goes through the same revert cycle. You can see the domino effect as each component transitions from healthy to rolled_back."

---

## Key Talking Points

- **GitOps as single source of truth** — deploy and rollback are both just git commits
- **Batched deployment** — components deploy in defined order, some sequential, some parallel
- **Manual approval gates** — configurable per component via `manual_approval` flag in app-config
- **Auto rollback** — configurable per component via `auto_rollback` flag
- **Placeholder resolution** — CIQ + Infoblox data → concrete values, one-time setup via support functions
- **Shared responsibility model** — vendor provides inputs, Hub orchestrates, Infra/Security validates
