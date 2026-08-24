# Homelab Documentation

Documentation for the 3-node HA Kubernetes homelab. This page is the map - start
here and follow the link that matches what you're trying to do.

> **Cluster in one line:** 3x Lenovo M80q (Ubuntu 24.04), kubeadm HA control
> plane, Cilium CNI, Longhorn storage, everything deployed via ArgoCD GitOps.
> Canonical values live in [context/Cluster.md](context/Cluster.md).

---

## 🔴 Something is broken right now

Go straight to **[runbooks/00-EMERGENCY.md](runbooks/00-EMERGENCY.md)** - the
symptom-first master troubleshooting guide, written to be used **even with no AI
assistant available**. It starts from what you see ("no internet", "a site's
down") and walks you to the fix.

Then: [runbooks/](runbooks/) for the detailed per-component/alert runbooks.

---

## 🟢 I want to do something (routine work)

**New here / inheriting the cluster?** Start with [ONBOARDING.md](ONBOARDING.md).

**[operations/](operations/)** - the how-to guides:

- [operations/day-to-day.md](operations/day-to-day.md) - command cheatsheet
- [operations/argocd-guide.md](operations/argocd-guide.md) - using GitOps / ArgoCD
- [operations/adding-a-service.md](operations/adding-a-service.md) - add a service end-to-end (Immich example)
- [operations/managing-secrets.md](operations/managing-secrets.md) - Vault + External Secrets
- [operations/restore.md](operations/restore.md) - restore Longhorn / Velero / database data
- [operations/node-lifecycle.md](operations/node-lifecycle.md) - maintain / add / decommission a node
- [operations/graceful-shutdown-startup.md](operations/graceful-shutdown-startup.md) - planned full-cluster power off/on
- [operations/certificate-rotation-manual.md](operations/certificate-rotation-manual.md) - manual TLS break-glass

---

## 📖 I want to know a fact or understand the design

**[context/](context/)** - reference and explanation (the knowledge base):

| Need | Doc |
|------|-----|
| Node IPs, MACs, hostnames, hardware | [context/Cluster.md](context/Cluster.md) |
| Physical layout, power tree, cabling, console access | [context/Hardware.md](context/Hardware.md) |
| VIPs, DNS, VLANs, network policy | [context/Networking.md](context/Networking.md) |
| GPU / Intel device plugin / NFD (QSV transcoding) | [context/GPU-and-Device-Plugins.md](context/GPU-and-Device-Plugins.md) |
| Why decisions were made | [context/Architecture.md](context/Architecture.md) |
| Commands, rules, repo layout | [context/Conventions.md](context/Conventions.md) |
| HTTPRoutes, Gateway, TLS | [context/Gateway.md](context/Gateway.md) |
| Prometheus, Grafana, alerting | [context/Monitoring.md](context/Monitoring.md) |
| Longhorn, NFS | [context/Storage.md](context/Storage.md) |
| Backup schedules, restore, off-site | [context/Backups.md](context/Backups.md) |
| 1Password / Vault paths | [context/Secrets.md](context/Secrets.md) |
| PSS, ESO hardening, SA tokens | [context/Security.md](context/Security.md) |
| Cloudflare, Tailscale, SMTP, GA4 | [context/ExternalServices.md](context/ExternalServices.md) |
| UPS, graceful shutdown | [context/UPS.md](context/UPS.md) |
| Upgrade / rollback procedures | [context/Upgrades.md](context/Upgrades.md) |
| Component versions | [../VERSIONS.md](../VERSIONS.md) |
| Kiro agent system (agents, access model, skills) | [../.kiro/README.md](../.kiro/README.md) |

Also: `CLAUDE.md` (repo root) has a **Gotchas** section that is effectively an
incident database - grep it for weird specific symptoms.

---

## 🛠️ I'm rebuilding from scratch / planning

| Need | Location |
|------|----------|
| Rebuild a release from nothing | [rebuild/](rebuild/) (one guide per release) |
| Initial cluster setup | [SETUP.md](SETUP.md) |
| Proxmox + OPNsense (firewall/network host) | [reference/PROXMOX_OPNSENSE_GUIDE.md](reference/PROXMOX_OPNSENSE_GUIDE.md) |
| What's planned next | [todo/](todo/) (active) and [todo/completed/](todo/completed/) |
| Remaining documentation work + known bugs | [todo/documentation-backlog.md](todo/documentation-backlog.md) |
| What changed and when | [reference/CHANGELOG.md](reference/CHANGELOG.md) |
| Kiro agent ecosystem - design spec | [plans/2026-08-14-kiro-homelab-agents-design.md](plans/2026-08-14-kiro-homelab-agents-design.md) |

---

## How this documentation is organized

Docs are split by *purpose* (loosely the [Diátaxis](https://diataxis.fr) model) so
the right kind is easy to find:

```
docs/
├── README.md          ← you are here (the map)
├── runbooks/          🔴 break-glass: fix it when it's broken (start: 00-EMERGENCY.md)
├── operations/        🟢 how-to: routine tasks (deploy, add service, secrets)
├── context/           📖 reference + explanation: facts, architecture, "why"
├── rebuild/           🛠️ disaster recovery: rebuild from scratch, per release
├── todo/              📋 planning: phase plans (active + completed)
└── reference/         📚 history: CHANGELOG, one-off guides
```

**Rule of thumb:** *fixing* -> `runbooks/`, *doing* -> `operations/`,
*knowing* -> `context/`, *rebuilding* -> `rebuild/`.
