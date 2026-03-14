# Deferred Tasks

> Items intentionally postponed - will be tackled after core phases complete

---

## Immich Photo Management

**Status:** Deferred - not on current roadmap
**Priority:** Low

**Namespace Strategy:**
| Project | Namespace | Database |
|---------|-----------|----------|
| Immich | `immich` | Own PostgreSQL + Redis inside namespace |

### Immich Namespace (`immich/`)

```
immich/
  ├── postgres (StatefulSet)     ← Immich's own database
  ├── redis (Deployment)
  ├── immich-server (Deployment)
  └── immich-ml (Deployment)
```

- Options: Fresh deployment vs migration from OMV NAS (10.10.30.4)
- Dependencies: PostgreSQL, Redis, NFS (photos)
- Photos storage: NFS from OMV NAS at `/export/Kubernetes`

**When:** No target date. Will plan as a future phase when prioritized.

---

## Loki Ruler for LogQL Alerts

**Status:** Deferred — waiting for a phase that touches Loki/monitoring architecture
**Priority:** Medium
**Added:** 2026-03-15 (Phase 5.1)

Audit alert rules exist at `manifests/monitoring/alerts/audit-alerts.yaml` (LogQL-based) but
cannot fire because Loki is running in single-binary mode without the ruler component.

**What's needed:**
- Enable Loki ruler in Helm values (`loki.ruler.enabled: true`)
- Configure ruler storage (local filesystem or object storage for rule state)
- Deploy the audit-alerts.yaml rules to Loki ruler
- Verify alerts fire (trigger a `kubectl exec` and confirm `AuditPodExec` fires)

**Manual queries work now** — `{source="audit_log"} | json` in Grafana Explore.
The gap is only automated alerting.

**When:** Next time Loki is upgraded or monitoring architecture is revisited.

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
