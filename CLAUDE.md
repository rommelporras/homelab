# CLAUDE.md

Kubernetes homelab for CKA prep. 3-node HA cluster (kubeadm, Cilium CNI, Longhorn storage, kube-vip ARP) on Ubuntu 24.04 LTS.

## Source of Truth

**docs/context/Cluster.md** has all canonical values (IPs, MACs, hostnames, hardware). Don't duplicate — reference it.

| When you need... | Read... |
|------------------|---------|
| IPs, MACs, hardware specs | docs/context/Cluster.md |
| Component versions | VERSIONS.md |
| Architecture decisions | docs/context/Architecture.md |
| Network/switch setup | docs/context/Networking.md |
| Storage setup | docs/context/Storage.md |
| Gateway, HTTPRoutes, TLS | docs/context/Gateway.md |
| Cloudflare, GA4, SMTP | docs/context/ExternalServices.md |
| 1Password items | docs/context/Secrets.md |
| Prometheus, Grafana, alerts | docs/context/Monitoring.md |
| PSS, ESO hardening, SA tokens | docs/context/Security.md |
| UPS, graceful shutdown | docs/context/UPS.md |
| Commands, rules, repo layout | docs/context/Conventions.md |
| Upgrade/rollback procedures | docs/context/Upgrades.md |
| Phase plans | docs/todo/ (active) or docs/todo/completed/ (done) |
| Decision history | docs/reference/CHANGELOG.md |
| Rebuild from scratch | docs/rebuild/ (one guide per release) |

## Architecture

- **3 nodes** — etcd quorum minimum
- **Longhorn on NVMe** — 2x replication, no extra hardware
- **kube-vip (ARP)** — VIP without OPNsense changes
- **Cilium CNI** — NetworkPolicy for CKA
- **kubeadm** — CKA exam alignment

## Conventions

- **Phase files:** 1 service = 1 phase in `docs/todo/`. Done phases move to `docs/todo/completed/`.
- **Infra + docs = 2 commits:** Infrastructure first (`/audit-security` → `/commit`), then docs (`/audit-docs` → `/commit`).
- **No direct git/gh commands** — never run `git add`, `git commit`, `git tag`, `git push`, `gh release create`, or `gh release delete` outside of `/commit` or `/release`. These slash commands exist to enforce format, confirmation gates, and secret scanning. Running git/gh directly bypasses all of that.
- **No em dashes** — use regular hyphens (`-`) in commit messages, release titles, and documentation. Em dashes (`—`) are an AI writing signal. Write: `infra: phase 5.2 - etcd encryption` not `infra: phase 5.2 — etcd encryption`.
- **Observability for every service:** alerts in `manifests/monitoring/alerts/`, dashboards in `manifests/monitoring/dashboards/`, probes in `manifests/monitoring/probes/`.
- **Timezone:** `Asia/Manila` everywhere — never UTC or America/Chicago.
- **Grafana dashboards:** Pod Status row → Network Traffic row → Resource Usage row (CPU/Memory with dashed request/limit lines). Descriptions on every panel and row. ConfigMap: `grafana_dashboard: "1"` label, `grafana_folder: "Homelab"` annotation.

## Secrets

- **1Password vault:** `Kubernetes` only. Format: `op://Kubernetes/<item>/<field>`. Full inventory: `docs/context/Secrets.md`.
- **1Password plan is FAMILY** — Connect is NOT available (requires Business/Teams).
- **Never run `op` commands** — this terminal has no `op` access. Includes `op read`, `op item create/edit`.
- **Never write or read secret values** — no `kubectl create secret` with literal values, no `kubectl get secret -o json/yaml`, no `kubectl describe secret`. Values would flow through Anthropic's servers. To check existence: `kubectl-homelab get secret <name> -n <ns>` (no `-o json`). Note: `kubectl-homelab` RBAC blocks `get` on secrets — enforcement is technical, not just policy.
- **Safe automation pattern:** generate scripts with `op://` references, user runs in safe terminal. Never design workflows where Claude sees credential values.

## Rules

- **Use `kubectl-homelab` and `helm-homelab`** — plain `kubectl`/`helm` connect to work AWS EKS.
  - `kubectl-homelab` → `~/.kube/homelab-claude.yaml` (restricted: read-only, no secret `get`)
  - `kubectl-admin` → `~/.kube/homelab.yaml` (full cluster-admin — use only when write access needed)
  - `helm-homelab` → uses `~/.kube/homelab.yaml` (Helm needs admin access for installs/upgrades)
- **`kubectl-homelab` is zsh-only** — scripts that need admin access must use `kubectl --kubeconfig ~/.kube/homelab.yaml`.
- **Verify container images before deploying** — check the registry for the exact tag. Many images drop version tags without notice.
- **PUBLIC repository** — security review before every commit. Once pushed, secrets cannot be revoked.
- **GitLab is the primary remote** — use `glab` CLI with `--hostname gitlab.k8s.rommelporras.com` for API calls.

## NAS Access

- **SSH user:** `wawashi` (not `admin`). Hostname: `omv.home.rommelporras.com` (10.10.30.4).
- **No direct SSH from WSL** — SSH to a k8s node first (`ssh wawashi@10.10.30.11`), then NFS mount from there.
- **Create NFS directories via mount:** `sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && sudo mkdir -p /tmp/nfs/<path> && sudo umount /tmp/nfs`
- **No SSH keys from k8s nodes to NAS** — use NFS mount approach, not `ssh wawashi@10.10.30.4`.

## Gotchas

- **kubeadm defaults ≠ raw component defaults** — kubeadm sets `anonymous-auth: false`, `authorization.mode: Webhook`, `rotateCertificates: true` on kubelet, and `--bind-address=0.0.0.0` on controller-manager/scheduler. CIS benchmarks reference raw defaults — verify actual state before planning changes.
- **Homepage uses kustomize** — `kubectl-homelab apply -k manifests/home/homepage/`, NOT `-f`.
- **qBittorrent CSRF blocks HTTP probes** — use `tcpSocket`, never `httpGet`.
- **PostgreSQL PGDATA** — set `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectory). Top-level mount breaks initdb.
- **Longhorn `orphan-resource-auto-deletion`** — NOT a boolean. Semicolon-separated: `replica-data;instance`.
- **Grafana RWO PVC on Helm upgrade** — new pod can't attach. Scale down first: `kubectl-admin scale deployment/prometheus-grafana -n monitoring --replicas=0`, wait for termination, then upgrade.
- **Cilium HTTPRoute `<none>` status** — `kubectl-homelab rollout restart deployment/cilium-operator -n kube-system`.
- **Sonarr/Radarr API** — external HTTPRoute returns 404. Must port-forward from WSL.
- **CiliumNP default-deny** — `ingress: [{}]` = allow-all (empty rule matches everything), `ingress: []` = deny-all. Opposite of K8s NP intuition where `{}` means deny.
- **CiliumNP CIDR vs pod traffic** — `toCIDR`/`fromCIDR` with pod CIDR `10.244.0.0/16` silently fails for pod-to-pod traffic. Cilium uses identity-based matching for managed endpoints. Use `toEndpoints`/`toEntities` instead.
- **CiliumNP `kube-apiserver` entity** — cross-node API server traffic (e.g. admission webhooks) arrives with `remote-node` identity in Cilium tunnel mode. Policies for webhook ports must allow both `kube-apiserver` and `remote-node`.
- **rsync to NTFS (WSL2 `/mnt/c/`)** — Unix sockets and device files can't be created. Use `--no-specials --no-devices`. Root-owned NAS files need `--rsync-path="sudo rsync"`.
- **jq with large file lists** — shell `ARG_MAX` limit breaks `--argjson` with 2000+ file JSON objects. Use temp files + `--slurpfile` instead.
- **Grafana sidecar resources** — set per-sidecar (`sidecar.dashboards.resources` + `sidecar.datasources.resources`), not shared `sidecar.resources`. Shared key can cause port 8080 conflicts.
- **Loki sidecar CrashLoop** — `sidecar:` key with only `resources:` enables the rules sidecar which crashes without Ruler. Set `sidecar.rules.enabled: false` if Ruler is not in use.
- **alpine/k8s has no tzdata** — `TZ=Asia/Manila` silently falls back to UTC. Use `TZ=UTC-8` (POSIX: means UTC+8 = Manila).
- **etcd image is distroless** — `registry.k8s.io/etcd:3.6.6-0` has no shell, no cp, no coreutils. Use initContainer to copy etcdctl, run backup from alpine/k8s.
- **SQLite live backup** — never raw `cp` a live SQLite DB (WAL corruption). Use `sqlite3 <db> ".backup <dest>"` or `keinos/sqlite3:3.46.1` image.
- **MinIO is dead** — repo archived Feb 2026. Use Garage S3 (`dxflrs/garage`) as replacement.
- **Scripts REPO_ROOT after reorg** — scripts in subdirectories (`scripts/vault/`, `scripts/monitoring/`). `REPO_ROOT` needs double dirname: `"$(dirname "$(dirname "$SCRIPT_DIR")")"`.
- **Longhorn v1.10 backup-target** — `backup-target` setting removed. Use Helm `defaultBackupStore.backupTarget` instead.
