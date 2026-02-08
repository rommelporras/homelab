# Phase 4.20: MySpeed Migration

> **Status:** Complete
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
| Image | `germannewsmaker/myspeed` |

## Target State

| Item | Value |
|------|-------|
| Namespace | `home` (alongside AdGuard + Homepage) |
| URL | `myspeed.k8s.rommelporras.com` |
| Port | 5216/TCP |
| Storage | Longhorn PVC 1Gi for data directory (SQLite) |
| Image | `germannewsmaker/myspeed:1.0.9` (Docker Hub, May 2024 — latest stable release) |

---

## Tasks

### 4.20.1 Research & Prepare

- [x] 4.20.1.1 Check MySpeed Docker image docs — required env vars, port, volume mount path, config options
- [x] 4.20.1.2 Pin image → `germannewsmaker/myspeed:1.0.9` (Docker Hub, not GHCR — ghcr.io returned 403)
- [x] 4.20.1.3 Fresh start — no data migration needed (SQLite history stays on LXC during soak period)

### 4.20.2 Create Manifests

- [x] 4.20.2.1 Create `manifests/home/myspeed/deployment.yaml` — Deployment
- [x] 4.20.2.2 Create `manifests/home/myspeed/pvc.yaml` — Longhorn PVC
- [x] 4.20.2.3 Create `manifests/home/myspeed/service.yaml` — ClusterIP Service
- [x] 4.20.2.4 Create `manifests/home/myspeed/httproute.yaml` — HTTPRoute for `myspeed.k8s.rommelporras.com`
- [x] 4.20.2.5 Security context: seccompProfile RuntimeDefault, drop ALL caps, allowPrivilegeEscalation false, fsGroup 1000. Note: `runAsNonRoot` breaks this image (needs root for data folder). `readOnlyRootFilesystem` also incompatible.
- [x] 4.20.2.6 Resource limits: `cpu: 100m/500m`, `memory: 128Mi/256Mi` (peak observed: 78Mi)
- [x] 4.20.2.7 PVC: 1Gi Longhorn RWO for `/myspeed/data`

### 4.20.3 Deploy & Verify

- [x] 4.20.3.1 Apply manifests and verify pod running
- [x] 4.20.3.2 Verify HTTPRoute works (`myspeed.k8s.rommelporras.com`)
- [x] 4.20.3.3 Fresh start (no migration) — K8s instance builds own history
- [x] 4.20.3.4 Verify speed tests run successfully (938/835 Mbps confirmed)

### 4.20.4 Cutover

- [x] 4.20.4.1 Update Homepage widget to point to K8s service URL
- [x] 4.20.4.2 Update Uptime Kuma to monitor new URL
- [x] 4.20.4.3 Discord webhook configured — posts to `#status` channel
- [x] 4.20.4.4 AdGuard DNS — covered by wildcard `*.k8s.rommelporras.com` rewrite
- [x] 4.20.4.5 Proxmox LXC stopped (no soak needed — fresh start, no data dependency)

### 4.20.5 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.20.5.1 Update `docs/todo/README.md` — add Phase 4.20 to phase index + namespace table
- [x] 4.20.5.2 Update `README.md` (root) — add MySpeed to services list
- [x] 4.20.5.3 Update `VERSIONS.md` — add MySpeed version + HTTPRoute
- [x] 4.20.5.4 Update `docs/reference/CHANGELOG.md` — add migration decision entry
- [x] 4.20.5.5 Update `docs/context/Gateway.md` — add HTTPRoute
- [x] 4.20.5.6 Create `docs/rebuild/v0.16.0-myspeed.md`
- [x] 4.20.5.7 `/audit-docs`
- [x] 4.20.5.8 `/commit`
- [x] 4.20.5.9 `/release v0.16.0 "MySpeed Migration"`
- [x] 4.20.5.10 Move this file to `docs/todo/completed/`

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/home/myspeed/deployment.yaml` | Deployment | MySpeed workload with security context |
| `manifests/home/myspeed/pvc.yaml` | PVC | 1Gi Longhorn for SQLite data |
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
