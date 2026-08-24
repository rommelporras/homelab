---
tags: [homelab, hardware, physical, power, network, topology]
updated: 2026-07-08
---

# Physical Hardware, Power & Network Topology

> ⚠️ **DRAFT / INCOMPLETE.** This is a skeleton. The most important physical facts
> (power tree, rack placement, console access) are `TODO` placeholders only you can
> fill by looking at the rack. Do not rely on it as complete reference until filled.
>
> Physical-layer reference: where the machines are, how they're powered, and how
> they're cabled. [Cluster.md](Cluster.md) has the logical facts (IPs/MACs/specs);
> this doc has the physical ones you need when a machine is dark and SSH is down.

---

## Devices (verified)

| Device | Model | Role | Mgmt IP |
|--------|-------|------|---------|
| k8s-cp1 | Lenovo ThinkCentre M80q (i5-10400T, 16GB, 512GB NVMe) | K8s control plane + **NUT server (UPS USB)** | 10.10.30.11 |
| k8s-cp2 | Lenovo ThinkCentre M80q | K8s control plane | 10.10.30.12 |
| k8s-cp3 | Lenovo ThinkCentre M80q | K8s control plane | 10.10.30.13 |
| NAS | Dell OptiPlex 3090 (i5-10500T, 32GB, 1TB SSD boot + 2TB NVMe) | OMV / NFS | 10.10.30.4 |
| Firewall | Topton N100 (16GB) | Proxmox + OPNsense | 10.10.30.1 |
| Switch | LIANGUO LG-SG5T1 (5x 2.5GbE + 10G SFP+) | Core switch | - |
| UPS | CyberPower CP1600EPFCLCD (1600VA / 1000W) | Battery backup | USB -> cp1 |
| WiFi | TP-Link Archer A6 (OpenWRT) + Archer AX1500 (backup) | VLAN WiFi | - |

Total steady-state draw ~100W (all devices). See [Cluster.md](Cluster.md#hardware-inventory--cost)
for full specs and cost.

## Network cabling

**Single source of truth: [Networking.md#switch](Networking.md) has the exact
port -> device -> native/trunk-VLAN table.** Do not duplicate it here (an earlier
copy drifted). Summary only:

- Ports 1-3 -> k8s-cp1/cp2/cp3 (`eno1`); ports 4-5 -> Dell 3090 (PVE) and OPNsense.
  For native vs trunk VLAN per port, read Networking.md - do not trust a copy.
- All 3 K8s nodes are single-NIC (`eno1`, Intel I219-LM 1GbE). The switch is
  2.5GbE but the M80q NICs are 1GbE, so node links negotiate at 1GbE.
- `TODO`: is the switch SFP+ port used (uplink) or spare?

## Power tree (TODO - fill from the physical rack)

> This is the highest-value physical fact during an outage and for DR planning.

- **Circuit / breaker:** `TODO` - which house circuit(s) feed the rack? Are all
  devices on ONE circuit? (If so, that circuit is a single point of failure.)
- **UPS load & outlets:** `TODO` - which devices are on the UPS **battery**
  outlets vs surge-only outlets? (Anything not on a battery outlet dies instantly
  on power loss regardless of NUT.)
- **Estimated UPS runtime** at ~100W load: `TODO` (check the CyberPower LCD or
  PowerPanel). Needed to know how long you have during an outage.
- **PSU:** M80q uses a single external power brick (~135W adapter) - no redundant
  PSU. `TODO`: confirm adapter wattage / spares on hand.
- **Power-off / power-on ORDER** for planned maintenance: see
  [../operations/graceful-shutdown-startup.md](../operations/graceful-shutdown-startup.md).
  The automated NUT shutdown order on power loss is in
  [UPS.md](UPS.md) and `docs/todo/deferred.md`.

## Physical placement (TODO)

- **Rack/shelf layout:** `TODO` - a simple diagram or list: which physical box is
  cp1 vs cp2 vs cp3 (they're identical M80q units - label them physically!). At
  2am you need "cp3 is the bottom-left unit" to pull the right one.
- Recommended: put a physical label (cp1/cp2/cp3 + IP + MAC-last-4) on each M80q.

## Local console access (TODO)

> When a node is `NotReady`, SSH is dead, and you must see the boot screen.

- **How to attach a console to an M80q:** `TODO` - HDMI/DisplayPort + USB keyboard?
  Is there a spare monitor/keyboard on hand, or a KVM? Document the exact steps so
  you're not hunting for a cable during an outage.
- M80q BIOS POST takes **5-7 minutes** - a booting node looks dead longer than you
  expect. Wait before assuming hardware failure.

## Single points of failure (fill in as you confirm the power tree)

| SPOF | Impact if it fails | Mitigation |
|------|--------------------|------------|
| Single UPS | All devices lose power together on UPS failure | `TODO` |
| Single circuit (if all on one) | Whole homelab down on breaker trip | `TODO` |
| NAS single data drive (2TB NVMe) | Media + config-on-NFS lost | Longhorn 2x replica for config; off-site restic; see [Backups.md](Backups.md) |
| Core switch (single) | All L2 connectivity down | `TODO` |
| AdGuard (single replica) | LAN DNS down (house "internet" down) | Escape hatch in [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md#3-dns-and-adguard-outages-most-common) |

## Related

- [[Cluster]] - specs, MACs, cost
- [[Networking]] - VLANs, VIPs, switch ports
- [[UPS]] - NUT, graceful shutdown on power loss
- [../operations/graceful-shutdown-startup.md](../operations/graceful-shutdown-startup.md) - planned power off/on
