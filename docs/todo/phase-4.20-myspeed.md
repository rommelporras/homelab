# Phase 4.20: MySpeed Migration

> **Status:** Planned
> **Target:** v0.16.0
> **Prerequisite:** Gateway API + monitoring stack running
> **Priority:** High (quick win, shrinks Proxmox footprint)
> **DevOps Topics:** Container migration, data migration (SQLite)
> **CKA Topics:** Deployment, Service, PVC, HTTPRoute

> **Purpose:** Migrate MySpeed internet speed test history from Proxmox LXC to Kubernetes.
>
> **Current location:** LXC at `10.10.30.6`, accessible at `https://myspeed.home.rommelporras.com` (port 5216)
>
> **Why:** Reduce Proxmox LXC count. Move to K8s where it gets Longhorn replication, automatic restarts, and centralized monitoring.

---

## Current State

| Item | Value |
|------|-------|
| Location | Proxmox LXC at `10.10.30.6` |
| URL | `https://myspeed.home.rommelporras.com` |
| Homepage widget | `http://10.10.30.6:5216` (type: `myspeed`) |
| Uptime Kuma | Monitored |
| Discord | Webhook posting speed test results to `#status` channel |
| Data | SQLite database (speed test history) |
| Image | `ghcr.io/gnmyt/myspeed` |

## Target State

| Item | Value |
|------|-------|
| Namespace | `home` (alongside AdGuard + Homepage) |
| URL | `myspeed.k8s.rommelporras.com` |
| Port | 5216/TCP |
| Storage | Longhorn PVC 1Gi for data directory (SQLite) |
| Image | `ghcr.io/gnmyt/myspeed:1.0.9` (May 2024 — latest release; project is low-activity, verify before deploy) |

---

## Tasks

### 4.20.1 Research & Prepare

- [ ] 4.20.1.1 Check MySpeed Docker image docs — required env vars, port, volume mount path, config options
- [x] 4.20.1.2 Pin image → `ghcr.io/gnmyt/myspeed:1.0.9` (May 2024, has built-in Prometheus endpoint — project low-activity, verify before deploy)
- [ ] 4.20.1.3 Check if MySpeed supports SQLite data export/import for migration

### 4.20.2 Create Manifests

- [ ] 4.20.2.1 Create `manifests/home/myspeed/deployment.yaml` — Deployment + PVC
- [ ] 4.20.2.2 Create `manifests/home/myspeed/service.yaml` — ClusterIP Service
- [ ] 4.20.2.3 Create `manifests/home/myspeed/httproute.yaml` — HTTPRoute for `myspeed.k8s.rommelporras.com`
- [ ] 4.20.2.4 Security context:
  - `runAsNonRoot: true`
  - `allowPrivilegeEscalation: false`
  - `capabilities.drop: [ALL]`
  - `seccompProfile.type: RuntimeDefault`
  - Check if `readOnlyRootFilesystem` is compatible
- [ ] 4.20.2.5 Resource limits: `cpu: 250m/500m`, `memory: 128Mi/256Mi`
- [ ] 4.20.2.6 PVC: 1Gi Longhorn for data directory

### 4.20.3 Deploy & Verify

- [ ] 4.20.3.1 Apply manifests and verify pod running
- [ ] 4.20.3.2 Verify HTTPRoute works (`myspeed.k8s.rommelporras.com`)
- [ ] 4.20.3.3 Migrate speed test history from Proxmox LXC (if export path exists)
- [ ] 4.20.3.4 Verify speed tests run successfully on K8s deployment

### 4.20.4 Cutover

- [ ] 4.20.4.1 Update Homepage widget to point to K8s service URL
- [ ] 4.20.4.2 Update Uptime Kuma to monitor new URL
- [ ] 4.20.4.3 Reconfigure Discord webhook in MySpeed UI — posts to `#status` channel (webhook URL stored in MySpeed's built-in settings, not in K8s manifests)
- [ ] 4.20.4.4 Update AdGuard DNS rewrite if applicable
- [ ] 4.20.4.5 Soak for 1 week, then decommission Proxmox LXC

### 4.20.5 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.20.5.1 Update `docs/todo/README.md` — add Phase 4.20 to phase index + namespace table
- [ ] 4.20.5.2 Update `README.md` (root) — add MySpeed to services list
- [ ] 4.20.5.3 Update `VERSIONS.md` — add MySpeed version + HTTPRoute
- [ ] 4.20.5.4 Update `docs/reference/CHANGELOG.md` — add migration decision entry
- [ ] 4.20.5.5 Update `docs/context/Gateway.md` — add HTTPRoute
- [ ] 4.20.5.6 Create `docs/rebuild/v0.16.0-myspeed.md`
- [ ] 4.20.5.7 `/audit-docs`
- [ ] 4.20.5.8 `/commit`
- [ ] 4.20.5.9 `/release v0.16.0 "MySpeed Migration"`
- [ ] 4.20.5.10 Move this file to `docs/todo/completed/`

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/home/myspeed/deployment.yaml` | Deployment + PVC | MySpeed workload + storage |
| `manifests/home/myspeed/service.yaml` | Service | ClusterIP for MySpeed |
| `manifests/home/myspeed/httproute.yaml` | HTTPRoute | `myspeed.k8s.rommelporras.com` |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Update MySpeed widget URL |

---

## Verification Checklist

- [ ] MySpeed pod running in `home` namespace
- [ ] `myspeed.k8s.rommelporras.com` loads and shows speed test history
- [ ] Speed tests execute successfully
- [ ] Historical data migrated (or fresh start if no export path)
- [ ] Discord webhook reconfigured and posting to `#status`
- [ ] Homepage widget functional with new URL
- [ ] Uptime Kuma monitoring new endpoint

---

## Rollback

```bash
kubectl-homelab delete -f manifests/home/myspeed/
# Proxmox LXC is still running during soak period
```
