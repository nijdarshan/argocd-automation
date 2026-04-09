# Support Functions Guide

One document, three sections:

- **Part I: Base Reference** – Shared: all function definitions, syntax, examples
- **Part II: Guide for Backend** – Converting YAML→JSON, editable vs non-editable, applying placeholders
- **Part III: Guide for Frontend** – How to read, parse, and resolve placeholders

**Related**: VMO2_Helm-Charts_Update_Guide_v1.8.pdf – portal flow and Helm chart updates.

---

## Flow: Where Placeholders Live

**Placeholders live in JSON (app-config), not in YAML.**

1. **YAML** (Helm values) → convert to **JSON** – structure preserved
2. **JSON** (app-config) – add placeholders to fields that need portal resolution
3. **Portal populates** – resolves placeholders in JSON
4. **JSON** (resolved) → convert to **YAML** – for deployment

**Structure must be identical at all points.** The JSON structure exactly mirrors the YAML structure so conversion is lossless in both directions.

---

# Part I: Base Reference

## 1. Placeholder Syntax

Placeholders use Jinja2/Ansible-style syntax. **Standard format**: 3 parts (function + 2 args).

```
{{ function_name | arg1 | arg2 }}
```

- **function_name**: The resolver to call (e.g. `whereabouts_range_end`, `pip_array`)
- **arg1**: Usually `network_name` (logical name from blueprint, e.g. `EMX-Signalling-MTAS`) — **not** the YAML CNI name like `macvlan-tas-app-emx`
- **arg2**: Usually `pod_name` (e.g. `SM`, `VLB`, `TAS`) or `component` / `nic` for cross-component and SRIOV functions

**Context at population time**: The portal has runtime context when resolving: `dc_name` (e.g. `slough`), `env` (e.g. `prod`, `preprod`, `rnd`), `tenant` (e.g. `IMS`). These are **not** in the placeholder – the portal injects them at values population time.

**Important**: Use **blueprint/network config names**, not the YAML network attachment names.

| Use in placeholders | Do **not** use |
|---------------------|----------------|
| `EMX-Signalling-MTAS` | `macvlan-tas-app-emx` |
| `oam-External` | `macvlan-tas-sm-oam` |

Example: `{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}` → `"172.16.50.2-172.16.50.4/26"`

---

## 2. Function Naming Convention

Function names follow: **`<plugin_or_domain>_<output_type>`**

- **whereabouts_range_end** = `whereabouts` + `range_end`
- **vip_array** = `vip` + `array`
- **pip_array** = `pip` + `array`
- **gateway_str** = `gateway` + `str`

---

## 3. Whereabouts IPAM Functions

These functions allocate IP range slices from a shared supernet. When multiple components use the same network (e.g., `oam-External`), each component gets a non-overlapping slice. The resolution pipeline iterates components per network, counts pods + VIPs + 25% buffer, and allocates sequential slices. See Section 4 for the full slicing algorithm.

### `whereabouts_range_end`

Returns IP range in `"start-end/mask"` format for a network and pod type.

**Arguments**: `network_name`, `pod_name`  
**Output**: String like `"172.16.50.2-172.16.50.4/26"`  
**Used in**: `ipam.range`

**JSON** (app-config, with placeholder):
```json
{
  "ipam": {
    "type": "whereabouts",
    "range": "{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}"
  }
}
```

**JSON** (resolved):
```json
{
  "ipam": {
    "type": "whereabouts",
    "range": "172.16.50.2-172.16.50.4/26"
  }
}
```

**YAML** (output for deployment):
```yaml
ipam:
  type: whereabouts
  range: "172.16.50.2-172.16.50.4/26"
```

---

### `whereabouts_range_cidr`

Returns CIDR-only range for networks with single CIDR block.

**Arguments**: `network_name`  
**Output**: String like `"10.x.x.247/24"`  
**Used in**: `ipam.range` (FTAS)

**JSON** (app-config, with placeholder):
```json
{
  "ipam": {
    "type": "whereabouts",
    "range": "{{ whereabouts_range_cidr | OAM-SM-MTAS }}"
  }
}
```

**JSON** (resolved) → **YAML** (output): structure identical, `range` becomes `"10.69.96.247/24"`.

---

### `ipam_subnet`

Returns subnet CIDR for a network.

**Arguments**: `network_name`  
**Output**: String like `"10.69.96.0/24"`  
**Used in**: CMS `ipamsubnet`

**JSON** (app-config, with placeholder):
```json
{
  "ipamsubnet": "{{ ipam_subnet | oam-External }}"
}
```

**JSON** (resolved):
```json
{
  "ipamsubnet": "10.69.96.0/24"
}
```

**YAML** (output for deployment):
```yaml
ipamsubnet: "10.69.96.0/24"
```

---

### `ipam_range_start` / `ipam_range_end`

Return first and last IP in range for network and pod type.

**Arguments**: `network_name`, `pod_name`  
**Output**: Strings like `"10.69.96.2"` and `"10.69.96.3"`  
**Used in**: CMS `ipamrangestart`, `ipamrangeend`

**JSON** (app-config, with placeholder):
```json
{
  "ipamrangestart": "{{ ipam_range_start | oam-External | CMS }}",
  "ipamrangeend": "{{ ipam_range_end | oam-External | CMS }}"
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

## 4. VIP / PIP Functions

### `vip_array`

Returns Virtual IP for a network as array. One VIP per network for HA.

**Arguments**: `network_name`, `pod_name`  
**Output**: Array e.g. `["172.16.50.30"]`  
**Used in**: `networking.ipPools[].addresses`

**JSON** (app-config, with placeholder):
```json
{
  "networking": {
    "ipPools": [
      {
        "name": "IMS-EMX-Signalling-TAS-vip",
        "addresses": "{{ vip_array | EMX-Signalling-MTAS | VLB }}"
      }
    ]
  }
}
```

**JSON** (resolved): `addresses` becomes `["172.16.50.30"]` → **YAML** (output): structure identical.

---

### `pip_array`

Returns Physical IPs for SRIOV/DPDK interfaces. Count scales with pod replicas.

**Arguments**: `network_name`, `pod_name`  
**Output**: Array e.g. `["172.16.50.28","172.16.50.29"]`  
**Used in**: `networking.ipPools[].addresses`

**JSON** (app-config, with placeholder):
```json
{
  "networking": {
    "ipPools": [
      {
        "name": "IMS-GRE-Tunnel-TAS-pip",
        "addresses": "{{ pip_array | GRE-Tunnel-IMC | VLB }}"
      }
    ]
  }
}
```

**JSON** (resolved): `addresses` becomes `["172.16.50.28","172.16.50.29"]` → **YAML** (output): structure identical.

---

## 5. Network Metadata Functions

### `vlan`

Returns VLAN ID for a network.

**Arguments**: `network_name`, `pod_name`  
**Output**: Integer e.g. `3200`  
**Used in**: `master: bond0.{{ vlan | oam-External | VLB }}`

**JSON** (app-config, with placeholder):
```json
{
  "master": "bond0.{{ vlan | oam-External | VLB }}"
}
```

**JSON** (resolved): `master` becomes `"bond0.3200"` → **YAML** (output): structure identical.

---

### `gateway_str`

Returns default gateway IP for a network subnet.

**Arguments**: `network_name`, `pod_name`  
**Output**: String e.g. `"10.69.96.1"`  
**Used in**: `extra_user_data.network.*.GATEWAY`

**JSON** (app-config, with placeholder):
```json
{
  "extra_user_data": {
    "network": {
      "fpbond0": {
        "GATEWAY": "{{ gateway_str | oam-External | VLB }}"
      }
    }
  }
}
```

**JSON** (resolved): `GATEWAY` becomes `"10.69.96.1"` → **YAML** (output): structure identical.

---

### `prefix`

Returns subnet prefix length (CIDR mask).

**Arguments**: `network_name`, `pod_name`  
**Output**: Integer e.g. `22`  
**Used in**: `extra_user_data.network.*.PREFIX`

**JSON** (app-config, with placeholder):
```json
{
  "extra_user_data": {
    "network": {
      "fpbond0": {
        "PREFIX": "{{ prefix | oam-External | VLB }}"
      }
    }
  }
}
```

**JSON** (resolved): `PREFIX` becomes `22` → **YAML** (output): structure identical.

---

## 6. SRIOV Functions

### `sriov_pool`

Returns SRIOV resource pool name for network and NIC.

**Arguments**: `network_name`, `nic` (e.g. `ens5f1`)  
**Output**: String e.g. `sriov_dpdk_agw1_vlb_ens5f1_gre_tunnel`  
**Used in**: `resources.limits["openshift.io/<pool>"]`

**JSON** (app-config, with placeholder):
```json
{
  "resources": {
    "limits": {
      "openshift.io/{{ sriov_pool | GRE-Tunnel-IMC | ens5f1 }}": "1"
    }
  }
}
```

**JSON** (resolved): key becomes `openshift.io/sriov_dpdk_agw1_vlb_ens5f1_gre_tunnel` → **YAML** (output): structure identical.

---

### `pci_env`

Returns PCI device env var name for SRIOV pool.

**Arguments**: `network_name`, `nic`  
**Output**: String e.g. `PCIDEVICE_OPENSHIFT_IO_SRIOV_DPDK_AGW1_VLB_ENS5F1_GRE_TUNNEL`  
**Used in**: VLB `env.fpeth*` entries

**JSON** (app-config, with placeholder):
```json
{
  "env": [
    {
      "name": "{{ pci_env | GRE-Tunnel-IMC | ens5f1 }}",
      "valueFrom": {
        "fieldRef": {
          "fieldPath": "status.podIP"
        }
      }
    }
  ]
}
```

**JSON** (resolved): `name` becomes `PCIDEVICE_OPENSHIFT_IO_...` → **YAML** (output): structure identical.

---

## 7. Cross-Component Function

### `component_ips`

Returns IP addresses of a component on a given network.

**Arguments**: `component` (e.g. `CMS`), `network_name`  
**Output**: Array e.g. `["10.69.96.4","10.69.96.5"]`  
**Used in**: `sm.cmsIPAddresses`, similar patterns

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "cmsIPAddresses": "{{ component_ips | CMS | oam-External }}"
  }
}
```

**JSON** (resolved): `cmsIPAddresses` becomes `["10.69.96.4","10.69.96.5"]` → **YAML** (output): structure identical.

---

## 8. Platform Functions

### `namespace`

**Arguments**: `dc_name`, `nf_type`  
**Output**: String e.g. `"ims-mtas-slough"`  

**JSON** (app-config, with placeholder):
```json
{
  "global": {
    "namespace": {
      "name": "{{ namespace | dc_name | MTAS }}"
    }
  }
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

### `image_registry`

**Arguments**: `nf_type`, `env`  
**Output**: String – registry URL (prod vs preprod)  

**JSON** (app-config, with placeholder):
```json
{
  "global": {
    "image": {
      "repository": "{{ image_registry | MTAS | env }}"
    }
  }
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

### `pull_secret`

**Tenant-specific**, not component-specific.  
**Arguments**: `tenant`, `env`  
**Output**: String e.g. `"mav-reg"`  

**JSON** (app-config, with placeholder):
```json
{
  "global": {
    "image_secrets": [
      { "name": "{{ pull_secret | tenant | env }}" }
    ]
  }
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

### `storage_class`

**Arguments**: `dc_name`, `nf_type`  
**Output**: String e.g. `"ocs-storagecluster-ceph-rbd"`  

**JSON** (app-config, with placeholder):
```json
{
  "volumes": [
    {
      "name": "data",
      "class": "{{ storage_class | dc_name | MTAS }}"
    }
  ]
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

### `image`

**Arguments**: `pod_name`, `nf_type`  
**Output**: Full image reference (registry/name:tag)  

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "image": "{{ image | SM | MTAS }}"
  }
}
```

**JSON** (resolved) → **YAML** (output): structure identical.

---

## 9. Sizing Functions

These functions resolve replica counts, resource limits/requests, and storage sizes from the CIQ blueprint. Using placeholders instead of hardcoded values means the template never needs manual edits when sizing changes between sites or environments.

### `replicas`

Returns replica count for a pod type within a component.

**Arguments**: `component`, `pod_name`
**Output**: Integer e.g. `3`
**Data source**: CIQ blueprint pod counts

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "replicas": "{{ replicas | IMC | SM }}"
  }
}
```

**JSON** (resolved): `"replicas"` becomes `3` (integer) → **YAML** (output): structure identical.

---

### `cpu_request` / `cpu_limit`

Returns CPU request or limit for a pod type.

**Arguments**: `component`, `pod_name`
**Output**: String e.g. `"4000m"`
**Data source**: CIQ blueprint resource sizing

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "resources": {
      "requests": { "cpu": "{{ cpu_request | MTAS | SM }}" },
      "limits":   { "cpu": "{{ cpu_limit | MTAS | SM }}" }
    }
  }
}
```

**JSON** (resolved): becomes `"4000m"` → **YAML** (output): structure identical.

---

### `memory_request` / `memory_limit`

Returns memory request or limit for a pod type.

**Arguments**: `component`, `pod_name`
**Output**: String e.g. `"16G"`
**Data source**: CIQ blueprint resource sizing

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "resources": {
      "requests": { "memory": "{{ memory_request | MTAS | SM }}" },
      "limits":   { "memory": "{{ memory_limit | MTAS | SM }}" }
    }
  }
}
```

**JSON** (resolved): becomes `"16G"` → **YAML** (output): structure identical.

---

### `storage_size`

Returns storage size for a named volume within a component. The volume name may include an `_internal` or `_external` suffix to distinguish storage types:

- **`_internal`** — cluster-local storage (e.g., local SSDs, Ceph RBD within the cluster)
- **`_external`** — external storage (e.g., SAN, NAS, external Ceph)

The suffix determines which size profile is used from the blueprint. Different storage types have different capacity allocations for the same logical volume.

**Arguments**: `component`, `volume_name` (e.g., `sm-storage`, `sm-storage_internal`, `sm-storage_external`)
**Output**: String e.g. `"31G"` (internal) or `"50G"` (external)
**Data source**: CIQ blueprint storage sizing, keyed by volume name with `_internal`/`_external` suffix

**JSON** (app-config, with placeholder):
```json
{
  "sm": {
    "volumes": {
      "sm-storage": {
        "resources": { "requests": { "storage": "{{ storage_size | MTAS | sm-storage }}" } }
      }
    }
  }
}
```

**JSON** (resolved): becomes `"31G"` → **YAML** (output): structure identical.

---

### Combined Example — Full Pod Resource Specification

A realistic MTAS SM pod showing all sizing functions together: replicas, CPU, memory, and storage.

**JSON** (app-config, with placeholders):
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
    "volumes": {
      "sm-storage": {
        "class": "{{ storage_class | dc_name | MTAS }}",
        "resources": {
          "requests": {
            "storage": "{{ storage_size | MTAS | sm-storage }}"
          }
        }
      }
    }
  }
}
```

**JSON** (resolved):
```json
{
  "sm": {
    "replicas": 3,
    "image": "quay.io/nokia/mtas-sm:24.3.0-123",
    "resources": {
      "requests": {
        "cpu": "4000m",
        "memory": "16G"
      },
      "limits": {
        "cpu": "4000m",
        "memory": "16G"
      }
    },
    "volumes": {
      "sm-storage": {
        "class": "ocs-storagecluster-ceph-rbd",
        "resources": {
          "requests": {
            "storage": "31G"
          }
        }
      }
    }
  }
}
```

**YAML** (output for deployment):
```yaml
sm:
  replicas: 3
  image: "quay.io/nokia/mtas-sm:24.3.0-123"
  resources:
    requests:
      cpu: "4000m"
      memory: "16G"
    limits:
      cpu: "4000m"
      memory: "16G"
  volumes:
    sm-storage:
      class: "ocs-storagecluster-ceph-rbd"
      resources:
        requests:
          storage: "31G"
```

All values come from the CIQ blueprint — changing the site or environment resolves different values without touching the template.

---

## 10. Summary Table

| Category       | Functions                                                                 |
|----------------|---------------------------------------------------------------------------|
| **Whereabouts**| `whereabouts_range_end`, `whereabouts_range_cidr`, `ipam_subnet`, `ipam_range_start`, `ipam_range_end` |
| **IP pools**   | `vip_array`, `pip_array`                                                 |
| **Network**    | `vlan`, `gateway_str`, `prefix`                                          |
| **SRIOV**      | `sriov_pool`, `pci_env`                                                  |
| **Cross-comp** | `component_ips`                                                          |
| **Platform**   | `namespace`, `image_registry`, `pull_secret`, `storage_class`, `image`   |
| **Sizing**     | `replicas`, `cpu_request`, `cpu_limit`, `memory_request`, `memory_limit`, `storage_size` |

---

## 11. Data Sources

- **ciq_blueprint.json**: Networks, IP counts, subnet sizes, pod placement, replicas, VIP/PIP requirements
- **app-config.json**: Chart structure, image mappings, deploy order
- **blueprint.site.networks** (from app onboarding): vlan, subnet, gateway keyed by `dc_name`

---

## 12. Known Inconsistencies

| Issue | Location | Resolution |
|-------|----------|------------|
| PIP format typo | AGW: `["<172.x.x.4","172.x.x.5>"]` | Output `["ip1","ip2"]` |
| FTAS CIDR-only | `range: "<10.x.x.247/24>"` | Use `whereabouts_range_cidr` |
| CMS IPAM | Uses `ipamsubnet`, `ipamrangestart`, `ipamrangeend` | Different from standard `ipam.range` |
| ENUMFE pci_env | Lowercase `sriov_dpdk` | Normalize to expected format |

---

# Part II: Guide for Backend

**Audience**: Backend team converting Helm values to JSON, classifying editable vs non-editable fields, and applying support function placeholders.

---

## 1. Your Role in the Process

You support the App Onboarding Portal by:

1. **Converting YAML values to JSON** – Structuring Helm values for portal consumption
2. **Classifying fields** – Marking each field as user-editable or non-editable
3. **Applying support functions** – Replacing hardcoded values with placeholders where the portal must populate them

The portal combines vendor inputs, blueprint data, and app config to produce deployment-ready values. Your work ensures the right fields are locked (non-editable) and the right fields use placeholders for portal resolution.

---

## 2. Editable vs Non-Editable Rules

### Rationale

The portal and blueprint drive **cluster sizing**, **IP allocation**, and **network design**. If a user changes replicas, IPs, or resource limits, the deployment can fail (e.g. not enough IPs for replicas, undersized cluster). These fields must be **non-editable**.

Fields that do not affect sizing, IP allocation, or blueprint consistency can be **editable** for application-specific tuning.

### Non-Editable (User Cannot Change)

| Category | Fields | Why |
|----------|--------|-----|
| **Replicas** | `replicas` for any pod | Replicas drive IP count (whereabouts, PIP). Changing replicas without updating IP allocation breaks deployment. |
| **IPs & ranges** | `ipam.range`, `ipamsubnet`, `ipamrangestart`, `ipamrangeend`, `networking.ipPools[].addresses` | Allocated by Infoblox IPAM. User must not override. |
| **Network metadata** | `vlan`, `gateway`, `prefix`, `master` (bond interface) | From network design; changing breaks connectivity. |
| **Platform** | `namespace`, `image_registry`, `pull_secret`, `storage_class`, `image` | Set by portal from `dc_name`, `env`, `tenant`. |
| **Resource limits** | `resources.limits`, `resources.requests` (CPU, memory) | Part of cluster sizing. Changing affects capacity planning. |
| **SRIOV** | `sriov_pool`, `pci_env` references | Tied to hardware and network design. |

**Rule of thumb**: If changing it would break IP allocation, replica consistency, cluster sizing, or network connectivity → **non-editable**.

### Editable (User Can Change)

Fields that do **not** affect blueprint, IP allocation, or cluster sizing. Examples (verify per component):

- Application-specific config (feature flags, log levels)
- Environment variables that are not IPs, ports, or network-related
- Timeouts, retry counts, buffer sizes (where they don't affect sizing)

**Rule of thumb**: If it's purely application behaviour and doesn't touch replicas, IPs, resources, or network → consider **editable**.

---

## 3. Converting YAML to JSON

**Placeholders live in JSON (app-config), not in YAML.** The flow is: YAML → JSON (add placeholders) → Portal populates → JSON (resolved) → YAML (output). **Structure must be identical at all points.**

### Rules

- Preserve structure: nested keys become nested JSON objects (exact 1:1 mapping with the Helm values.yaml)
- Preserve types: numbers stay numbers, booleans stay booleans
- For arrays (e.g. `addresses`, `consumers`), keep as JSON arrays
- Add placeholders in JSON where the portal must populate (not in YAML)
- **Use nested JSON** (not flat dot-path keys) for both `user_editable` and `non_editable` under `helm_values` — the JSON structure must mirror the Helm values.yaml hierarchy exactly

### user_editable and non_editable (app-config format)

Each chart uses `user_editable` and `non_editable` under `helm_values`. Both use **nested JSON that mirrors the Helm values.yaml structure**. At deployment time, both objects are deep-merged by key to produce the final values file. Values in `non_editable` use support function placeholders where the portal must resolve them.

**Why nested, not flat dot-path?**
- The JSON structure is identical to the YAML structure at every stage (YAML → JSON → resolved JSON → YAML). Nested JSON preserves this 1:1 mapping naturally.
- Deep-merge by key is straightforward — no dot-path expansion/parsing needed.
- Part I and Part III of this guide already use nested JSON for all examples. This keeps everything consistent.

**Example** (AGW-style):

```json
{
  "helm_values": {
    "user_editable": {
      "global": {
        "secrets": false,
        "enableNetworkPolicy": false,
        "enableMultiNetworkPolicy": false
      },
      "sm": {
        "extra_user_data": {
          "config": {
            "VNF_TYPE": "AGW",
            "CLOUD_PROFILE_ID": "NFV30"
          }
        }
      }
    },
    "non_editable": {
      "global": {
        "serviceAccountName": "ims-agw-svc",
        "namespace": {
          "name": "{{ namespace | dc_name | AGW }}"
        },
        "image": {
          "repository": "{{ image_registry | AGW | env }}"
        },
        "image_secrets": [
          { "name": "{{ pull_secret | tenant | env }}" }
        ]
      },
      "sm": {
        "replicas": 3,
        "image": "{{ image | SM | AGW }}",
        "resources": {
          "limits": { "cpu": "4000m", "memory": "16G" },
          "requests": { "cpu": "4000m", "memory": "16G" }
        },
        "cmsIPAddresses": "{{ component_ips | CMS | oam-External }}",
        "networking": {
          "ipPools": "{{ vip_array | EMX-Signalling-AGW | VLB }}"
        },
        "volumes": {
          "sm-storage": {
            "class": "{{ storage_class | dc_name | AGW }}"
          }
        }
      },
      "agw": {
        "replicas": 2,
        "image": "{{ image | AGW | AGW }}"
      },
      "networks": [
        {
          "name": "macvlan-agw-sm-oam",
          "type": "networks_macvlan",
          "master": "bond0.{{ vlan | oam-External | SM }}",
          "ipam": {
            "type": "whereabouts",
            "range": "{{ whereabouts_range_end | oam-External | SM }}"
          }
        }
      ]
    }
  }
}
```

- **user_editable**: Nested JSON matching the Helm values hierarchy. Values are defaults the user can change in the portal.
- **non_editable**: Nested JSON matching the Helm values hierarchy. Values are either literals or support function placeholders. Portal resolves placeholders before generating YAML.
- **Merge**: At deployment time, `non_editable` and `user_editable` are deep-merged by key. If the same key exists in both, `non_editable` wins (users cannot override locked fields).

---

## 4. Applying Support Functions

### When to Use a Support Function

In the **JSON** (app-config), use a placeholder string instead of a hardcoded value when:

- The value comes from **blueprint** (network, replica count, IP plan)
- The value comes from **app onboarding** (vlan, subnet, gateway by `dc_name`)
- The value comes from **portal context** (`dc_name`, `env`, `tenant`)

### How to Apply

1. Convert YAML to JSON (structure identical)
2. Identify the field (e.g. `ipam.range`, `addresses`, `GATEWAY`)
3. In JSON, set the value to the placeholder string, using **blueprint network names** (not YAML CNI names)
4. Find the matching function in **Part I** above

**Example** – In JSON (app-config):

Before (hardcoded):
```json
{
  "ipam": {
    "range": "172.16.50.2-172.16.50.4/26"
  }
}
```

After (with placeholder):
```json
{
  "ipam": {
    "range": "{{ whereabouts_range_end | EMX-Signalling-MTAS | SM }}"
  }
}
```

Structure stays identical. Portal resolves the placeholder; output YAML has the resolved value.

### Common Mappings

| Field type | Support function | Example |
|------------|------------------|---------|
| IP range (whereabouts) | `whereabouts_range_end` | `{{ whereabouts_range_end \| EMX-Signalling-MTAS \| SM }}` |
| VIP addresses | `vip_array` | `{{ vip_array \| EMX-Signalling-MTAS \| VLB }}` |
| PIP addresses | `pip_array` | `{{ pip_array \| GRE-Tunnel-IMC \| VLB }}` |
| Gateway | `gateway_str` | `{{ gateway_str \| oam-External \| VLB }}` |
| VLAN | `vlan` | `{{ vlan \| oam-External \| VLB }}` |
| Namespace | `namespace` | `{{ namespace \| dc_name \| MTAS }}` |
| Image registry | `image_registry` | `{{ image_registry \| MTAS \| env }}` |
| Pull secret | `pull_secret` | `{{ pull_secret \| tenant \| env }}` |

---

## 5. Reference: Portal Flow

For full portal flow and Helm chart update process, see **VMO2_Helm-Charts_Update_Guide_v1.8.pdf** (linked at top of this document).

The Hub automates:

- Phase 1: Vendor input submission  
- Phase 2: Network design & IP allocation (Infoblox)  
- Phase 3: Configuration generation (app-config placeholders resolved with CIQ blueprint + IP JSON; per-component values shown; final JSON returned via API)  
- Phase 4: Deployment & validation  

Your work feeds Phase 3: ensuring values are structured correctly and the right fields use support functions for portal resolution.

---

# Part III: Guide for Frontend

**Audience**: Frontend team implementing the App Onboarding Portal – how to read, parse, and resolve support function placeholders.

---

## 1. Overview

The portal reads **app-config** (not Helm values files). It finds support function placeholders in app-config, matches them to the appropriate resolver, and replaces them with data **combined from**:

- **CIQ blueprint** – network definitions, site config (vlan, subnet, gateway)
- **IP JSON** – allocated IPs from Infoblox / app onboarding

The portal then shows **per-component values** to the user, lets them edit **editable** fields, and returns the **final JSON** with all data for deployment as an **API response** when the deployment endpoint is called.

---

## 2. Resolution Flow

1. **Read** app-config (per component: `charts.<component>.helm_values`)
2. **Find** placeholders in `non_editable` (and nested structures like `networks[]`) with regex
3. **Resolve** each placeholder by calling the matching support function with parsed args and data from **CIQ blueprint + IP JSON**
4. **Replace** the placeholder string with the resolved value (string, number, or JSON array)
5. **Merge** `user_editable` and resolved `non_editable` into per-component values
6. **Show** per-component values to user – allow editing of `user_editable` fields only
7. **Return** final JSON with all data (resolved + user edits) as API response when deployment is requested

---

## 3. Parsing Placeholders

### Regex

```
\{\{\s*(\w+)\s*\|\s*([^|]+)\s*(?:\|\s*([^|]+))?\s*\}\}
```

- **Group 1**: function name (e.g. `whereabouts_range_end`, `vip_array`)
- **Group 2**: first arg (required)
- **Group 3**: second arg (optional)

### Examples

| Placeholder | Group 1 | Group 2 | Group 3 |
|-------------|---------|---------|---------|
| `{{ whereabouts_range_end \| EMX-Signalling-MTAS \| SM }}` | `whereabouts_range_end` | `EMX-Signalling-MTAS` | `SM` |
| `{{ vip_array \| EMX-Signalling-MTAS \| VLB }}` | `vip_array` | `EMX-Signalling-MTAS` | `VLB` |
| `{{ ipam_subnet \| oam-External }}` | `ipam_subnet` | `oam-External` | (none) |

---

## 4. Placeholder → Replacement Rules

**Standard format**: `{{ function | arg1 | arg2 }}`

| Function | Replace with | Type |
|----------|--------------|------|
| `whereabouts_range_end`, `whereabouts_range_cidr`, `ipam_subnet` | String | `"172.16.50.2-172.16.50.4/26"` |
| `ipam_range_start`, `ipam_range_end` | String | `"10.69.96.2"` |
| `vlan`, `prefix` | Number | `3200`, `22` |
| `gateway_str`, `namespace`, `image_registry`, `pull_secret`, `storage_class`, `image` | String | `"10.69.96.1"`, `"ims-mtas-slough"` |
| `vip_array`, `pip_array`, `component_ips` | JSON array | `["172.16.50.30"]`, `["10.69.96.4","10.69.96.5"]` |
| `sriov_pool`, `pci_env` | String | `sriov_dpdk_agw1_vlb_ens5f1_gre_tunnel` |

### Replacement Format

- **String/number**: Replace placeholder with the value directly (quote strings in YAML)
- **Array**: Replace with valid YAML array or JSON array as required by the field

---

## 5. Portal Context (Injected at Population)

These are **not** in the placeholder. The portal provides them when resolving:

| Context | Example | Used by |
|---------|---------|---------|
| `dc_name` | `slough` | `namespace`, `storage_class`, `vlan`, `gateway`, `prefix` |
| `env` | `prod`, `preprod`, `rnd` | `image_registry`, `pull_secret` |
| `tenant` | `IMS` | `pull_secret` |

When resolving `{{ namespace | dc_name | MTAS }}`, the portal substitutes `dc_name` with the current `dc_name` (e.g. `slough`) from context.

---

## 6. JSON Structure for Data Sources

### Input (What the Portal Reads)

| Source | Path | Content |
|--------|------|---------|
| ciq_blueprint.json | `blueprint.rnd.network[]` | network_name, no_of_ip, subnet_size, traffic_types |
| ciq_blueprint.json | `blueprint.site.networks[]` | vlan, subnet, gateway (keyed by dc_name) |
| app-config.json | `charts.<component>.helm_values` | Placeholders, `user_editable`, `non_editable` |
| IP JSON | (from Infoblox / app onboarding) | Allocated IPs per network, component |

Use **literal paths** (e.g. `blueprint.rnd.network`), not `global.*`. `global.*` is for values the portal **outputs** into merged Helm values.

### Output

- **Per-component values** – shown to user for editing (editable fields only)
- **Final JSON** – returned as API response when deployment endpoint is called; contains all resolved data + user edits, ready for deployment

---

## 7. Function Resolution Logic (Summary)

| Function | Lookup key | Data source |
|----------|------------|-------------|
| `whereabouts_range_end` | network_name, pod_name | blueprint.rnd.network, replica count |
| `vip_array` | network_name, pod_name | IP JSON (from Infoblox / app onboarding) |
| `pip_array` | network_name, pod_name | IP JSON, replica count |
| `vlan`, `gateway_str`, `prefix` | network_name, dc_name | blueprint.site.networks |
| `namespace` | dc_name, nf_type | Constructed: `ims-{nf_type_lower}-{dc_name}` |
| `image_registry` | nf_type, env | Config: registry URL per env |
| `pull_secret` | tenant, env | Config: secret name per tenant/env |
| `component_ips` | component, network_name | IP JSON for that component on that network |

---

## 8. Edge Cases

- **Single-arg functions** (e.g. `ipam_subnet`): Group 3 is empty; pass only arg1 to resolver
- **Array output**: Ensure valid YAML/JSON when replacing (e.g. `["ip1","ip2"]` not `[ip1, ip2]`)
- **AGW PIP typo**: Input may have `["<172.x.x.4","172.x.x.5>"]`; output must be `["ip1","ip2"]`
- **ENUMFE pci_env**: Normalize casing (`sriov_dpdk` vs `SRIOV_DPDK`) to expected format
