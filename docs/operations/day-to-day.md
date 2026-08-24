# Day-to-Day Operations Cheatsheet

> Routine commands for running the cluster. Not an emergency guide - for "it's
> broken" go to [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md).

---

## The two kubectl wrappers (never use plain `kubectl`)

| Wrapper | Kubeconfig | Access | Use for |
|---------|-----------|--------|---------|
| `kubectl-homelab` | `~/.kube/homelab-claude.yaml` | read-only, no secret get, no pod logs | looking at things |
| `kubectl-admin` | `~/.kube/homelab.yaml` | full cluster-admin | changes, logs, exec |
| `helm-homelab` | `~/.kube/homelab.yaml` | admin | Helm (only `cilium` is Helm-managed) |
| plain `kubectl` / `helm` | `~/.kube/config` | **work AWS EKS** | ⚠️ NOT this cluster - don't |

`kubectl-homelab` is a zsh function - in a plain script use
`kubectl --kubeconfig ~/.kube/homelab.yaml`.

> **What `kubectl-homelab` is blocked from (use `kubectl-admin` instead):** it's
> broader than "secrets + logs". The restricted SA cannot `exec`, cannot `get` a
> named secret (only `get secrets` list works), and cannot list ArgoCD
> Applications, Velero `schedules`/`backups`, or cert-manager
> `certificates`/`challenges`/`orders`. For those, use `kubectl-admin`. Pods,
> nodes, events, PVCs, CronJobs, HTTPRoutes, CNPs, leases, ExternalSecrets, and
> Longhorn volumes all read fine on `kubectl-homelab`.

---

## Looking at the cluster

```bash
kubectl-homelab get nodes -o wide
kubectl-homelab get pods -A | grep -vE 'Running|Completed'   # anything unhealthy
kubectl-homelab get pods -n <ns> -o wide
kubectl-homelab top nodes                                     # CPU/mem per node
kubectl-homelab top pod -A --sort-by=memory | head -20        # biggest memory users
kubectl-homelab get events -n <ns> --sort-by=.lastTimestamp | tail -20
kubectl-homelab describe pod <pod> -n <ns>                    # events at the bottom
```

Logs and exec need admin (homelab is RBAC-blocked on `pods/log`):

```bash
kubectl-admin logs <pod> -n <ns> --tail=100
kubectl-admin logs <pod> -n <ns> --previous            # after a crash
kubectl-admin logs deploy/<name> -n <ns> -f            # follow
kubectl-admin exec -it <pod> -n <ns> -- sh
```

---

## Deploying / changing a service

It's all GitOps - see [argocd-guide.md](argocd-guide.md). The short loop:

```bash
# edit manifest/helm-values in Git  ->  /commit  ->  ArgoCD syncs in ≤3 min
kubectl-admin get applications -n argocd | grep -vE 'Synced.*Healthy'   # watch (admin: homelab can't list Applications)
```

Never `kubectl apply`/`helm upgrade` a managed resource (selfHeal reverts it).

---

## ArgoCD quick ops

```bash
# status of everything (admin: homelab RBAC can't list Applications)
kubectl-admin get applications -n argocd
# force one app to sync now (via controller pod, --core = no login)
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync <app> --core
# gitlab is manual-sync - always sync it by hand after changes
kubectl-admin exec -n argocd statefulset/argocd-application-controller -- \
  argocd app sync gitlab --core
```

UI: `https://argocd.k8s.rommelporras.com` (admin; password in 1Password "ArgoCD").

---

## Storage (Longhorn)

```bash
kubectl-homelab get pvc -A
kubectl-homelab get volumes.longhorn.io -n longhorn-system     # state/robustness
```

Longhorn UI: `https://longhorn.k8s.rommelporras.com`.
**Golden rule: never delete a PVC to fix a mount error** - see
[../runbooks/storage.md](../runbooks/storage.md). Take a snapshot before any
destructive storage op.

---

## Common surgical actions (need `kubectl-admin`)

```bash
# Restart a workload (safe, rolling)
kubectl-admin rollout restart deploy/<name> -n <ns>
# Force-recreate a stuck pod (e.g. OOM-in-place Longhorn deadlock)
kubectl-admin delete pod <pod> -n <ns>
# Scale
kubectl-admin scale deploy/<name> -n <ns> --replicas=0   # (then back up)
# Cordon/drain a node for maintenance
kubectl-admin cordon <node>
kubectl-admin drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl-admin uncordon <node>
```

Before scaling down anything with a Longhorn RWO volume, take a snapshot.

---

## Node access

```bash
ssh wawashi@10.10.30.11        # cp1  (also cp2 .12, cp3 .13)
# On a node:
sudo crictl ps                          # running containers
sudo journalctl -u kubelet -n 50        # kubelet issues (e.g. post-reboot sysctl)
sudo systemctl status kubelet
```

NAS: no direct SSH from WSL - hop through a node, then NFS-mount. See CLAUDE.md
"NAS Access".

---

## Monitoring & alerts

- **Grafana:** `https://grafana.k8s.rommelporras.com` (admin; password in 1Password)
- **Prometheus / Alertmanager:** exposed via their HTTPRoutes
- **Uptime Kuma:** `https://uptime.k8s.rommelporras.com` (external probing - this
  is often what pings you first for a DNS blip that Prometheus misses)
- Alerts route to Discord (`#incidents`, `#apps`, `#infra`, etc.) and email.
- Every alert has a runbook - find it by name in `docs/runbooks/`.

---

## Backups (verify they're running)

```bash
kubectl-homelab get cronjobs -A | grep -iE 'backup|snapshot'
kubectl-admin get schedules.velero.io -n velero        # Velero schedules (admin: velero.io RBAC-blocked on homelab)
kubectl-admin get backups.velero.io -n velero | tail    # recent backups
```

Backup alert triage: [../runbooks/backup.md](../runbooks/backup.md). Backup
design/coverage: [../context/Backups.md](../context/Backups.md). **Restore
procedures:** [../operations/restore.md](restore.md) (Longhorn / Velero / DB).

---

## Secrets

Add/rotate: [managing-secrets.md](managing-secrets.md). Never
`kubectl get secret -o yaml`. Check existence with plain `get`:

```bash
kubectl-homelab get externalsecret -A | grep -v SecretSynced   # any not synced?
kubectl-homelab get secrets -n <ns>                            # list names (get-by-name + -o yaml are RBAC-blocked)
```

---

## Slash commands (when the AI *is* available)

| Command | Does |
|---------|------|
| `/commit` | Secret-scan + conventional commit (use this, not raw git) |
| `/ship` | Cut a release tag |
| `/audit-security` | Pre-commit secret/security scan |
| `/audit-docs` | Check docs against live cluster |
| `/verify-sync` | Confirm an ArgoCD sync landed |
| `/audit-cluster` | Cluster security audit |

---

## Related

- [argocd-guide.md](argocd-guide.md) · [adding-a-service.md](adding-a-service.md) ·
  [managing-secrets.md](managing-secrets.md)
- [../context/Conventions.md](../context/Conventions.md) - the canonical rules
- [../runbooks/00-EMERGENCY.md](../runbooks/00-EMERGENCY.md) - when it breaks
