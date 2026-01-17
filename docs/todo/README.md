# TODO

> **Current Phase:** 3.5 Gateway API
> **Goals:** CKA Certification (Sep 2026) + DevOps Upskilling (CI/CD, GitOps)

---

## Release Mapping

| Version | Content | Phases | Status |
|---------|---------|--------|--------|
| v0.1.0 | Project setup, documentation | Phase 1 | ✅ Released |
| v0.2.0 | Kubernetes HA cluster bootstrap | Phase 2 | ✅ Released |
| v0.3.0 | Storage infrastructure (Longhorn + NFS) | Phase 3.1-3.4 | ✅ Released |
| v0.4.0 | Gateway API, Monitoring, Logging | Phase 3.5-3.7 | ⬜ Pending |
| v0.5.0 | UPS monitoring (NUT migration) | Phase 3.8 | ⬜ Pending |
| v0.6.0 | Stateless workloads (AdGuard, Homepage) | Phase 4.1-4.4 | ⬜ Pending |
| v0.7.0 | Cloudflare Tunnel HA | Phase 4.5 | ⬜ Pending |
| v0.8.0 | GitLab CI/CD Platform | Phase 4.6 | ⬜ Pending |
| v0.9.0 | Application migrations (Portfolio, Invoicetron) | Phase 4.7-4.8 | ⬜ Pending |
| v0.10.0 | Production hardening (RBAC, NetworkPolicy) | Phase 5 | ⬜ Pending |
| v1.0.0 | CKA-ready cluster | Phase 6 + exam prep | ⬜ Target: Sep 2026 |

---

## Phase Index

### Completed

| Phase | Description | File |
|-------|-------------|------|
| 1 | Foundation (hardware, VLANs, Ubuntu) | [phase-1-foundation.md](completed/phase-1-foundation.md) |
| 2 | Kubernetes Bootstrap (kubeadm, Cilium) | [phase-2-bootstrap.md](completed/phase-2-bootstrap.md) |
| 3.1-3.4 | Storage (Longhorn + NFS) | [phase-3.1-3.4-storage.md](completed/phase-3.1-3.4-storage.md) |

### In Progress / Planned

| Phase | Description | File | Status |
|-------|-------------|------|--------|
| 3.5-3.8 | Gateway API, Monitoring, Logging, UPS | [phase-3.5-3.8-monitoring.md](phase-3.5-3.8-monitoring.md) | 🔄 Next |
| 4.1-4.4 | Stateless Workloads (AdGuard, Homepage) | [phase-4.1-4.4-stateless.md](phase-4.1-4.4-stateless.md) | ⬜ Planned |
| 4.5 | Cloudflare Tunnel HA | [phase-4.5-cloudflare.md](phase-4.5-cloudflare.md) | ⬜ Planned |
| 4.6 | GitLab CI/CD Platform | [phase-4.6-gitlab.md](phase-4.6-gitlab.md) | ⬜ Planned |
| 4.7 | Portfolio Migration | [phase-4.7-portfolio.md](phase-4.7-portfolio.md) | ⬜ Planned |
| 4.8 | Invoicetron Migration | [phase-4.8-invoicetron.md](phase-4.8-invoicetron.md) | ⬜ Planned |
| 5 | Production Hardening | [phase-5-hardening.md](phase-5-hardening.md) | ⬜ Planned |
| 6 | CKA Focused Learning | [phase-6-cka.md](phase-6-cka.md) | ⬜ Planned |

### Deferred

| Description | File |
|-------------|------|
| Stateful Workloads (Immich, ARR), Firmware | [deferred.md](deferred.md) |

---

## Namespace Strategy

> **Pattern:** Hybrid — shared infrastructure + self-contained projects

### System Namespaces (Shared Infrastructure)
| Namespace | Purpose |
|-----------|---------|
| `kube-system` | Control plane (exists) |
| `longhorn-system` | Distributed storage (exists) |
| `monitoring` | ALL observability (Prometheus, Grafana, Loki, exporters) |
| `cert-manager` | TLS certificate management |
| `cloudflare` | Cloudflare Tunnel (external access) |

### CI/CD Namespaces
| Namespace | Contents | Storage |
|-----------|----------|---------|
| `gitlab` | GitLab (web, sidekiq, gitaly, registry) | PostgreSQL, Redis, Git repos |
| `gitlab-runner` | GitLab Runner (Kubernetes executor) | Ephemeral (build caches) |

### Project Namespaces (Self-Contained Apps)
| Namespace | Contents | Database |
|-----------|----------|----------|
| `home` | AdGuard, Homepage | None (stateless) |
| `portfolio` | rommelporras.com (static Next.js) | None (static nginx) |
| `invoicetron` | Invoice processing app | Own PostgreSQL |
| `immich` | Immich server, ML, Redis | Own PostgreSQL |
| `arr` | Sonarr, Radarr, Prowlarr | Own PostgreSQL |

### Why This Pattern
- **Matches Docker Compose** — each project = one namespace
- **Simple service discovery** — `postgres:5432` works within namespace
- **Easy cleanup** — `kubectl delete namespace immich` removes everything
- **Isolated failures** — Immich DB issue doesn't affect ARR
- **Scoped NetworkPolicies** — each project controls its own access

### Database Strategy
- **Separate PostgreSQL per project** (not one shared instance)
- Each project's database lives in its own namespace
- Matches your Docker Compose setup

---

## Quick Reference

```bash
# Cluster health check
kubectl-homelab get nodes
kubectl-homelab get pods -A | grep -v Running

# Longhorn status
kubectl-homelab -n longhorn-system get pods
kubectl-homelab -n longhorn-system get volumes.longhorn.io

# Monitoring
kubectl-homelab -n monitoring port-forward svc/prometheus-grafana 3000:80

# etcd backup (CKA essential)
sudo etcdctl snapshot save /backup/etcd-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

## Learning Checkpoints

After each phase, you should be able to:

| Phase | Checkpoint |
|-------|------------|
| 3 | Explain PV/PVC binding, create StorageClass, troubleshoot PVC Pending |
| 4 | Deploy Deployments, configure Services, manage ConfigMaps, create Ingress |
| 5 | Write NetworkPolicies, configure RBAC, enforce Pod Security |
| 6 | Pass CKA with confidence |
| Deferred | Deploy StatefulSets, manage Secrets, handle stateful workloads |
