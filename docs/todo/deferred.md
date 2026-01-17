# Deferred Tasks

> Items intentionally postponed - will be tackled after core phases complete

---

## Stateful Workloads (PostgreSQL, Immich, ARR)

**Status:** Deferred - focus on stateless workloads first

**Namespace Strategy:**
| Project | Namespace | Database |
|---------|-----------|----------|
| Immich | `immich` | Own PostgreSQL + Redis inside namespace |
| ARR | `arr` | Own PostgreSQL inside namespace |

### Immich Namespace (`immich/`)

```
immich/
  ├── postgres (StatefulSet)     ← Immich's own database
  ├── redis (Deployment)
  ├── immich-server (Deployment)
  └── immich-ml (Deployment)
```

- Options: Fresh deployment vs migration from Dell 5090
- Dependencies: PostgreSQL, Redis, NFS (photos)
- Decision pending: validate K8s stack with simpler workloads first

### ARR Namespace (`arr/`)

```
arr/
  ├── postgres (StatefulSet)     ← ARR's own database
  ├── sonarr (Deployment)
  ├── radarr (Deployment)
  └── prowlarr (Deployment)
```

- Config storage on Longhorn
- Media files on NFS from Dell 5090
- Lower priority than Immich

**When:** After AdGuard + Homepage are stable and you're confident with K8s workflow

---

## Firmware Updates (Low Priority)

**Status:** Deferred - requires physical access (HDMI, keyboard)

| Node | BIOS | EC | Status |
|------|------|-----|--------|
| k8s-cp1 | 1.99 | 256.24 | Complete |
| k8s-cp2 | 1.90 | 256.20 | **Pending** (Boot Order Lock) |
| k8s-cp3 | 1.82 | 256.20 | **Pending** (Boot Order Lock) |

**CVEs:** All Medium/Low severity. NVMe (High) already completed.

**Steps:**
1. Connect HDMI + keyboard
2. `sudo systemctl reboot --firmware-setup`
3. Disable Boot Order Lock in BIOS
4. `sudo fwupdmgr update`

**When:** During scheduled maintenance or when physically accessing rack
