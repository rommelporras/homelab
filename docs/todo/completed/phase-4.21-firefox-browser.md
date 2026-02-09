# Phase 4.21: Containerized Firefox Browser

> **Status:** Complete
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
| Image | `lscr.io/linuxserver/firefox:latest` (always pull for security patches) |
| Port | 3000/TCP (KasmVNC web UI) |
| Storage | Longhorn PVC 2Gi for `/config` |
| Auth | Basic HTTP auth (`CUSTOM_USER` + `PASSWORD`) |
| Access | LAN only — do NOT expose via Cloudflare Tunnel |

---

## Tasks

### 4.21.1 Prepare

- [x] 4.21.1.1 Use `latest` tag — browsers need frequent security patches, `imagePullPolicy: Always` ensures fresh pulls
- [x] 4.21.1.2 Create 1Password item: `op://Kubernetes/Firefox Browser/username` + `password`

### 4.21.2 Create Manifests

- [x] 4.21.2.1 Create `manifests/browser/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: baseline` (KasmVNC needs some capabilities)
  - Audit/warn: restricted (shows what would break if tightened)
- [x] 4.21.2.2 Create `manifests/browser/deployment.yaml`
  - Deployment with:
    - `strategy: Recreate` (RWO volume — no rolling update)
    - Longhorn PVC 2Gi mounted at `/config`
    - `emptyDir` with `medium: Memory` + `sizeLimit: 1Gi` for `/dev/shm`
    - Password from K8s Secret (created via `op read`)
    - Env: `PUID=1000`, `PGID=1000`, `TZ=Asia/Manila`
    - Resource limits: `cpu: 250m/2`, `memory: 512Mi/2Gi`
    - AdGuard DNS routing (`dnsPolicy: None` with primary + failover)
    - Least-privilege capabilities (drop ALL + add CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER)
    - TCP probes (HTTP probes fail due to basic auth 401)
- [x] 4.21.2.3 Create `manifests/browser/service.yaml` — ClusterIP (port 3000)
- [x] 4.21.2.4 Create `manifests/browser/httproute.yaml` — `browser.k8s.rommelporras.com`

### 4.21.3 Deploy & Verify

- [x] 4.21.3.1 Create K8s Secret from 1Password:
  ```bash
  kubectl-homelab create secret generic firefox-auth \
    --from-literal=username="$(op read 'op://Kubernetes/Firefox Browser/username')" \
    --from-literal=password="$(op read 'op://Kubernetes/Firefox Browser/password')" \
    -n browser
  ```
- [x] 4.21.3.2 Apply manifests and verify pod running
- [x] 4.21.3.3 Test: access from desktop browser, login, open tabs
- [x] 4.21.3.4 Test: close tab, access from different device (mobile), verify session persists
- [x] 4.21.3.5 Test: install a browser extension, verify it persists across restarts

### 4.21.4 Integration

- [x] 4.21.4.1 Add to Homepage (Apps section)
- [x] 4.21.4.2 Add to Uptime Kuma monitoring
- [x] 4.21.4.3 DNS rewrite via wildcard `*.k8s.rommelporras.com` (already exists in AdGuard)

### 4.21.5 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.21.5.1 Update `docs/todo/README.md` — add browser namespace to namespace table
- [x] 4.21.5.2 Update `README.md` (root) — add Firefox browser to services list + timeline
- [x] 4.21.5.3 Update `VERSIONS.md` — add Firefox browser version + HTTPRoute
- [x] 4.21.5.4 Update `docs/reference/CHANGELOG.md` — add deployment decision entry
- [x] 4.21.5.5 Update `docs/context/Cluster.md` — add `browser` namespace
- [x] 4.21.5.6 Update `docs/context/Gateway.md` — add HTTPRoute
- [x] 4.21.5.7 Update `docs/context/Secrets.md` — add Firefox Browser 1Password item
- [x] 4.21.5.8 Create `docs/rebuild/v0.18.0-firefox-browser.md`
- [x] 4.21.5.9 `/audit-docs`
- [ ] 4.21.5.10 `/commit`
- [ ] 4.21.5.11 `/release v0.18.0 "Containerized Firefox Browser"`
- [ ] 4.21.5.12 Move this file to `docs/todo/completed/`

---

## Security Notes

- Basic HTTP auth is sufficient for LAN-only access behind Gateway API
- **Do NOT expose via Cloudflare Tunnel** — browser session = full machine access
- If remote access needed in future, use Tailscale (Phase 4.10)
- Container runs as non-root (PUID/PGID) after s6 init
- Least-privilege capabilities: drop ALL + add only what s6/nginx need

---

## Lessons Learned

- **LinuxServer images need capabilities** — `drop: ALL` alone causes `Operation not permitted` on chown/chmod. Must add back CHOWN, SETUID, SETGID, DAC_OVERRIDE, FOWNER for s6-overlay init system.
- **HTTP probes + basic auth = restart loop** — KasmVNC returns 401 on unauthenticated requests. Use `tcpSocket` probes instead of `httpGet`.
- **Volume name `emptyDir` is invalid** — Kubernetes rejects camelCase volume names (RFC 1123 requires all lowercase). Use `shm` instead.
- **`/dev/shm` needs 1Gi** — Default container `/dev/shm` is 64MB. Firefox multi-process tabs crash with "out of shared memory" without a larger tmpfs mount.
- **Corrupted PVC from failed runs** — When capability errors prevent proper file ownership, subsequent restarts inherit broken permissions. Delete PVC for clean start.

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/browser/namespace.yaml` | Namespace | Browser namespace with PSS labels |
| `manifests/browser/deployment.yaml` | Deployment | Firefox workload with KasmVNC |
| `manifests/browser/pvc.yaml` | PVC | Longhorn 2Gi for Firefox profile |
| `manifests/browser/service.yaml` | Service | ClusterIP (port 3000) |
| `manifests/browser/httproute.yaml` | HTTPRoute | `browser.k8s.rommelporras.com` |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add Firefox browser + Uptime Kuma widget |

---

## Verification Checklist

- [x] Firefox pod running in `browser` namespace
- [x] `browser.k8s.rommelporras.com` loads KasmVNC login page
- [x] Login works with configured credentials
- [x] Firefox session persists across tab close + reopen
- [x] Session accessible from different device (same tabs visible)
- [x] Firefox extensions survive pod restart
- [x] Homepage entry functional
- [x] Uptime Kuma monitoring active

---

## Rollback

```bash
kubectl-homelab delete namespace browser
```
