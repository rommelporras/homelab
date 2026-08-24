# Operations Guides

**How to *do* routine things** in this homelab - deploy, add a service, manage
secrets, use ArgoCD. These are *how-to guides* for normal operation.

> Broken and need to fix it? Go to
> [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) instead. Runbooks are
> for firefighting; these guides are for calm, planned work.

| Guide | Read it when you want to... |
|-------|------------------------------|
| [day-to-day.md](day-to-day.md) | Look things up: the command cheatsheet (kubectl wrappers, logs, ArgoCD, storage, nodes, backups) |
| [argocd-guide.md](argocd-guide.md) | Understand and drive GitOps: sync, diff, roll back, the app-of-apps + AppProject model |
| [adding-a-service.md](adding-a-service.md) | Add a new service end-to-end (worked example: Immich) - manifests, secrets, network policy, ArgoCD app, monitoring |
| [managing-secrets.md](managing-secrets.md) | Add or rotate a secret (1Password -> Vault -> ESO -> pod), incl. the DB-password lockstep rule |
| [restore.md](restore.md) | Restore data - Longhorn volumes, Velero namespaces, databases (the safe paths) |
| [node-lifecycle.md](node-lifecycle.md) | Node maintenance (drain/reboot), adding a node, decommissioning a dead one |
| [graceful-shutdown-startup.md](graceful-shutdown-startup.md) | Planned full-cluster power-off and cold-start sequence |
| [certificate-rotation-manual.md](certificate-rotation-manual.md) | Manual TLS cert break-glass when cert-manager itself is down |

> Break-glass procedures (etcd restore, monitoring-infra down, alert lookup) live in
> [../runbooks/](../runbooks/) - see [etcd-recovery.md](../runbooks/etcd-recovery.md),
> [monitoring-infra.md](../runbooks/monitoring-infra.md), [alert-index.md](../runbooks/alert-index.md).

## How the docs are organized

This repo follows a documentation split (loosely the [Diátaxis](https://diataxis.fr)
model) so you can find the *right kind* of doc fast:

| Kind | Location | Answers |
|------|----------|---------|
| **How-to (routine)** | `docs/operations/` (here) | "How do I add a service / rotate a secret?" |
| **How-to (break-glass)** | `docs/runbooks/` | "It's on fire - how do I fix it?" |
| **Reference / explanation** | `docs/context/` | "What are the IPs / how is this architected / why?" |
| **Disaster rebuild** | `docs/rebuild/` | "Rebuild this from nothing" |
| **Planning / history** | `docs/todo/`, `docs/reference/` | "What's next / what changed?" |

Start at [../README.md](../README.md) for the full map.
