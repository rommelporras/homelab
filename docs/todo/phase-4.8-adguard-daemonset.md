# Phase 4.8: AdGuard DaemonSet Migration

> **Status:** Planned
> **Target:** v0.8.2
> **Prerequisite:** Phase 4.7 complete
> **CKA Topics:** DaemonSet, externalTrafficPolicy, Service topology

> **Purpose:** Convert AdGuard from Deployment to DaemonSet for reliable L2 announcement with client IP preservation
>
> **Problem:** With `externalTrafficPolicy: Local`, Cilium L2 must announce from the node where the pod runs. Current Deployment can schedule on any node, causing mismatch.
>
> **Solution:** DaemonSet ensures a pod on every node, so L2 can announce from any node.

---

## Background

### Current State
- AdGuard runs as **Deployment** (1 replica)
- Service uses `externalTrafficPolicy: Cluster` (workaround)
- Client IPs not visible in AdGuard logs (all show as node IPs)

### Desired State
- AdGuard runs as **DaemonSet** (1 pod per node)
- Service uses `externalTrafficPolicy: Local`
- Client IPs visible in AdGuard logs

---

## 4.8.1 Prepare Shared Configuration

- [ ] 4.8.1.1 Export current AdGuard config
  ```bash
  kubectl-homelab exec -n home deploy/adguard-home -- cat /opt/adguardhome/conf/AdGuardHome.yaml > adguard-config-backup.yaml
  ```

- [ ] 4.8.1.2 Create ConfigMap from config
  ```yaml
  # manifests/home/adguard/configmap.yaml
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: adguard-config
    namespace: home
  data:
    AdGuardHome.yaml: |
      # Paste sanitized config here
  ```

---

## 4.8.2 Create DaemonSet

- [ ] 4.8.2.1 Create DaemonSet manifest
  ```yaml
  # manifests/home/adguard/daemonset.yaml
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: adguard-home
    namespace: home
  spec:
    selector:
      matchLabels:
        app: adguard-home
    template:
      metadata:
        labels:
          app: adguard-home
      spec:
        containers:
        - name: adguard-home
          image: adguard/adguardhome:v0.107.71
          ports:
          - containerPort: 53
            protocol: UDP
          - containerPort: 53
            protocol: TCP
          - containerPort: 3000
          volumeMounts:
          - name: config
            mountPath: /opt/adguardhome/conf
          - name: work
            mountPath: /opt/adguardhome/work
          resources:
            requests:
              memory: "128Mi"
              cpu: "100m"
            limits:
              memory: "256Mi"
              cpu: "500m"
        volumes:
        - name: config
          configMap:
            name: adguard-config
        - name: work
          emptyDir: {}
  ```

- [ ] 4.8.2.2 Delete old Deployment
  ```bash
  kubectl-homelab delete deployment adguard-home -n home
  ```

- [ ] 4.8.2.3 Apply DaemonSet
  ```bash
  kubectl-homelab apply -f manifests/home/adguard/daemonset.yaml
  ```

---

## 4.8.3 Update Service

- [ ] 4.8.3.1 Change externalTrafficPolicy to Local
  ```bash
  kubectl-homelab patch svc adguard-dns -n home \
    -p '{"spec":{"externalTrafficPolicy":"Local"}}'
  ```

- [ ] 4.8.3.2 Update manifest
  ```yaml
  # manifests/home/adguard/service.yaml
  spec:
    externalTrafficPolicy: Local  # Restore client IP visibility
  ```

---

## 4.8.4 Verify

- [ ] 4.8.4.1 Check pods running on all nodes
  ```bash
  kubectl-homelab get pods -n home -l app=adguard-home -o wide
  # Should show 3 pods, one per node
  ```

- [ ] 4.8.4.2 Test DNS resolution
  ```bash
  nslookup google.com 10.10.30.53
  ```

- [ ] 4.8.4.3 Verify client IPs in AdGuard logs
  ```
  AdGuard UI → Query Log
  Should show actual client IPs (10.10.x.x) not node IPs
  ```

---

## Considerations

### Config Sync
- ConfigMap is read-only - UI changes won't persist
- For persistent UI changes, consider:
  - Shared PVC (NFS) - but can't mount same PVC to multiple pods RWX
  - Accept read-only config (manage via GitOps)
  - Use single replica with node pinning instead

### Alternative: Node Pinning (Simpler)
If DaemonSet complexity isn't worth it:
```yaml
# Add to Deployment
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: k8s-cp1
```
Then delete the L2 lease to force re-announcement from k8s-cp1.

---

## Rollback

```bash
# Delete DaemonSet
kubectl-homelab delete daemonset adguard-home -n home

# Restore Deployment
kubectl-homelab apply -f manifests/home/adguard/deployment.yaml

# Revert to Cluster policy
kubectl-homelab patch svc adguard-dns -n home \
  -p '{"spec":{"externalTrafficPolicy":"Cluster"}}'
```

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.8.2
  ```bash
  /release v0.8.2
  ```
