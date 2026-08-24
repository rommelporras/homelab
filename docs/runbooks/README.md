# Runbooks - Break-Glass Troubleshooting

**When something is broken, start here.** These are firefighting guides. For calm,
planned work (adding a service, rotating a secret), use
[../operations/](../operations/) instead.

## 👉 Start with the emergency guide

### [00-EMERGENCY.md](00-EMERGENCY.md) - symptom-first master guide

Read this **first** in any outage, especially when no AI assistant is available.
It's organized by what you *see* ("no internet", "a website's down", "a pod won't
start"), not by alert name. It has the quick-reference card (nodes, IPs, VIPs,
kubectl wrappers), the DNS/AdGuard playbook (your #1 cause of house-wide
outages), and the "everything is broken" root-cause triage.

## Detailed runbooks (by component / alert name)

Once you know the specific alert or component, these have the deep detail. Most
alerts route to Discord with the alert name - find it here.

**Don't know the alert name?** [alert-index.md](alert-index.md) maps every
Prometheus alert name to its triage path.

| Runbook | Covers |
|---------|--------|
| [alert-index.md](alert-index.md) | **Alert-name -> runbook lookup** (start here if you got a Discord alert with an unfamiliar name) |
| [networking.md](networking.md) | AdGuard DNS, NIC saturation, Cloudflare Tunnel, Tailscale, kube-vip |
| [cluster.md](cluster.md) | Pods (pending/crashloop/init/imagepull), CPU throttling, apiserver restarts, version-checker |
| [etcd-recovery.md](etcd-recovery.md) | **etcd disaster recovery** - restore the cluster from a snapshot (last resort) |
| [storage.md](storage.md) | Longhorn volumes/replicas, NVMe SMART, LonghornUI, **StaleISCSISession** |
| [longhorn-hardware.md](longhorn-hardware.md) | Longhorn hardware / NVMe crash recovery |
| [oomkilled.md](oomkilled.md) | ContainerOOMKilled + repeat, common culprits |
| [argocd.md](argocd.md) | App OutOfSync/Unhealthy, sync failed, repo/controller down |
| [vault.md](vault.md) | Vault sealed/down/latency, ESO sync errors, snapshot failing |
| [apps.md](apps.md) | Ghost, Invoicetron, Portfolio, Karakeep, Ollama, Atuin, Uptime-Kuma, Homepage, MySpeed, GitLab |
| [arr-stack.md](arr-stack.md) | Prowlarr, Sonarr, Radarr, qBittorrent, Jellyfin, Tdarr, etc. |
| [certificates.md](certificates.md) | cert-manager / Let's Encrypt DNS-01 |
| [monitoring-infra.md](monitoring-infra.md) | **The watchers themselves** - blackbox/smartctl/metrics-server down, CSI control-plane down |
| [logging.md](logging.md) | Loki, Alloy |
| [otel.md](otel.md) | OTel Collector |
| [backup.md](backup.md) | Velero, Longhorn backups, vault snapshots (alert triage; **restore** procedures are in [../operations/restore.md](../operations/restore.md)) |
| [ups.md](ups.md) | UPS, NUT, graceful shutdown on power loss |
| [argo-workflows.md](argo-workflows.md) | Argo Workflows / CI pipelines (vault-snapshot CronWorkflow) |
| [argo-events.md](argo-events.md) | Argo Events controller / EventBus / EventSources / Sensors |
| [ci-cd.md](ci-cd.md) | CI/CD pipeline (GitLab -> Argo Events -> Argo Workflows), CIBuildStuck |

## The richest source of hard-won fixes

`CLAUDE.md` (repo root) has a **Gotchas** section that is effectively an incident
database - specific symptoms with their exact fixes. When you have a weird,
specific error, grep it there first:

```bash
grep -niE '<your symptom keyword>' /home/wsl/personal/homelab/CLAUDE.md
```

## Related

- [../operations/](../operations/) - routine how-to guides
- [../context/](../context/) - reference (IPs, architecture, monitoring, security)
- [../rebuild/](../rebuild/) - rebuild-from-scratch guides
