# Phase 4.1-4.4: Stateless Workloads (Quick Wins)

> **Status:** ✅ Completed
> **Completed:** January 22, 2026
> **CKA Topics:** Deployments, Services, ConfigMaps, Secrets, Gateway API (HTTPRoute), Kustomize
> **Namespace:** `home` (shared for stateless home services)

> **Focus:** Low-risk stateless services first. Validates K8s workflow before tackling databases.

---

## Summary of What Was Done

| Component | Version | Status | Notes |
|-----------|---------|--------|-------|
| AdGuard Home | v0.107.71 | ✅ Running | DNS on 10.10.30.55 (PRIMARY for all VLANs) |
| Homepage | v1.9.0 | ✅ Running | 2 replicas, multi-tab layout, all widgets working |
| Metrics Server | v0.8.0 | ✅ Running | Helm chart 3.13.0 |
| Glances on OMV | v3.3.1 | ✅ Running | apt install, password auth |
| Longhorn UI | - | ✅ Exposed | HTTPRoute added for widget access |

---

## 4.1 Create Home Namespace

- [x] 4.1.1 Create namespace with Pod Security
  ```bash
  kubectl-homelab create namespace home
  kubectl-homelab label namespace home \
    pod-security.kubernetes.io/enforce=baseline \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted
  ```

---

## 4.2 Deploy AdGuard Home

### Architecture Decisions

**DNS Setup:**
- K8s AdGuard: 10.10.30.55 (LoadBalancer via Cilium L2)
- FW AGH LXC: 10.10.30.54 (permanent failover)
- Old PVE AGH: 10.10.30.53 (to be retired after testing)

**Storage:** Init container pattern
- ConfigMap → copied to Longhorn PVC on first boot
- Runtime changes preserved in PVC

**Manifests Location:** `manifests/home/adguard/`

### Completed Steps

- [x] 4.2.1 Export and sanitize AdGuard config from Dell 5090
  - Changed HTTP port 80 → 3000 (non-root container)
  - Updated DNS rewrites: `*.home.rommelporras.com` → 10.10.30.20 (Gateway API)

- [x] 4.2.2-4.2.7 Create manifests
  ```
  manifests/home/adguard/
  ├── configmap.yaml      # Full sanitized config
  ├── deployment.yaml     # v0.107.71, init container, security context
  ├── httproute.yaml      # adguard.k8s.home.rommelporras.com
  ├── pvc.yaml            # 5Gi Longhorn storage
  └── service.yaml        # LoadBalancer (DNS) + ClusterIP (HTTP)
  ```

- [x] 4.2.8 Deploy to K8s
  ```bash
  kubectl-homelab apply -f manifests/home/adguard/
  ```

- [x] 4.2.9 Verify DNS resolution
  ```bash
  dig @10.10.30.55 google.com
  dig @10.10.30.55 homepage.k8s.home.rommelporras.com
  ```

### Key Learnings (For Talos Rebuild)

1. **Security Context:** AdGuard needs `NET_BIND_SERVICE` capability but NOT `runAsNonRoot`
   ```yaml
   securityContext:
     allowPrivilegeEscalation: false
     capabilities:
       drop: ["ALL"]
       add: ["NET_BIND_SERVICE"]
   ```

2. **Cilium LB-IPAM:** Ensure IP is within pool range
   ```bash
   kubectl-homelab get ciliumloadbalancerippool -o yaml
   # Current range: 10.10.30.20-99
   ```

3. **HTTPRoute timing:** If 500 errors occur after deployment, delete and recreate HTTPRoute

---

## 4.3 Deploy Homepage Dashboard

### Architecture Decisions

**Storage:** ConfigMap only (stateless)
- Kustomize `configMapGenerator` with hash suffix for automatic rollout
- Secrets managed via 1Password CLI (not committed to git)

**Service Discovery:** Manual config (not K8s auto-discovery)
- Chose manual `services.yaml` for version control
- Set `gateway: false` in kubernetes.yaml

**Manifests Location:** `manifests/home/homepage/`

### 4.3.A Glances on OMV (Prerequisite)

- [x] 4.3.A.1 Install Glances via apt (simpler than pipx on OMV)
  ```bash
  ssh root@10.10.30.4
  apt update && apt install -y glances python3-bottle
  ```

- [x] 4.3.A.2 Create systemd service with password auth
  ```bash
  cat > /etc/systemd/system/glances.service << 'EOF'
  [Unit]
  Description=Glances monitoring web server (authenticated)
  After=network.target

  [Service]
  Type=simple
  ExecStart=/usr/bin/glances -w -B 10.10.30.4 --password
  Restart=on-failure
  RestartSec=5

  [Install]
  WantedBy=multi-user.target
  EOF

  systemctl daemon-reload
  systemctl enable --now glances
  ```

- [x] 4.3.A.3 Set password (interactive prompt on first run)
  ```bash
  systemctl stop glances
  glances -w --password  # Enter password when prompted, Ctrl+C after saved
  systemctl start glances
  ```

- [x] 4.3.A.4 Save password to 1Password
  ```bash
  op item edit Homepage --vault Kubernetes glances-pass="<password>"
  ```

**Key Learning:** Glances v3.x (OMV apt) uses `version: 3` in Homepage widgets, not `version: 4`

### 4.3.B Homepage Manifests

- [x] 4.3.1 Manifests structure (Kustomize)
  ```
  manifests/home/homepage/
  ├── kustomization.yaml    # configMapGenerator for config files
  ├── config/
  │   ├── bookmarks.yaml
  │   ├── custom.css
  │   ├── custom.js
  │   ├── docker.yaml
  │   ├── kubernetes.yaml   # mode: cluster, gateway: false
  │   ├── services.yaml     # {{HOMEPAGE_VAR_XXX}} placeholders
  │   ├── settings.yaml
  │   └── widgets.yaml
  ├── deployment.yaml       # v1.9.0, envFrom secretRef
  ├── httproute.yaml
  ├── rbac.yaml             # Includes metrics.k8s.io access
  ├── secret.yaml           # Template only (not applied)
  └── service.yaml
  ```

- [x] 4.3.2 Create secrets from 1Password (imperative)
  ```bash
  # First, populate 1Password "Homepage" item with all credentials
  # Then create K8s secret:
  kubectl-homelab create secret generic homepage-secrets -n home \
    --from-literal=HOMEPAGE_VAR_PROXMOX_PVE_USER="$(op read 'op://Kubernetes/Homepage/proxmox-pve-user')" \
    --from-literal=HOMEPAGE_VAR_PROXMOX_PVE_TOKEN="$(op read 'op://Kubernetes/Homepage/proxmox-pve-token')" \
    # ... all other fields
  ```

- [x] 4.3.3 Deploy via Kustomize
  ```bash
  kubectl-homelab apply -k manifests/home/homepage/
  ```

- [x] 4.3.4 Verify accessible
  ```bash
  curl -I https://homepage.k8s.home.rommelporras.com
  ```

### Key Learnings (For Talos Rebuild)

1. **Security Context:** Homepage image runs as root, cannot use `runAsNonRoot: true`
   ```yaml
   securityContext:
     # Note: Homepage image runs as root, cannot use runAsNonRoot
     seccompProfile:
       type: RuntimeDefault
   containers:
     - securityContext:
         allowPrivilegeEscalation: false
         capabilities:
           drop: ["ALL"]
   ```

2. **Kustomize secret exclusion:** Remove secret.yaml from kustomization resources
   ```yaml
   resources:
     - rbac.yaml
     # secret.yaml excluded - managed imperatively via 1Password CLI
     - deployment.yaml
   ```

3. **1Password field names:** Use lowercase with hyphens (e.g., `glances-pass` not `GLANCES_PASS`)

4. **Glances NVMe path:** Use full UUID mount path
   ```yaml
   metric: fs:/srv/dev-disk-by-uuid-00ece9b6-d675-4371-82e2-efa6cfd7e589
   ```

5. **Variable substitution limitation:** `{{HOMEPAGE_VAR_*}}` works in services.yaml but NOT in settings.yaml `providers` section. Hardcode API keys in providers if needed.

6. **Longhorn widget requires HTTPRoute:** Must expose Longhorn UI via Gateway API for the info widget to fetch storage data.

---

## 4.3.C Metrics Server (For Homepage K8s Widget)

Homepage's Kubernetes widget requires metrics-server for CPU/memory stats.

- [x] 4.3.C.1 Install via Helm
  ```bash
  helm-homelab repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
  helm-homelab install metrics-server metrics-server/metrics-server \
    --namespace kube-system \
    --version 3.13.0 \
    -f helm/metrics-server/values.yaml
  ```

- [x] 4.3.C.2 Values file (`helm/metrics-server/values.yaml`)
  ```yaml
  args:
    - --kubelet-insecure-tls  # Required for kubeadm clusters
    - --kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname
    - --kubelet-use-node-status-port
    - --metric-resolution=15s
  resources:
    requests:
      cpu: 100m
      memory: 200Mi
  ```

- [x] 4.3.C.3 Verify
  ```bash
  kubectl-homelab top nodes
  kubectl-homelab top pods -n home
  ```

**Key Learning:** `--kubelet-insecure-tls` is acceptable for homelab (traffic within private cluster)

---

## 4.4 Verification Checklist

- [x] 4.4.1 All pods running in home namespace
  ```bash
  kubectl-homelab get pods -n home
  # adguard-home-xxx  1/1 Running
  # homepage-xxx      1/1 Running (x2)
  ```

- [x] 4.4.2 K8s AdGuard resolving DNS
  ```bash
  dig @10.10.30.55 google.com
  ```

- [x] 4.4.3 Homepage accessible with working widgets
  ```bash
  curl -I https://homepage.k8s.home.rommelporras.com
  ```

- [x] 4.4.4 AdGuard web UI accessible
  ```bash
  curl -I https://adguard.k8s.home.rommelporras.com
  ```

- [x] 4.4.5 Metrics server providing cluster stats
  ```bash
  kubectl-homelab top nodes
  ```

---

## DNS Cutover (Completed January 22, 2026)

- [x] 4.2.9 Update DHCP to use K8s AdGuard (10.10.30.55) as primary
  - Updated OPNsense DHCPv4 for: GUEST, IOT, LAN, SERVERS, TRUSTED_WIFI
  - Primary: 10.10.30.55 (K8s AdGuard)
  - Secondary: 10.10.30.54 (FW LXC failover)

### Pending Retirement (after 1 week stable)

- [ ] 4.2.10 Retire old PVE AGH LXC (10.10.30.53)
- [ ] 4.3.8 Disable Dell 5090 Homepage Docker container (portal.home.rommelporras.com)

---

## 1Password Items Created

| Item | Vault | Fields |
|------|-------|--------|
| Homepage | Kubernetes | proxmox-pve-user, proxmox-pve-token, proxmox-fw-user, proxmox-fw-token, opnsense-username, opnsense-password, immich-key, omv-user, omv-pass, glances-pass, karakeep-key, adguard-user, adguard-pass, adguard-fw-user, adguard-fw-pass, tailscale-device, tailscale-key, openwrt-user, openwrt-pass, weather-key, grafana-user, grafana-pass |

---

## Files Created/Modified

```
manifests/
├── home/
│   ├── adguard/
│   │   ├── configmap.yaml
│   │   ├── deployment.yaml
│   │   ├── httproute.yaml
│   │   ├── pvc.yaml
│   │   └── service.yaml
│   └── homepage/
│       ├── kustomization.yaml
│       ├── config/
│       │   ├── bookmarks.yaml
│       │   ├── custom.css
│       │   ├── custom.js
│       │   ├── docker.yaml
│       │   ├── kubernetes.yaml
│       │   ├── services.yaml      # Multi-tab layout (Main, Infra)
│       │   ├── settings.yaml      # Providers, layout config
│       │   └── widgets.yaml       # K8s, Longhorn, weather widgets
│       ├── deployment.yaml
│       ├── httproute.yaml
│       ├── rbac.yaml
│       ├── secret.yaml (template, not applied)
│       └── service.yaml
└── storage/
    └── longhorn/
        └── httproute.yaml         # Exposes Longhorn UI for widget

helm/metrics-server/
└── values.yaml

docs/todo/
└── phase-4.9-tailscale-operator.md  # Future: mobile access via Tailscale
```

---

## Talos Rebuild Notes

When rebuilding on Talos Linux after CKA:

1. **Namespace:** Same `home` namespace with Pod Security labels
2. **Cilium:** Ensure LB-IPAM pool includes AdGuard IP
3. **Secrets:** Re-create from 1Password using same commands
4. **Glances:** Already running on OMV (no changes needed)
5. **Metrics Server:** Same Helm install command
6. **Key differences for Talos:**
   - No `--kubelet-insecure-tls` needed (Talos has proper kubelet certs)
   - May need different security contexts (Talos is more locked down)
