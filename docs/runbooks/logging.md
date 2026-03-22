# Logging Runbook

Covers: Loki log aggregation, Alloy log collection

---

## LokiDown

**Severity:** critical

Loki has been unreachable (scrape target `up == 0`) for more than 5 minutes. Log ingestion and querying are unavailable.

### Triage Steps

1. Check Loki pod status:
   ```
   kubectl-homelab get pods -n monitoring -l app.kubernetes.io/name=loki
   ```
2. Describe the pod for events (OOMKilled, probe failures, scheduling issues):
   ```
   kubectl-homelab describe pod -n monitoring -l app.kubernetes.io/name=loki
   ```
3. Check Loki logs for crash or startup errors:
   ```
   kubectl-homelab logs -n monitoring -l app.kubernetes.io/name=loki --tail=100
   ```
4. Check the Loki PVC is bound and not full:
   ```
   kubectl-homelab get pvc -n monitoring
   ```
5. If the PVC shows `Pending` or the pod is stuck on `ContainerCreating`, check Longhorn volume health in the Longhorn UI.

---

## LokiIngestionStopped

**Severity:** warning

Loki has received zero log lines for 15 minutes (`loki_distributor_lines_received_total` rate is 0). Logs are not being collected but Loki itself may still be running.

### Triage Steps

1. Confirm Alloy pods are running on all nodes:
   ```
   kubectl-homelab get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide
   ```
2. Check Alloy pod logs for send errors or connection failures to Loki:
   ```
   kubectl-homelab logs -n monitoring -l app.kubernetes.io/name=alloy --tail=100
   ```
3. Verify the Loki ingestion endpoint is responding (from within the cluster via a node or pod):
   ```
   curl -s http://loki.monitoring.svc.cluster.local:3100/ready
   ```
4. Check Loki distributor metrics in Grafana (Loki dashboard) to confirm whether the drop started at a specific time.
5. If Alloy appears healthy, restart the DaemonSet to force reconnection:
   ```
   kubectl-admin rollout restart daemonset/alloy -n monitoring
   ```

---

## LokiHighErrorRate

**Severity:** warning

More than 10% of Loki HTTP requests are returning 5xx errors, sustained for 10 minutes.

### Triage Steps

1. Check Loki logs for error details:
   ```
   kubectl-homelab logs -n monitoring -l app.kubernetes.io/name=loki --tail=200
   ```
2. Look for storage-related errors (chunk write failures, object store timeouts). Check the Loki PVC usage:
   ```
   kubectl-homelab get pvc -n monitoring
   ```
3. Check Longhorn volume health for the Loki volume in the Longhorn UI or via:
   ```
   kubectl-homelab get volumes -n longhorn-system
   ```
4. Check whether ingestion rate has spiked - a log storm from a misbehaving pod can overwhelm Loki. Inspect recent log volume in Grafana (Loki Operational dashboard).
5. If storage is near capacity, investigate which namespace is producing the most log volume using LogQL in Grafana Explore:
   ```
   sum by (namespace) (rate({job=~".+"} [5m]))
   ```

---

## AlloyNotOnAllNodes

**Severity:** warning

Fewer Alloy DaemonSet pods are running than there are nodes in the cluster. At least one node is not collecting logs.

### Triage Steps

1. Check the DaemonSet desired vs. ready counts:
   ```
   kubectl-homelab get daemonset alloy -n monitoring
   ```
2. Identify which node is missing an Alloy pod:
   ```
   kubectl-homelab get pods -n monitoring -l app.kubernetes.io/name=alloy -o wide
   kubectl-homelab get nodes
   ```
3. Describe the missing pod or check if it is in a crash loop or pending:
   ```
   kubectl-homelab describe pod -n monitoring <alloy-pod-name>
   ```
4. Check for node taints that Alloy's tolerations do not cover:
   ```
   kubectl-homelab describe node <node-name> | grep -A5 Taints
   ```
5. If the pod is `Pending` due to resource pressure, check node allocatable resources:
   ```
   kubectl-homelab describe node <node-name> | grep -A10 Allocated
   ```

---

## AlloyNotSendingLogs

**Severity:** warning

Alloy pods are running but `loki_write_sent_bytes_total` rate is 0 for 15 minutes - no data is being forwarded to Loki.

### Triage Steps

1. Check Alloy pod logs for write errors or Loki connection refusals:
   ```
   kubectl-homelab logs -n monitoring -l app.kubernetes.io/name=alloy --tail=100
   ```
2. Verify the Loki endpoint URL in the Alloy ConfigMap matches the in-cluster Loki service:
   ```
   kubectl-homelab get configmap -n monitoring -l app.kubernetes.io/name=alloy -o yaml
   ```
   The endpoint should resolve to `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`.
3. Confirm Loki is reachable from inside an Alloy pod:
   ```
   kubectl-admin exec -n monitoring <alloy-pod> -- wget -qO- http://loki.monitoring.svc.cluster.local:3100/ready
   ```
4. Check whether LokiDown is also firing - if Loki is down, this alert is a secondary symptom.
5. If the config looks correct and Loki is healthy, restart the Alloy DaemonSet:
   ```
   kubectl-admin rollout restart daemonset/alloy -n monitoring
   ```

---

## AlloyHighMemory

**Severity:** warning

An Alloy pod is using more than 80% of its configured memory limit for 10 minutes. The pod is at risk of OOMKill.

### Triage Steps

1. Identify which pod(s) are high:
   ```
   kubectl-homelab top pods -n monitoring -l app.kubernetes.io/name=alloy
   ```
2. Check if the node the pod runs on is experiencing a log spike (a noisy application logging at high rate):
   ```
   kubectl-homelab logs -n monitoring <alloy-pod> --tail=50
   ```
3. Identify the highest-volume namespaces or pods on that node using Grafana Explore (LogQL):
   ```
   sum by (pod) (rate({node="<node-name>"} [5m]))
   ```
4. If a specific pod is flooding logs, consider applying a log rate limit or fixing the application.
5. If memory usage is consistently high across all Alloy pods, increase the memory limit in the Alloy values/manifest and apply:
   ```
   kubectl-admin rollout restart daemonset/alloy -n monitoring
   ```
6. Check current resource limits:
   ```
   kubectl-homelab get daemonset alloy -n monitoring -o jsonpath='{.spec.template.spec.containers[0].resources}'
   ```
