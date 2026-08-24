# Alert-name to runbook index

> **Got a Discord alert and don't recognize the name? Start here.** This maps the
> **141 custom homelab alerts** (plus the key upstream ones) to the runbook or the
> [00-EMERGENCY.md](00-EMERGENCY.md) symptom section. Generic kube-prometheus-stack
> upstream alerts (many `Kube*`/`Node*`/`Alertmanager*`) are NOT all listed here -
> their `runbook_url` annotation links to the upstream runbooks site instead. Use
> this when you know the *alert name* but not the *symptom*. If you only know the
> symptom ("internet's down", "a site won't load"), start at
> [00-EMERGENCY.md](00-EMERGENCY.md) instead.
>
> Facts checked against the live cluster 2026-07-08; verify live state before acting.

---

## How alerts point to their runbook

Every alert carries a `runbook_url` annotation. There are **two kinds**, and this
matters during an outage:

- **Custom homelab alerts** point into this repo:
  `https://github.com/rommelporras/homelab/blob/main/docs/runbooks/<file>.md#<AlertName>`.
  The `#<AlertName>` anchor lands you on the exact section. Every custom alert has
  one (verified 2026-07-08: 141 custom alert definitions across the 34
  `*-alerts.yaml` files under `manifests/monitoring/alerts/`, and all 141 have a
  `runbook_url`).
- **kube-prometheus-stack defaults** (the `Kube*`, `etcd*`, `Node*`, `Watchdog`
  alerts shipped by the chart) point to the **upstream** site
  `https://runbooks.prometheus-operator.dev/runbooks/kubernetes/<alertname>`.

> **Caveat during a DNS/internet outage:** the upstream `runbooks.prometheus-operator.dev`
> links need working internet **and** DNS. In the exact scenario where AdGuard is
> down (your most common outage), those links won't load. The homelab `docs/runbooks/`
> files are cloned to disk at `~/personal/homelab/docs/runbooks/` - open them locally.
> This index gives you a local landing spot for the important upstream alerts too, so
> you don't need the internet to triage them.

**To see the annotation for any firing alert:**

```bash
# From the repo (fastest - it's declarative). Note the space after the colon:
grep -rn -A6 'alert: <AlertName>' manifests/monitoring/alerts/*.yaml \
  | grep -E 'alert:|runbook_url'

# From the live cluster (the read-only kubeconfig CAN read prometheusrules -o json).
# The JSON stores it as `"alert": "Name"` - the space after the colon matters:
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get prometheusrules -A -o json \
  | grep -A3 '"alert": "<AlertName>"'
```

**To enumerate every alert name defined in the repo:**

```bash
grep -rh 'alert:' manifests/monitoring/alerts/*.yaml | sed 's/.*alert: *//' | sort -u
```

---

## The index (grouped by area)

Anchors are the alert name itself (e.g. `networking.md#AdGuardDNSDown`). The
"Runbook" column is a relative link that works offline. A one-line meaning is in the
last column.

### Cluster / API / control-plane

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `KubeApiserverFrequentRestarts` | [cluster.md](cluster.md#KubeApiserverFrequentRestarts) | apiserver static pod restarting. Also [00-EMERGENCY §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable). |
| `KubeAPIDown` (upstream) | [00-EMERGENCY §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable) | The API is unreachable behind VIP `10.10.30.10`. Check kube-vip lease + etcd quorum. |
| `KubeControllerManagerDown` (upstream) | see [triage note below](#kubecontrollermanagerdown--kubeschedulerdown-no-local-runbook) | Deployments stop rolling, new pods never get created. **No local runbook - read below.** |
| `KubeSchedulerDown` (upstream) | see [triage note below](#kubecontrollermanagerdown--kubeschedulerdown-no-local-runbook) | Pods stuck `Pending`, nothing schedules. **No local runbook - read below.** |
| `etcdMembersDown` / `etcdInsufficientMembers` (upstream) | [etcd-recovery.md](etcd-recovery.md), [00-EMERGENCY §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable), [00-EMERGENCY §8](00-EMERGENCY.md#8-a-node-is-down-or-notready) | etcd lost a member. 2 of 3 = quorum; two down = API goes read-only. Get a node back first; only restore etcd as a last resort. |
| `KubeNodeNotReady` / `KubeNodeUnreachable` (upstream) | [00-EMERGENCY §8](00-EMERGENCY.md#8-a-node-is-down-or-notready), [../operations/node-lifecycle.md](../operations/node-lifecycle.md) | A node dropped. Often the kubelet sysctl-on-reboot issue. |
| `CPUThrottlingHigh` | [cluster.md](cluster.md#CPUThrottlingHigh) | Container hitting its CPU limit. |
| `NodeMemoryMajorPagesFaults` | [cluster.md](cluster.md#NodeMemoryMajorPagesFaults) | Node thrashing on major page faults. |
| `ClusterJanitorFailing` | [cluster.md](cluster.md#ClusterJanitorFailing) | The cleanup CronJob's last run failed. |
| `VersionCheckerDown` / `VersionCheckerImageOutdated` / `VersionCheckerKubeOutdated` | [cluster.md](cluster.md#VersionCheckerDown) | version-checker down or flagging outdated images/k8s. |

### Pods (won't start / crashing)

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `PodStuckPending` | [cluster.md](cluster.md#PodStuckPending) | Nothing will schedule it. Also [00-EMERGENCY §5](00-EMERGENCY.md#5-a-pod-wont-start). If *many* pods pend, check `KubeSchedulerDown`. |
| `PodStuckInInit` | [cluster.md](cluster.md#PodStuckInInit) | initContainer blocked on a dep/config/secret. |
| `PodImagePullBackOff` | [cluster.md](cluster.md#PodImagePullBackOff) | Bad tag or Docker Hub rate limit. |
| `PodCrashLoopingExtended` | [cluster.md](cluster.md#PodCrashLoopingExtended) | App crashes on boot; read `logs --previous`. |
| `ContainerOOMKilled` / `ContainerOOMKilledRepeat` | [oomkilled.md](oomkilled.md#ContainerOOMKilled) | Container hit its memory limit (exit 137). Watch for the Longhorn OOM-in-place mount deadlock ([00-EMERGENCY §5](00-EMERGENCY.md#5-a-pod-wont-start)). |
| `ResourceQuotaNearLimit` | [backup.md](backup.md#ResourceQuotaNearLimit) | A namespace ResourceQuota is nearly full. |

### Storage / Longhorn / NVMe

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `LonghornVolumeDegraded` | [storage.md](storage.md#LonghornVolumeDegraded) | A replica is missing (still serving from the other). |
| `LonghornVolumeReplicaFailed` | [storage.md](storage.md#LonghornVolumeReplicaFailed) | A replica failed to rebuild. |
| `LonghornVolumeAllReplicasStopped` | [storage.md](storage.md#LonghornVolumeAllReplicasStopped) | **Volume offline - all replicas down.** Do NOT delete the PVC. |
| `LonghornVolumeAutoSalvaged` | [longhorn-hardware.md](longhorn-hardware.md#LonghornVolumeAutoSalvaged) | Longhorn auto-recovered a volume after a crash. |
| `LonghornBackupFailed` | [backup.md](backup.md#LonghornBackupFailed) | A Longhorn recurring backup failed. |
| `LonghornUIDown` | [storage.md](storage.md#LonghornUIDown) | The Longhorn UI is down (volumes may still be fine). |
| `NVMeMediaErrors` / `NVMeSpareWarning` / `NVMeTemperatureHigh` / `NVMeWearHigh` | [storage.md](storage.md#NVMeMediaErrors) | SMART health of a node's NVMe drive. |
| `NodePCIeBusError` | [longhorn-hardware.md](longhorn-hardware.md#NodePCIeBusError) | PCIe bus error on a node (often the cp3 NVMe seating issue). |
| Mount stuck / `mke2fs in use` / stale iSCSI | [storage.md#StaleISCSISession](storage.md#StaleISCSISession), [00-EMERGENCY §6](00-EMERGENCY.md#6-storage--volume-stuck) | Node-level mount failures (multipathd, iSCSI). Never delete the PVC. |

### Networking / DNS / Gateway

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `AdGuardDNSDown` | [networking.md](networking.md#AdGuardDNSDown), [00-EMERGENCY §3](00-EMERGENCY.md#3-dns-and-adguard-outages-most-common) | LAN's primary DNS (`10.10.30.53`) is down. **Your #1 outage.** |
| `NetworkInterfaceCritical` / `NetworkInterfaceSaturated` | [networking.md](networking.md#NetworkInterfaceCritical) | A node NIC (`eno1`) errored or saturated. |
| `KubeVipInstanceDown` / `KubeVipAllDown` / `KubeVipHighRestarts` / `KubeVipLeaseStale` | [networking.md](networking.md#KubeVipInstanceDown) | kube-vip serves the API VIP `10.10.30.10` (lease `plndr-cp-lock`). See also [00-EMERGENCY §7](00-EMERGENCY.md#7-the-kubernetes-api-is-unreachable). |
| `CloudflareTunnelDown` / `CloudflareTunnelDegraded` | [networking.md](networking.md#CloudflareTunnelDown) | The Cloudflare Tunnel (external ingress) is down/degraded. |
| `TailscaleOperatorDown` / `TailscaleConnectorDown` | [networking.md](networking.md#TailscaleOperatorDown) | Tailscale operator/connector down. |
| A web app won't load (Gateway VIP `10.10.30.20`) | [00-EMERGENCY §4](00-EMERGENCY.md#4-a-single-web-app-is-down) | HTTPRoute / Cilium Gateway / CNP-ingress issues. |

### Certificates / TLS

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `CertificateExpiringSoon` / `CertificateExpiryCritical` | [certificates.md](certificates.md#CertificateExpiringSoon) | A cert is close to expiry. Wildcard certs live in the `default` ns. |
| `CertificateNotReady` | [certificates.md](certificates.md#CertificateNotReady), [00-EMERGENCY §4.1](00-EMERGENCY.md#41-tls-certificate-problems) | A cert failed to issue/renew (usually Cloudflare DNS-01 token). Manual re-issue: [../operations/certificate-rotation-manual.md](../operations/certificate-rotation-manual.md). |
| `CertManagerWebhookDown` | [certificates.md](certificates.md#CertManagerWebhookDown) | cert-manager webhook down - blocks new cert operations. |

### Vault / ESO (secrets)

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `VaultSealed` | [vault.md](vault.md#VaultSealed), [00-EMERGENCY §10](00-EMERGENCY.md#10-vault-sealed--secrets-missing) | Vault is sealed - ESO can't mint secrets. Check `vault-unsealer` first. |
| `VaultDown` | [vault.md](vault.md#VaultDown) | Vault pod down. |
| `VaultHighLatency` / `VaultMetricsMissing` / `VaultAuditFailure` | [vault.md](vault.md#VaultHighLatency) | Vault degraded / metrics or audit log issue. |
| `VaultSnapshotFailing` | [vault.md](vault.md#VaultSnapshotFailing) | Vault raft snapshot CronWorkflow failing. |
| `VaultSnapshotStale` | [argo-workflows.md](argo-workflows.md#VaultSnapshotStale) | Vault snapshot hasn't produced a recent file (runs via Argo Workflows). Restore steps: [argo-workflows.md](argo-workflows.md#vault-snapshot-restore-from-nfs). |
| `ESOSecretNotSynced` / `ESOSyncErrors` / `ESOWebhookDown` | [vault.md](vault.md#ESOSecretNotSynced) | ExternalSecrets not syncing (often a downstream symptom of Vault sealed). |

### ArgoCD / GitOps

> **Anchor note:** several ArgoCD alerts (`ArgocdGitFetchFailed`,
> `ArgocdClusterConnectionLost`, `ArgocdRepoServerPending`,
> `ArgocdNotificationDeliveryFailed`) do not yet have their own section in
> [argocd.md](argocd.md) - those links land at the top of the file. The general
> ArgoCD recovery steps and the [00-EMERGENCY §9](00-EMERGENCY.md#9-argocd--gitops-stuck)
> playbook cover them.

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `ArgocdAppOutOfSync` | [argocd.md](argocd.md#ArgocdAppOutOfSync), [00-EMERGENCY §9](00-EMERGENCY.md#9-argocd--gitops-stuck) | An app drifted from Git (covers `gitlab`; `cilium` excluded). |
| `ArgocdAppUnhealthy` | [argocd.md](argocd.md#ArgocdAppUnhealthy) | An app is unhealthy > 15 min. |
| `ArgocdSyncFailed` | [argocd.md](argocd.md#ArgocdSyncFailed) | A sync operation failed. |
| `ArgocdControllerDown` / `ArgocdRepoServerDown` / `ArgocdRepoServerPending` | [argocd.md](argocd.md#ArgocdControllerDown) | An ArgoCD core component is down. |
| `ArgocdGitFetchFailed` | [argocd.md](argocd.md), [00-EMERGENCY §9](00-EMERGENCY.md#9-argocd--gitops-stuck) | Can't fetch from the git repo. |
| `ArgocdClusterConnectionLost` | [argocd.md](argocd.md), [00-EMERGENCY §9](00-EMERGENCY.md#9-argocd--gitops-stuck) | ArgoCD lost its cluster connection. |
| `ArgocdNotificationDeliveryFailed` | [argocd.md](argocd.md) | ArgoCD notification delivery failed (cosmetic). |

### Apps

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `GhostDown`, `InvoicetronDown`, `PortfolioDown`, `KarakeepDown` / `KarakeepHighRestarts`, `OllamaDown` / `OllamaHighMemory` / `OllamaHighRestarts`, `AtuinDown` / `AtuinHighMemory` / `AtuinHighRestarts` / `AtuinPostgresDown`, `UptimeKumaDown`, `HomepageDown`, `MySpeedDown`, `ServiceHighResponseTime` | [apps.md](apps.md) (anchor = alert name) | A homelab web app is down or degraded. Also [00-EMERGENCY §4](00-EMERGENCY.md#4-a-single-web-app-is-down). |
| `GitLabPostgresDown` / `GitLabPostgresConnectionsHigh` / `GitLabRedisDown` / `GitLabRedisHighMemory` / `GitLabSidekiqQueueHigh` / `GitLabWebservice5xxHigh` | [apps.md](apps.md#GitLabPostgresDown) | GitLab component issues. `gitlab` is manual-sync in ArgoCD. |

### ARR stack / media

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `ArrAppDown` / `ArrQueueError` / `ArrQueueWarning` | [arr-stack.md](arr-stack.md#ArrAppDown) | A generic *arr app is down or its queue errored. |
| `ProwlarrDown`, `SonarrDown` / `SonarrQueueStalled`, `RadarrDown` / `RadarrQueueStalled`, `BazarrDown`, `ByparrDown`, `SeerrDown`, `RecommendarrDown` | [arr-stack.md](arr-stack.md) (anchor = alert name) | Specific *arr service down or stalled. |
| `QBittorrentStalledDownloads` | [arr-stack.md](arr-stack.md#QBittorrentStalledDownloads) | qBittorrent has stalled downloads. |
| `JellyfinDown` / `JellyfinHighMemory` | [arr-stack.md](arr-stack.md#JellyfinDown) | Jellyfin down / high memory. |
| `TdarrDown` / `TdarrHealthCheckErrors` / `TdarrHealthCheckErrorsBurst` / `TdarrTranscodeErrors` / `TdarrTranscodeErrorsBurst` | [arr-stack.md](arr-stack.md#TdarrDown) | Tdarr transcode/health-check issues. |

### CI/CD (Argo Events + Argo Workflows)

> **Note:** [ci-cd.md](ci-cd.md) is being **created alongside this index**. If that
> link 404s on disk, the runbook isn't written yet - fall back to
> [argo-events.md](argo-events.md), [argo-workflows.md](argo-workflows.md), and the
> CLAUDE.md gotchas (`grep -niE 'argo events|sensor|eventsource|ci pipeline' CLAUDE.md`).

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `ArgoWorkflowsControllerDown` / `ArgoWorkflowFailed` / `ArgoWorkflowError` | [argo-workflows.md](argo-workflows.md#ArgoWorkflowsControllerDown) | Argo Workflows controller down / a workflow failed. |
| `ArgoEventsControllerDown` / `EventBusDegraded` / `EventSourceDown` / `SensorDown` | [argo-events.md](argo-events.md#ArgoEventsControllerDown) | Argo Events plumbing (controller / NATS EventBus / EventSource / Sensor). |
| `CIPipelineFailed` / `CIBuildStuck` / `CIDeployMutexHeldTooLong` / `WebhookDeliveryFailed` | [ci-cd.md](ci-cd.md#CIPipelineFailed) | The CI/CD pipeline failed, stuck, mutex stuck, or a webhook didn't deliver. (`WebhookDeliveryFailed` is defined in `argo-events-alerts.yaml`.) |

### Backups

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `VeleroBackupFailed` / `VeleroBackupStale` | [backup.md](backup.md#VeleroBackupFailed) | A Velero backup failed or is stale. Restore: [../operations/restore.md](../operations/restore.md). |
| `EtcdBackupStale` | [backup.md](backup.md#EtcdBackupStale) | The etcd snapshot CronJob hasn't produced a recent backup. Restore: [etcd-recovery.md](etcd-recovery.md). |
| `GarageDown` | [backup.md](backup.md#GarageDown) | Garage S3 (backup target) is down. |
| `CronJobFailed` / `CronJobNotScheduled` | [backup.md](backup.md#CronJobFailed) | A CronJob failed or missed its schedule. |
| `LonghornBackupFailed` | [backup.md](backup.md#LonghornBackupFailed) | (Also under Storage.) A Longhorn recurring backup failed. |

### Monitoring / logging / observability infra

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `LokiDown` / `LokiHighErrorRate` / `LokiIngestionStopped` / `LokiCompactionStalled` / `LokiRetentionNotRunning` / `LokiWALDiskFull` | [logging.md](logging.md#LokiDown) | Loki (log store) down or degraded. |
| `AlloyNotSendingLogs` / `AlloyNotOnAllNodes` / `AlloyHighMemory` | [logging.md](logging.md#AlloyNotSendingLogs) | Alloy (log shipper DaemonSet) issue. |
| `OTelCollectorDown` | [otel.md](otel.md#OTelCollectorDown) | OTel Collector down. |
| `ClaudeCodeHighDailySpend` / `ClaudeCodeCriticalDailySpend` / `ClaudeCodeNoActivity` | [otel.md](otel.md#ClaudeCodeHighDailySpend) | Claude Code OTel spend/activity signals. |
| `DotctlCollectionStale` / `DotctlDriftDetected` | [otel.md](otel.md#DotctlCollectionStale) | dotctl telemetry stale / drift detected. |

### UPS / power

| Alert | Runbook | Meaning / where to go |
|-------|---------|-----------------------|
| `UPSOnBattery` / `UPSOffline` / `UPSLowBattery` / `UPSBatteryWarning` / `UPSBatteryCritical` / `UPSHighLoad` / `UPSBackOnline` / `UPSExporterDown` | [ups.md](ups.md) (anchor = alert name) | UPS/NUT state. `UPSLowBattery`/`UPSBatteryCritical` = graceful-shutdown territory ([../operations/graceful-shutdown-startup.md](../operations/graceful-shutdown-startup.md)). |

---

## Triage notes for alerts with NO local runbook

These two are **upstream** kube-prometheus-stack alerts (verified present in the
live cluster 2026-07-08). Their `runbook_url` points to `runbooks.prometheus-operator.dev`,
which needs internet, and their symptoms are not obviously mapped to a symptom
section - so here is the minimum you need, offline.

### `KubeControllerManagerDown` / `KubeSchedulerDown` (no local runbook)

Both are **static pods** run by kubelet from `/etc/kubernetes/manifests/` on **every**
control-plane node (they run active/standby with leader election, so only one is
"active" at a time, but a pod exists per node). The alert fires when Prometheus
can't scrape any instance.

**What you'll actually notice:**

- `KubeControllerManagerDown` - **Deployments/StatefulSets stop rolling. New pods
  from ReplicaSets/Jobs never get created.** Scaling does nothing. Deleted pods are
  not recreated. Nodes going `NotReady` don't get their pods evicted/rescheduled.
- `KubeSchedulerDown` - **Pods stay `Pending` forever; nothing gets assigned a
  node.** `kubectl describe pod` shows no `Scheduled` event.

**Detect (all read-only):**

```bash
# 1. Are the static pods Running on all 3 nodes? (read-only kubeconfig is fine)
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n kube-system -o wide \
  | grep -E 'controller-manager|scheduler'
# Expect kube-controller-manager-k8s-cp1/2/3 and kube-scheduler-k8s-cp1/2/3.

# 2. If a pod is missing/CrashLoop, read its logs. Pod logs are RBAC-BLOCKED on the
#    read-only kubeconfig - use kubectl-admin:
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n kube-system kube-controller-manager-k8s-cp1 --tail=50
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n kube-system kube-scheduler-k8s-cp1 --tail=50

# 3. Or straight from the node (works even if kubectl is degraded):
ssh wawashi@10.10.30.11 'sudo crictl ps -a | grep -E "controller-manager|scheduler"'
ssh wawashi@10.10.30.11 'sudo ls -1 /etc/kubernetes/manifests/'
# Should list: etcd.yaml, kube-apiserver.yaml, kube-controller-manager.yaml,
#              kube-scheduler.yaml, kube-vip.yaml
```

**Common causes:**

- A bad edit / corruption of the manifest file
  (`/etc/kubernetes/manifests/kube-controller-manager.yaml` or `...kube-scheduler.yaml`).
- The component crash-looping (check its logs, step 2/3 above - usually a flag or
  cert issue).
- A node down (then the *other* nodes' instances take leadership - this alone
  shouldn't fire the alert unless scraping is also broken; treat the node first via
  [00-EMERGENCY §8](00-EMERGENCY.md#8-a-node-is-down-or-notready)).

**Restart a static pod (the standard, safe way): move the manifest out and back.**
kubelet watches that directory - removing the file stops the pod, restoring it
starts a fresh one. Do this on the affected node.

> **WARNING:** these are control-plane components. Restarting the scheduler or
> controller-manager on a node briefly removes that instance from leader election;
> the other two nodes keep the function running, so a single-node restart is safe.
> Do NOT touch all three at once. Restart one, confirm the alert clears, then stop.
> If the manifest itself was edited/corrupted, do NOT blindly move-and-restore - a
> broken manifest will just crash-loop again; fix the manifest first (or restore it
> from a known-good copy / another node's identical file). The move-and-back trick
> restores the SAME file, so it only helps a genuinely-crashed-but-valid pod.

```bash
# Controller-manager on cp1 (repeat per node only if needed, one at a time):
ssh wawashi@10.10.30.11 \
  'sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/ && sleep 5 && \
   sudo mv /tmp/kube-controller-manager.yaml /etc/kubernetes/manifests/'

# Scheduler on cp1:
ssh wawashi@10.10.30.11 \
  'sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ && sleep 5 && \
   sudo mv /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/'
```

**Verify:**

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n kube-system -o wide \
  | grep -E 'controller-manager|scheduler'   # back to Running, restart count reset
```

Give Prometheus a couple of minutes to scrape and the alert to resolve. If it
persists, the component is crash-looping on start - read its logs (step 2/3) for
the real error before trying anything else.

---

## Related

- [00-EMERGENCY.md](00-EMERGENCY.md) - symptom-first master guide. Its §12 is a
  runbook-**file**-level index; this doc is the alert-**name**-level index (the two
  are complementary).
- [README.md](README.md) - runbook folder overview.
- [etcd-recovery.md](etcd-recovery.md) - etcd quorum loss / snapshot restore.
- [../operations/node-lifecycle.md](../operations/node-lifecycle.md) - reboot, drain,
  reset, rejoin a node.
- [../operations/restore.md](../operations/restore.md) - Velero / data restore.
- [../operations/graceful-shutdown-startup.md](../operations/graceful-shutdown-startup.md) - power-loss shutdown/startup order.
- [../operations/certificate-rotation-manual.md](../operations/certificate-rotation-manual.md) - manual TLS cert re-issue.
- [../context/Monitoring.md](../context/Monitoring.md) - Prometheus/Grafana/alerting reference.
- `CLAUDE.md` (repo root) - the "Gotchas" section is an incident database; grep it
  for weird, specific symptoms: `grep -niE '<keyword>' /home/wsl/personal/homelab/CLAUDE.md`.

