# Phase 3.5-3.8: Gateway API, Monitoring, Logging, UPS

> **Status:** Phase 3.5-3.7 ✅ Complete | Phase 3.8 🔄 Next
> **Target:** v0.4.0 (Gateway + Monitoring), v0.5.0 (UPS)
> **CKA Topics:** Gateway API, TLS termination, DaemonSets, ServiceMonitors, StatefulSets

---

## 3.5 Gateway API & HTTPS Access ✅

> **Why Gateway API?** Ingress is deprecated (NGINX Ingress EOL March 2026).
> Gateway API is the Kubernetes-native successor with better role separation.
> Cilium (already installed) has native Gateway API support.
>
> **CKA Topics:** Gateway API, TLS termination, Service routing

**Current Cilium Status:**
- Cilium v1.18.6 installed ✅
- `gatewayAPI.enabled`: true ✅
- `kubeProxyReplacement`: true ✅
- Gateway API CRDs v1.4.1: Installed ✅
- cert-manager v1.19.2: Installed ✅
- kube-proxy: Removed ✅ (Cilium eBPF handles services)

### 3.5.1 Install Gateway API CRDs

- [x] 3.5.1.1 Install standard Gateway API CRDs
  ```bash
  # Use --server-side to avoid "annotations too long" error with large CRDs
  kubectl-homelab apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
  ```

- [x] 3.5.1.2 Install experimental TLSRoute CRD (optional)
  ```bash
  kubectl-homelab apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
  ```

- [x] 3.5.1.3 Verify CRDs installed
  ```bash
  kubectl-homelab get crd | grep gateway
  # Should see: gatewayclasses, gateways, httproutes, etc.
  ```

### 3.5.2 Enable Cilium Gateway API

- [x] 3.5.2.1 Update Cilium Helm values file
  ```bash
  # Create/update helm/cilium/values.yaml with Gateway API enabled
  cat helm/cilium/values.yaml
  ```

- [x] 3.5.2.2 Upgrade Cilium with Gateway API
  ```bash
  helm-homelab upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version 1.18.6 \
    --values helm/cilium/values.yaml
  ```

- [x] 3.5.2.3 Restart Cilium components
  ```bash
  kubectl-homelab -n kube-system rollout restart deployment/cilium-operator
  kubectl-homelab -n kube-system rollout restart ds/cilium
  ```

- [x] 3.5.2.4 Verify GatewayClass exists
  ```bash
  kubectl-homelab get gatewayclass
  # Should see: cilium
  ```

### 3.5.3 Install cert-manager for HTTPS

> **Note:** cert-manager now recommends OCI registry over Helm repo.
> No `helm repo add` needed.

- [x] 3.5.3.1 Install cert-manager with Gateway API support (OCI)
  ```bash
  # OCI registry is the recommended installation method
  helm-homelab install cert-manager oci://quay.io/jetstack/charts/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.19.2 \
    --set crds.enabled=true \
    --set config.enableGatewayAPI=true
  ```

- [x] 3.5.3.2 Verify cert-manager pods running
  ```bash
  kubectl-homelab -n cert-manager get pods
  ```

- [x] 3.5.3.3 Create Cloudflare API token secret
  ```bash
  # Store token in 1Password first, then create secret
  kubectl-homelab create secret generic cloudflare-api-token \
    --namespace cert-manager \
    --from-literal=api-token="$(op read 'op://Kubernetes/Cloudflare DNS API Token/credential')"
  ```

- [x] 3.5.3.4 Create ClusterIssuer (Let's Encrypt + Cloudflare DNS-01)
  ```bash
  kubectl-homelab apply -f manifests/cert-manager/cluster-issuer.yaml
  # Creates letsencrypt-prod and letsencrypt-staging issuers
  ```

### 3.5.4 Create Homelab Gateway

- [x] 3.5.4.1 Configure DNS rewrites in BOTH AdGuard instances
  ```
  # Add wildcard rewrite in each AdGuard Home UI:
  #   Domain: *.k8s.home.rommelporras.com
  #   Answer: 10.10.30.20 (Gateway LoadBalancer IP)
  #
  # Instances to configure:
  #   - K8s AdGuard (10.10.30.53) - primary after Phase 4
  #   - AGH LXC on FW Node (10.10.30.54) - permanent failover
  #
  # Keep both in sync manually (or use config export/import)
  ```

- [x] 3.5.4.2 Create Gateway resource
  ```bash
  kubectl-homelab apply -f manifests/gateway/homelab-gateway.yaml
  ```

- [x] 3.5.4.3 Verify Gateway has LoadBalancer IP
  ```bash
  kubectl-homelab get gateway -A
  # Should show ADDRESS: 10.10.30.20
  ```

- [x] 3.5.4.4 Test with simple HTTPRoute
  ```bash
  # Create test HTTPRoute pointing to any service
  # Verify HTTPS access works
  ```

### 3.5.5 Cleanup kube-proxy (Post-Verification) ✅

> **Why?** With `kubeProxyReplacement: true`, Cilium handles all service load balancing.
> kube-proxy is now redundant and can be safely removed after verifying Gateway works.
>
> **Docs:** https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/

- [x] 3.5.5.1 Verify services work with Cilium
  ```bash
  # Verify Cilium is handling all services
  kubectl-homelab -n kube-system exec ds/cilium -- cilium-dbg service list

  # Verify Gateway routing works
  kubectl-homelab get gateway homelab-gateway
  ```

- [x] 3.5.5.2 Delete kube-proxy DaemonSet
  ```bash
  kubectl-homelab -n kube-system delete ds kube-proxy
  kubectl-homelab -n kube-system delete cm kube-proxy
  ```

- [x] 3.5.5.3 Clean iptables rules on each node
  ```bash
  # SSH to each node and remove KUBE-* iptables chains
  for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    ssh wawashi@${node}.home.rommelporras.com \
      'sudo iptables-save | grep -v KUBE | sudo iptables-restore'
  done

  # Verify no KUBE-SVC rules remain
  ssh wawashi@k8s-cp1.home.rommelporras.com 'sudo iptables-save | grep KUBE-SVC'
  # Should return empty
  ```

- [x] 3.5.5.4 Verify cluster remains healthy
  ```bash
  kubectl-homelab get nodes
  kubectl-homelab get pods -A | grep -v Running
  ```

### 3.5.6 Documentation Updates

- [x] 3.5.6.1 Update VERSIONS.md
  - Change component status from "Planned" to "Installed"
  - Add version history entry

- [x] 3.5.6.2 Update docs/reference/CHANGELOG.md
  - Add phase section with milestone, decisions, lessons learned

---

## 3.6 Install Monitoring Stack ✅

> **CKA Topics:** DaemonSets, ServiceMonitors, StatefulSets, Resource Metrics
>
> **Access:** https://grafana.k8s.home.rommelporras.com (via Gateway API)
>
> **Note:** kube-prometheus-stack uses OCI registry (recommended by upstream).
> No `helm repo add` needed.
>
> **Docs:** https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack

- [x] 3.6.1 Create monitoring namespace with Pod Security
  ```bash
  kubectl-homelab create namespace monitoring
  kubectl-homelab label namespace monitoring pod-security.kubernetes.io/enforce=privileged
  # Note: Changed to privileged for node-exporter (requires hostNetwork/hostPID/hostPath)
  ```

- [x] 3.6.2 Create Helm values file
  ```bash
  # See helm/prometheus/values.yaml for:
  #   - 90-day retention, 50Gi storage
  #   - Resource limits for 16GB nodes
  #   - Grafana password from 1Password
  cat helm/prometheus/values.yaml
  ```

- [x] 3.6.3 Install kube-prometheus-stack (OCI)
  ```bash
  # OCI registry is the recommended installation method
  helm-homelab install prometheus oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    --namespace monitoring \
    --version 81.0.0 \
    --values helm/prometheus/values.yaml \
    --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"
  ```

- [x] 3.6.4 Verify all pods running
  ```bash
  kubectl-homelab -n monitoring get pods
  # Wait for all pods to be Running (2-3 minutes)
  ```

- [x] 3.6.5 Create HTTPRoute for Grafana
  ```bash
  kubectl-homelab apply -f manifests/monitoring/grafana-httproute.yaml
  ```

- [x] 3.6.6 Access Grafana via HTTPS
  ```
  https://grafana.k8s.home.rommelporras.com
  Login: admin / (from 1Password)
  ```

- [x] 3.6.7 Verify node metrics visible
  - Check "Node Exporter / Nodes" dashboard
  - Verify all 3 nodes appear with metrics

### 3.6.8 Documentation Updates

- [x] 3.6.8.1 Update VERSIONS.md
  - Change kube-prometheus-stack status to "Installed"
  - Add version history entry

- [x] 3.6.8.2 Update docs/reference/CHANGELOG.md
  - Add Phase 3.6 section with milestone, decisions, lessons learned

---

## 3.7 Install Logging Stack (Loki + Alloy) ✅

> **IMPORTANT:** Promtail is deprecated (EOL March 2026). Use Grafana Alloy instead.
>
> **Components:**
> - Loki: Log storage (like Prometheus for logs)
> - Grafana Alloy: Log collector (replaces Promtail)
>
> **CKA Topics:** DaemonSets, Log aggregation
>
> **Note:** Loki supports OCI (`oci://ghcr.io/grafana/helm-charts/loki`).
> Alloy does NOT support OCI yet (403 denied) - uses traditional Helm repo.
>
> **Docs:**
> - Loki: https://grafana.com/docs/loki/latest/setup/install/helm/
> - Alloy: https://grafana.com/docs/alloy/latest/set-up/install/kubernetes/

- [x] 3.7.1 Add Grafana Helm repo
  ```bash
  # Required for Alloy (Loki uses OCI, Alloy doesn't support it yet)
  helm-homelab repo add grafana https://grafana.github.io/helm-charts
  helm-homelab repo update
  ```

- [x] 3.7.2 Create Helm values for Loki
  ```bash
  # See helm/loki/values.yaml for:
  #   - deploymentMode: SingleBinary (suitable for homelab <20GB/day)
  #   - 10Gi storage, 90-day retention
  #   - Filesystem backend with Longhorn PVC
  cat helm/loki/values.yaml
  ```

- [x] 3.7.3 Install Loki (OCI)
  ```bash
  # Loki supports OCI registry
  helm-homelab install loki oci://ghcr.io/grafana/helm-charts/loki \
    --namespace monitoring \
    --version 6.49.0 \
    --values helm/loki/values.yaml
  ```

- [x] 3.7.4 Create Helm values for Alloy
  ```bash
  # See helm/alloy/values.yaml for:
  #   - Log collection from all pods via K8s API
  #   - Kubernetes events collection (only from k8s-cp1)
  #   - 256Mi memory limit for events handling
  cat helm/alloy/values.yaml
  ```

- [x] 3.7.5 Install Grafana Alloy
  ```bash
  # Alloy replaces Promtail (EOL March 2026)
  # Does NOT support OCI - uses traditional repo
  helm-homelab install alloy grafana/alloy \
    --namespace monitoring \
    --version 1.5.2 \
    --values helm/alloy/values.yaml
  ```

- [x] 3.7.6 Verify Alloy DaemonSet running (one pod per node)
  ```bash
  kubectl-homelab -n monitoring get ds
  # Should see alloy with 3/3 ready
  ```

- [x] 3.7.7 Verify Loki data source in Grafana
  - Grafana → Connections → Data Sources
  - Loki auto-configured via ConfigMap (manifests/monitoring/loki-datasource.yaml)

- [x] 3.7.8 Verify logs in Grafana Explore
  - Go to Explore → Select Loki
  - Query: `{namespace="monitoring"}`
  - Query: `{source="kubernetes_events"}` (K8s events)
  - Should see logs from monitoring pods

- [x] 3.7.9 Create ServiceMonitors for Loki and Alloy
  ```bash
  kubectl-homelab apply -f manifests/monitoring/loki-servicemonitor.yaml
  kubectl-homelab apply -f manifests/monitoring/alloy-servicemonitor.yaml
  ```

- [x] 3.7.10 Create PrometheusRule for logging alerts
  ```bash
  kubectl-homelab apply -f manifests/monitoring/logging-alerts.yaml
  # 7 alerts: LokiDown, LokiIngestionStopped, LokiHighErrorRate, LokiStorageLow,
  #           AlloyNotOnAllNodes, AlloyNotSendingLogs, AlloyHighMemory
  ```

### 3.7.11 Documentation Updates

- [x] 3.7.11.1 Update VERSIONS.md
  - Change Loki and Alloy status to "Installed"
  - Add version history entry

- [x] 3.7.11.2 Update docs/reference/CHANGELOG.md
  - Add Phase 3.7 section with milestone, decisions, lessons learned

---

## 3.8 UPS Monitoring (NUT)

> **Purpose:** Graceful cluster shutdown during power outage + historical UPS metrics
> **Prerequisite:** Move USB cable from Proxmox to k8s-cp1
> **Current:** PeaNUT + NUT on Proxmox → Migrate to K8s cluster
>
> **Why Grafana over PeaNUT?**
> - PeaNUT has NO data persistence (resets on page refresh)
> - Grafana + Prometheus stores 90 days of historical data
> - Alerting via Alertmanager (email/Discord on power events)
> - Correlate UPS events with cluster metrics
>
> **Docs:**
> - NUT: https://networkupstools.org/docs/user-manual.chunked/
> - nut_exporter: https://github.com/DRuggeri/nut_exporter

**Architecture:**
```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server + Master)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3        K8s Cluster
        (upssched)      (upssched)     ┌─────────────────┐
        2min → shutdown 5min → shutdown│  nut-exporter   │
                                       │  (Deployment)   │
                                       └────────┬────────┘
                                                │ :9995
                                       ┌────────▼────────┐
                                       │   Prometheus    │
                                       │ (ServiceMonitor)│
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │    Grafana      │
                                       │  (Dashboard)    │
                                       └────────┬────────┘
                                                │
                                       ┌────────▼────────┐
                                       │  Alertmanager   │
                                       │(PrometheusRule) │
                                       └─────────────────┘
```

**Staggered Shutdown Strategy (Time-Based - Recommended):**

> **Why time-based?** NUT's upsmon does NOT natively support per-client battery
> percentage thresholds. Using `upssched` timers is simpler and more reliable.
> Battery percentage requires custom scripts polling `battery.charge`.

| Node | Shutdown Trigger | Reason |
|------|------------------|--------|
| k8s-cp3 | 2 minutes on battery | Reduce load early, maintain quorum |
| k8s-cp2 | 5 minutes on battery | Maintain quorum with 2 nodes |
| k8s-cp1 | Low Battery (LB) event | Last node, triggers UPS power-off |

**Alternative: Battery Percentage (Complex)**

If you prefer percentage-based shutdown, see 3.8.2.4 for custom script approach.
This requires polling `battery.charge` and comparing against thresholds.

### 3.8.1 Install NUT Server on k8s-cp1 (bare metal)

> **Why bare metal?** NUT must run outside K8s to shutdown the node itself

- [ ] 3.8.1.1 Connect CyberPower USB to k8s-cp1
  - Physically move USB from Proxmox to k8s-cp1

- [ ] 3.8.1.2 Install NUT packages
  ```bash
  ssh wawashi@k8s-cp1.home.rommelporras.com "sudo apt install nut nut-server nut-client -y"
  ```

- [ ] 3.8.1.3 Configure UPS driver (/etc/nut/ups.conf)
  ```ini
  [cyberpower]
    driver = usbhid-ups
    port = auto
    desc = "CyberPower UPS"
  ```

- [ ] 3.8.1.4 Configure NUT mode (/etc/nut/nut.conf)
  ```ini
  MODE=netserver
  ```

- [ ] 3.8.1.5 Configure upsd (/etc/nut/upsd.conf)
  ```ini
  LISTEN 0.0.0.0 3493
  ```

- [ ] 3.8.1.6 Create NUT credentials in 1Password
  ```bash
  # Create two items in 1Password Kubernetes vault:
  #   - "NUT Admin" with password field (for master upsmon)
  #   - "NUT Monitor" with password field (for slaves and exporter)
  #
  # Verify they exist:
  op read "op://Kubernetes/NUT Admin/password" >/dev/null && echo "NUT Admin OK"
  op read "op://Kubernetes/NUT Monitor/password" >/dev/null && echo "NUT Monitor OK"
  ```

- [ ] 3.8.1.7 Configure upsd users (/etc/nut/upsd.users)
  ```bash
  # Generate config with 1Password values
  sudo tee /etc/nut/upsd.users > /dev/null <<EOF
  [admin]
    password = $(op read "op://Kubernetes/NUT Admin/password")
    actions = SET
    instcmds = ALL
    upsmon master

  [monitor]
    password = $(op read "op://Kubernetes/NUT Monitor/password")
    upsmon slave
  EOF
  sudo chmod 640 /etc/nut/upsd.users
  sudo chown root:nut /etc/nut/upsd.users
  ```

- [ ] 3.8.1.8 Configure upsmon for cp1 (/etc/nut/upsmon.conf)
  ```bash
  # cp1 is the master - shuts down on Low Battery (LB) event
  sudo tee /etc/nut/upsmon.conf > /dev/null <<EOF
  MONITOR cyberpower@localhost 1 admin $(op read "op://Kubernetes/NUT Admin/password") master
  SHUTDOWNCMD "/sbin/shutdown -h +0"
  POWERDOWNFLAG /etc/killpower
  MINSUPPLIES 1
  POLLFREQ 5
  POLLFREQALERT 2
  FINALDELAY 5
  EOF
  sudo chmod 640 /etc/nut/upsmon.conf
  sudo chown root:nut /etc/nut/upsmon.conf
  ```

- [ ] 3.8.1.9 Start and enable NUT services
  ```bash
  sudo systemctl enable --now nut-server nut-monitor
  sudo systemctl status nut-server nut-monitor
  ```

- [ ] 3.8.1.10 Verify UPS is detected
  ```bash
  upsc cyberpower@localhost
  # Should show battery.charge, ups.status, etc.
  ```

### 3.8.2 Install NUT Clients on cp2, cp3 (bare metal)

> **Time-based shutdown:** cp3 shuts down after 2 min on battery, cp2 after 5 min.
> This uses `upssched` timers which are native to NUT (no custom scripts needed).

- [ ] 3.8.2.1 Install nut-client on cp2 and cp3
  ```bash
  for node in k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "sudo apt install nut-client -y"
  done
  ```

- [ ] 3.8.2.2 Configure NUT mode on clients (/etc/nut/nut.conf)
  ```bash
  for node in k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "echo 'MODE=netclient' | sudo tee /etc/nut/nut.conf"
  done
  ```

- [ ] 3.8.2.3 Configure upsmon on cp3 (shutdown after 2 minutes)
  ```bash
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo tee /etc/nut/upsmon.conf > /dev/null" <<EOF
  MONITOR cyberpower@10.10.30.11 1 monitor $(op read "op://Kubernetes/NUT Monitor/password") slave
  MINSUPPLIES 1
  POLLFREQ 5
  POLLFREQALERT 2
  SHUTDOWNCMD "/sbin/shutdown -h +0"
  # Use upssched for timed shutdown
  NOTIFYCMD /usr/sbin/upssched
  NOTIFYFLAG ONLINE SYSLOG+EXEC
  NOTIFYFLAG ONBATT SYSLOG+EXEC
  NOTIFYFLAG LOWBATT SYSLOG+EXEC
  NOTIFYFLAG FSD SYSLOG+EXEC
  EOF
  ```

- [ ] 3.8.2.4 Configure upssched on cp3 (2-minute timer)
  ```bash
  # upssched.conf - starts timer on battery, cancels on power restore
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo tee /etc/nut/upssched.conf > /dev/null" <<EOF
  CMDSCRIPT /usr/local/bin/upssched-cmd
  PIPEFN /run/nut/upssched.pipe
  LOCKFN /run/nut/upssched.lock

  # cp3 shuts down after 2 minutes on battery (earliest)
  AT ONBATT * START-TIMER early-shutdown 120
  AT ONLINE * CANCEL-TIMER early-shutdown
  AT LOWBATT * EXECUTE forced-shutdown
  AT FSD * EXECUTE forced-shutdown
  EOF

  # Create the command script
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo tee /usr/local/bin/upssched-cmd > /dev/null" <<'EOF'
  #!/bin/bash
  case $1 in
    early-shutdown)
      logger -t upssched "UPS on battery for 2 minutes, initiating early shutdown (cp3)"
      /sbin/shutdown -h +0
      ;;
    forced-shutdown)
      logger -t upssched "UPS low battery or FSD, forcing immediate shutdown"
      /sbin/shutdown -h +0
      ;;
    *)
      logger -t upssched "Unknown command: $1"
      ;;
  esac
  EOF
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo chmod +x /usr/local/bin/upssched-cmd"
  ```

- [ ] 3.8.2.5 Configure upsmon on cp2 (shutdown after 5 minutes)
  ```bash
  ssh wawashi@k8s-cp2.home.rommelporras.com "sudo tee /etc/nut/upsmon.conf > /dev/null" <<EOF
  MONITOR cyberpower@10.10.30.11 1 monitor $(op read "op://Kubernetes/NUT Monitor/password") slave
  MINSUPPLIES 1
  POLLFREQ 5
  POLLFREQALERT 2
  SHUTDOWNCMD "/sbin/shutdown -h +0"
  NOTIFYCMD /usr/sbin/upssched
  NOTIFYFLAG ONLINE SYSLOG+EXEC
  NOTIFYFLAG ONBATT SYSLOG+EXEC
  NOTIFYFLAG LOWBATT SYSLOG+EXEC
  NOTIFYFLAG FSD SYSLOG+EXEC
  EOF
  ```

- [ ] 3.8.2.6 Configure upssched on cp2 (5-minute timer)
  ```bash
  ssh wawashi@k8s-cp2.home.rommelporras.com "sudo tee /etc/nut/upssched.conf > /dev/null" <<EOF
  CMDSCRIPT /usr/local/bin/upssched-cmd
  PIPEFN /run/nut/upssched.pipe
  LOCKFN /run/nut/upssched.lock

  # cp2 shuts down after 5 minutes on battery (middle)
  AT ONBATT * START-TIMER early-shutdown 300
  AT ONLINE * CANCEL-TIMER early-shutdown
  AT LOWBATT * EXECUTE forced-shutdown
  AT FSD * EXECUTE forced-shutdown
  EOF

  # Create the command script (same as cp3)
  ssh wawashi@k8s-cp2.home.rommelporras.com "sudo tee /usr/local/bin/upssched-cmd > /dev/null" <<'EOF'
  #!/bin/bash
  case $1 in
    early-shutdown)
      logger -t upssched "UPS on battery for 5 minutes, initiating early shutdown (cp2)"
      /sbin/shutdown -h +0
      ;;
    forced-shutdown)
      logger -t upssched "UPS low battery or FSD, forcing immediate shutdown"
      /sbin/shutdown -h +0
      ;;
    *)
      logger -t upssched "Unknown command: $1"
      ;;
  esac
  EOF
  ssh wawashi@k8s-cp2.home.rommelporras.com "sudo chmod +x /usr/local/bin/upssched-cmd"
  ```

- [ ] 3.8.2.7 Start and enable nut-monitor on clients
  ```bash
  for node in k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "sudo systemctl enable --now nut-monitor"
  done
  ```

- [ ] 3.8.2.8 Verify clients can reach server
  ```bash
  ssh wawashi@k8s-cp2.home.rommelporras.com "upsc cyberpower@10.10.30.11"
  ssh wawashi@k8s-cp3.home.rommelporras.com "upsc cyberpower@10.10.30.11"
  ```

#### Alternative: Battery Percentage Shutdown (Complex)

> **Only use this if time-based doesn't meet your needs.**
> Requires custom script that polls `battery.charge` periodically.

<details>
<summary>Click to expand battery percentage approach</summary>

```bash
# /usr/local/bin/nut-battery-check.sh
# Run via upssched every 60 seconds while on battery

#!/bin/bash
THRESHOLD=${1:-50}  # Default 50%, pass as argument
UPS="cyberpower@10.10.30.11"

CHARGE=$(upsc $UPS battery.charge 2>/dev/null)
if [[ -z "$CHARGE" ]]; then
  logger -t nut-battery-check "Failed to get battery charge"
  exit 1
fi

if (( CHARGE <= THRESHOLD )); then
  logger -t nut-battery-check "Battery at ${CHARGE}%, below ${THRESHOLD}% threshold. Shutting down."
  /sbin/shutdown -h +0
else
  logger -t nut-battery-check "Battery at ${CHARGE}%, above ${THRESHOLD}% threshold. OK."
fi
```

Then in upssched.conf:
```
AT ONBATT * START-TIMER battery-check 60
AT ONLINE * CANCEL-TIMER battery-check
```

And upssched-cmd:
```bash
battery-check)
  /usr/local/bin/nut-battery-check.sh 50  # Threshold for this node
  # Re-arm the timer to check again in 60 seconds
  ;;
```

</details>

### 3.8.3 Configure Kubelet Graceful Shutdown

> **Purpose:** K8s evicts pods gracefully before node powers off

- [ ] 3.8.3.1 Edit kubelet config on ALL nodes
  ```bash
  # Add to /var/lib/kubelet/config.yaml on each node:
  shutdownGracePeriod: 120s
  shutdownGracePeriodCriticalPods: 30s
  ```

- [ ] 3.8.3.2 Restart kubelet on all nodes
  ```bash
  for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "sudo systemctl restart kubelet"
  done
  ```

- [ ] 3.8.3.3 Verify kubelet picked up the config
  ```bash
  ssh wawashi@k8s-cp1.home.rommelporras.com "sudo cat /var/lib/kubelet/config.yaml | grep -A1 shutdown"
  ```

### 3.8.4 Deploy NUT Exporter for Grafana

> **Purpose:** UPS metrics in Prometheus/Grafana dashboards
>
> **Why DRuggeri/nut_exporter?**
> - Actively maintained (v3.2.3, Dec 2025)
> - Has official Helm chart
> - Better multi-UPS support
> - TLS and basic auth support
>
> **Alternative (hon95/prometheus-nut-exporter):** Last updated Aug 2024, no Helm chart.
>
> **Docs:** https://github.com/DRuggeri/nut_exporter

- [ ] 3.8.4.1 Create K8s secret for NUT credentials
  ```bash
  # Create secret from 1Password (for nut-exporter pod)
  kubectl-homelab create secret generic nut-credentials \
    --namespace monitoring \
    --from-literal=username=monitor \
    --from-literal=password="$(op read 'op://Kubernetes/NUT Monitor/password')"
  ```

- [ ] 3.8.4.2 Create Helm values file (helm/nut-exporter/values.yaml)
  ```yaml
  # DRuggeri/nut_exporter Helm values
  # Docs: https://github.com/DRuggeri/nut_exporter
  #
  # Install:
  #   helm repo add nut-exporter https://druggeri.github.io/nut_exporter
  #   helm-homelab install nut-exporter nut-exporter/nut-exporter \
  #     --namespace monitoring \
  #     --values helm/nut-exporter/values.yaml

  # NUT server connection
  nut:
    server: "10.10.30.11"
    # Credentials from K8s secret
    existingSecret: nut-credentials
    usernameKey: username
    passwordKey: password

  # Resource limits for homelab
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      cpu: 50m
      memory: 64Mi

  # ServiceMonitor for Prometheus (kube-prometheus-stack)
  serviceMonitor:
    enabled: true
    interval: 30s
    labels:
      release: prometheus  # Match kube-prometheus-stack selector
  ```

- [ ] 3.8.4.3 Install nut-exporter via Helm
  ```bash
  # Add Helm repo
  helm-homelab repo add nut-exporter https://druggeri.github.io/nut_exporter
  helm-homelab repo update

  # Install
  helm-homelab install nut-exporter nut-exporter/nut-exporter \
    --namespace monitoring \
    --values helm/nut-exporter/values.yaml
  ```

- [ ] 3.8.4.4 Verify nut-exporter is running
  ```bash
  kubectl-homelab -n monitoring get pods -l app.kubernetes.io/name=nut-exporter
  # Should be Running

  # Test metrics endpoint
  kubectl-homelab -n monitoring port-forward svc/nut-exporter 9995:9995 &
  curl -s http://localhost:9995/metrics | grep nut_
  kill %1
  ```

- [ ] 3.8.4.5 Verify Prometheus is scraping
  ```bash
  # Check in Prometheus UI or via API
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/targets' | jq '.data.activeTargets[] | select(.labels.job | contains("nut"))'
  kill %1
  ```

- [ ] 3.8.4.6 Import Grafana dashboard for NUT
  ```
  # Dashboard for DRuggeri/nut_exporter
  Dashboard ID: 19308
  Name: "Prometheus NUT Exporter for DRuggeri"

  # Steps:
  # 1. Grafana → Dashboards → Import
  # 2. Enter ID: 19308
  # 3. Select Prometheus data source
  # 4. Import

  # Verify metrics visible:
  #   - Battery Charge %
  #   - Battery Runtime (seconds)
  #   - Input/Output Voltage
  #   - UPS Load %
  #   - UPS Status (Online/On Battery)
  ```

### 3.8.5 Create PrometheusRule for UPS Alerts

> **Purpose:** Alert on power events via Alertmanager

- [ ] 3.8.5.1 Create UPS alerting rules (manifests/monitoring/ups-alerts.yaml)
  ```yaml
  # PrometheusRule for UPS Alerts
  # Alert on power outage, low battery, high load
  #
  # Apply:
  #   kubectl-homelab apply -f manifests/monitoring/ups-alerts.yaml
  ---
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: ups-alerts
    namespace: monitoring
    labels:
      release: prometheus
      app.kubernetes.io/part-of: kube-prometheus-stack
  spec:
    groups:
      - name: ups
        rules:
          # Alert when UPS switches to battery power
          - alert: UPSOnBattery
            expr: nut_status{status="OB"} == 1
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "UPS is running on battery power"
              description: "UPS {{ $labels.ups }} has been on battery for more than 1 minute. Check power supply."

          # Alert when UPS battery is low (<30%)
          - alert: UPSLowBattery
            expr: nut_battery_charge < 30
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "UPS battery is critically low"
              description: "UPS {{ $labels.ups }} battery is at {{ $value }}%. Nodes will begin shutting down."

          # Alert when UPS battery is getting low (<50%)
          - alert: UPSBatteryWarning
            expr: nut_battery_charge < 50 and nut_battery_charge >= 30
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "UPS battery is below 50%"
              description: "UPS {{ $labels.ups }} battery is at {{ $value }}%. Monitor closely."

          # Alert when UPS load is high (>80%)
          - alert: UPSHighLoad
            expr: nut_load > 80
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "UPS load is high"
              description: "UPS {{ $labels.ups }} is at {{ $value }}% load. Consider reducing connected equipment."

          # Alert when UPS runtime is low (<10 minutes)
          - alert: UPSLowRuntime
            expr: nut_battery_runtime < 600
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "UPS runtime is low"
              description: "UPS {{ $labels.ups }} has only {{ $value | humanizeDuration }} runtime remaining."

          # Alert when UPS is unreachable
          - alert: UPSUnreachable
            expr: up{job=~".*nut.*"} == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Cannot reach UPS exporter"
              description: "NUT exporter has been unreachable for 2 minutes. Check nut-exporter pod and NUT server."

          # Alert when UPS returns to line power (informational)
          - alert: UPSBackOnline
            expr: nut_status{status="OL"} == 1 and changes(nut_status{status="OL"}[5m]) > 0
            for: 0m
            labels:
              severity: info
            annotations:
              summary: "UPS is back on line power"
              description: "UPS {{ $labels.ups }} has returned to line power."
  ```

- [ ] 3.8.5.2 Apply the PrometheusRule
  ```bash
  kubectl-homelab apply -f manifests/monitoring/ups-alerts.yaml
  ```

- [ ] 3.8.5.3 Verify rule is loaded in Prometheus
  ```bash
  # Check via Prometheus API
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/rules' | jq '.data.groups[] | select(.name == "ups")'
  kill %1
  ```

### 3.8.6 Update Proxmox (Optional)

> If Proxmox still needs UPS protection after migration

- [ ] 3.8.6.1 Configure Proxmox as NUT client
  ```bash
  # On Proxmox host, edit /etc/nut/upsmon.conf:
  MONITOR cyberpower@10.10.30.11 1 monitor <password> slave

  # Or via Datacenter → Options → UPS if using built-in NUT
  ```

### 3.8.7 Test Shutdown Sequence

> **IMPORTANT:** Test during maintenance window
>
> **Expected sequence (time-based):**
> 1. Power lost → All nodes detect ONBATT
> 2. +2 minutes → cp3 shuts down (upssched timer fires)
> 3. +5 minutes → cp2 shuts down (upssched timer fires)
> 4. Low battery → cp1 shuts down (LB event from UPS)
> 5. cp1 sends UPS power-off command

- [ ] 3.8.7.1 Verify current UPS status
  ```bash
  upsc cyberpower@10.10.30.11
  # Note current battery.charge and battery.runtime
  ```

- [ ] 3.8.7.2 Verify all clients can communicate
  ```bash
  for node in k8s-cp1 k8s-cp2 k8s-cp3; do
    echo "=== $node ==="
    ssh wawashi@$node.home.rommelporras.com "upsc cyberpower@10.10.30.11 battery.charge"
  done
  ```

- [ ] 3.8.7.3 Test upssched timers (without actual shutdown)
  ```bash
  # On cp3, temporarily change upssched-cmd to just log (not shutdown)
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo sed -i 's|/sbin/shutdown|echo WOULD_SHUTDOWN #|g' /usr/local/bin/upssched-cmd"

  # Simulate ONBATT event (run on cp3)
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo upsmon -c notify ONBATT"

  # Wait 2 minutes, check syslog
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo journalctl -t upssched --since '5 minutes ago'"

  # Restore original script
  ssh wawashi@k8s-cp3.home.rommelporras.com "sudo sed -i 's|echo WOULD_SHUTDOWN #||g' /usr/local/bin/upssched-cmd"
  ```

- [ ] 3.8.7.4 Simulate power failure (CAREFUL - full test)
  ```bash
  # ONLY do this when ready for actual shutdown test
  # 1. Unplug UPS from wall power
  # 2. Watch Grafana dashboard for battery drain
  # 3. Watch from workstation:
  kubectl-homelab get nodes -w
  kubectl-homelab get pods -A -w

  # Expected timeline (depends on UPS capacity and load):
  #   0:00 - Power lost, all nodes detect ONBATT
  #   2:00 - cp3 shuts down
  #   5:00 - cp2 shuts down
  #   ~XX:XX - cp1 shuts down when LB event fires
  ```

- [ ] 3.8.7.5 Verify pods evicted gracefully
  ```bash
  # During test, watch for graceful eviction
  # Pods should terminate with SIGTERM, not SIGKILL
  kubectl-homelab get events -A --field-selector reason=Killing -w
  ```

- [ ] 3.8.7.6 Restore power and verify cluster recovers
  ```bash
  # After test, plug UPS back in
  # Wait for nodes to boot (may need manual power-on)

  # Verify cluster health
  kubectl-homelab get nodes
  kubectl-homelab get pods -A | grep -v Running
  kubectl-homelab get cs  # Component status

  # Verify Longhorn volumes recovered
  kubectl-homelab -n longhorn-system get volumes.longhorn.io
  ```

- [ ] 3.8.7.7 Document actual shutdown times
  ```
  # Record for future reference:
  # - UPS model: CyberPower ___
  # - Capacity: ___ VA
  # - Load during test: ___ %
  # - cp3 shutdown: ___ minutes after power loss
  # - cp2 shutdown: ___ minutes after power loss
  # - cp1 shutdown: ___ minutes after power loss (battery at ___%)
  ```

**Rollback:** If issues, reconnect USB to Proxmox and revert NUT config

### 3.8.8 Documentation Updates

- [ ] 3.8.8.1 Update VERSIONS.md
  ```
  # Add to Helm Charts section:
  | nut-exporter | (chart version) | v3.2.3 | Installed | monitoring |

  # Add to Version History:
  | YYYY-MM-DD | Installed: NUT v(version) for UPS monitoring |
  | YYYY-MM-DD | Installed: nut-exporter v3.2.3 (DRuggeri) for Prometheus metrics |
  ```

- [ ] 3.8.8.2 Update docs/reference/CHANGELOG.md
  - Add Phase 3.8 section with:
    - Milestone: NUT + Grafana UPS Monitoring
    - Files added (helm/nut-exporter/values.yaml, manifests/monitoring/ups-alerts.yaml)
    - Key decisions (time-based vs percentage, DRuggeri vs HON95, Grafana vs PeaNUT)
    - Lessons learned
    - Architecture diagram

- [ ] 3.8.8.3 Add NUT items to 1Password
  ```
  # Verify these exist in Kubernetes vault:
  # - "NUT Admin" (master password)
  # - "NUT Monitor" (slave/exporter password)
  ```

---

## Final: Documentation

> **After all phases complete**, create a single rebuild document.

- [ ] Create docs/REBUILD_FROM_SCRATCH.md
  - Single file with step-by-step commands
  - Copy-paste friendly
  - Covers: Ansible playbooks → Gateway API → cert-manager → Monitoring → Logging → UPS
  - Include verification steps after each phase
  - Reference values files and manifests locations

- [ ] Move this file to completed folder
  ```bash
  mkdir -p docs/todo/completed
  mv docs/todo/phase-3.5-3.8-monitoring.md docs/todo/completed/
  ```
