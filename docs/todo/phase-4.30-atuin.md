# Phase 4.30: Atuin Self-Hosted Shell History

> **Status:** ⬜ Planned
> **Target:** v0.28.0
> **Prerequisite:** Phase 4.28 complete (Alerting & Observability)
> **Priority:** Medium (quality-of-life, not blocking other phases)
> **DevOps Topics:** Stateful services, PostgreSQL, secrets management, multi-tenant accounts, CronJob backups
> **CKA Topics:** Deployment, StatefulSet vs Deployment, Service, PVC, Secrets, HTTPRoute, CronJob

> **Purpose:** Deploy a self-hosted Atuin sync server on the homelab cluster so shell history
> syncs across all machines (WSL2, Aurora DX, Distrobox containers) without relying on
> Atuin's public cloud. Two accounts (`rommel-personal`, `rommel-work`) provide context
> isolation between personal and work shell history.
>
> **Why self-host:** Full control over data, no third-party dependency, aligns with homelab
> philosophy. End-to-end encrypted regardless — the server never sees plaintext history.
>
> **Design doc:** `docs/plans/2026-02-28-aurora-dx-migration-design.md` § "Atuin History Sync"

---

## Current State

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
| Server image | `ghcr.io/atuinsh/atuin:v18.12.1` (match client version) |
| Server port | 8888/TCP |
| PostgreSQL | `docker.io/library/postgres:16` (dedicated, not shared — docs require 14+) |
| PostgreSQL port | 5432/TCP (ClusterIP, internal only) |
| URL | `atuin.k8s.rommelporras.com` (HTTPS via Gateway API) |
| Storage | Longhorn PVC 5Gi for PostgreSQL data, 10Mi for Atuin config |
| Registration | Open initially (close after both accounts created) |
| Accounts | `rommel-personal`, `rommel-work` |

---

## Dual-Account Architecture

```
rommel-personal account:
├── WSL2 Work Laptop (personal shell)
├── WSL2 Gaming Desktop (personal shell)
├── Aurora distrobox-personal
└── All share personal history

rommel-work account:
├── WSL2 Work Laptop (work context)
├── WSL2 Gaming Desktop (work context)
├── Aurora distrobox-work
└── All share work history

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

- [ ] 4.30.1.1 Verify `ghcr.io/atuinsh/atuin:v18.12.1` includes server binary (`atuin server start`)
- [ ] 4.30.1.2 Check Atuin server health endpoint — determine correct liveness/readiness probe path
- [ ] 4.30.1.3 Determine PostgreSQL resource usage — Atuin server is lightweight, most load is on Postgres
- [ ] 4.30.1.4 Plan 1Password items: `Atuin PostgreSQL` (DB credentials), `Atuin Encryption Key - Personal`, `Atuin Encryption Key - Work`
- [ ] 4.30.1.5 Decide Deployment vs StatefulSet for PostgreSQL — official docs suggest StatefulSet for production; Deployment+Recreate is simpler and matches other homelab services

### 4.30.2 Create Secrets

> Uses imperative `kubectl create secret` via 1Password. Migrate to ExternalSecret after Phase 4.29 (Vault + ESO).

- [ ] 4.30.2.1 Create 1Password item `Atuin PostgreSQL` in Kubernetes vault with fields: `username`, `password`, `database`, `uri`
- [ ] 4.30.2.2 Generate `kubectl create secret` command for `atuin-secrets` in `atuin` namespace — ask user to run in safe terminal
- [ ] 4.30.2.3 Verify secret exists: `kubectl-homelab -n atuin get secret atuin-secrets`

### 4.30.3 Create Manifests

- [ ] 4.30.3.1 Create `manifests/atuin/namespace.yaml` — Namespace with PSS labels
- [ ] 4.30.3.2 Create `manifests/atuin/postgres-deployment.yaml` — PostgreSQL Deployment + PVC
  - `Recreate` strategy (RWO PVC — only one pod can mount at a time)
  - Pinned image `postgres:16`
  - `preStop` lifecycle hook for graceful shutdown (`pg_ctl stop -D /var/lib/postgresql/data -w -t 60 -m fast`)
  - Security context: `runAsUser: 999`, `fsGroup: 999` (postgres user)
  - Resources: `cpu: 100m/250m`, `memory: 256Mi/512Mi` (official docs recommend 100Mi/600Mi)
  - PVC: 5Gi Longhorn for `/var/lib/postgresql/data`
  - TZ: `Asia/Manila`
- [ ] 4.30.3.3 Create `manifests/atuin/postgres-service.yaml` — ClusterIP on port 5432
- [ ] 4.30.3.4 Create `manifests/atuin/server-deployment.yaml` — Atuin server Deployment
  - Pinned image `ghcr.io/atuinsh/atuin:v18.12.1`
  - Args: `["server", "start"]`
  - Env: `ATUIN_HOST=0.0.0.0`, `ATUIN_PORT=8888`, `ATUIN_OPEN_REGISTRATION=true`, `ATUIN_DB_URI` from secret
  - Security context: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, `drop: ALL`
  - Resources: `cpu: 100m/250m`, `memory: 256Mi/1Gi` (official docs recommend 250m/1Gi — tune down later with metrics)
  - PVC: 10Mi Longhorn for `/config` (server config only, data is in PostgreSQL)
  - Liveness/readiness probe on port 8888
- [ ] 4.30.3.5 Create `manifests/atuin/server-service.yaml` — ClusterIP on port 8888
- [ ] 4.30.3.6 Create `manifests/atuin/httproute.yaml` — HTTPRoute for `atuin.k8s.rommelporras.com`
- [ ] 4.30.3.7 Create `manifests/atuin/networkpolicy.yaml` — CiliumNetworkPolicy
  - Atuin server → PostgreSQL on 5432
  - Ingress to Atuin server from gateway on 8888
  - Deny all other traffic
- [ ] 4.30.3.8 Create `manifests/atuin/backup-cronjob.yaml` — Weekly PostgreSQL backup
  - Schedule: `0 2 * * 0` (Sunday 2 AM Manila time)
  - Image: `postgres:16` (same as database)
  - Command: `pg_dump --host=postgres --username=atuin --format=c --file=/backup/atuin-backup-$(date +'%Y-%m-%d').pg_dump`
  - PVC or NFS mount for backup storage (consider NAS at `/export/Kubernetes/Backups/atuin/`)
  - Retention: keep last 4 backups (cleanup old dumps in the same job)
  - Secret: reuse `atuin-secrets` for `PGPASSWORD`

### 4.30.4 Deploy & Verify

- [ ] 4.30.4.1 Apply namespace and secrets first
- [ ] 4.30.4.2 Deploy PostgreSQL, wait for pod ready
- [ ] 4.30.4.3 Deploy Atuin server, wait for pod ready
- [ ] 4.30.4.4 Verify HTTPRoute: `curl -s https://atuin.k8s.rommelporras.com` (should respond)
- [ ] 4.30.4.5 Test registration: `atuin register -u test-user -e test@test.com` → verify success → delete test user

### 4.30.5 Create Accounts & Sync History

- [ ] 4.30.5.1 On WSL2, set `sync_address` in chezmoi data → `chezmoi apply`
- [ ] 4.30.5.2 Register: `atuin register -u rommel-personal -e <personal-email>`
- [ ] 4.30.5.3 **Save encryption key to 1Password** — `atuin key` → create `Atuin Encryption Key - Personal` item
- [ ] 4.30.5.4 Import existing history: review `~/.zsh_history` for sensitive data, then `atuin import zsh`
- [ ] 4.30.5.5 Sync: `atuin sync` → verify `atuin status`
- [ ] 4.30.5.6 Register second account: `atuin logout` → `atuin register -u rommel-work -e <work-email>`
- [ ] 4.30.5.7 **Save encryption key to 1Password** — `atuin key` → create `Atuin Encryption Key - Work` item
- [ ] 4.30.5.8 Switch back to personal: `atuin logout` → `atuin login -u rommel-personal`
- [ ] 4.30.5.9 Close registration: set `ATUIN_OPEN_REGISTRATION=false` in server deployment, reapply

### 4.30.6 Cutover

- [ ] 4.30.6.1 Update Homepage widget — add Atuin to infrastructure services
- [ ] 4.30.6.2 Add Uptime Kuma monitor for `https://atuin.k8s.rommelporras.com`
- [ ] 4.30.6.3 Add AdGuard DNS rewrite if needed (wildcard may cover it)
- [ ] 4.30.6.4 Verify sync works: run a command on WSL2, check `atuin search` shows it, then check from another session

### 4.30.7 Observability

- [ ] 4.30.7.1 Create `manifests/monitoring/atuin-dashboard-configmap.yaml` — Grafana dashboard
  - Pod status row (UP/DOWN for both Atuin server and PostgreSQL)
  - Network traffic row
  - Resource usage row (CPU + Memory with request/limit lines)
- [ ] 4.30.7.2 Create PrometheusRule for Atuin alerts
  - Pod not ready > 5m
  - PostgreSQL pod not ready > 5m
  - High memory usage (> 80% of limit)
- [ ] 4.30.7.3 Add Blackbox probe for `https://atuin.k8s.rommelporras.com` (HTTP 200 check)

### 4.30.8 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.30.8.1 Update `docs/context/Cluster.md` — add Atuin to services
- [ ] 4.30.8.2 Update `docs/context/Gateway.md` — add HTTPRoute
- [ ] 4.30.8.3 Update `docs/context/Secrets.md` — add Atuin 1Password items
- [ ] 4.30.8.4 Update `VERSIONS.md` — add Atuin server + PostgreSQL versions
- [ ] 4.30.8.5 Update `README.md` — add Atuin to services list
- [ ] 4.30.8.6 Update `docs/reference/CHANGELOG.md`
- [ ] 4.30.8.7 Create `docs/rebuild/v0.28.0-atuin.md`
- [ ] 4.30.8.8 `/audit-docs`
- [ ] 4.30.8.9 `/commit`
- [ ] 4.30.8.10 `/release v0.28.0 "Atuin Self-Hosted Shell History"`
- [ ] 4.30.8.11 Move this file to `docs/todo/completed/`

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/atuin/namespace.yaml` | Namespace | `atuin` namespace with PSS labels |
| `manifests/atuin/postgres-deployment.yaml` | Deployment + PVC | PostgreSQL 16 for Atuin |
| `manifests/atuin/postgres-service.yaml` | Service | ClusterIP for PostgreSQL |
| `manifests/atuin/server-deployment.yaml` | Deployment + PVC | Atuin sync server |
| `manifests/atuin/server-service.yaml` | Service | ClusterIP for Atuin server |
| `manifests/atuin/httproute.yaml` | HTTPRoute | `atuin.k8s.rommelporras.com` |
| `manifests/atuin/networkpolicy.yaml` | CiliumNetworkPolicy | Atuin ↔ PostgreSQL traffic rules |
| `manifests/atuin/backup-cronjob.yaml` | CronJob | Weekly PostgreSQL pg_dump backup |
| `manifests/monitoring/atuin-dashboard-configmap.yaml` | ConfigMap | Grafana dashboard |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Add Atuin widget |
| `manifests/monitoring/uptime-kuma/` | Add Atuin monitor |

---

## Dotfiles Changes Required

After the server is deployed, the dotfiles repo needs **no code changes** — the template
already supports everything. The user just needs to update their chezmoi data:

### 1. Update chezmoi data on each machine

```bash
chezmoi edit-config
# Set: atuin_sync_address = "https://atuin.k8s.rommelporras.com"
# Set: atuin_account = "rommel-personal"  (or "rommel-work" for work containers)
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
| distrobox-work | `rommel-work` | `atuin login -u rommel-work` |
| distrobox-sandbox | `none` | No Atuin (excluded in `.chezmoiignore`) |
| aurora | `none` | No Atuin (excluded in `.chezmoiignore`) |

---

## Critical: Encryption Key Backup

Atuin is **end-to-end encrypted**. The encryption key is generated locally during
`atuin register` and stored at `~/.local/share/atuin/key`. If this key is lost,
synced history is **unrecoverable** — the server cannot decrypt it.

**Immediately after registration:**
```bash
atuin key
# Copy the output → save to 1Password as "Atuin Encryption Key - Personal"
```

Do this for both accounts. The key is needed when logging in on new machines.

---

## Verification Checklist

- [ ] Atuin server pod running in `atuin` namespace
- [ ] PostgreSQL pod running with Longhorn PVC attached
- [ ] `atuin.k8s.rommelporras.com` responds with HTTPS
- [ ] Both accounts registered (`rommel-personal`, `rommel-work`)
- [ ] Encryption keys saved to 1Password
- [ ] Registration closed (`ATUIN_OPEN_REGISTRATION=false`)
- [ ] WSL2 history imported and syncing
- [ ] `atuin search` returns results across sessions
- [ ] Homepage widget shows Atuin status
- [ ] Uptime Kuma monitoring endpoint
- [ ] Grafana dashboard created
- [ ] PrometheusRule alerts firing correctly on test
- [ ] Backup CronJob runs successfully (manual trigger: `kubectl-homelab -n atuin create job --from=cronjob/atuin-backup test-backup`)
- [ ] Backup file exists on NAS or PVC

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
