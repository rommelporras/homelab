# Phase 4.21: Containerized Firefox Browser

> **Status:** Planned
> **Target:** v0.18.0
> **Prerequisite:** Gateway API + Longhorn storage running
> **Priority:** High (daily-use productivity tool)
> **DevOps Topics:** KasmVNC, persistent sessions, container isolation
> **CKA Topics:** Deployment, PVC, Secret, Namespace, HTTPRoute, Pod Security Standards

> **Purpose:** Deploy a persistent Firefox browser accessible from any device on the LAN via `browser.k8s.rommelporras.com`. Close the tab on work laptop, open the URL on desktop — same session, same tabs.
>
> **Use case:** Single persistent browser session shared across work laptop and personal desktop. All browsing history, cookies, and extensions stay in one place.

---

## Technology Decision

| Option | Streaming | RAM | Persistence | K8s Fit | Verdict |
|--------|-----------|-----|-------------|---------|---------|
| **linuxserver/firefox** | KasmVNC (WebSocket) | 1-2Gi | Simple `/config` vol | Excellent | **Winner** |
| jlesage/firefox | VNC/noVNC | 1-2Gi | Simple `/config` vol | Good | Older VNC tech, no audio |
| Neko (m1k1o) | WebRTC | 3-4Gi | Needs config | Hard (UDP ports) | Overkill for single user |
| Webtop | KasmVNC | 2-4Gi | Simple `/config` vol | Good | Overkill (full desktop) |
| Kasm Workspaces | KasmVNC | 4Gi+ | Complex | Bad (needs agents) | Enterprise, skip |

**Decision:** `linuxserver/firefox` — lightest footprint, best persistence story, modern KasmVNC streaming with clipboard + audio, trivial K8s deployment.

### How It Works

1. Firefox runs inside the container, rendered via a virtual display
2. KasmVNC encodes the display as compressed image tiles over WebSocket
3. You access it via `https://browser.k8s.rommelporras.com` in any browser
4. Closing the browser tab does NOT close Firefox — the session keeps running
5. Opening the URL from another device shows the same Firefox session
6. The `/config` volume holds the full Firefox profile (bookmarks, cookies, extensions, open tabs)

---

## Target State

| Item | Value |
|------|-------|
| Namespace | `browser` (new) |
| URL | `browser.k8s.rommelporras.com` |
| Image | `lscr.io/linuxserver/firefox` (pin specific tag at deploy time — check [releases](https://github.com/linuxserver/docker-firefox/releases)) |
| Port | 3000/TCP (KasmVNC web UI) |
| Storage | Longhorn PVC 2Gi for `/config` |
| Auth | Basic HTTP auth (`CUSTOM_USER` + `PASSWORD`) |
| Access | LAN only — do NOT expose via Cloudflare Tunnel |

---

## Tasks

### 4.21.1 Prepare

- [ ] 4.21.1.1 Pin `linuxserver/firefox` — check latest tag at https://github.com/linuxserver/docker-firefox/releases (uses `ls##` build numbering, verify at deploy time)
- [ ] 4.21.1.2 Create 1Password item: `op://Kubernetes/Firefox Browser/password`

### 4.21.2 Create Manifests

- [ ] 4.21.2.1 Create `manifests/browser/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: baseline` (KasmVNC needs some capabilities)
- [ ] 4.21.2.2 Create `manifests/browser/deployment.yaml`
  - Deployment with:
    - `strategy: Recreate` (RWO volume — no rolling update)
    - Longhorn PVC 2Gi mounted at `/config`
    - `emptyDir` with `medium: Memory` + `sizeLimit: 1Gi` for `/dev/shm`
    - Password from K8s Secret (created via `op read`)
    - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
    - Resource limits: `cpu: 250m/2`, `memory: 512Mi/2Gi`
  - Note: `readOnlyRootFilesystem` NOT compatible — KasmVNC needs writable dirs
- [ ] 4.21.2.3 Create `manifests/browser/service.yaml` — ClusterIP (port 3000)
- [ ] 4.21.2.4 Create `manifests/browser/httproute.yaml` — `browser.k8s.rommelporras.com`

### 4.21.3 Deploy & Verify

- [ ] 4.21.3.1 Create K8s Secret from 1Password:
  ```bash
  kubectl-homelab create secret generic firefox-auth \
    --from-literal=password="$(op read 'op://Kubernetes/Firefox Browser/password')" \
    -n browser
  ```
- [ ] 4.21.3.2 Apply manifests and verify pod running
- [ ] 4.21.3.3 Test: access from desktop browser, login, open tabs
- [ ] 4.21.3.4 Test: close tab, access from different device, verify session persists
- [ ] 4.21.3.5 Test: install a browser extension, verify it persists across restarts

### 4.21.4 Integration

- [ ] 4.21.4.1 Add to Homepage (Apps section)
- [ ] 4.21.4.2 Add to Uptime Kuma monitoring
- [ ] 4.21.4.3 Add DNS rewrite in AdGuard for `browser.k8s.rommelporras.com`

### 4.21.5 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.21.5.1 Update `docs/todo/README.md` — add Phase 4.21 to phase index + namespace table
- [ ] 4.21.5.2 Update `README.md` (root) — add Firefox browser to services list
- [ ] 4.21.5.3 Update `VERSIONS.md` — add Firefox browser version + HTTPRoute
- [ ] 4.21.5.4 Update `docs/reference/CHANGELOG.md` — add deployment decision entry
- [ ] 4.21.5.5 Update `docs/context/Cluster.md` — add `browser` namespace
- [ ] 4.21.5.6 Update `docs/context/Gateway.md` — add HTTPRoute
- [ ] 4.21.5.7 Update `docs/context/Secrets.md` — add Firefox Browser 1Password item
- [ ] 4.21.5.8 Create `docs/rebuild/v0.18.0-firefox-browser.md`
- [ ] 4.21.5.9 `/audit-docs`
- [ ] 4.21.5.10 `/commit`
- [ ] 4.21.5.11 `/release v0.18.0 "Containerized Firefox Browser"`
- [ ] 4.21.5.12 Move this file to `docs/todo/completed/`

---

## Security Notes

- Basic HTTP auth is sufficient for LAN-only access behind Gateway API
- **Do NOT expose via Cloudflare Tunnel** — browser session = full machine access
- If remote access needed in future, use Tailscale (Phase 4.10)
- Container runs as non-root (PUID/PGID)
- No special Linux capabilities required beyond baseline PSS

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/browser/namespace.yaml` | Namespace | Browser namespace with PSS labels |
| `manifests/browser/deployment.yaml` | Deployment + PVC | Firefox workload + Longhorn storage |
| `manifests/browser/service.yaml` | Service | ClusterIP (port 3000) |
| `manifests/browser/httproute.yaml` | HTTPRoute | `browser.k8s.rommelporras.com` |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add Firefox browser entry |

---

## Verification Checklist

- [ ] Firefox pod running in `browser` namespace
- [ ] `browser.k8s.rommelporras.com` loads KasmVNC login page
- [ ] Login works with configured credentials
- [ ] Firefox session persists across tab close + reopen
- [ ] Session accessible from different device (same tabs visible)
- [ ] Firefox extensions survive pod restart
- [ ] Homepage entry functional
- [ ] Uptime Kuma monitoring active

---

## Rollback

```bash
kubectl-homelab delete namespace browser
```
