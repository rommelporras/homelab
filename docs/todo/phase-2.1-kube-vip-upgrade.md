# Phase 2.1: kube-vip Upgrade + Monitoring

> **Status:** Planned
> **Target:** v0.19.0
> **Prerequisite:** Phase 2 (Kubernetes Bootstrap)
> **CKA Topics:** Static pods, leader election, Lease objects, rolling upgrades, Prometheus monitoring

---

## Overview

Upgrade kube-vip from v1.0.3 to v1.0.4 to fix leader election errors, then add Prometheus monitoring with Grafana dashboard and Discord alerting.

**Current problem:** cp3 (current VIP leader) spams `Failed to update lock optimistically` every second. 19 container restarts. The VIP works but the error loop wastes API server resources and risks lease expiration under load.

**Architecture:**
```
                    ┌──────────────┐
                    │  Prometheus  │
                    └──┬───┬───┬──┘
           ┌──────────┘   │   └──────────┐
           ▼              ▼              ▼
      cp1:2112       cp2:2112       cp3:2112
    (kube-vip)     (kube-vip)     (kube-vip)
     non-leader     non-leader      LEADER
                                      │
                                VIP 10.10.30.10
                                      │
                                API server :6443
```

---

## v1.0.4 Release Analysis

> Released: 2026-01-29 | 41 commits since v1.0.3 | E2E tested against K8s 1.35.0

### Relevant fixes

| PR | Description | Impact |
|----|-------------|--------|
| #1383 | Fix stalled lease in leader election | **Directly fixes our cp3 error** |
| #1386 | Retry on leader election error | Improves recovery after transient failures |
| #1368 | Pass context to leader elector | Cleaner cancellation/shutdown |
| #1375 | Remove panic(), propagate context | Prevents crash on edge cases |
| #1361 | Graceful shutdown improvements | Better behavior during node drain |

### Risk assessment

| Factor | Assessment |
|--------|------------|
| Breaking changes | None (no config changes, same CLI flags) |
| K8s compatibility | E2E tested against K8s 1.35.0 (exact match) |
| Open issue #1413 | Low risk: Deployment mode only, we use static pods |
| Static pod upgrade | Kubelet auto-restarts on manifest change, seconds of downtime per node |
| VIP failover | 5s lease duration, sub-second failover to another node |

### Metrics caveat

kube-vip v1.0.3 (and v1.0.4) only exposes **Go runtime + process metrics** on port 2112. There are NO custom metrics for leader election status, ARP announcements, or VIP holder identity. Leader election health will be monitored via **kube-state-metrics lease metrics** instead (`kube_lease_owner`, `kube_lease_renew_time`).

---

## Pre-plan research findings

| Finding | Detail |
|---------|--------|
| Current leader | cp3 (`holderIdentity: k8s-cp3`) |
| cp3 error rate | ~1 error/second (continuous since lease acquisition Feb 2) |
| cp3 restarts | 19 container restarts |
| cp3 memory | 51MB (vs 21MB on cp1 — error loop overhead) |
| Lease transitions | 3 total since cluster creation |
| Prometheus metrics available | `up`, `process_*`, `go_*`, `promhttp_*` (no kube-vip custom metrics) |
| Lease metrics | Verify `kube_lease_owner` availability from kube-state-metrics |

---

## Tasks

### 2.1.1 Pre-upgrade preparation _(MANUAL: SSH to nodes)_

- [ ] 2.1.1.1 Verify VIP is healthy: `curl -sk https://10.10.30.10:6443/healthz`
- [ ] 2.1.1.2 Record current leader: `kubectl-homelab get lease plndr-cp-lock -n kube-system -o jsonpath='{.spec.holderIdentity}'`
- [ ] 2.1.1.3 Backup manifests from all 3 nodes:
  ```bash
  for node in cp1 cp2 cp3; do
    ssh wawashi@${node}.k8s.rommelporras.com \
      "sudo cp /etc/kubernetes/manifests/kube-vip.yaml /etc/kubernetes/kube-vip.yaml.v1.0.3.bak"
  done
  ```
- [ ] 2.1.1.4 Pre-pull v1.0.4 image on all 3 nodes:
  ```bash
  for node in cp1 cp2 cp3; do
    ssh wawashi@${node}.k8s.rommelporras.com \
      "sudo ctr image pull ghcr.io/kube-vip/kube-vip:v1.0.4"
  done
  ```

### 2.1.2 Rolling upgrade _(MANUAL: SSH to nodes, one at a time)_

**Order:** Non-leaders first (cp1, cp2), then leader (cp3) last.

- [ ] 2.1.2.1 Upgrade cp1 (non-leader):
  ```bash
  ssh wawashi@cp1.k8s.rommelporras.com \
    "sudo sed -i 's|ghcr.io/kube-vip/kube-vip:v1.0.3|ghcr.io/kube-vip/kube-vip:v1.0.4|' /etc/kubernetes/manifests/kube-vip.yaml"
  ```
- [ ] 2.1.2.2 Wait 30s, verify cp1 pod is Running:
  ```bash
  kubectl-homelab get pods -n kube-system -l component=kube-vip -o wide
  ```
- [ ] 2.1.2.3 Verify cp1 metrics still accessible: `curl -s http://10.10.30.11:2112/metrics | head -5`
- [ ] 2.1.2.4 Upgrade cp2 (non-leader): same sed command on cp2
- [ ] 2.1.2.5 Wait 30s, verify cp2 pod Running + metrics accessible
- [ ] 2.1.2.6 Upgrade cp3 (LEADER — triggers VIP failover):
  ```bash
  ssh wawashi@cp3.k8s.rommelporras.com \
    "sudo sed -i 's|ghcr.io/kube-vip/kube-vip:v1.0.3|ghcr.io/kube-vip/kube-vip:v1.0.4|' /etc/kubernetes/manifests/kube-vip.yaml"
  ```
- [ ] 2.1.2.7 Verify VIP failover: `curl -sk https://10.10.30.10:6443/healthz` (should succeed within 10s)
- [ ] 2.1.2.8 Verify new leader: `kubectl-homelab get lease plndr-cp-lock -n kube-system -o jsonpath='{.spec.holderIdentity}'`
- [ ] 2.1.2.9 Verify NO more lease errors on any node:
  ```bash
  for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "--- $node ---"
    kubectl-homelab logs -n kube-system kube-vip-${node} --tail=5
  done
  ```

### 2.1.3 Update Ansible version

- [ ] 2.1.3.1 Update `ansible/group_vars/all.yml`: `kubevip_version: "v1.0.3"` → `"v1.0.4"`

### 2.1.4 Prometheus monitoring

- [ ] 2.1.4.1 Verify kube-state-metrics exposes lease metrics:
  ```bash
  kubectl-homelab get --raw "/api/v1/namespaces/monitoring/services/prometheus-kube-state-metrics:http/proxy/metrics" | grep kube_lease
  ```
- [ ] 2.1.4.2 Create `manifests/monitoring/kube-vip-monitoring.yaml`:
  - Headless Service (clusterIP: None, no selector) in `monitoring` namespace
  - Endpoints with all 3 node IPs (10.10.30.11, .12, .13) on port 2112
  - ServiceMonitor with `release: prometheus` label, scrape interval 30s
- [ ] 2.1.4.3 Apply and verify Prometheus target discovery
- [ ] 2.1.4.4 Create `manifests/monitoring/kube-vip-alerts.yaml` (PrometheusRule):
  - `KubeVipInstanceDown` — one instance unreachable for 2m (warning, Discord #status)
  - `KubeVipAllDown` — all instances unreachable for 1m (critical, Discord #incidents + email)
  - `KubeVipLeaseStale` — lease renewTime not updated in 30s (critical, Discord #incidents)
  - `KubeVipHighRestarts` — frequent pod restarts detected (warning, Discord #status)
- [ ] 2.1.4.5 Create `manifests/monitoring/kube-vip-dashboard-configmap.yaml` (Grafana dashboard):
  - Row 1: VIP status — leader identity, lease age, last transition time
  - Row 2: Instance health — up/down per node, restart count
  - Row 3: Process metrics — memory usage, CPU, goroutines per node
  - Row 4: Network — bytes sent/received per node (correlates with ARP activity)
- [ ] 2.1.4.6 Apply all monitoring manifests and verify in Grafana

### 2.1.5 Documentation & Release

- [ ] 2.1.5.1 Security audit (`/audit-security`)
- [ ] 2.1.5.2 Commit infrastructure changes
- [ ] 2.1.5.3 Update documentation:
  - `docs/todo/README.md` — add Phase 2.1, update version mapping
  - `README.md` — update kube-vip version
  - `VERSIONS.md` — kube-vip v1.0.3 → v1.0.4, version history entry
  - `docs/reference/CHANGELOG.md` — decision history
  - `docs/context/Cluster.md` — if any cluster-level changes
  - `docs/rebuild/v0.19.0-kube-vip-upgrade.md` — rebuild guide
- [ ] 2.1.5.4 `/audit-docs`
- [ ] 2.1.5.5 Commit documentation changes
- [ ] 2.1.5.6 `/release v0.19.0 "kube-vip Upgrade + Monitoring"`
- [ ] 2.1.5.7 Move this file to `docs/todo/completed/`

---

## Rollback Plan

### Scenario A: Single node fails after upgrade

```bash
# Revert manifest to v1.0.3 on the failed node
ssh wawashi@cpX.k8s.rommelporras.com \
  "sudo cp /etc/kubernetes/kube-vip.yaml.v1.0.3.bak /etc/kubernetes/manifests/kube-vip.yaml"
# Kubelet auto-restarts the pod within seconds
```

### Scenario B: VIP stuck after leader node upgrade

```bash
# 1. Check if any node holds VIP
ip addr show eno1 | grep 10.10.30.10  # run on each node via SSH

# 2. If no node holds VIP, delete the stale lease to force re-election
kubectl-homelab delete lease plndr-cp-lock -n kube-system

# 3. If still stuck, revert all nodes to v1.0.3
for node in cp1 cp2 cp3; do
  ssh wawashi@${node}.k8s.rommelporras.com \
    "sudo cp /etc/kubernetes/kube-vip.yaml.v1.0.3.bak /etc/kubernetes/manifests/kube-vip.yaml"
done
```

### Scenario C: Complete cluster API access lost

```bash
# If VIP is unreachable, SSH directly to a node and use local kubectl
ssh wawashi@cp1.k8s.rommelporras.com
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get pods -n kube-system

# Revert kube-vip manifest locally
sudo cp /etc/kubernetes/kube-vip.yaml.v1.0.3.bak /etc/kubernetes/manifests/kube-vip.yaml
```

### Rollback verification checklist

- [ ] VIP responds: `curl -sk https://10.10.30.10:6443/healthz`
- [ ] All kube-vip pods Running: `kubectl-homelab get pods -n kube-system -l component=kube-vip`
- [ ] Lease has valid holder: `kubectl-homelab get lease plndr-cp-lock -n kube-system`
- [ ] kubectl works normally: `kubectl-homelab get nodes`

---

## Files Added

| File | Purpose |
|------|---------|
| manifests/monitoring/kube-vip-monitoring.yaml | Headless Service + Endpoints + ServiceMonitor |
| manifests/monitoring/kube-vip-alerts.yaml | PrometheusRule with 4 alerts |
| manifests/monitoring/kube-vip-dashboard-configmap.yaml | Grafana dashboard ConfigMap |

## Files Modified

| File | Change |
|------|--------|
| ansible/group_vars/all.yml | kubevip_version: v1.0.3 → v1.0.4 |
| /etc/kubernetes/manifests/kube-vip.yaml (all 3 nodes) | Image tag v1.0.3 → v1.0.4 |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Upgrade path | Rolling (non-leaders first, leader last) | Maintains VIP availability throughout |
| Monitoring pattern | Headless Service + Endpoints + ServiceMonitor | Standard pattern for static pods (same as etcd in kube-prometheus-stack) |
| Leader monitoring | kube-state-metrics lease metrics | kube-vip has no custom Prometheus metrics; lease object gives leader identity |
| Alert routing | critical → #incidents + email, warning → #status | Matches existing alerting convention |
| Dashboard scope | Process metrics + lease status | Limited by kube-vip's metric surface (no custom metrics exposed) |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| Static pods | Kubelet watches `/etc/kubernetes/manifests/` and auto-restarts on changes |
| Leader election | Kubernetes Lease objects in coordination.k8s.io API group |
| Rolling upgrade | Non-leaders first to maintain VIP during leader restart |
| Optimistic concurrency | Lease updates use resourceVersion; stale version = "object has been modified" |
| Monitoring static pods | No Service selector possible; use manual Endpoints pointing to node IPs |

---

## Lessons Learned

1. **kube-vip has no custom Prometheus metrics** (v1.0.3 and v1.0.4) — only standard Go runtime and process metrics. Monitor leader election via Kubernetes Lease objects through kube-state-metrics instead.

2. **Optimistic lock errors don't mean VIP is down** — cp3 was the leader AND successfully maintaining the VIP despite constant lease update errors. The VIP worked fine; only log noise and wasted API server resources.

3. **Static pod restart count matters** — cp3 had 19 restarts. High restart count on a static pod running critical infrastructure is a signal to investigate, not ignore.

4. **Pre-pull images before static pod upgrades** — If the new image isn't cached when kubelet restarts the pod, the pull delay extends the VIP downtime window.

---

## Blog Update Notes

> For the blog agent to update https://blog.dev.k8s.rommelporras.com/kube-vip-ha/

### Changes to document

1. **Version upgrade**: v1.0.3 → v1.0.4
2. **Bug fix**: Leader election "optimistic lock" errors resolved
   - cp3 was spamming `Failed to update lock optimistically` every second
   - 19 container restarts accumulated
   - Fix: PRs #1383 (stalled lease) and #1386 (retry on error)
3. **Prometheus monitoring added**: kube-vip metrics now scraped on port 2112
4. **Grafana dashboard**: VIP health dashboard with leader identity, instance status, process metrics
5. **Alerting**: Discord notifications for VIP failures (#incidents for critical, #status for warnings)

### Suggested blog sections to add/update

- Update the "Current Version" or version reference from v1.0.3 to v1.0.4
- Add a "Monitoring" section covering Prometheus + Grafana setup
- Add a "Troubleshooting" section about the leader election error and fix
- Update any screenshots showing the old version
- Note the release analysis: 41 commits, E2E tested against K8s 1.35.0

### Key quote for blog

> "The `Failed to update lock optimistically` error was harmless — the VIP kept working. But v1.0.4 fixes the stalled lease bug (PR #1383) and adds retry logic (PR #1386), eliminating the log spam and reducing API server load."

---

## Verification Checklist

- [ ] VIP responds on all tests: `curl -sk https://10.10.30.10:6443/healthz`
- [ ] All 3 kube-vip pods Running with v1.0.4 image
- [ ] Zero lease errors in logs (all 3 nodes)
- [ ] Prometheus scraping all 3 kube-vip targets
- [ ] Grafana dashboard loads with data
- [ ] Alerts visible in Prometheus rules (4 alerts)
- [ ] cp3 restart count reset to 0 (fresh pod)
- [ ] Ansible group_vars updated to v1.0.4
- [ ] Security audit: PASS
