# ARR Stack Runbook

Covers: Sonarr, Radarr, Prowlarr, Jellyfin, Tdarr, qBittorrent, Seerr, Byparr, Bazarr

---

## ArrAppDown

**Severity:** critical

Scraparr exporter is unreachable. All ARR app monitoring is blind — no metrics from Sonarr, Radarr, Prowlarr, or any other ARR service will be collected while this is firing.

### Triage Steps

```
1. Check Scraparr pod status:
   kubectl-homelab get pods -n arr-stack -l app=scraparr

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/scraparr --tail=50

3. Verify ARR apps are running (Scraparr depends on their APIs):
   kubectl-homelab get pods -n arr-stack

4. If API key issues, check the ExternalSecret:
   kubectl-homelab describe externalsecret arr-api-keys -n arr-stack
```

---

## SonarrQueueStalled

**Severity:** warning

Sonarr has items in the download queue but the missing episode count has not decreased in 2+ hours. Downloads may be stuck or stalled.

### Triage Steps

```
1. Check Sonarr Activity queue:
   https://sonarr.k8s.rommelporras.com/activity/queue

2. Check qBittorrent for stalled downloads:
   https://qbittorrent.k8s.rommelporras.com

3. Check Prowlarr for indexer health:
   https://prowlarr.k8s.rommelporras.com/system/status
```

---

## RadarrQueueStalled

**Severity:** warning

Radarr has items in the download queue but the missing movie count has not decreased in 2+ hours. Downloads may be stuck or stalled.

### Triage Steps

```
1. Check Radarr Activity queue:
   https://radarr.k8s.rommelporras.com/activity/queue

2. Check qBittorrent for stalled downloads:
   https://qbittorrent.k8s.rommelporras.com

3. Check Prowlarr for indexer health:
   https://prowlarr.k8s.rommelporras.com/system/status
```

---

## SeerrDown

**Severity:** warning

Seerr (Overseerr) request portal is unreachable. Users cannot submit media requests.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n arr-stack -l app=seerr

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/seerr --tail=50

3. Verify Sonarr/Radarr connectivity (Seerr depends on them):
   kubectl-homelab get pods -n arr-stack -l app=sonarr
   kubectl-homelab get pods -n arr-stack -l app=radarr

4. Check events:
   kubectl-homelab describe pod -n arr-stack -l app=seerr
```

---

## TdarrDown

**Severity:** warning

Tdarr GPU transcoding service is unreachable. GPU transcoding is unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n arr-stack -l app=tdarr

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/tdarr --tail=50

3. Check GPU device plugin:
   kubectl-homelab get pods -n kube-system -l app=intel-gpu-plugin

4. Check events:
   kubectl-homelab describe pod -n arr-stack -l app=tdarr
```

---

## ByparrDown

**Severity:** warning

Byparr Cloudflare bypass proxy is unreachable. Prowlarr cannot reach Cloudflare-protected indexers.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n arr-stack -l app=byparr

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/byparr --tail=50

3. Check events:
   kubectl-homelab describe pod -n arr-stack -l app=byparr
```

---

## BazarrDown

**Severity:** warning

Bazarr subtitle downloader is unreachable. Automatic subtitle downloads for Jellyfin are unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n arr-stack -l app=bazarr

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/bazarr --tail=50

3. Verify Sonarr/Radarr connectivity (Bazarr syncs from them):
   kubectl-homelab get pods -n arr-stack -l app=sonarr
   kubectl-homelab get pods -n arr-stack -l app=radarr

4. Check events:
   kubectl-homelab describe pod -n arr-stack -l app=bazarr
```

---

## ArrQueueWarning

**Severity:** warning

Sonarr/Radarr have queue items flagged as stalled for 60+ minutes. The arr-stall-resolver CronJob runs every 30 minutes and switches quality profile to "Any", blocklists the release, and triggers a re-search. Firing at 60 minutes means the automation ran twice and could not clear the items. Common causes: content not on any indexer, all indexers down, Prowlarr config issue.

### Triage Steps

```
1. Check stall-resolver CronJob logs (last 3 runs):
   kubectl-homelab logs -n arr-stack -l app=arr-stall-resolver --tail=100

2. Check Sonarr/Radarr Activity queues for specific items:
   https://sonarr.k8s.rommelporras.com/activity/queue
   https://radarr.k8s.rommelporras.com/activity/queue

3. Check Prowlarr indexer health (no results = content not available):
   https://prowlarr.k8s.rommelporras.com/indexers

4. If indexers are healthy but no releases found, the content may not
   be available yet — remove from queue and re-add when released.
```

---

## ArrQueueError

**Severity:** critical

Sonarr/Radarr queue items are in hard error state for 15+ minutes. Two distinct causes - check CronJob logs to determine which: `state=stopped` means the download failed (no seeds) and the stall-resolver handled it automatically; `state=importFailed/importBlocked` means the torrent downloaded but import failed and needs a manual fix (NFS/disk/perms).

### Triage Steps

```
1. Check stall-resolver logs to determine the error type:
   kubectl-homelab logs -n arr-stack -l app=arr-stall-resolver --tail=100

   If logs show [SKIP/IMPORT]: torrent downloaded OK, import failed.
     → Go to step 3 (NFS/disk/perms issue).
   If logs show [ERROR] with state=stopped: download failed, automation acted.
     → Check Prowlarr for indexer health (step 4).

2. Check Sonarr/Radarr queue for error details:
   https://sonarr.k8s.rommelporras.com/activity/queue
   https://radarr.k8s.rommelporras.com/activity/queue

3. For import failures — check NFS and disk:
   kubectl-homelab exec -n arr-stack deploy/sonarr -- df -h /data
   kubectl-homelab get pvc -n arr-stack
   https://omv.home.rommelporras.com  (NAS disk usage)

4. For download failures — check indexer availability:
   https://prowlarr.k8s.rommelporras.com/indexers

5. Check qBittorrent for stuck torrents:
   https://qbit.k8s.rommelporras.com
```

---

## JellyfinDown

**Severity:** critical

Jellyfin media server is unreachable. Media streaming is unavailable.

### Triage Steps

```
1. Check Jellyfin pod status:
   kubectl-homelab get pods -n arr-stack -l app=jellyfin

2. Check pod logs:
   kubectl-homelab logs -n arr-stack deploy/jellyfin --tail=50

3. Check if NFS mount is healthy:
   kubectl-homelab exec -n arr-stack deploy/jellyfin -- ls /data/media/

4. Check GPU device plugin (QSV):
   kubectl-homelab get pods -n kube-system -l app=intel-gpu-plugin
```

---

## JellyfinHighMemory

**Severity:** warning

Jellyfin memory usage is above 3.5Gi (87% of the 4Gi limit). QSV transcoding can spike ~500Mi per concurrent stream; with 2-3 streams, approaching 4Gi is realistic. Risk of OOM kill if usage continues to climb.

### Triage Steps

```
1. Check Jellyfin memory usage in Grafana (Resource Usage row → ARR Stack dashboard)

2. Check active transcodes in Jellyfin UI:
   https://jellyfin.k8s.rommelporras.com/web/#/dashboard

3. Stop unnecessary transcodes or reduce concurrent stream count

4. If memory stays high with no active transcodes, restart Jellyfin:
   kubectl-homelab rollout restart deploy/jellyfin -n arr-stack

5. If this fires frequently, consider raising the memory limit in the Jellyfin manifest
```

---

## TdarrTranscodeErrors

**Severity:** warning

Tdarr has accumulated more than 2 new encode failures in the last hour. Uses `increase()[1h]` on a cumulative counter - auto-resolves approximately 1 hour after errors stop accumulating. Threshold of >2 avoids false positives from occasional one-off plugin failures.

### Triage Steps

```
1. Check Tdarr library stats in Grafana (Tdarr Library Stats row → ARR Stack dashboard)

2. Open Tdarr UI and inspect the failed items:
   https://tdarr.k8s.rommelporras.com

3. Check Tdarr server logs for plugin errors:
   kubectl-homelab logs -n arr-stack deploy/tdarr --tail=100

4. Common causes:
   - Boosh-QSV NaN bug: files with no per-stream BitRate (DASH-remuxed WEB-DL)
     Fix: set min/max_average_bitrate in plugin config, or add to skip list
   - GPU session conflict: only 1 QSV transcode at a time (UHD 630 limit)
     Fix: verify GPU worker count = 1
```

---

## TdarrTranscodeErrorsBurst

**Severity:** critical

Tdarr has more than 15 new encode failures in the last hour - indicative of a systematic plugin or node failure. All transcodes may be broken. Fires immediately with no grace period (`for: 0m`).

### Triage Steps

```
1. Open Tdarr UI immediately and check worker status:
   https://tdarr.k8s.rommelporras.com

2. Check Tdarr server + node logs for errors:
   kubectl-homelab logs -n arr-stack deploy/tdarr --tail=200
   kubectl-homelab logs -n arr-stack -l app=tdarr-node --tail=200

3. Check Intel GPU plugin availability:
   kubectl-homelab get pods -n kube-system -l app=intel-gpu-plugin

4. If all items are failing, pause the Tdarr queue and investigate before restarting.

5. Common burst causes:
   - All files in a library have the same unsupported codec/container
   - GPU device lost (node GPU plugin restart needed)
   - NFS mount issue causing all input files to be unreadable
```

---

## TdarrHealthCheckErrors

**Severity:** warning

Tdarr has accumulated more than 5 new health check failures in the last hour. Note: 73+ historical health check errors already exist from lifetime operation - this threshold targets new bursts, not the existing baseline. A burst of health check errors may indicate a library scan issue or NFS problem.

### Triage Steps

```
1. Check Tdarr library stats in Grafana (Tdarr Library Stats row → ARR Stack dashboard)

2. Open Tdarr UI and inspect health check failures:
   https://tdarr.k8s.rommelporras.com

3. Check if NFS is healthy (health checks need to read the files):
   kubectl-homelab exec -n arr-stack deploy/tdarr -- df -h /media

4. If NFS is healthy, the errors are likely files with minor codec issues —
   review in Tdarr UI and decide whether to skip or transcode them.
```

---

## TdarrHealthCheckErrorsBurst

**Severity:** critical

Tdarr has more than 50 new health check failures in the last hour - possible NFS or storage failure affecting bulk file reads. Fires immediately with no grace period (`for: 0m`).

### Triage Steps

```
1. Check NFS mount health immediately:
   kubectl-homelab exec -n arr-stack deploy/tdarr -- df -h /media
   kubectl-homelab exec -n arr-stack deploy/tdarr -- ls /media/

2. Check NAS status:
   https://omv.home.rommelporras.com

3. Check NFS PVC status in Kubernetes:
   kubectl-homelab get pvc -n arr-stack

4. If NFS is healthy, check Longhorn volume health:
   https://longhorn.k8s.rommelporras.com

5. Pause Tdarr library scan until NFS/storage is confirmed healthy.
```

---

## QBittorrentStalledDownloads

**Severity:** warning

One or more qBittorrent downloads have been in `stalledDL` state for 45+ minutes. `stalledDL` means no peers are sending data - normal briefly while peers are connecting, but after 45 minutes the arr-stall-resolver CronJob has had 1-2 cycles to clear them. If still stalled, the release may have no seeders or port forwarding is broken.

### Triage Steps

```
1. Open qBittorrent and identify the stalled torrents:
   https://qbittorrent.k8s.rommelporras.com

2. Check stall-resolver CronJob logs:
   kubectl-homelab logs -n arr-stack -l app=arr-stall-resolver --tail=100

3. Common causes:
   - No seeders available (release is dead): remove from queue and try another release
   - Port forwarding broken: check OPNsense firewall rules for qBittorrent port
   - Tracker offline: the tracker will reconnect automatically

4. Force re-announce in qBittorrent UI (right-click torrent → Force re-announce)
   to attempt reconnection with more peers.

5. If no seeders at any quality, remove from queue and re-search in Sonarr/Radarr.
```
