# 4. Network Design & IP Allocation

> **Audience:** Platform engineers maintaining the Hub's CIQ generation and network integration.
> **Source docs:** CNF-Network-Provisioning-Presentation.md, Blueprint-Template-Variables.md, CIQ-Analysis-vs-Helm-and-Blueprint.md, Tabular-to-JSON-Transformation-Guide.md, Network_Team_Endpoint_Request.md, ciq_blueprint.json
> **Visual reference:** `docs/presentation/onboarding-overview.html` (Phase 2)

---

## 4.1 What This Phase Does

Phase 2 takes vendor requirements (what's needed) and turns them into live network infrastructure (what's provisioned). The Hub sits in the middle — it generates the CIQ, coordinates with the network team, and retrieves allocations via Infoblox API.

```
Vendor Input               Hub CIQ Generator           Network Team             Hub
(Phase 1)                  (calculates)                (provisions)             (retrieves)
─────────────             ──────────────────          ──────────────           ────────────
Subscribers: 40M    ───►  Pod counts: 790        ───► VLAN 1801 assigned  ───► values.yaml
Sites: PROD-1,2          IP counts: 250+              Subnet 172.16.33.0/24     gets real
Features: VoLTE,          Bandwidth: 11.4 Gbps        Gateway 172.16.33.1       IPs/VLANs
  VoWiFi, PSTN           QoS requirements             Firewall rules
                          External system reqs         LB VIPs
```

**Key principle:** The Hub specifies **what** is needed (IP count, protocols, bandwidth). The network team decides **how** (which VLAN, which subnet, which gateway). This separation means the Hub never makes network architecture decisions — it just captures requirements precisely enough that the network team can provision without back-and-forth.

---

## 4.2 CIQ Generation

### What the Hub Calculates

From vendor inputs (subscribers, BHCA, features, sites), the Hub computes:

| Output | How It's Calculated | IMS Example |
|--------|--------------------|----|
| **Pod counts** | Sizing formulas per component (see 4.3) | ~790 pods (690 non-DPDK + 100 DPDK) |
| **IP counts** | Sum of pods per network segment + VIPs + PIPs | ~250 IPs across all segments |
| **Bandwidth** | Traffic profiles × pod counts × protocol overhead | 11.4 Gbps intra-site, 5.5 Gbps inter-site |
| **VLAN requirements** | One per network segment type | 5+ VLANs (OAM, Diameter×2, SIP internal, SIP external) |
| **QoS markings** | Per protocol (DSCP values) | Diameter: EF (46), SIP: AF31 (26), OAM: CS1 (8) |
| **External systems** | Protocols, ports, directions, target systems | HSS, PCRF, STP, I-SBC, MGW, MRF endpoints |
| **Node requirements** | Non-DPDK vs DPDK, NUMA, NIC types | 46 non-DPDK + 20 DPDK per site pair |

### CIQ Output Structure

The CIQ specifies requirements, **not** allocations:

```yaml
# What the Hub outputs (requirements)
diamre_oam:
  ip_count: 12
  protocols: ["SCTP/3868", "TCP/3868"]
  bandwidth_sustained: "2 Gbps"
  bandwidth_burst: "4 Gbps"
  qos_dscp: 46
  external_destination: "HSS VIP, PCRF VIP"

# What the Network Team returns (allocations)
diamre_oam:
  vlan: 1801
  subnet: 172.16.33.86-89/24
  gateway: 172.16.33.1
  bond_interface: bond1.1801
```

The Hub never specifies VLAN IDs or IP subnets in the CIQ — only how many IPs, what protocols, and what bandwidth.

---

## 4.3 Sizing Formulas (IMS Reference)

These formulas drive pod count calculations. They come from the vendor's capacity planning data.

| Component | Formula | IMS PROD (40M subs) | IMS LAB (~10%) |
|-----------|---------|---------------------|----------------|
| **TAS SC** | `ceil(subscribers / 714,000)` | 56 pods | 3 pods |
| **SIPRE** | `ceil(subs_mobile / 7,000,000)` | 5 pods | 2 pods |
| **DIAMRE** | Fixed HA pairs per site | 6 pods | 4 pods |
| **SM** | Concurrent sessions formula | 40 pods | 4 pods |
| **VLBFE** | Scales with BHCA on DPDK nodes | 20 pods | 2 pods |
| **IMC SC** | Unclear — needs Mavenir confirmation | 72 pods (CIQ) | 12 (Helm) |
| **UAG MP** | Unclear — needs Mavenir confirmation | 46 pods (CIQ) | 2 (Helm) |

**Environment-specific scaling:**

```yaml
environments:
  production:
    sizing_multiplier: 1.0
    ha_redundancy: 1.4    # 40% headroom for failover
  test_lab:
    sizing_multiplier: 0.1  # ~10% of production
    ha_redundancy: 1.0      # no redundancy in lab
```

**Open item:** CIQ BOM shows production sizing; Helm `values-sample.yaml` shows lab sizing. These are different by design (10x factor) but must be reconciled per environment. The `sizing_multiplier` in the blueprint handles this.

---

## 4.4 The Blueprint (ciq_blueprint.json)

The blueprint is the infrastructure design document — it defines all networks, traffic types, interface assignments, and pod configurations per environment.

### Structure

```json
{
  "tag": "Testing",
  "blueprint": {
    "rnd": {
      "networks": [ ... ],     // 54 network definitions
      "pods": { ... }          // pod sizing per component per environment
    }
  }
}
```

> **Note:** The current blueprint (`ciq_blueprint.json`) contains only the `rnd` environment. Production (`prod`) and pre-production (`preprod`) environment entries must be added before deploying to those environments. The structure is identical — duplicate the `rnd` block with environment-specific sizing and network allocations.

### Network Definition

Each network contains multiple traffic types, one per NF (Network Function) type:

```json
{
  "network_name": "oam-External",
  "no_of_ip": 226,
  "subnet_size": "/24",
  "type": "external",
  "traffic_types": [
    {
      "traffic_type": "oam",
      "nf_type": "IMC",
      "vip_required": false,
      "consumers": ["APP", "SIPRE", "DIAMRE", "GTRE", "VLB", "SM"],
      "interface": "macvlan",
      "macvlan_if": "eth1"
    },
    {
      "traffic_type": "oam",
      "nf_type": "MTAS",
      "vip_required": false,
      "consumers": ["APP", "SIPRE", "DIAMRE", "GTRE", "VLB", "SM", "SS7RE"],
      "interface": "macvlan",
      "macvlan_if": "eth1"
    }
    // ... one entry per NF type that uses this network
  ]
}
```

### Key Fields

| Field | Meaning |
|-------|---------|
| `network_name` | Unique identifier for the network segment |
| `no_of_ip` | Total IPs required across all NF types using this network |
| `subnet_size` | Recommended subnet mask |
| `type` | `internal` (pod-to-pod) or `external` (reaches outside cluster) |
| `traffic_type` | Logical name (oam, diameter, sip_signaling, gre_internal, etc.) |
| `nf_type` | Which component uses this entry (IMC, MTAS, CMS, etc.) |
| `interface` | `macvlan` or `sriov` — determines how pods attach to the network |
| `macvlan_if` / `sriov_vf1` / `sriov_vf2` | Physical interface names on worker nodes |
| `bond_interface` | Bond name for SRIOV interfaces (DPDK) |
| `vip_required` | Whether this traffic type needs a Virtual IP (load balancer) |
| `pip_required` | Physical IP — needed when `vip_required=true` AND `interface=sriov` (DPDK can't use Whereabouts IPAM) |
| `consumers` | Which sub-chart components use this network (APP, SIPRE, DIAMRE, VLB, SM, etc.) |

### Interface Logic

```
If MACVLAN column has value → interface: "macvlan", use macvlan_if
If SRIOV columns have value → interface: "sriov", use sriov_vf1, sriov_vf2, bond_interface

PIP logic:
  pip_required = vip_required AND (interface == "sriov")
  (Because DPDK/SRIOV pods can't use Whereabouts IPAM for VIPs)
```

---

## 4.5 Network Segments

### Currently in Blueprint

| Segment | Purpose | Type | Interface |
|---------|---------|------|-----------|
| **oam-External** | Management, monitoring, SNMP, syslog | External | macvlan |
| **Core-Diameter-1/2** | Diameter signaling (HSS, PCRF, OCS queries) | External | macvlan |
| **Core-Signalling** | SIP signaling (call setup, registration) | External | macvlan |
| **GRE-Tunnel-*** | Internal GRE tunnels per component | Internal | sriov (DPDK) |
| **EMX-Signalling-*** | Internal signaling per component | Internal | macvlan/sriov |
| **Session-DB-*** | CRDL session database access | Internal | macvlan |

### Missing from Blueprint (Gaps)

| Segment | Purpose | Why It's Needed | Priority |
|---------|---------|-----------------|----------|
| **SIGTRAN-1/2** | SS7 over IP (SCTP) to STP | PSTN interconnect — required for fixed-line calls | High |
| **Core-Media** | RTP/RTCP media streams | Voice/video media path — required for all calls | High |
| **Access-Sig-Media-ipv6** | IPv6 access signaling | VoWiFi and future IPv6 requirements | Medium |

**Recommended additions:**

```yaml
sigtran_1:
  purpose: "SS7 signaling (SCTP)"
  protocols: ["SCTP/2905", "SCTP/9900"]
  qos_dscp: 26
  latency_requirement_ms: 100

core_media:
  purpose: "RTP media streams"
  protocols: ["RTP/16384-32767", "RTCP/16384-32767"]
  qos_dscp: 46
  latency_requirement_ms: 50
  bandwidth_model: "scales with concurrent calls"
```

---

## 4.6 External System Endpoints

The Hub needs IP/port/DC data for every external system the CNF communicates with. This feeds into CIQ generation and later into NetworkPolicy rules.

### By Protocol

| Protocol | Ports | Systems | Status |
|----------|-------|---------|--------|
| **SIP** | 5060 (UDP/TCP), 5061 (TLS) | EPG, NSBG, I-SBC, MGW, MRF, ENM-BE, Ribbon Q.20 | Partially captured |
| **Diameter** | 3868 (TCP/SCTP) | DSC1, DSC2, CBF, PCRF, HSS, OCS | Partially captured |
| **RTP/RTCP** | 10000-60000 (UDP) | MGW, MRF, SBG, UPF | **Missing from blueprint** |
| **SIGTRAN** | 2905 (M3UA), 14001 (SCTP) | STP98, STP99, ENUMFE, MTAS | **Missing from blueprint** |
| **REST/HTTP** | 80, 443, 8080 | NetCracker, SCEAS, Foresight, F5-LB | Partially captured |
| **OAM** | 161/162, 514, 123, 53 | Netcool, syslog, NTP, DNS | Captured |
| **Database** | DNS/custom | ENUMFE, RDB, Voice Mail, IPSMGWY | Partially captured |

### Required Data Per Endpoint

```json
{
  "protocol": "Diameter",
  "system": "DSC1",
  "purpose": "DRA/DEA Primary",
  "endpoints": [
    {
      "datacenter": "Slough",
      "ip": "10.50.20.10",
      "port": 3868,
      "transport": "SCTP",
      "direction": "bidirectional",
      "redundancy": "active/standby",
      "firewall_zone": "core"
    }
  ]
}
```

**Outstanding request:** Formal endpoint data requested from Network Team (Graham) — see `docs/Network_Team_Endpoint_Request.md`. Covers all 7 protocol categories with preferred JSON output format.

### Network Design Process

The network team provides supernets (parent ranges) based on the comms matrix and destination endpoints. The service orchestration portal then:

1. **Slices subnets** from parent ranges based on component requirements (pod count, VIP count, interface count)
2. **Adds configurable buffer** — default 25% extra IPs per subnet for growth and HA
3. **Generates Infoblox allocation requests** — structured data for automated or manual provisioning

Network-specific details (multi-DC routing, firewall rules, intermediary devices) are resolved during the network design phase and captured in the CIQ blueprint.

---

## 4.7 Hub ↔ Infoblox Integration

### Current Flow (Manual + API)

```
Hub generates CIQ requirements
        │
        ▼
Network team provisions in Infoblox manually
  - Creates subnets
  - Assigns VLANs
  - Tags resources: app=ims, env=prod, component=mtas, segment=oam
        │
        ▼
Hub retrieves allocations via Infoblox API
  - Query by tags: GET /wapi/v2.12/network?*app=ims&*env=prod
  - Returns: subnet, gateway, VLAN, available IPs
        │
        ▼
Hub uses allocations to generate values.yaml
```

### Tag-Based Retrieval

Infoblox resources are tagged with extensible attributes that the Hub queries:

| Tag | Purpose | Example |
|-----|---------|---------|
| `app` | Application domain | `ims`, `pcrf`, `ccs` |
| `env` | Environment | `prod`, `preprod`, `rnd` |
| `component` | NF component | `mtas`, `cms`, `agw` |
| `segment` | Network segment | `oam`, `diameter`, `sip_signaling` |
| `site` | Datacenter | `slough`, `reading` |

This tagging scheme means the Hub doesn't hardcode any IP addresses — it discovers them dynamically. When a network team provisions a new site, they tag it and the Hub picks it up automatically.

### Future: Zero-Touch Provisioning (ZTP)

The long-term vision is to remove the manual provisioning step:

```
Current:  Hub → CIQ → Network Team (manual) → Infoblox → Hub retrieves
Future:   Hub → Infoblox API directly → Network Team approves → Hub retrieves
```

- Hub would request subnet allocation directly via Infoblox WAPI
- Network team provides an **approval gate** instead of manual provisioning
- Supernets and VLAN pools pre-allocated per site; Hub slices as needed
- Reduces Phase 2 from days to minutes

---

## 4.8 Site-Specific Variables (12 Categories)

Everything that changes between sites or environments must be parameterized. The blueprint template captures these across 12 categories:

| # | Category | What Changes | Example |
|---|----------|-------------|---------|
| 1 | **Network** | VLAN IDs, subnets, bonds, VIPs | PROD-1: VLAN 1801, PROD-2: VLAN 2201 |
| 2 | **K8s Cluster** | Cluster name, namespace, node count | `mavenir-ims-prod-1` vs `prod-2` |
| 3 | **Capacity** | Subscriber count, pod replicas, CPU/memory | 24M subs (60% hub) vs 16M subs (40% spoke) |
| 4 | **External Systems** | HSS/PCRF/OCS IPs per region | `10.50.20.10` (Slough) vs `10.50.21.10` (Reading) |
| 5 | **DNS/FQDNs** | Service domains, certificate SANs | `sip-prod-1.ims.uk` vs `sip-prod-2.ims.uk` |
| 6 | **Storage** | Storage class, size, backup retention | `fast-ssd-prod` vs `standard-hdd-lab` |
| 7 | **Security** | TLS certs, CA bundle, security policies | `strict-prod` vs `relaxed-lab` |
| 8 | **Config** | Log levels, feature flags, debug settings | `INFO` (prod) vs `DEBUG` (lab) |
| 9 | **Peering** | Peer carrier lists, interconnect VLANs | 15 peers (hub) vs 8 peers (spoke) |
| 10 | **Compliance** | Data residency, encryption, retention | UK vs EU requirements |
| 11 | **Time/Locale** | Timezones, NTP servers | `Europe/London`, site-local NTP |
| 12 | **Resource Flavors** | Worker node types, NIC models, NUMA | Ice Lake vs Cascade Lake |

### Hub Data Store Structure

```yaml
sites:
  PROD-1:
    cluster_name: mavenir-ims-prod-1
    capacity_tier: hub        # 60% traffic
    timezone: Europe/London
    vlan_pool: [1800-1900]
    subnet_pool: 172.16.33.0/16
  PROD-2:
    cluster_name: mavenir-ims-prod-2
    capacity_tier: spoke      # 40% traffic
    timezone: Europe/London
    vlan_pool: [2200-2300]
    subnet_pool: 172.17.33.0/16

environments:
  prod:
    log_level: INFO
    security_policy: strict
    sizing_multiplier: 1.0
  rnd:
    log_level: DEBUG
    security_policy: relaxed
    sizing_multiplier: 0.1

external_systems:
  hss:
    PROD-1: 10.50.20.10
    PROD-2: 10.50.21.10
  pcrf:
    PROD-1: 10.50.20.20
    PROD-2: 10.50.21.20
```

**Generation flow:**
1. Vendor submits: Sites [PROD-1, PROD-2]
2. Hub looks up: site inventory, environment profiles, external systems, network standards
3. Hub generates: site-specific CIQs
4. Network team: provisions PROD-1 and PROD-2 allocations separately
5. Hub generates: `values-prod-1.yaml` and `values-prod-2.yaml` with all variables filled

---

## 4.9 Tabular-to-JSON Transformation

Network data often starts as spreadsheets. The Hub needs it as structured JSON in the blueprint. Here's the transformation logic:

### Source (Spreadsheet Row)

```
NF Type | Traffic-type | Network Name | Internal/External
MACVLAN-if | SRIOV-VF-1 | SRIOV-VF-2 | Bond Interface
VIP Required | [Consumer columns: APP, SIPRE, DIAMRE, GTRE, VLB, SM, SS7RE, ...]
```

### Target (Blueprint JSON)

```json
{
  "network_name": "GRE-Tunnel-MTAS",
  "no_of_ip": 7,
  "subnet_size": "/28",
  "type": "internal",
  "traffic_types": [
    {
      "traffic_type": "vfe_gre",
      "interface": "sriov",
      "sriov_vf1": "fpeth3",
      "sriov_vf2": "fpeth4",
      "bond_interface": "fpbond0",
      "vip_required": true,
      "pip_required": true,
      "consumers": ["VLB"]
    }
  ]
}
```

### Transformation Rules

1. **Group rows** by `(NF Type, Network Name)` → one JSON network object
2. **Each row** → one `traffic_type` entry
3. **Interface detection:**
   - MACVLAN column has value (not `NA`) → `"interface": "macvlan"`
   - SRIOV columns have value → `"interface": "sriov"`
4. **PIP logic:** `pip_required = vip_required AND (interface == "sriov")`
5. **Consumers:** List of column names where cell value is "YES"
6. **`no_of_ip` and `subnet_size`** come from IP plan, not the CIQ table

### Edge Cases

- `NA` in interface columns → treat as empty
- Case-insensitive for YES/NO
- Multiple NF types can share the same network name (group by both)
- If neither MACVLAN nor SRIOV is specified → default to `macvlan` (or `calico` for pure cluster-internal)

---

## 4.10 IMS Reference: Network Topology Summary

For a 40M subscriber IMS deployment across two sites:

| Metric | Value |
|--------|-------|
| **Total pods** | ~790 (690 non-DPDK + 100 DPDK) |
| **Total IPs** | ~250 across all segments |
| **VLANs** | 5+ per site (OAM, Diameter×2, SIP internal, SIP external) |
| **Nodes** | 46 non-DPDK + 20 DPDK per site pair |
| **Intra-site bandwidth** | 11.4 Gbps |
| **Inter-site bandwidth** | 5.5 Gbps |
| **Hub site (60% traffic)** | PROD-1 — 24M subs equivalent |
| **Spoke site (40% traffic)** | PROD-2 — 16M subs equivalent |

### Site Distribution

```
         Hub Site (PROD-1)                Spoke Site (PROD-2)
         60% of traffic                   40% of traffic
    ┌─────────────────────┐          ┌─────────────────────┐
    │  ~474 pods          │  ◄────►  │  ~316 pods          │
    │  28 non-DPDK nodes  │  Inter-  │  18 non-DPDK nodes  │
    │  12 DPDK nodes      │  site    │   8 DPDK nodes      │
    │  ~150 IPs           │  link    │  ~100 IPs           │
    └─────────────────────┘  5.5Gbps └─────────────────────┘
```

---

## 4.11 Current Gaps & Open Items

| Gap | Impact | Priority | Notes |
|-----|--------|----------|-------|
| SIGTRAN network segments missing from blueprint | Can't provision PSTN interconnect | High | Add `sigtran_1`, `sigtran_2` |
| Core-Media network missing | Can't provision RTP media path | High | Add `core_media` |
| IPv6 access networks missing | VoWiFi may not work | Medium | Add when IPv6 requirements confirmed |
| External endpoint data incomplete | CIQ generation produces partial requirements | High | Awaiting network team response |
| Sizing formulas for IMC, UAG unclear | Can't auto-calculate correct pod counts | Medium | Awaiting Mavenir confirmation |
| TAS DIAMRE sizing incorrect (4 vs 6) | Under-provisioned in current Helm values | Medium | Fix to 6 (fixed HA per site) |
| No environment-specific sizing multiplier in blueprint | Lab and prod use same pod counts | Medium | Add `sizing_multiplier` per env |
| ZTP not implemented | Phase 2 still requires manual network provisioning | Low (future) | Design ready, needs infra approval |
| Cross-namespace service references must use full FQDN | Services in different namespaces (e.g., `ims-mtas` calling `ims-cms`) cannot use short names when proxies or custom DNS resolvers are involved | High | All cross-namespace references in values.yaml must use `service.namespace.svc.cluster.local:port` format. Short names (`service.namespace:port`) fail with nginx resolver, envoy, and other proxy DNS lookups |

---

*Previous: [Section 3 — Artifact Intake & Promotion](03-artifact-intake.md) | Next: [Section 5 — Data Models & Template System](05-data-models-templates.md)*
