# Phase 3.5-3.8: Gateway API, Monitoring, Logging, UPS

> **Status:** 🔄 Next
> **Target:** v0.4.0 (Gateway + Monitoring), v0.5.0 (UPS)
> **CKA Topics:** Gateway API, TLS termination, DaemonSets, ServiceMonitors, StatefulSets

---

## 3.5 Gateway API & HTTPS Access

> **Why Gateway API?** Ingress is deprecated (NGINX Ingress EOL March 2026).
> Gateway API is the Kubernetes-native successor with better role separation.
> Cilium (already installed) has native Gateway API support.
>
> **CKA Topics:** Gateway API, TLS termination, Service routing

**Current Cilium Status:**
- Cilium v1.18.6 installed ✅
- `gatewayAPI.enabled`: Not set ❌
- `kubeProxyReplacement`: Not set ❌
- Gateway API CRDs: Not installed ❌
- cert-manager: Not installed ❌

### 3.5.1 Install Gateway API CRDs

- [ ] 3.5.1.1 Install standard Gateway API CRDs
  ```bash
  # Use --server-side to avoid "annotations too long" error with large CRDs
  kubectl-homelab apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
  ```

- [ ] 3.5.1.2 Install experimental TLSRoute CRD (optional)
  ```bash
  kubectl-homelab apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
  ```

- [ ] 3.5.1.3 Verify CRDs installed
  ```bash
  kubectl-homelab get crd | grep gateway
  # Should see: gatewayclasses, gateways, httproutes, etc.
  ```

### 3.5.2 Enable Cilium Gateway API

- [ ] 3.5.2.1 Update Cilium Helm values file
  ```bash
  # Create/update helm/cilium/values.yaml with Gateway API enabled
  cat helm/cilium/values.yaml
  ```

- [ ] 3.5.2.2 Upgrade Cilium with Gateway API
  ```bash
  helm-homelab upgrade cilium cilium/cilium \
    --namespace kube-system \
    --version 1.18.6 \
    --values helm/cilium/values.yaml
  ```

- [ ] 3.5.2.3 Restart Cilium components
  ```bash
  kubectl-homelab -n kube-system rollout restart deployment/cilium-operator
  kubectl-homelab -n kube-system rollout restart ds/cilium
  ```

- [ ] 3.5.2.4 Verify GatewayClass exists
  ```bash
  kubectl-homelab get gatewayclass
  # Should see: cilium
  ```

### 3.5.3 Install cert-manager for HTTPS

- [ ] 3.5.3.1 Add Jetstack Helm repo
  ```bash
  helm-homelab repo add jetstack https://charts.jetstack.io
  helm-homelab repo update
  ```

- [ ] 3.5.3.2 Install cert-manager with Gateway API support
  ```bash
  # Simplified syntax since cert-manager 1.16 (no apiVersion/kind needed)
  # v1.17.0 is LTS release (Feb 2025)
  helm-homelab install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version v1.17.0 \
    --set crds.enabled=true \
    --set config.enableGatewayAPI=true
  ```

- [ ] 3.5.3.3 Verify cert-manager pods running
  ```bash
  kubectl-homelab -n cert-manager get pods
  ```

- [ ] 3.5.3.4 Create ClusterIssuer (self-signed for now)
  ```bash
  kubectl-homelab apply -f manifests/cert-manager/cluster-issuer.yaml
  ```

### 3.5.4 Create Homelab Gateway

- [ ] 3.5.4.1 Configure DNS rewrites in BOTH AdGuard instances
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

- [ ] 3.5.4.2 Create Gateway resource
  ```bash
  kubectl-homelab apply -f manifests/gateway/homelab-gateway.yaml
  ```

- [ ] 3.5.4.3 Verify Gateway has LoadBalancer IP
  ```bash
  kubectl-homelab get gateway -A
  # Should show ADDRESS: 10.10.30.20
  ```

- [ ] 3.5.4.4 Test with simple HTTPRoute
  ```bash
  # Create test HTTPRoute pointing to any service
  # Verify HTTPS access works
  ```

---

## 3.6 Install Monitoring Stack

> **CKA Topics:** DaemonSets, ServiceMonitors, StatefulSets, Resource Metrics
>
> **Access:** https://grafana.k8s.home.rommelporras.com (via Gateway API)

- [ ] 3.6.1 Add Prometheus Helm repo
  ```bash
  helm-homelab repo add prometheus-community https://prometheus-community.github.io/helm-charts
  helm-homelab repo update
  ```

- [ ] 3.6.2 Create monitoring namespace with Pod Security
  ```bash
  kubectl-homelab create namespace monitoring
  kubectl-homelab label namespace monitoring pod-security.kubernetes.io/enforce=baseline
  ```

- [ ] 3.6.3 Create Helm values file
  ```bash
  # See helm/prometheus/values.yaml for:
  #   - 90-day retention, 50Gi storage
  #   - Resource limits for 16GB nodes
  #   - Grafana password from 1Password
  cat helm/prometheus/values.yaml
  ```

- [ ] 3.6.4 Install kube-prometheus-stack
  ```bash
  helm-homelab install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --version 81.0.0 \
    --values helm/prometheus/values.yaml \
    --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"
  ```

- [ ] 3.6.5 Verify all pods running
  ```bash
  kubectl-homelab -n monitoring get pods
  # Wait for all pods to be Running (2-3 minutes)
  ```

- [ ] 3.6.6 Create HTTPRoute for Grafana
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/grafana.yaml
  ```

- [ ] 3.6.7 Access Grafana via HTTPS
  ```
  https://grafana.k8s.home.rommelporras.com
  Login: admin / (from 1Password)
  ```

- [ ] 3.6.8 Verify node metrics visible
  - Check "Node Exporter / Nodes" dashboard
  - Verify all 3 nodes appear with metrics

---

## 3.7 Install Logging Stack (Loki + Alloy)

> **IMPORTANT:** Promtail is deprecated (EOL March 2026). Use Grafana Alloy instead.
>
> **Components:**
> - Loki: Log storage (like Prometheus for logs)
> - Grafana Alloy: Log collector (replaces Promtail)
>
> **CKA Topics:** DaemonSets, Log aggregation

- [ ] 3.7.1 Add Grafana Helm repo (if not already added)
  ```bash
  helm-homelab repo add grafana https://grafana.github.io/helm-charts
  helm-homelab repo update
  ```

- [ ] 3.7.2 Create Helm values for Loki
  ```bash
  # See helm/loki/values.yaml for:
  #   - deploymentMode: SingleBinary (suitable for homelab <20GB/day)
  #   - 50Gi storage, 90-day retention
  #   - Memcached enabled by default in 6.x
  cat helm/loki/values.yaml
  ```

- [ ] 3.7.3 Install Loki
  ```bash
  helm-homelab install loki grafana/loki \
    --namespace monitoring \
    --version 6.49.0 \
    --values helm/loki/values.yaml
  ```

- [ ] 3.7.4 Create Helm values for Alloy
  ```bash
  # See helm/alloy/values.yaml for:
  #   - Log collection from all pods
  #   - Kubernetes events collection
  cat helm/alloy/values.yaml
  ```

- [ ] 3.7.5 Install Grafana Alloy
  ```bash
  # Alloy replaces Promtail (EOL March 2026)
  helm-homelab install alloy grafana/alloy \
    --namespace monitoring \
    --version 1.5.2 \
    --values helm/alloy/values.yaml
  ```

- [ ] 3.7.6 Verify Alloy DaemonSet running (one pod per node)
  ```bash
  kubectl-homelab -n monitoring get ds
  # Should see alloy with 3/3 ready
  ```

- [ ] 3.7.7 Verify Loki data source in Grafana
  - Grafana → Connections → Data Sources
  - Loki should be auto-configured (or add manually: http://loki:3100)

- [ ] 3.7.8 Verify logs in Grafana Explore
  - Go to Explore → Select Loki
  - Query: `{namespace="monitoring"}`
  - Should see logs from monitoring pods

---

## 3.8 UPS Monitoring (NUT)

> **Purpose:** Graceful cluster shutdown during power outage
> **Prerequisite:** Move USB cable from Proxmox to k8s-cp1
> **Current:** PeaNUT + NUT on Proxmox → Migrate to K8s cluster

**Architecture:**
```
CyberPower UPS ──USB──► k8s-cp1 (NUT Server)
                              │
                    TCP 3493 (nutserver)
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
          k8s-cp2         k8s-cp3         Grafana
        (NUT client)    (NUT client)    (nut-exporter)
        shutdown@50%    shutdown@75%     dashboards
```

**Staggered Shutdown Strategy:**
| Node | Shutdown At | Reason |
|------|-------------|--------|
| k8s-cp3 | 75% battery | Reduce load, maintain quorum |
| k8s-cp2 | 50% battery | Maintain quorum with 2 nodes |
| k8s-cp1 | 20% battery | Last node, sends UPS power-off |

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

- [ ] 3.8.1.6 Configure upsd users (/etc/nut/upsd.users)
  ```ini
  [admin]
    password = <secure-password>
    actions = SET
    instcmds = ALL
    upsmon master

  [monitor]
    password = <monitor-password>
    upsmon slave
  ```

- [ ] 3.8.1.7 Configure upsmon for cp1 (/etc/nut/upsmon.conf)
  ```ini
  MONITOR cyberpower@localhost 1 admin <password> master
  SHUTDOWNCMD "/sbin/shutdown -h +0"
  POWERDOWNFLAG /etc/killpower
  MINSUPPLIES 1
  POLLFREQ 5
  POLLFREQALERT 2
  FINALDELAY 5
  ```

- [ ] 3.8.1.8 Start and enable NUT services
  ```bash
  sudo systemctl enable --now nut-server nut-monitor
  sudo systemctl status nut-server nut-monitor
  ```

- [ ] 3.8.1.9 Verify UPS is detected
  ```bash
  upsc cyberpower@localhost
  ```

### 3.8.2 Install NUT Clients on cp2, cp3 (bare metal)

- [ ] 3.8.2.1 Install nut-client on cp2 and cp3
  ```bash
  for node in k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "sudo apt install nut-client -y"
  done
  ```

- [ ] 3.8.2.2 Configure NUT mode on clients
  ```bash
  # /etc/nut/nut.conf on cp2 and cp3
  MODE=netclient
  ```

- [ ] 3.8.2.3 Configure upsmon on cp2 (shutdown at 50%)
  ```ini
  # /etc/nut/upsmon.conf on cp2
  MONITOR cyberpower@10.10.30.11 1 monitor <password> slave
  SHUTDOWNCMD "/sbin/shutdown -h +0"
  MINSUPPLIES 1
  POLLFREQ 5
  ```
  > Note: Configure BATTERY threshold in custom script or use upsmon NOTIFYCMD

- [ ] 3.8.2.4 Configure upsmon on cp3 (shutdown at 75%)
  > cp3 shuts down earliest to reduce UPS load

- [ ] 3.8.2.5 Start and enable nut-monitor on clients
  ```bash
  for node in k8s-cp2 k8s-cp3; do
    ssh wawashi@$node.home.rommelporras.com "sudo systemctl enable --now nut-monitor"
  done
  ```

- [ ] 3.8.2.6 Verify clients can reach server
  ```bash
  ssh wawashi@k8s-cp2.home.rommelporras.com "upsc cyberpower@10.10.30.11"
  ```

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

- [ ] 3.8.4.1 Deploy nut-exporter in monitoring namespace
  ```bash
  kubectl-homelab apply -f - <<EOF
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: nut-exporter
    namespace: monitoring
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: nut-exporter
    template:
      metadata:
        labels:
          app: nut-exporter
      spec:
        containers:
        - name: nut-exporter
          image: hon95/prometheus-nut-exporter:1
          env:
          - name: NUT_EXPORTER_SERVER
            value: "10.10.30.11"
          - name: NUT_EXPORTER_USERNAME
            value: "monitor"
          - name: NUT_EXPORTER_PASSWORD
            valueFrom:
              secretKeyRef:
                name: nut-credentials
                key: password
          ports:
          - containerPort: 9199
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: nut-exporter
    namespace: monitoring
    labels:
      app: nut-exporter
  spec:
    ports:
    - port: 9199
    selector:
      app: nut-exporter
  EOF
  ```

- [ ] 3.8.4.2 Create ServiceMonitor for Prometheus
  ```bash
  kubectl-homelab apply -f - <<EOF
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: nut-exporter
    namespace: monitoring
  spec:
    selector:
      matchLabels:
        app: nut-exporter
    endpoints:
    - port: "9199"
      interval: 30s
  EOF
  ```

- [ ] 3.8.4.3 Import Grafana dashboard for NUT
  - Dashboard ID: 14371 (or search "NUT UPS")
  - Verify: Load %, Battery %, Runtime, Input Voltage visible

### 3.8.5 Update Proxmox (Optional)

> If Proxmox still needs UPS protection after migration

- [ ] 3.8.5.1 Configure Proxmox as NUT client
  - Point to k8s-cp1:3493 instead of local USB
  - Datacenter → Options → NUT Server: 10.10.30.11

### 3.8.6 Test Shutdown Sequence

> **IMPORTANT:** Test during maintenance window

- [ ] 3.8.6.1 Verify current UPS status
  ```bash
  upsc cyberpower@10.10.30.11
  ```

- [ ] 3.8.6.2 Simulate power failure (CAREFUL)
  - Unplug UPS from wall power
  - Watch battery drain
  - Verify nodes shutdown in order: cp3 → cp2 → cp1

- [ ] 3.8.6.3 Verify pods evicted gracefully
  ```bash
  # Watch from workstation during test
  kubectl-homelab get pods -A -w
  ```

- [ ] 3.8.6.4 Verify UPS powers off after cp1 shutdown

- [ ] 3.8.6.5 Restore power and verify cluster recovers
  ```bash
  kubectl-homelab get nodes
  kubectl-homelab get pods -A | grep -v Running
  ```

**Rollback:** If issues, reconnect USB to Proxmox and revert NUT config
