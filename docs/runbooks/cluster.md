# Cluster Runbook

Covers: Pod lifecycle issues, cluster janitor, CPU throttling, node health, API server, version checking, test alerts

---

## PodStuckInInit

**Severity:** warning

Pod has been stuck in an init container state for more than 30 minutes. The init container is either crash-looping or running but the pod remains Pending. Common causes: misconfigured init container, missing ConfigMap/Secret, or dependency service unavailable.

### Triage Steps

1. Describe the pod to inspect init container status and events:
   ```
   kubectl-homelab describe pod <pod> -n <namespace>
   ```
2. Check events for the pod:
   ```
   kubectl-homelab get events -n <namespace> --field-selector involvedObject.name=<pod>
   ```
3. Check init container logs:
   ```
   kubectl-homelab logs <pod> -n <namespace> -c <init-container-name>
   ```
4. Verify referenced ConfigMaps and Secrets exist in the namespace:
   ```
   kubectl-homelab get configmap,secret -n <namespace>
   ```

---

## PodStuckPending

**Severity:** warning

Pod cannot be scheduled and has been in Pending state for more than 15 minutes. Typical causes: insufficient node resources, unbound PVC, node affinity/taint mismatch, or missing StorageClass.

### Triage Steps

1. Describe pod: `kubectl-homelab describe pod {{ $labels.pod }} -n {{ $labels.namespace }}`
2. Check events: `kubectl-homelab get events -n {{ $labels.namespace }} --field-selector involvedObject.name={{ $labels.pod }}`
3. Check node resources: `kubectl-homelab top nodes`
4. Check PVC bindings: `kubectl-homelab get pvc -n {{ $labels.namespace }}`

---

## PodCrashLoopingExtended

**Severity:** critical

A container has been in CrashLoopBackOff for more than 1 hour. This is an escalation beyond the standard 15-minute kube-prometheus-stack alert and will not self-heal - the root cause must be investigated.

### Triage Steps

1. Check pod logs: `kubectl-homelab logs {{ $labels.pod }} -n {{ $labels.namespace }} -c {{ $labels.container }} --previous`
2. Describe pod: `kubectl-homelab describe pod {{ $labels.pod }} -n {{ $labels.namespace }}`
3. Check if config/secret changed: `kubectl-homelab get events -n {{ $labels.namespace }}`

---

## PodImagePullBackOff

**Severity:** warning

A container image has been failing to pull for more than 15 minutes. Causes include: wrong image tag, tag deleted from registry, registry authentication failure, or network unreachable from nodes.

### Triage Steps

1. Check pod events: `kubectl-homelab describe pod {{ $labels.pod }} -n {{ $labels.namespace }}`
2. Verify image exists: check registry for the exact tag
3. Check network: ensure nodes can reach the container registry

---

## ClusterJanitorFailing

**Severity:** warning

The cluster-janitor CronJob in `kube-system` has had failed job runs for 30 or more minutes. The janitor cleans up Failed pods and stopped Longhorn replicas and reports to Discord #janitor. While failing, these resources will accumulate without cleanup.

### Triage Steps

1. Check recent janitor job status:
   ```
   kubectl-homelab get jobs -n kube-system -l app=cluster-janitor
   ```
2. Check logs from the failing job:
   ```
   kubectl-homelab logs -n kube-system -l app=cluster-janitor --tail=50
   ```
3. Check the CronJob definition for recent changes:
   ```
   kubectl-homelab describe cronjob cluster-janitor -n kube-system
   ```
4. Verify the service account and RBAC are intact:
   ```
   kubectl-homelab get clusterrolebinding -l app=cluster-janitor
   ```

---

## CPUThrottlingHigh

**Severity:** info

A container outside the `arr-stack` namespace has had more than 50% of its CPU scheduling periods throttled for 15 consecutive minutes. This is a custom override of the built-in alert (threshold raised from 25% to 50%, `arr-stack` excluded for Tdarr/Byparr bursty workloads). Routed to null in Alertmanager - visible in UI only, no Discord notification.

### Triage Steps

1. Identify the container's current CPU request and limit:
   ```
   kubectl-homelab describe pod <pod> -n <namespace>
   ```
2. Check actual CPU usage against the limit:
   ```
   kubectl-homelab top pod <pod> -n <namespace> --containers
   ```
3. Review resource usage trends in Grafana (Resource Usage row on the namespace dashboard).
4. If the limit is too low for the workload, increase `resources.limits.cpu` in the manifest and redeploy.

---

## NodeMemoryMajorPagesFaults

**Severity:** warning

A node has a major page fault rate above 2000/s AND less than 15% memory available, sustained for 15 minutes. This compound condition distinguishes real memory exhaustion from routine NFS page cache misses during media transcoding (a known false positive at high page fault rates with plentiful free memory).

### Triage Steps

1. Check memory pressure on the node:
   ```
   kubectl-homelab describe node <node> | grep -A10 "Conditions:"
   ```
2. Identify top memory consumers on the node:
   ```
   kubectl-homelab top pods --all-namespaces --sort-by=memory | grep <node-name>
   ```
3. Check node-level memory metrics in Grafana (Node Exporter dashboard, memory breakdown).
4. If a specific pod is consuming excess memory, check its logs and consider restarting it or adjusting its memory limit.
5. If the node itself is under pressure, consider cordoning it and draining workloads:
   ```
   kubectl-admin cordon <node>
   kubectl-admin drain <node> --ignore-daemonsets --delete-emptydir-data
   ```

---

## KubeApiserverFrequentRestarts

**Severity:** warning

A single kube-apiserver pod has restarted more than 5 times in the last 24 hours. Each restart causes kube-vip to drop the cluster VIP (10.10.30.10) for approximately 2 minutes, causing brief connectivity loss. The root cause pattern is: etcd transient blip -> apiserver liveness probe returns HTTP 500 on /livez -> kubelet kills the API server -> kube-vip on the current leader loses lease renewal -> VIP drops.

### Triage Steps

1. Check current restart count:
   ```
   kubectl-homelab get pod -n kube-system {{ $labels.pod }}
   ```

2. Check previous container logs (before last restart):
   ```
   kubectl-homelab logs -n kube-system {{ $labels.pod }} --previous --tail=100
   ```

3. Check kube-vip lease holder (may have changed):
   ```
   kubectl-homelab get lease plndr-cp-lock -n kube-system -o jsonpath='{.spec.holderIdentity}{"\n"}'
   ```

4. Check etcd health (common root cause):
   ```
   kubectl-homelab exec -n kube-system etcd-k8s-cp1 -- etcdctl \
     --cacert /etc/kubernetes/pki/etcd/ca.crt \
     --cert /etc/kubernetes/pki/etcd/peer.crt \
     --key /etc/kubernetes/pki/etcd/peer.key \
     endpoint health --cluster
   ```

5. Check apiserver liveness probe (triggers restart on failure):
   ```
   # /livez returns 500 when etcd is unreachable
   kubectl-homelab exec -n kube-system {{ $labels.pod }} -- wget -qO- http://127.0.0.1:8080/livez 2>/dev/null || echo "probe failed"
   ```

6. Check node events for OOM or system pressure:
   ```
   NODE=$(echo {{ $labels.pod }} | sed 's/kube-apiserver-//'); \
   kubectl-homelab describe node $NODE | grep -A5 Events
   ```

---

## VersionCheckerImageOutdated

**Severity:** warning

Note: this alert is being renamed from `ContainerImageOutdated` to `VersionCheckerImageOutdated`.

A container image has been running an outdated version for 7 or more days. Init containers and cert-manager images (Quay returns build numbers instead of semver) are excluded. This is informational - outdated images carry patch-level security risk but are not an immediate incident.

### Triage Steps

1. Check version-checker logs to confirm which image is flagged:
   ```
   kubectl-homelab logs -n monitoring -l app=version-checker --tail=50
   ```
2. Review the Grafana version-checker dashboard for a full list of outdated images.
3. Look up the latest tag for the image in its registry and update the manifest.
4. After updating, verify the new image tag exists before applying:
   ```
   kubectl-homelab apply -f manifests/<path-to-manifest>
   ```

---

## VersionCheckerKubeOutdated

**Severity:** info

Note: this alert is being renamed from `KubernetesVersionOutdated` to `VersionCheckerKubeOutdated`.

The Kubernetes version running on the cluster has been outdated for 14 or more days. Kubernetes upgrades require planning (drain order, etcd backup, kubeadm upgrade apply) so the threshold is longer than image alerts. No immediate action required.

### Triage Steps

1. Check current and latest versions reported by version-checker:
   ```
   kubectl-homelab logs -n monitoring -l app=version-checker --tail=20
   ```
2. Review the Grafana version-checker dashboard for current vs latest version detail.
3. Consult `docs/context/Upgrades.md` for the upgrade procedure before proceeding.
4. Schedule the upgrade during a maintenance window following the documented kubeadm upgrade path.

---

## VersionCheckerDown

**Severity:** warning

The version-checker service has been unreachable for 15 minutes. While it is down, outdated image and Kubernetes version alerts will not fire.

### Triage Steps

1. Check version-checker pod status:
   ```
   kubectl-homelab get pods -n monitoring -l app=version-checker
   ```
2. Check version-checker logs for errors:
   ```
   kubectl-homelab logs -n monitoring -l app=version-checker --tail=50
   ```
3. Describe the pod if it is not running:
   ```
   kubectl-homelab describe pod -n monitoring -l app=version-checker
   ```
4. Check the Grafana version-checker dashboard for historical availability.

---

## TestAlertCritical

**Severity:** critical

This is a test alert used to verify Alertmanager routing. It is applied from `manifests/monitoring/test-alert.yaml` and routes to Discord #incidents and email (critical@rommelporras.com). No action needed.

### Triage Steps

This alert is intentional and requires no remediation. If it fires unexpectedly, the PrometheusRule may have been accidentally left applied.

Remove it with:
```
kubectl-homelab delete prometheusrule test-alert -n monitoring
```

---

## TestAlertWarning

**Severity:** warning

This is a test alert used to verify Alertmanager routing. It is applied from `manifests/monitoring/test-alert.yaml` and routes to Discord #apps. No action needed.

### Triage Steps

This alert is intentional and requires no remediation. If it fires unexpectedly, the PrometheusRule may have been accidentally left applied.

Remove it with:
```
kubectl-homelab delete prometheusrule test-alert -n monitoring
```
