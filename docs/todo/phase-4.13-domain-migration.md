# Phase 4.13: Domain Migration (k8s.home → k8s.rommelporras.com)

> **Status:** Planned
> **Target:** v0.12.0
> **Prerequisite:** Phase 4.12 complete (Ghost Blog)
> **DevOps Topics:** DNS management, TLS certificates, Gateway API, zero-downtime migration
> **CKA Topics:** Gateway listeners, cert-manager Certificate resources, kubeadm cert renewal

> **Purpose:** Shorten internal domain and introduce corporate-style environment tiers
> **Design Doc:** `docs/plans/2026-02-02-domain-migration-design.md`

---

## Domain Scheme

### Tier Structure

| Tier | Wildcard | Purpose |
|------|----------|---------|
| Base | `*.k8s.rommelporras.com` | Infrastructure + production apps |
| Dev | `*.dev.k8s.rommelporras.com` | Development environments |
| Stg | `*.stg.k8s.rommelporras.com` | Staging environments |

**Convention:** Production is the default — no environment qualifier. Non-production gets `dev` or `stg`.

**Boundary:** `*.home.rommelporras.com` stays for Proxmox/legacy (OMV, OPNsense, failover AdGuard LXC).

### Complete Domain Mapping

| Service | Old Domain | New Domain | Listener |
|---------|-----------|------------|----------|
| Homepage | portal.k8s.home.rommelporras.com | portal.k8s.rommelporras.com | https-base → https (after cleanup) |
| Grafana | grafana.k8s.home.rommelporras.com | grafana.k8s.rommelporras.com | https-base → https (after cleanup) |
| AdGuard | adguard.k8s.home.rommelporras.com | adguard.k8s.rommelporras.com | https-base → https (after cleanup) |
| Longhorn | longhorn.k8s.home.rommelporras.com | longhorn.k8s.rommelporras.com | https-base → https (after cleanup) |
| GitLab | gitlab.k8s.home.rommelporras.com | gitlab.k8s.rommelporras.com | https-base → https (after cleanup) |
| Registry | registry.k8s.home.rommelporras.com | registry.k8s.rommelporras.com | https-base → https (after cleanup) |
| Blog Prod | blog.k8s.home.rommelporras.com | blog.k8s.rommelporras.com | https-base → https (after cleanup) |
| Portfolio Prod | portfolio-prod.k8s.home.rommelporras.com | portfolio.k8s.rommelporras.com | https-base → https (after cleanup) |
| Blog Dev | blog-dev.k8s.home.rommelporras.com | blog.dev.k8s.rommelporras.com | https-dev |
| Portfolio Dev | portfolio-dev.k8s.home.rommelporras.com | portfolio.dev.k8s.rommelporras.com | https-dev |
| Portfolio Stg | portfolio-staging.k8s.home.rommelporras.com | portfolio.stg.k8s.rommelporras.com | https-stg |
| K8s API | k8s-api.home.rommelporras.com | api.k8s.rommelporras.com | N/A (port 6443) |
| Blog Public | blog.rommelporras.com | blog.rommelporras.com | No change |

---

## 4.13.0 Pre-flight: Failover DNS

> **WHY FIRST:** If K8s AdGuard restarts during migration, all clients fall back to the LXC at
> 10.10.30.54. Without new rewrites there, new domains won't resolve and you lose access.

- [ ] 4.13.0.1 Update failover AdGuard LXC (10.10.30.54) via web UI

  Add these DNS rewrites in the LXC AdGuard web UI (`http://10.10.30.54:3000`):

  ```
  *.k8s.rommelporras.com        → 10.10.30.20
  *.dev.k8s.rommelporras.com    → 10.10.30.20
  *.stg.k8s.rommelporras.com    → 10.10.30.20
  api.k8s.rommelporras.com      → 10.10.30.10
  cp1.k8s.rommelporras.com      → 10.10.30.11
  cp2.k8s.rommelporras.com      → 10.10.30.12
  cp3.k8s.rommelporras.com      → 10.10.30.13
  ```

  > **Do NOT remove old rewrites from LXC yet.** Both old and new must coexist.

- [ ] 4.13.0.2 Verify failover DNS resolves new domains

  ```bash
  nslookup portal.k8s.rommelporras.com 10.10.30.54
  nslookup api.k8s.rommelporras.com 10.10.30.54
  nslookup blog.dev.k8s.rommelporras.com 10.10.30.54
  nslookup portfolio.stg.k8s.rommelporras.com 10.10.30.54
  ```

  All should return the correct IPs. If any fail, fix in LXC before proceeding.

---

## 4.13.1 Update K8s AdGuard DNS (additive)

- [ ] 4.13.1.1 Update AdGuard configmap with new rewrites

  Edit `manifests/home/adguard/configmap.yaml` — add new rewrites **alongside** existing ones:

  ```yaml
  rewrites:
    # Legacy Proxmox services (keep)
    - domain: '*.home.rommelporras.com'
      answer: 10.10.30.80
      enabled: true

    # OLD K8s services (keep during migration, remove in cleanup)
    - domain: '*.k8s.home.rommelporras.com'
      answer: 10.10.30.20
      enabled: true

    # NEW K8s services — Gateway VIP
    - domain: '*.k8s.rommelporras.com'
      answer: 10.10.30.20
      enabled: true
    - domain: '*.dev.k8s.rommelporras.com'
      answer: 10.10.30.20
      enabled: true
    - domain: '*.stg.k8s.rommelporras.com'
      answer: 10.10.30.20
      enabled: true

    # NEW API server — explicit override (VIP 10.10.30.10, NOT Gateway 10.10.30.20)
    - domain: api.k8s.rommelporras.com
      answer: 10.10.30.10
      enabled: true

    # NEW node hostnames
    - domain: cp1.k8s.rommelporras.com
      answer: 10.10.30.11
      enabled: true
    - domain: cp2.k8s.rommelporras.com
      answer: 10.10.30.12
      enabled: true
    - domain: cp3.k8s.rommelporras.com
      answer: 10.10.30.13
      enabled: true

    # OLD node hostnames (keep during migration, remove in cleanup)
    - domain: k8s-cp1.home.rommelporras.com
      answer: 10.10.30.11
      enabled: true
    - domain: k8s-cp2.home.rommelporras.com
      answer: 10.10.30.12
      enabled: true
    - domain: k8s-cp3.home.rommelporras.com
      answer: 10.10.30.13
      enabled: true
    - domain: k8s-api.home.rommelporras.com
      answer: 10.10.30.10
      enabled: true
  ```

- [ ] 4.13.1.2 Apply AdGuard configmap

  ```bash
  kubectl-homelab apply -f manifests/home/adguard/configmap.yaml
  ```

- [ ] 4.13.1.3 Restart AdGuard pod to pick up new configmap

  ```bash
  kubectl-homelab -n home rollout restart deployment adguard
  kubectl-homelab -n home rollout status deployment adguard
  ```

- [ ] 4.13.1.4 Verify new DNS rewrites work

  ```bash
  nslookup portal.k8s.rommelporras.com 10.10.30.53
  nslookup api.k8s.rommelporras.com 10.10.30.53
  nslookup blog.dev.k8s.rommelporras.com 10.10.30.53
  nslookup portfolio.stg.k8s.rommelporras.com 10.10.30.53
  ```

- [ ] 4.13.1.5 Verify OLD domains still resolve (parallel operation)

  ```bash
  nslookup portal.k8s.home.rommelporras.com 10.10.30.53
  nslookup k8s-api.home.rommelporras.com 10.10.30.53
  ```

  > **STOP if old domains break.** Rollback: re-apply old configmap.

---

## 4.13.2 Update Gateway (add new listeners)

- [ ] 4.13.2.1 Update Gateway manifest

  Edit `manifests/gateway/homelab-gateway.yaml` — keep old listener as `https` (so existing
  HTTPRoutes keep working), add new listeners alongside it:

  ```yaml
  apiVersion: gateway.networking.k8s.io/v1
  kind: Gateway
  metadata:
    name: homelab-gateway
    namespace: default
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
  spec:
    gatewayClassName: cilium
    listeners:
      # HTTP → HTTPS redirect
      - name: http
        protocol: HTTP
        port: 80
        allowedRoutes:
          namespaces:
            from: All

      # OLD listener — KEEP name as 'https' so existing HTTPRoutes still work
      - name: https
        protocol: HTTPS
        port: 443
        hostname: "*.k8s.home.rommelporras.com"
        allowedRoutes:
          namespaces:
            from: All
        tls:
          mode: Terminate
          certificateRefs:
            - name: wildcard-k8s-home-tls
              kind: Secret

      # NEW: Base (infra + production)
      - name: https-base
        protocol: HTTPS
        port: 443
        hostname: "*.k8s.rommelporras.com"
        allowedRoutes:
          namespaces:
            from: All
        tls:
          mode: Terminate
          certificateRefs:
            - name: wildcard-k8s-tls
              kind: Secret

      # NEW: Development
      - name: https-dev
        protocol: HTTPS
        port: 443
        hostname: "*.dev.k8s.rommelporras.com"
        allowedRoutes:
          namespaces:
            from: All
        tls:
          mode: Terminate
          certificateRefs:
            - name: wildcard-dev-k8s-tls
              kind: Secret

      # NEW: Staging
      - name: https-stg
        protocol: HTTPS
        port: 443
        hostname: "*.stg.k8s.rommelporras.com"
        allowedRoutes:
          namespaces:
            from: All
        tls:
          mode: Terminate
          certificateRefs:
            - name: wildcard-stg-k8s-tls
            kind: Secret
  ```

  > During Phase 2, HTTPRoutes switch from `sectionName: https` (old) to `sectionName: https-base` (new).
  > During Phase 3 cleanup, remove old `https` listener and rename `https-base` → `https`.

- [ ] 4.13.2.2 Apply Gateway

  ```bash
  kubectl-homelab apply -f manifests/gateway/homelab-gateway.yaml
  ```

- [ ] 4.13.2.3 Verify Gateway accepted all listeners

  ```bash
  kubectl-homelab get gateway homelab-gateway -o yaml | grep -A5 'listeners'
  kubectl-homelab get gateway homelab-gateway -o jsonpath='{.status.listeners[*].name}'
  ```

  Expected: `http`, `https`, `https-base`, `https-dev`, `https-stg`

- [ ] 4.13.2.4 Wait for all new certificates to reach Ready

  ```bash
  kubectl-homelab get certificate -A -w
  ```

  Wait until these show `Ready: True`:
  - `wildcard-k8s-tls`
  - `wildcard-dev-k8s-tls`
  - `wildcard-stg-k8s-tls`

  > **DO NOT proceed until all 3 are Ready.** DNS-01 challenges take 1-5 minutes each.
  > If a cert fails, check cert-manager logs before retrying (5 failures/hour LE rate limit):
  > ```bash
  > kubectl-homelab -n cert-manager logs -l app=cert-manager --tail=50
  > ```

- [ ] 4.13.2.5 Verify existing services still work on old domain

  ```bash
  curl -sk https://portal.k8s.home.rommelporras.com | head -5
  curl -sk https://grafana.k8s.home.rommelporras.com/api/health
  ```

  > **STOP if existing services break.** Old listener is unchanged — this should not happen.

---

## 4.13.3 Renew API Server Certificate

> **WHY:** The API server cert only has `k8s-api.home.rommelporras.com` as a SAN.
> We need to add `api.k8s.rommelporras.com` before updating kubeconfig.
> Old SANs remain valid — this is additive, not destructive.

- [ ] 4.13.3.1 SSH to k8s-cp1 and check current SANs

  ```bash
  ssh wawashi@10.10.30.11
  sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 "Subject Alternative Name"
  ```

  Confirm `k8s-api.home.rommelporras.com` is present.

- [ ] 4.13.3.2 Update kubeadm ClusterConfiguration ConfigMap

  The kubeadm config is stored as a ConfigMap in `kube-system`. Update it so all nodes
  read the new SANs when renewing certs:

  ```bash
  kubectl-homelab -n kube-system get cm kubeadm-config -o yaml > /tmp/kubeadm-config-backup.yaml

  kubectl-homelab -n kube-system edit cm kubeadm-config
  # In the ClusterConfiguration data, find or add apiServer.certSANs:
  #   apiServer:
  #     certSANs:
  #       - api.k8s.rommelporras.com
  #       - k8s-api.home.rommelporras.com   (keep for rollback)
  ```

  > **Note:** The ConfigMap is the source of truth. Each node reads it during `kubeadm certs renew`.

- [ ] 4.13.3.3 Renew API server cert on k8s-cp1

  ```bash
  ssh wawashi@10.10.30.11
  sudo kubeadm certs renew apiserver
  # Restart kube-apiserver
  sudo crictl pods --name kube-apiserver -q | xargs sudo crictl stopp
  # Wait for it to come back (kubelet auto-restarts, ~10 seconds)
  sleep 15
  ```

- [ ] 4.13.3.4 Verify new SAN and API health on k8s-cp1

  ```bash
  sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep "api.k8s.rommelporras.com"
  ```

  **From local workstation — verify cluster is healthy before touching next node:**
  ```bash
  kubectl-homelab get nodes
  # All 3 nodes must show Ready
  ```

  > **STOP if any node shows NotReady.** Wait for recovery before proceeding.

- [ ] 4.13.3.5 Renew API server cert on k8s-cp2

  ```bash
  ssh wawashi@10.10.30.12
  sudo kubeadm certs renew apiserver
  sudo crictl pods --name kube-apiserver -q | xargs sudo crictl stopp
  sleep 15
  sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep "api.k8s.rommelporras.com"
  ```

  **Verify cluster health before next node:**
  ```bash
  kubectl-homelab get nodes
  ```

- [ ] 4.13.3.6 Renew API server cert on k8s-cp3

  ```bash
  ssh wawashi@10.10.30.13
  sudo kubeadm certs renew apiserver
  sudo crictl pods --name kube-apiserver -q | xargs sudo crictl stopp
  sleep 15
  sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep "api.k8s.rommelporras.com"
  ```

  **Final cluster health check:**
  ```bash
  kubectl-homelab get nodes
  ```

- [ ] 4.13.3.7 Update local kubeconfig

  ```bash
  # Edit ~/.kube/homelab.yaml
  # Change: server: https://k8s-api.home.rommelporras.com:6443
  # To:     server: https://api.k8s.rommelporras.com:6443
  ```

- [ ] 4.13.3.8 Verify kubectl works on new API hostname

  ```bash
  kubectl-homelab get nodes
  kubectl-homelab cluster-info
  ```

  > **If this fails:** Revert kubeconfig to `k8s-api.home.rommelporras.com` (old SAN still valid).
  > Debug: `openssl s_client -connect 10.10.30.10:6443 -servername api.k8s.rommelporras.com </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A1 SAN`

- [ ] 4.13.3.9 Verify old kubeconfig hostname still works (rollback safety)

  ```bash
  # Temporarily test old hostname
  kubectl --kubeconfig=~/.kube/homelab.yaml get nodes --server=https://k8s-api.home.rommelporras.com:6443
  ```

---

## 4.13.4 Cutover: GitLab (dependency — registry must be first)

> **WHY FIRST:** Portfolio pulls container images from `registry.k8s.rommelporras.com`.
> Registry must work on the new domain before portfolio image refs are updated.

- [ ] 4.13.4.1 Update GitLab Helm values

  Edit `helm/gitlab/values.yaml`:

  ```yaml
  global:
    hosts:
      domain: k8s.rommelporras.com        # was: k8s.home.rommelporras.com
      gitlab:
        name: gitlab.k8s.rommelporras.com  # was: gitlab.k8s.home.rommelporras.com
      registry:
        name: registry.k8s.rommelporras.com  # was: registry.k8s.home.rommelporras.com
  ```

- [ ] 4.13.4.2 Update GitLab HTTPRoutes

  Edit `manifests/gateway/routes/gitlab.yaml`:
  ```yaml
  hostnames: ["gitlab.k8s.rommelporras.com"]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base    # was: https
  ```

  Edit `manifests/gateway/routes/gitlab-registry.yaml`:
  ```yaml
  hostnames: ["registry.k8s.rommelporras.com"]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base    # was: https
  ```

- [ ] 4.13.4.3 Apply GitLab HTTPRoutes

  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/gitlab.yaml
  kubectl-homelab apply -f manifests/gateway/routes/gitlab-registry.yaml
  ```

- [ ] 4.13.4.4 Helm upgrade GitLab

  ```bash
  helm-homelab upgrade gitlab gitlab/gitlab \
    -n gitlab \
    -f helm/gitlab/values.yaml \
    --timeout 10m
  ```

- [ ] 4.13.4.5 Verify GitLab accessible on new domain

  ```bash
  curl -sk https://gitlab.k8s.rommelporras.com/users/sign_in | grep "GitLab"
  curl -sk https://registry.k8s.rommelporras.com/v2/ | head -5
  ```

- [ ] 4.13.4.6 Update GitLab Runner Helm values

  Edit `helm/gitlab-runner/values.yaml`:
  ```yaml
  gitlabUrl: https://gitlab.k8s.rommelporras.com  # was: https://gitlab.k8s.home.rommelporras.com
  ```

- [ ] 4.13.4.7 Helm upgrade GitLab Runner

  ```bash
  helm-homelab upgrade gitlab-runner gitlab/gitlab-runner \
    -n gitlab-runner \
    -f helm/gitlab-runner/values.yaml
  ```

- [ ] 4.13.4.8 Verify Runner connected

  ```bash
  kubectl-homelab -n gitlab-runner get pods
  # Check GitLab UI → Admin → Runners for runner status
  ```

  > **If runner fails to connect:** May need re-registration. Check runner pod logs:
  > `kubectl-homelab -n gitlab-runner logs -l app=gitlab-runner --tail=30`

---

## 4.13.5 Cutover: Portfolio

> **Prerequisite:** GitLab registry accessible on new domain (4.13.4.5 verified).

- [ ] 4.13.5.1 Update Portfolio image reference

  Edit `manifests/portfolio/deployment.yaml`:
  ```yaml
  image: registry.k8s.rommelporras.com/0xwsh/portfolio:latest
  # was: registry.k8s.home.rommelporras.com/0xwsh/portfolio:latest
  ```

- [ ] 4.13.5.2 Update Portfolio HTTPRoutes

  Edit `manifests/gateway/routes/portfolio-prod.yaml`:
  ```yaml
  hostnames: ["portfolio.k8s.rommelporras.com"]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base
  ```

  Edit `manifests/gateway/routes/portfolio-dev.yaml`:
  ```yaml
  hostnames: ["portfolio.dev.k8s.rommelporras.com"]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-dev
  ```

  Edit `manifests/gateway/routes/portfolio-staging.yaml`:
  ```yaml
  hostnames: ["portfolio.stg.k8s.rommelporras.com"]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-stg
  ```

- [ ] 4.13.5.3 Apply Portfolio changes

  ```bash
  kubectl-homelab apply -f manifests/portfolio/deployment.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-prod.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-dev.yaml
  kubectl-homelab apply -f manifests/gateway/routes/portfolio-staging.yaml
  ```

- [ ] 4.13.5.4 Verify Portfolio accessible on new domains

  ```bash
  curl -sk https://portfolio.k8s.rommelporras.com | head -5
  curl -sk https://portfolio.dev.k8s.rommelporras.com | head -5
  curl -sk https://portfolio.stg.k8s.rommelporras.com | head -5
  ```

---

## 4.13.6 Cutover: Grafana + Prometheus Stack

- [ ] 4.13.6.1 Update Grafana HTTPRoute

  Edit `manifests/monitoring/grafana-httproute.yaml`:
  ```yaml
  hostnames: [grafana.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base
  ```

- [ ] 4.13.6.2 Update Grafana root_url in Helm values

  Edit `helm/prometheus/values.yaml`:
  ```yaml
  grafana:
    grafana.ini:
      server:
        root_url: https://grafana.k8s.rommelporras.com
  ```

- [ ] 4.13.6.3 Apply HTTPRoute and Helm upgrade

  ```bash
  kubectl-homelab apply -f manifests/monitoring/grafana-httproute.yaml
  ./scripts/upgrade-prometheus.sh
  ```

- [ ] 4.13.6.4 Verify Grafana accessible

  ```bash
  curl -sk https://grafana.k8s.rommelporras.com/api/health
  ```

---

## 4.13.7 Cutover: Longhorn, AdGuard, Ghost

These are independent — order doesn't matter.

- [ ] 4.13.7.1 Update Longhorn HTTPRoute

  Edit `manifests/storage/longhorn/httproute.yaml`:
  ```yaml
  hostnames: [longhorn.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base
  ```

  ```bash
  kubectl-homelab apply -f manifests/storage/longhorn/httproute.yaml
  curl -sk https://longhorn.k8s.rommelporras.com | head -5
  ```

- [ ] 4.13.7.2 Update AdGuard HTTPRoute

  Edit `manifests/home/adguard/httproute.yaml`:
  ```yaml
  hostnames: [adguard.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base
  ```

  ```bash
  kubectl-homelab apply -f manifests/home/adguard/httproute.yaml
  curl -sk https://adguard.k8s.rommelporras.com | head -5
  ```

- [ ] 4.13.7.3 Update Ghost Dev (HTTPRoute + deployment)

  Edit `manifests/ghost-dev/httproute.yaml`:
  ```yaml
  hostnames: [blog.dev.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-dev    # was: https
  ```

  Edit `manifests/ghost-dev/ghost-deployment.yaml`:
  ```yaml
  env:
    - name: url
      value: "https://blog.dev.k8s.rommelporras.com"
  ```

  ```bash
  kubectl-homelab apply -f manifests/ghost-dev/httproute.yaml
  kubectl-homelab apply -f manifests/ghost-dev/ghost-deployment.yaml
  # Pod restart needed for env change
  kubectl-homelab -n ghost-dev rollout restart deployment ghost
  curl -sk https://blog.dev.k8s.rommelporras.com | head -5
  ```

- [ ] 4.13.7.4 Update Ghost Prod HTTPRoute

  Edit `manifests/ghost-prod/httproute.yaml`:
  ```yaml
  hostnames: [blog.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base   # was: https
  ```

  ```bash
  kubectl-homelab apply -f manifests/ghost-prod/httproute.yaml
  curl -sk https://blog.k8s.rommelporras.com | head -5
  ```

  > **Note:** Ghost prod `url` env is `https://blog.rommelporras.com` (Cloudflare Tunnel) — no change needed.

---

## 4.13.8 Cutover: Homepage (last — all URLs must work first)

> **WHY LAST:** Homepage has ~33 bookmark URLs pointing to other services.
> All services must be on new domains before updating bookmarks.

- [ ] 4.13.8.1 Update Homepage HTTPRoute

  Edit `manifests/home/homepage/httproute.yaml`:
  ```yaml
  hostnames: [portal.k8s.rommelporras.com]
  parentRefs:
    - name: homelab-gateway
      namespace: default
      sectionName: https-base
  ```

- [ ] 4.13.8.2 Update Homepage deployment HOMEPAGE_ALLOWED_HOSTS

  Edit `manifests/home/homepage/deployment.yaml`:
  ```yaml
  env:
    - name: HOMEPAGE_ALLOWED_HOSTS
      value: "portal.k8s.rommelporras.com"
  ```

- [ ] 4.13.8.3 Update Homepage services.yaml (all bookmark URLs)

  Edit `manifests/home/homepage/config/services.yaml`:

  > **DANGER: This file has BOTH `k8s.home.rommelporras.com` (K8s) AND `home.rommelporras.com`
  > (Proxmox/legacy) URLs. DO NOT blindly find-replace `home.rommelporras` — you will break
  > Proxmox, OPNsense, OMV, Immich, Karakeep, MySpeed, and failover AdGuard links.**

  **Only change these (K8s services):**
  - `grafana.k8s.home.rommelporras.com` → `grafana.k8s.rommelporras.com` (~8 occurrences)
  - `adguard.k8s.home.rommelporras.com` → `adguard.k8s.rommelporras.com` (~4 occurrences)
  - `longhorn.k8s.home.rommelporras.com` → `longhorn.k8s.rommelporras.com` (~4 occurrences)
  - `blog-dev.k8s.home.rommelporras.com` → `blog.dev.k8s.rommelporras.com` (~2 occurrences)
  - `homepage.k8s.home.rommelporras.com` → `portal.k8s.rommelporras.com` (~2 occurrences, note: name change too)

  **DO NOT change these (Proxmox/legacy — stays on `*.home.rommelporras.com`):**
  - `pve.home.rommelporras.com` (Proxmox)
  - `firewall.home.rommelporras.com` (OPNsense)
  - `omv.home.rommelporras.com` (NAS)
  - `fw-agh.home.rommelporras.com` (Failover AdGuard LXC)
  - `immich.home.rommelporras.com` (Immich)
  - `karakeep.home.rommelporras.com` (Karakeep)
  - `myspeed.home.rommelporras.com` (MySpeed)
  - `blog.rommelporras.com` (Public blog — Cloudflare Tunnel)

- [ ] 4.13.8.4 Update Homepage settings.yaml

  Edit `manifests/home/homepage/config/settings.yaml`:
  ```yaml
  url: https://longhorn.k8s.rommelporras.com
  ```

- [ ] 4.13.8.5 Apply all Homepage changes

  ```bash
  kubectl-homelab apply -f manifests/home/homepage/httproute.yaml
  kubectl-homelab apply -f manifests/home/homepage/deployment.yaml
  kubectl-homelab apply -k manifests/home/homepage/config/ 2>/dev/null || \
    kubectl-homelab apply -f manifests/home/homepage/config/services.yaml \
                          -f manifests/home/homepage/config/settings.yaml
  kubectl-homelab -n home rollout restart deployment homepage
  kubectl-homelab -n home rollout status deployment homepage
  ```

- [ ] 4.13.8.6 Verify Homepage accessible and all bookmarks work

  ```bash
  curl -sk https://portal.k8s.rommelporras.com | head -5
  ```

  Open in browser — verify all bookmark links point to new domains.

---

## 4.13.9 Cutover: Remaining Items

- [ ] 4.13.9.1 Verify Blackbox exporter probe targets

  `manifests/monitoring/adguard-dns-probe.yaml` uses IP `10.10.30.53`, not a domain — no changes needed.
  Verify probes still work after migration:

  ```bash
  kubectl-homelab -n monitoring get probe -o wide
  ```

- [ ] 4.13.9.2 Update local SSH config (GitLab)

  Edit `~/.ssh/config`:
  ```
  Host gitlab.k8s.rommelporras.com
  HostName ssh.gitlab.k8s.rommelporras.com
  User git
  ```

  Verify:
  ```bash
  ssh -T git@gitlab.k8s.rommelporras.com
  ```

- [ ] 4.13.9.3 Update sync script

  Edit `scripts/sync-ghost-prod-to-dev.sh`:
  - Line 74: SQL URL → `https://blog.dev.k8s.rommelporras.com`
  - Line 90: output message → `https://blog.dev.k8s.rommelporras.com`

- [ ] 4.13.9.4 Update Ansible group_vars

  Edit `ansible/group_vars/all.yml`:
  ```yaml
  vip_hostname: "api.k8s.rommelporras.com"     # was: k8s-api.home.rommelporras.com
  cluster_domain: "rommelporras.com"             # was: home.rommelporras.com
  ```

  Edit `ansible/group_vars/control_plane.yml`:
  ```yaml
  cert_sans:
    - "api.k8s.rommelporras.com"       # was: k8s-api.home.rommelporras.com
    - "10.10.30.10"
    - "10.10.30.11"
    - "10.10.30.12"
    - "10.10.30.13"
    - "k8s-cp1"
    - "k8s-cp2"
    - "k8s-cp3"
  ```

---

## 4.13.10 Full Verification (before cleanup)

> **Every service must be verified before proceeding to cleanup.
> Cleanup removes the old domain — there is no rollback after that.**

- [ ] 4.13.10.1 Verify all services on new domains

  | Service | URL | Expected |
  |---------|-----|----------|
  | Homepage | `https://portal.k8s.rommelporras.com` | Dashboard loads |
  | Grafana | `https://grafana.k8s.rommelporras.com` | Login page |
  | AdGuard | `https://adguard.k8s.rommelporras.com` | Admin UI |
  | Longhorn | `https://longhorn.k8s.rommelporras.com` | Dashboard |
  | GitLab | `https://gitlab.k8s.rommelporras.com` | Login page |
  | Registry | `https://registry.k8s.rommelporras.com/v2/` | `{}` or auth |
  | Blog Prod | `https://blog.k8s.rommelporras.com` | Ghost blog |
  | Blog Public | `https://blog.rommelporras.com` | Ghost blog (tunnel) |
  | Portfolio Prod | `https://portfolio.k8s.rommelporras.com` | Portfolio |
  | Portfolio Dev | `https://portfolio.dev.k8s.rommelporras.com` | Portfolio |
  | Portfolio Stg | `https://portfolio.stg.k8s.rommelporras.com` | Portfolio |
  | Blog Dev | `https://blog.dev.k8s.rommelporras.com` | Ghost blog |
  | K8s API | `kubectl-homelab get nodes` | 3 nodes Ready |
  | GitLab SSH | `ssh -T git@gitlab.k8s.rommelporras.com` | Welcome message |

- [ ] 4.13.10.2 Check for alert firing

  ```bash
  kubectl-homelab -n monitoring get prometheusrule -o name
  # Check Discord #status for any alerts triggered during migration
  ```

- [ ] 4.13.10.3 Verify Cloudflare Tunnel still works

  ```bash
  curl -s https://blog.rommelporras.com | head -5
  ```

---

## 4.13.11 Commit Deployment Changes

> **Commit all manifest, helm, script, and ansible changes. Do NOT commit docs yet.**

- [ ] 4.13.11.1 Commit deployment changes

  Stage and commit all changed files in `manifests/`, `helm/`, `scripts/`, `ansible/`.

  ```
  feat: migrate all services to k8s.rommelporras.com domain

  - Add multi-tier Gateway listeners (base, dev, stg)
  - Update all HTTPRoute hostnames
  - Update GitLab, Grafana Helm values
  - Update Ghost, Homepage, Portfolio configs
  - Update Ansible group_vars for future bootstrap
  - Update sync scripts
  ```

---

## 4.13.12 Cleanup: Remove Legacy Domain

> **Only proceed after 4.13.10 full verification is complete.**

- [ ] 4.13.12.1 Remove old Gateway listener

  Edit `manifests/gateway/homelab-gateway.yaml`:
  - Remove the `https` listener (old `*.k8s.home.rommelporras.com`)
  - Rename `https-base` → `https`

  ```bash
  kubectl-homelab apply -f manifests/gateway/homelab-gateway.yaml
  ```

- [ ] 4.13.12.2 Update all HTTPRoute sectionNames

  All HTTPRoutes currently referencing `sectionName: https-base` → change to `sectionName: https`.

  Apply all HTTPRoutes:
  ```bash
  kubectl-homelab apply -f manifests/gateway/routes/
  kubectl-homelab apply -f manifests/monitoring/grafana-httproute.yaml
  kubectl-homelab apply -f manifests/storage/longhorn/httproute.yaml
  kubectl-homelab apply -f manifests/home/adguard/httproute.yaml
  kubectl-homelab apply -f manifests/home/homepage/httproute.yaml
  kubectl-homelab apply -f manifests/ghost-dev/httproute.yaml
  kubectl-homelab apply -f manifests/ghost-prod/httproute.yaml
  ```

- [ ] 4.13.12.3 Remove old AdGuard DNS rewrites (K8s)

  Edit `manifests/home/adguard/configmap.yaml` — remove:
  ```yaml
  # Remove these (old domains):
  - domain: '*.k8s.home.rommelporras.com'
  - domain: k8s-cp1.home.rommelporras.com
  - domain: k8s-cp2.home.rommelporras.com
  - domain: k8s-cp3.home.rommelporras.com
  - domain: k8s-api.home.rommelporras.com
  # Note: new node hostnames are cp1.k8s / cp2.k8s / cp3.k8s (keep those)
  ```

  ```bash
  kubectl-homelab apply -f manifests/home/adguard/configmap.yaml
  kubectl-homelab -n home rollout restart deployment adguard
  ```

- [ ] 4.13.12.4 Remove old DNS rewrites from failover AdGuard LXC

  Via web UI at `http://10.10.30.54:3000` — remove old `*.k8s.home` rewrites.

- [ ] 4.13.12.5 Delete orphaned TLS secret

  ```bash
  kubectl-homelab delete secret wildcard-k8s-home-tls -n default
  ```

- [ ] 4.13.12.6 Check Cloudflare dashboard

  Verify tunnel ingress rules don't reference old `*.k8s.home` origins.

- [ ] 4.13.12.7 Final verification after cleanup

  Re-run the full verification from 4.13.10.1. All services must work.

  Also verify old domains NO LONGER resolve:
  ```bash
  nslookup portal.k8s.home.rommelporras.com 10.10.30.53
  # Should return NXDOMAIN or no answer
  ```

- [ ] 4.13.12.8 Commit cleanup

  ```
  refactor: remove legacy k8s.home.rommelporras.com domain

  - Remove old Gateway listener
  - Rename https-base listener to https
  - Remove old AdGuard DNS rewrites
  - Delete orphaned wildcard-k8s-home-tls secret
  ```

---

## 4.13.13 Documentation and Audit

- [ ] 4.13.13.1 Update VERSIONS.md

  Update all HTTPRoute URLs, domain references, add version history entry.

- [ ] 4.13.13.2 Update CLAUDE.md

  Update SSH references, HTTPRoute table, quick reference section.

- [ ] 4.13.13.3 Update docs/CLUSTER_STATUS.md

  Update all domain entries (source of truth).

- [ ] 4.13.13.4 Update docs/ARCHITECTURE.md

  Add domain tier rationale.

- [ ] 4.13.13.5 Update docs/context/ files

  - `Networking.md` (18 occurrences)
  - `Gateway.md` (18 occurrences)
  - `Monitoring.md` (1 occurrence)
  - `Conventions.md` (1 occurrence)
  - `Storage.md` (1 occurrence)

- [ ] 4.13.13.6 Update docs/rebuild/ guides

  - `v0.4.0-observability.md` (3 occurrences)
  - `v0.6.0-home-services.md` (7 occurrences)
  - `v0.7.0-cloudflare.md` (4 occurrences)
  - `v0.8.0-gitlab.md` (20 occurrences)
  - `v0.10.0-portfolio-cicd.md` (10 occurrences)
  - `v0.11.0-ghost-blog.md` (11 occurrences)
  - `README.md` (1 occurrence)

- [ ] 4.13.13.7 Update active plans

  - `docs/todo/phase-4.14-uptime-kuma.md` (already updated)
  - `docs/todo/phase-4.9-invoicetron.md` (4 occurrences)

- [ ] 4.13.13.8 Update completed phase history

  - `docs/todo/completed/phase-4.6-gitlab.md` (28 occurrences)
  - `docs/todo/completed/phase-4.7-portfolio.md` (17 occurrences)
  - `docs/todo/completed/phase-4.12-ghost-blog.md` (15 occurrences)
  - `docs/todo/completed/phase-4.5-cloudflare.md` (9 occurrences)
  - `docs/todo/completed/phase-4.1-4.4-stateless.md` (5 occurrences)
  - `docs/todo/completed/phase-3.5-3.8-monitoring.md` (4 occurrences)

- [ ] 4.13.13.9 Update docs/reference/CHANGELOG.md

  Add domain migration entry (11 existing occurrences to update).

- [ ] 4.13.13.10 Update README.md

- [ ] 4.13.13.11 Create rebuild guide

  Create `docs/rebuild/v0.12.0-domain-migration.md` with the exact commands used.

- [ ] 4.13.13.12 Run audit-docs

  ```bash
  # /audit-docs to verify consistency
  ```

- [ ] 4.13.13.13 Commit documentation

  ```
  docs: update all references for domain migration to k8s.rommelporras.com

  - Update 21+ docs files (205+ domain references)
  - Update VERSIONS.md, CLAUDE.md, CLUSTER_STATUS.md
  - Update rebuild guides, context docs, completed phases
  - Add v0.12.0-domain-migration.md rebuild guide
  ```

---

## Final Checklist

- [ ] All services accessible on new `*.k8s.rommelporras.com` domains
- [ ] All dev services on `*.dev.k8s.rommelporras.com`
- [ ] All staging services on `*.stg.k8s.rommelporras.com`
- [ ] `kubectl-homelab get nodes` works via `api.k8s.rommelporras.com`
- [ ] GitLab SSH works via `gitlab.k8s.rommelporras.com`
- [ ] Blog public access via `blog.rommelporras.com` (Cloudflare Tunnel)
- [ ] Old `*.k8s.home.rommelporras.com` domains no longer resolve
- [ ] No alerts firing in Discord #status
- [ ] Failover AdGuard LXC updated (old rewrites removed)
- [ ] All docs updated and committed
- [ ] Release tagged as v0.12.0

---

## Rollback Procedures

### During Phase 1-2 (old domain still active):
- **Per-service:** Revert single HTTPRoute + config, re-apply
- **Full rollback:** `git checkout manifests/ helm/ scripts/ ansible/` and re-apply all
- **Kubeconfig:** Revert `~/.kube/homelab.yaml` to `k8s-api.home.rommelporras.com` (old SAN still valid)

### After Phase 3 cleanup (point of no return):
- Old DNS rewrites removed — must re-add manually in AdGuard configmap + LXC
- Old Gateway listener removed — must re-add to Gateway manifest
- Old TLS secret deleted — cert-manager will re-create if listener is re-added

### Emergency (lost all access):
- SSH to nodes uses IPs directly (10.10.30.11/12/13) — not affected by DNS
- kubeconfig can use IP: `server: https://10.10.30.10:6443`
- Physical console access as last resort
