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
- **Observability for every service:** alerts in `manifests/monitoring/alerts/`, dashboards in `manifests/monitoring/dashboards/`, probes in `manifests/monitoring/probes/`.
- **Timezone:** `Asia/Manila` everywhere — never UTC or America/Chicago.
- **Grafana dashboards:** Pod Status row → Network Traffic row → Resource Usage row (CPU/Memory with dashed request/limit lines). Descriptions on every panel and row. ConfigMap: `grafana_dashboard: "1"` label, `grafana_folder: "Homelab"` annotation.

## Secrets

- **1Password vault:** `Kubernetes` only. Format: `op://Kubernetes/<item>/<field>`. Full inventory: `docs/context/Secrets.md`.
- **1Password plan is FAMILY** — Connect is NOT available (requires Business/Teams).
- **Never run `op` commands** — this terminal has no `op` access. Includes `op read`, `op item create/edit`.
- **Never write or read secret values** — no `kubectl create secret` with literal values, no `kubectl get secret -o json/yaml`, no `kubectl describe secret`. Values would flow through Anthropic's servers. To check existence: `kubectl-homelab get secret <name> -n <ns>` (no `-o json`).
- **Safe automation pattern:** generate scripts with `op://` references, user runs in safe terminal. Never design workflows where Claude sees credential values.

## Rules

- **Use `kubectl-homelab` and `helm-homelab`** — plain `kubectl`/`helm` connect to work AWS EKS. Aliases use `~/.kube/homelab.yaml`.
- **`kubectl-homelab` is zsh-only** — scripts must use `kubectl --kubeconfig ~/.kube/homelab.yaml`.
- **Verify container images before deploying** — check the registry for the exact tag. Many images drop version tags without notice.
- **PUBLIC repository** — security review before every commit. Once pushed, secrets cannot be revoked.
- **GitLab is the primary remote** — use `glab` CLI with `--hostname gitlab.k8s.rommelporras.com` for API calls.

## NAS Access

- **SSH user:** `wawashi` (not `admin`). Hostname: `omv.home.rommelporras.com` (10.10.30.4).
- **No direct SSH from WSL** — SSH to a k8s node first (`ssh wawashi@10.10.30.11`), then NFS mount from there.
- **Create NFS directories via mount:** `sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && sudo mkdir -p /tmp/nfs/<path> && sudo umount /tmp/nfs`
- **No SSH keys from k8s nodes to NAS** — use NFS mount approach, not `ssh wawashi@10.10.30.4`.

## Gotchas

- **Homepage uses kustomize** — `kubectl-homelab apply -k manifests/home/homepage/`, NOT `-f`.
- **qBittorrent CSRF blocks HTTP probes** — use `tcpSocket`, never `httpGet`.
- **PostgreSQL PGDATA** — set `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectory). Top-level mount breaks initdb.
- **Longhorn `orphan-resource-auto-deletion`** — NOT a boolean. Semicolon-separated: `replica-data;instance`.
- **Grafana RWO PVC on Helm upgrade** — new pod can't attach. Scale down old RS, delete old pod first.
- **Cilium HTTPRoute `<none>` status** — `kubectl-homelab rollout restart deployment/cilium-operator -n kube-system`.
- **Sonarr/Radarr API** — external HTTPRoute returns 404. Must port-forward from WSL.
