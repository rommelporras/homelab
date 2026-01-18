# Phase 4.1-4.4: Stateless Workloads (Quick Wins)

> **Status:** ⬜ Planned
> **Target:** v0.6.0 (February-March 2026)
> **CKA Topics:** Deployments, Services, ConfigMaps, Ingress
> **Namespace:** `home` (shared for stateless home services)

> **Focus:** Low-risk stateless services first. Validates K8s workflow before tackling databases.

---

## 4.1 Create Home Namespace

- [ ] 4.1.1 Create namespace with Pod Security
  ```bash
  kubectl-homelab create namespace home
  kubectl-homelab label namespace home pod-security.kubernetes.io/enforce=baseline
  ```

---

## 4.2 Migrate AdGuard Home (Low Risk)

**Why first:** Simple DNS service, can run dual during transition

> **DNS ARCHITECTURE (Option B - Simple AGH):**
> ```
> ┌─────────────────────────────────────────────────────────┐
> │                    DNS Resolution                       │
> ├─────────────────────────────────────────────────────────┤
> │  K8s AdGuard (10.10.30.53)     ← PRIMARY (this phase)  │
> │  AGH LXC on FW Node (10.10.30.54)  ← PERMANENT FAILOVER│
> └─────────────────────────────────────────────────────────┘
>
> Why keep AGH LXC on FW Node?
> - Same physical host as OPNsense (if FW Node dies, OPNsense dies anyway)
> - Survives K8s cluster issues (etcd problems, CNI failures, etc.)
> - Zero additional complexity (no OPNsense Unbound needed)
>
> What gets retired?
> - AGH LXC on PVE Node (10.10.30.53) → Replaced by K8s AdGuard
> - NPM on PVE Node (10.10.30.80) → Replaced by Gateway API
> ```

> **STORAGE NEEDED:**
> - ConfigMap: Initial config (AdGuardHome.yaml) - version controlled, read-only
> - Longhorn PVC: Runtime data (query logs, downloaded blocklists, client stats)
>
> Without PVC, AdGuard would lose query logs and re-download blocklists on every restart.

- [ ] 4.2.1 Export AdGuard config from Dell 5090
  ```bash
  # SSH to Dell 5090 and copy /opt/AdGuardHome/AdGuardHome.yaml
  scp wawashi@10.10.30.4:/opt/AdGuardHome/AdGuardHome.yaml .
  ```

- [ ] 4.2.2 Create ConfigMap for initial configuration
  ```bash
  # ConfigMap holds the static config (filters, DNS settings, etc.)
  kubectl-homelab create configmap adguard-config \
    --from-file=AdGuardHome.yaml \
    -n home
  ```

- [ ] 4.2.3 Create Longhorn PVC for runtime data
  ```yaml
  # manifests/home/adguard-pvc.yaml
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: adguard-data
    namespace: home
  spec:
    accessModes: [ReadWriteOnce]
    storageClassName: longhorn
    resources:
      requests:
        storage: 5Gi  # Query logs, blocklist cache
  ```

- [ ] 4.2.4 Deploy AdGuard with LoadBalancer (for DNS port 53)
  ```bash
  # Deployment mounts:
  #   - ConfigMap at /opt/adguardhome/conf (initial config)
  #   - PVC at /opt/adguardhome/work (runtime data)
  kubectl-homelab apply -f manifests/home/adguard-deployment.yaml -n home
  kubectl-homelab get svc -n home  # Note the LoadBalancer IP
  ```

- [ ] 4.2.5 Run K8s AdGuard alongside PVE LXC for 1 week
  - PVE AGH LXC (10.10.30.53) remains primary
  - Add K8s AdGuard as secondary DNS in DHCP
  - Keep FW AGH LXC (10.10.30.54) as-is (failover)

- [ ] 4.2.6 Sync DNS rewrites to FW AGH LXC
  - Ensure `*.k8s.home.rommelporras.com → 10.10.30.20` exists in FW AGH
  - This keeps Gateway API working even if K8s cluster has issues

- [ ] 4.2.7 Switch primary to K8s AdGuard
  - Update DHCP: primary DNS = K8s AdGuard LoadBalancer IP
  - FW AGH LXC (10.10.30.54) becomes secondary in DHCP

- [ ] 4.2.8 After 1 week stable, disable PVE AGH LXC only
  - Stop/delete LXC 53 on PVE Node
  - **Keep FW AGH LXC (54) running permanently as failover**

**Rollback:** Re-enable PVE AGH LXC, update DHCP

---

## 4.3 Migrate Homepage Dashboard (Low Risk)

**Why second:** Truly stateless, no runtime data to persist

> **STORAGE APPROACH:**
> - ConfigMap only - Homepage reads config files, doesn't write runtime data
> - No PVC needed - Can run multiple replicas for HA
> - Kubernetes auto-discovery - Homepage can detect services via K8s API (no manual config)
>
> For NAS storage display: Use Glances widget to query OMV's Glances API, not NFS mount.
> Ref: https://gethomepage.dev/widgets/services/glances/

- [ ] 4.3.1 Create Homepage ConfigMap
  ```bash
  # Export config from existing Homepage on Dell 5090
  # Then create ConfigMap with all config files
  kubectl-homelab create configmap homepage-config \
    --from-file=services.yaml \
    --from-file=settings.yaml \
    --from-file=widgets.yaml \
    --from-file=bookmarks.yaml \
    -n home
  ```

- [ ] 4.3.2 Create ServiceAccount for Kubernetes auto-discovery
  ```yaml
  # Homepage can auto-discover K8s services with annotations
  # Needs read access to services, deployments, ingresses
  # See: https://gethomepage.dev/configs/kubernetes/
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: homepage
    namespace: home
  ---
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: homepage
  rules:
    - apiGroups: [""]
      resources: ["namespaces", "pods", "nodes"]
      verbs: ["get", "list"]
    - apiGroups: ["extensions", "networking.k8s.io"]
      resources: ["ingresses"]
      verbs: ["get", "list"]
    - apiGroups: ["traefik.io"]  # If using Traefik
      resources: ["ingressroutes"]
      verbs: ["get", "list"]
  ```

- [ ] 4.3.3 Deploy Homepage Deployment (2 replicas for HA)
  ```bash
  # Mounts ConfigMap at /app/config (read-only)
  # Uses ServiceAccount for K8s discovery
  kubectl-homelab apply -f manifests/home/homepage-deployment.yaml -n home
  ```

- [ ] 4.3.4 Create Service and Ingress
  ```bash
  kubectl-homelab apply -f manifests/home/homepage-service.yaml -n home
  kubectl-homelab apply -f manifests/home/homepage-ingress.yaml -n home
  ```

- [ ] 4.3.5 Configure Glances widget for NAS storage display
  ```yaml
  # In widgets.yaml - query OMV's Glances API for storage info
  # Install Glances on OMV: apt install glances
  # Run: glances -w (web server mode)
  - glances:
      url: http://10.10.30.4:61208
      widget:
        type: info
        chart: false
  ```

- [ ] 4.3.6 Update DNS to point to K8s

- [ ] 4.3.7 Disable Dell 5090 Homepage

---

## 4.4 Verify Phase 4.1-4.4 Complete

- [ ] 4.4.1 All pods running in home namespace
  ```bash
  kubectl-homelab get pods -n home
  ```

- [ ] 4.4.2 K8s AdGuard resolving DNS queries
  ```bash
  # Test from workstation
  dig @<k8s-adguard-lb-ip> google.com
  ```

- [ ] 4.4.3 Homepage accessible via Gateway API (HTTPRoute)
  ```
  https://homepage.k8s.home.rommelporras.com
  ```

- [ ] 4.4.4 Retired services on PVE Node:
  - AGH LXC (53) - **disabled** (replaced by K8s AdGuard)
  - NPM LXC (80) - **disabled** (replaced by Gateway API)

- [ ] 4.4.5 Verify FW AGH LXC (10.10.30.54) still running as failover

---

## Final: Documentation Updates

- [ ] Update VERSIONS.md
  - Add AdGuard Home and Homepage components
  - Add version history entry

- [ ] Update docs/reference/CHANGELOG.md
  - Add Phase 4.1-4.4 section with milestone, decisions, lessons learned

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-4.1-4.4-stateless.md docs/todo/completed/
  ```
