# Phase 4.30: Atuin Self-Hosted Shell History

> **Status:** ✅ Complete
> **Target:** v0.28.0
> **Prerequisite:** Phase 4.28 complete (Alerting & Observability)
> **Priority:** Medium (quality-of-life, not blocking other phases)
> **DevOps Topics:** Stateful services, PostgreSQL, secrets management, multi-tenant accounts, CronJob backups
> **CKA Topics:** Deployment, StatefulSet vs Deployment, Service, PVC, Secrets, HTTPRoute, CronJob

> **Purpose:** Deploy a self-hosted Atuin sync server on the homelab cluster so shell history
> syncs across all machines (WSL2, Aurora DX, Distrobox containers) without relying on
> Atuin's public cloud. Two accounts (`rommel-personal`, `rommel-eam`) provide context
> isolation between personal and work shell history.
>
> **Why self-host:** Full control over data, no third-party dependency, aligns with homelab
> philosophy. End-to-end encrypted regardless — the server never sees plaintext history.
>
> **Design doc:** `docs/plans/2026-02-28-aurora-dx-migration-design.md` § "Atuin History Sync"

---

## Current State (pre-deployment)

| Item | Value |
|------|-------|
| Atuin client | Installed on WSL2 (v18.12.1 via bootstrap) |
| Sync | **Disabled** — `sync_address` blank, local-only mode |
| History | `~/.zsh_history` only (no Atuin database) |
| Dotfiles support | `config.toml.tmpl` templates `sync_address`, `.zshrc` conditionally inits Atuin |
| Accounts | None registered (no server to register against) |

## Target State

| Item | Value |
|------|-------|
| Namespace | `atuin` |
| Server image | `ghcr.io/atuinsh/atuin:18.12.0` (`v18.12.1` was client-only patch, not published to GHCR) |
| Server port | 8888/TCP |
| Metrics port | 9001/TCP (Prometheus, enabled via `ATUIN_METRICS__ENABLE`) |
| PostgreSQL | `docker.io/library/postgres:18.3` (dedicated, not shared — docs require 14+, tested with 18) |
| PostgreSQL port | 5432/TCP (ClusterIP, internal only) |
| URL | `atuin.k8s.rommelporras.com` (HTTPS via Gateway API) |
| Storage | Longhorn PVC 5Gi for PostgreSQL data, 10Mi for Atuin config |
| Registration | Open initially (close after both accounts created) |
| Accounts | `rommel-personal`, `rommel-eam` (naming: `rommel-<department-or-company>`) |
| PSS | `enforce: baseline` (NFS volume in backup CronJob requires it), `audit+warn: restricted` |

---

## Multi-Account Architecture

Account naming convention: `rommel-<context>` where context is a department, company,
or role name. This scales to future jobs/freelance work (e.g. `rommel-freelance`,
`rommel-acme`). All personal accounts share a single encryption key (by design —
`atuin register` reuses `~/.local/share/atuin/key` if it exists). A separate key
would only be needed for a third party using the server.

```
rommel-personal account:
├── WSL2 Work Laptop (personal shell)
├── WSL2 Gaming Desktop (personal shell)
├── Aurora distrobox-personal
└── All share personal history

rommel-eam account:
├── WSL2 Work Laptop (work context)
├── WSL2 Gaming Desktop (work context)
├── Aurora distrobox-work
└── All share EAM work history

Future accounts (as needed):
├── rommel-<company>  — new employer or freelance client
└── Share encryption key (separate key only if a different person uses the server)

No Atuin:
├── distrobox-sandbox (local zsh history only)
└── AI Sandbox Podman (no history at all)
```

WSL2 machines default to `rommel-personal`. Work commands on WSL2 end up in personal
history (acceptable — it's a personal machine). Clean separation only on Aurora/Bluefin
where Distrobox containers have separate HOMEs.

---

## Tasks

### 4.30.1 Research & Prepare

- [x] 4.30.1.1 Verify `ghcr.io/atuinsh/atuin:18.12.0` includes server binary (entrypoint: `/usr/local/bin/atuin-server`, args: `["start"]`; `v18.12.1` was client-only, not published to GHCR)
- [x] 4.30.1.2 Check Atuin server health endpoint — determine correct liveness/readiness probe path
- [x] 4.30.1.3 Determine PostgreSQL resource usage — Atuin server is lightweight, most load is on Postgres
- [x] 4.30.1.4 Plan 1Password item: unified `Atuin` item in Kubernetes vault with `db-*` fields (database), `personal-*`/`eam-*` fields (accounts), and shared `encryption-key`
- [x] 4.30.1.5 Decide Deployment vs StatefulSet for PostgreSQL — official docs suggest StatefulSet for production; Deployment+Recreate is simpler and matches other homelab services

### 4.30.2 Create Secrets

> Originally used imperative `kubectl create secret`. Migrated to ExternalSecret in Phase 4.29 (Vault + ESO) — see `manifests/atuin/externalsecret.yaml`.

- [x] 4.30.2.1 Create 1Password item `Atuin` in Kubernetes vault — unified item with `db-*` fields (database), `personal-*`/`eam-*` fields (accounts), and shared `encryption-key` — **db-password must use only `[A-Za-z0-9.~_-]`** (special chars like `@`, `!`, `#` break `ATUIN_DB_URI` parsing)
- [x] 4.30.2.2 Generate `kubectl create secret` command for `atuin-secrets` in `atuin` namespace — ask user to run in safe terminal
- [x] 4.30.2.3 Verify secret exists: `kubectl-homelab -n atuin get secret atuin-secrets`

### 4.30.3 Create Manifests

- [x] 4.30.3.1 Create `manifests/atuin/namespace.yaml` — Namespace with PSS labels (`enforce: baseline` for NFS, `audit+warn: restricted`)
- [x] 4.30.3.2 Create `manifests/atuin/postgres-deployment.yaml` — PostgreSQL Deployment + PVC
  - `Recreate` strategy (RWO PVC — only one pod can mount at a time)
  - Pinned image `postgres:18.3`
  - `preStop` lifecycle hook for graceful shutdown (`pg_ctl stop -D /var/lib/postgresql/data/pgdata -w -t 60 -m fast`)
  - `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectory required by postgres image when mounting a volume at `/var/lib/postgresql/data`)
  - Security context: `runAsUser: 999`, `fsGroup: 999` (postgres user)
  - Resources: `cpu: 100m/250m`, `memory: 256Mi/512Mi` (official docs recommend 100Mi/600Mi)
  - PVC: 5Gi Longhorn for `/var/lib/postgresql/data`
  - Probes using `pg_isready -U atuin`:
    - `startupProbe`: `failureThreshold: 30`, `periodSeconds: 10` (5 min for initial data directory setup)
    - `livenessProbe`: `periodSeconds: 30`, `failureThreshold: 3`
    - `readinessProbe`: `periodSeconds: 10`, `failureThreshold: 2`
  - `automountServiceAccountToken: false`
  - TZ: `Asia/Manila`
- [x] 4.30.3.3 Create `manifests/atuin/postgres-service.yaml` — ClusterIP on port 5432
- [x] 4.30.3.4 Create `manifests/atuin/server-deployment.yaml` — Atuin server Deployment
  - Pinned image `ghcr.io/atuinsh/atuin:18.12.0` (entrypoint is `atuin-server`, not `atuin`)
  - Args: `["start"]` (not `["server", "start"]` — entrypoint already is `atuin-server`)
  - Env: `ATUIN_HOST=0.0.0.0`, `ATUIN_PORT=8888`, `ATUIN_OPEN_REGISTRATION=false`, `ATUIN_DB_URI` from secret, `RUST_LOG=info,atuin_server=debug`
  - Metrics: `ATUIN_METRICS__ENABLE=true`, `ATUIN_METRICS__HOST=0.0.0.0`, `ATUIN_METRICS__PORT=9001`
  - Init container: `wait-for-db` using `busybox:1.37` — `until nc -z postgres 5432; do sleep 2; done`
  - Security context: `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `allowPrivilegeEscalation: false`, `drop: ALL`, `seccompProfile: RuntimeDefault`
  - Resources: `cpu: 100m/250m`, `memory: 256Mi/1Gi` (official docs recommend 250m/1Gi — tune down later with metrics)
  - `automountServiceAccountToken: false`
  - PVC: 10Mi Longhorn for `/config` (server config only, data is in PostgreSQL)
  - Probes on `/healthz` port 8888:
    - `startupProbe`: `failureThreshold: 30`, `periodSeconds: 10` (5 min for initial DB connection)
    - `livenessProbe`: `initialDelaySeconds: 3`, `periodSeconds: 3`
    - `readinessProbe`: `tcpSocket` port 8888, `initialDelaySeconds: 15`, `periodSeconds: 10`
- [x] 4.30.3.5 Create `manifests/atuin/server-service.yaml` — ClusterIP on port 8888
- [x] 4.30.3.6 Create `manifests/atuin/httproute.yaml` — HTTPRoute for `atuin.k8s.rommelporras.com`
- [x] 4.30.3.7 Create `manifests/atuin/networkpolicy-ingress.yaml` — CiliumNetworkPolicy (ingress, per-app selectors)
  - `atuin-server-ingress`: gateway on 8888, monitoring on 8888+9001 (metrics), kubelet host on 8888
  - `postgres-ingress`: atuin-server on 5432, atuin-backup on 5432, kubelet host on 5432
- [x] 4.30.3.8 Create `manifests/atuin/networkpolicy-egress.yaml` — CiliumNetworkPolicy (egress, per-app selectors)
  - `atuin-server-egress`: DNS (53/UDP) + PostgreSQL (5432)
  - `postgres-egress`: DNS (53/UDP) only (passive listener)
  - `atuin-backup-egress`: DNS (53/UDP) + PostgreSQL (5432) + NAS NFS (10.10.30.4:2049)
- [x] 4.30.3.9 Create `manifests/atuin/backup-cronjob.yaml` — Weekly PostgreSQL backup
  - Schedule: `0 2 * * 0` with `timeZone: "Asia/Manila"` (Sunday 2 AM Manila — requires K8s 1.27+)
  - Image: `postgres:18.3` (same as database)
  - `concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 300`
  - Command: `pg_dump --host=postgres --username=atuin --format=c --file=/backup/atuin-backup-$(date +'%Y-%m-%d').pg_dump`
  - Retention: `find /backup -name '*.pg_dump' -mtime +28 -delete` (keep ~4 weekly backups)
  - NFS mount for backup storage: NAS at `/Kubernetes/Backups/atuin/` (NFSv4 path; fixed in v0.28.1 from `/export/...`)
  - Secret: reuse `atuin-secrets` for `PGPASSWORD`

### 4.30.4 Deploy & Verify

- [x] 4.30.4.1 Apply namespace and secrets first
- [x] 4.30.4.2 Deploy PostgreSQL, wait for pod ready
- [x] 4.30.4.3 Deploy Atuin server, wait for pod ready
- [x] 4.30.4.4 Verify HTTPRoute: `curl -s https://atuin.k8s.rommelporras.com` (should respond)
- [x] 4.30.4.5 Test registration: `atuin register -u test-user -e test@test.com` → verify success → delete test user

### 4.30.5 Create Accounts & Sync History

- [x] 4.30.5.1 On WSL2, set `sync_address` in chezmoi data → `chezmoi apply`
- [x] 4.30.5.2 Register: `atuin register -u rommel-personal -e <personal-email>`
- [x] 4.30.5.3 **Save encryption key to 1Password** — `atuin key` → `op item edit "Atuin" --vault "Kubernetes" 'encryption-key[text]=<key>'` (shared across all personal accounts)
- [x] 4.30.5.4 Import existing history: review `~/.zsh_history` for sensitive data, then `atuin import zsh`
- [x] 4.30.5.5 Sync: `atuin sync` → verify `atuin status`
- [x] 4.30.5.6 Register second account: `atuin logout` → `atuin register -u rommel-eam -e <eam-email>`
- [x] 4.30.5.7 Verify EAM uses same encryption key — `atuin key` should match `op://Kubernetes/Atuin/encryption-key`
- [x] 4.30.5.8 Switch back to personal: `atuin logout` → `atuin login -u rommel-personal`
- [x] 4.30.5.9 Close registration: set `ATUIN_OPEN_REGISTRATION=false` in server deployment, reapply

### 4.30.6 Cutover

- [x] 4.30.6.1 Update Homepage widget — add Atuin to infrastructure services
- [x] 4.30.6.2 Add Uptime Kuma monitor for `https://atuin.k8s.rommelporras.com`
- [x] 4.30.6.3 Add AdGuard DNS rewrite if needed (wildcard may cover it)
- [x] 4.30.6.4 Verify sync works: run a command on WSL2, check `atuin search` shows it, then check from another session

### 4.30.7 Observability

- [x] 4.30.7.1 Create `manifests/monitoring/dashboards/atuin-dashboard-configmap.yaml` — Grafana dashboard
  - Pod status row (UP/DOWN for both Atuin server and PostgreSQL)
  - Network traffic row
  - Resource usage row (CPU + Memory with request/limit lines)
- [x] 4.30.7.2 Create PrometheusRule for Atuin alerts
  - `AtuinDown`: Blackbox probe fails for 3m (probe_success==0)
  - `AtuinPostgresDown`: PostgreSQL 0 available replicas for 5m
  - `AtuinHighRestarts`: >3 container restarts in 1h (sustained 5m)
  - `AtuinHighMemory`: >80% memory limit for 10m
- [x] 4.30.7.3 Add Blackbox probe for `http://atuin-server.atuin.svc.cluster.local:8888/healthz` (internal ClusterIP, HTTP 200 check — tests pod health only, not gateway/TLS path)

### 4.30.8 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.30.8.1 Update `docs/context/Cluster.md` — add Atuin to services
- [x] 4.30.8.2 Update `docs/context/Gateway.md` — add HTTPRoute
- [x] 4.30.8.3 Update `docs/context/Secrets.md` — add Atuin 1Password items
- [x] 4.30.8.4 Update `VERSIONS.md` — add Atuin server + PostgreSQL versions
- [x] 4.30.8.5 Update `README.md` — add Atuin to services list
- [x] 4.30.8.6 Update `docs/reference/CHANGELOG.md`
- [x] 4.30.8.7 Create `docs/rebuild/v0.28.0-atuin.md`
- [x] 4.30.8.8 `/audit-docs`
- [x] 4.30.8.9 `/commit`
- [x] 4.30.8.10 `/release v0.28.0 "Atuin Self-Hosted Shell History"`
- [x] 4.30.8.11 Move this file to `docs/todo/completed/`

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/atuin/namespace.yaml` | Namespace | `atuin` namespace with PSS labels |
| `manifests/atuin/postgres-deployment.yaml` | Deployment + PVC | PostgreSQL 18.3 for Atuin |
| `manifests/atuin/postgres-service.yaml` | Service | ClusterIP for PostgreSQL |
| `manifests/atuin/server-deployment.yaml` | Deployment + PVC | Atuin sync server |
| `manifests/atuin/server-service.yaml` | Service | ClusterIP for Atuin server |
| `manifests/atuin/httproute.yaml` | HTTPRoute | `atuin.k8s.rommelporras.com` |
| `manifests/atuin/networkpolicy-ingress.yaml` | CiliumNetworkPolicy | Default deny ingress + allow gateway, intra-ns |
| `manifests/atuin/networkpolicy-egress.yaml` | CiliumNetworkPolicy | Allow DNS + intra-ns, deny internet |
| `manifests/atuin/backup-cronjob.yaml` | CronJob | Weekly PostgreSQL pg_dump backup |
| `manifests/monitoring/dashboards/atuin-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard |
| `manifests/monitoring/alerts/atuin-alerts.yaml` | PrometheusRule | Atuin + PostgreSQL alerts |
| `manifests/monitoring/probes/atuin-probe.yaml` | Probe | Blackbox HTTP probe for health endpoint |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add Atuin widget |
| Uptime Kuma UI | Add HTTP monitor for `https://atuin.k8s.rommelporras.com/healthz` with accepted status codes `200-299, 403` (403 from in-cluster hairpin through Cilium Gateway is expected) |

---

## Dotfiles Changes Required

After the server is deployed, the dotfiles repo needs **no code changes** — the template
already supports everything. The user just needs to update their chezmoi data:

### 1. Update chezmoi data on each machine

```bash
chezmoi edit-config
# Set: atuin_sync_address = "https://atuin.k8s.rommelporras.com"
# Set: atuin_account = "rommel-personal"  (or "rommel-eam" for work containers)
chezmoi apply
```

This populates `~/.config/atuin/config.toml` with the `sync_address` line.

### 2. Login on each machine

```bash
# First machine (already registered above):
atuin login -u rommel-personal
# Enter password + encryption key from 1Password

# Import existing zsh history (first machine only):
atuin import zsh
atuin sync
```

### 3. Account mapping per environment

| Environment | chezmoi `atuin_account` | What to run |
|---|---|---|
| wsl-work | `rommel-personal` | `atuin login -u rommel-personal` |
| wsl-gaming | `rommel-personal` | `atuin login -u rommel-personal` |
| distrobox-personal | `rommel-personal` | `atuin login -u rommel-personal` |
| distrobox-work | `rommel-eam` | `atuin login -u rommel-eam -k $(op read 'op://Kubernetes/Atuin/encryption-key')` |
| distrobox-sandbox | `none` | No Atuin (excluded in `.chezmoiignore`) |
| aurora | `none` | No Atuin (excluded in `.chezmoiignore`) |

---

## Critical: Encryption Key Backup

Atuin is **end-to-end encrypted**. The encryption key is generated locally during
`atuin register` and stored at `~/.local/share/atuin/key`. If this key is lost,
synced history is **unrecoverable** — the server cannot decrypt it.

All personal accounts (`rommel-personal`, `rommel-eam`) share a single encryption key.
This is by design — `atuin register` reuses the existing key file if present.

**Immediately after first registration:**
```bash
atuin key
# Copy the output → save to 1Password "Atuin" item field "encryption-key"
```

The key is needed when logging in on new machines:
```bash
atuin login -u rommel-personal -p '<password>' -k "$(op read 'op://Kubernetes/Atuin/encryption-key')"
```

---

## Verification Checklist

- [x] Atuin server pod running in `atuin` namespace
- [x] PostgreSQL pod running with Longhorn PVC attached
- [x] `atuin.k8s.rommelporras.com` responds with HTTPS
- [x] Both accounts registered (`rommel-personal`, `rommel-eam`) — naming: `rommel-<dept-or-company>`
- [x] Encryption keys saved to 1Password
- [x] Registration closed (`ATUIN_OPEN_REGISTRATION=false`)
- [x] WSL2 history imported and syncing
- [x] `atuin search` returns results across sessions
- [x] Homepage widget shows Atuin status
- [x] Uptime Kuma monitoring endpoint
- [x] Grafana dashboard created
- [x] PrometheusRule alerts firing correctly on test
- [x] Backup CronJob runs successfully (manual trigger: `kubectl-homelab -n atuin create job --from=cronjob/atuin-backup atuin-backup-test`)
- [x] Backup file exists on NAS or PVC

---

## Rollback

```bash
# Remove Atuin server (history stays on clients)
kubectl-homelab delete -f manifests/atuin/

# Revert to local-only mode:
chezmoi edit-config
# Set: atuin_sync_address = ""
chezmoi apply
# Atuin continues working locally without sync
```
