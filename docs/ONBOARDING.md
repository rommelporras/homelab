# Operator Onboarding - Running This Cluster

> Read this if you're inheriting this cluster, or you're the owner returning after
> months away. It's the calm "how do I run this day to day" orientation - NOT the
> firefighting guide. When something is broken, go straight to
> [runbooks/00-EMERGENCY.md](runbooks/00-EMERGENCY.md).
>
> Full navigation: [README.md](README.md).

---

## First 5 minutes - can you operate?

```bash
kubectl-homelab get nodes                 # all 3 Ready? (read-only wrapper)
kubectl-admin get applications -n argocd | grep -vE 'Synced.*Healthy'   # GitOps healthy?
```

- **kubectl access:** two wrappers. `kubectl-homelab` = read-only (safe for
  looking); `kubectl-admin` = full admin (for changes/logs/exec). Plain `kubectl`
  points at a **work** cluster - never use it here. Details + the RBAC blind spots:
  [operations/day-to-day.md](operations/day-to-day.md).
- **Web dashboards:** ArgoCD `argocd.k8s.rommelporras.com`, Grafana
  `grafana.k8s.rommelporras.com`, Longhorn `longhorn.k8s.rommelporras.com`,
  Uptime-Kuma `uptime.k8s.rommelporras.com`, Vault `vault.k8s.rommelporras.com`.
  Admin passwords are in 1Password (vault "Kubernetes").
- **Credentials:** all secrets flow 1Password -> Vault -> ESO -> pod. You need
  1Password access to the "Kubernetes" vault. See
  [operations/managing-secrets.md](operations/managing-secrets.md).

## The mental model in 6 lines

1. **GitOps:** you don't deploy, you `git push`; ArgoCD applies it (≤3 min). Never
   `kubectl apply`/`helm upgrade` managed resources - selfHeal reverts them.
2. **3 control-plane nodes**, etcd quorum needs 2 of 3. One node down is survivable.
3. **Longhorn** storage (2x replica). **Never delete a PVC** to fix a mount error.
4. **Cilium** CNI with NetworkPolicy default-deny-ish; new services need explicit
   ingress/egress rules.
5. **AdGuard (10.10.30.53)** is the LAN's DNS and a single point of failure - when
   it's down the whole house feels offline.
6. **Vault** auto-unseals via the vault-unsealer pod after a restart.

## What's normal vs actionable (alerts)

Alerts go to Discord and email. Severity/routing detail:
[context/Monitoring.md](context/Monitoring.md). Quick read:

| Channel / signal | Meaning | Action |
|------------------|---------|--------|
| `#incidents` (critical) + email | Something user-facing is down | Act now - [00-EMERGENCY.md](runbooks/00-EMERGENCY.md) |
| `#infra` | Platform-level warning (node, storage, cert) | Investigate today |
| `#apps` | An app is degraded/OutOfSync | Investigate; often self-heals |
| `#versions` | A newer image/chart exists | Non-urgent, batch it |
| `#janitor` / `#speedtest` | Routine job reports | Informational, ignore unless it stops |
| Uptime-Kuma push | External probe failed | Often the first sign of a DNS/L2 blip |
| Alert name you don't recognize | - | Look it up: [runbooks/alert-index.md](runbooks/alert-index.md) |

## Critical external dependencies - what breaks if each is lost

> These are outside the cluster. A lapse here causes an outage that no amount of
> kubectl fixes. This is the table to check before a token/subscription expires.

| Dependency | What it powers | What breaks if lost/expired | Where it lives |
|------------|----------------|------------------------------|----------------|
| **Domain `rommelporras.com`** | All DNS, all TLS SANs | Everything public + cert issuance | Registrar (renew!) |
| **Cloudflare DNS API token** | cert-manager DNS-01 challenges | TLS certs stop renewing -> all `*.k8s` sites show cert errors after expiry | Vault `cert-manager/cloudflare-api-token`, 1P "Cloudflare DNS API Token" |
| **Cloudflare Tunnel token** | `cloudflared` public ingress | External (internet) access to published services | Vault `cloudflare/cloudflared-token` |
| **1Password (Kubernetes vault)** | Source of truth for all secrets | Can't re-seed Vault / rotate secrets; running cluster keeps working | 1Password account |
| **Vault unseal keys** | Unsealing Vault after restart | If auto-unsealer AND keys both lost, ESO can't mint secrets cluster-wide | 1P "Vault Unseal Keys" + in-cluster `vault-unseal-keys` Secret |
| **Tailscale** | Remote access (subnet router) | Remote admin/DNS via tailnet; LAN unaffected | 1P (token has a hard expiry - see below) |
| **iCloud SMTP app password** | Alertmanager email + Ghost mail | Email alerts + blog transactional mail | Vault `monitoring/smtp`, 1P "iCloud SMTP" |
| **GitHub repo** | ArgoCD sync source | New deploys (running state unaffected) | github.com/rommelporras/homelab |
| **NAS (OMV, 10.10.30.4)** | NFS media + config, backup target | ARR media, NFS-backed config, backups | Physical, single 2TB drive |

**Credentials with hard expiry dates** (rotate before these):
- Tailscale API token: docs say expiry **2026-05-14** - but that date is already
  in the PAST (as of this writing 2026-07-08). ⚠️ **Verify in 1Password whether it
  lapsed or was rotated**, and update this date + `context/ExternalServices.md`. If
  it lapsed, the Homepage Tailscale widget may need re-provisioning.
- kubeadm certs: ~**Jan 2027** (weekly cert-expiry-check CronJob alerts at <30 days).
- TLS wildcard certs: auto-renewed by cert-manager (90-day); alerts at 30/7 days.
- Cloudflare token / SMTP password: no documented expiry - `TODO`: confirm and add.

> There is no single credential-rotation calendar yet - see
> [todo/documentation-backlog.md](todo/documentation-backlog.md).

## Where to go next

- Do a routine task -> [operations/](operations/)
- Fix something broken -> [runbooks/00-EMERGENCY.md](runbooks/00-EMERGENCY.md)
- Understand the design -> [context/](context/)
- Rebuild from scratch -> [rebuild/](rebuild/)
