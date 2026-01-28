# Kubernetes Interactive Learning Guide

> **Purpose:** Step-by-step teaching companion for hands-on homelab learning  
> **Approach:** Run commands â†’ Understand what happens â†’ Build mental model  
> **Last Updated:** January 11, 2026

---

## Table of Contents

1. [Learning Philosophy](#learning-philosophy)
2. [Module 1: Core Concepts](#module-1-core-concepts)
3. [Module 2: Workloads](#module-2-workloads)
4. [Module 3: Networking](#module-3-networking)
5. [Module 4: Storage](#module-4-storage)
6. [Module 5: Configuration](#module-5-configuration)
7. [Module 6: Security](#module-6-security)
8. [Module 7: Scheduling](#module-7-scheduling)
9. [Module 8: Cluster Operations](#module-8-cluster-operations)
10. [Module 9: Troubleshooting](#module-9-troubleshooting)
11. [Module 10: CKA New Topics (2025)](#module-10-cka-new-topics-2025)
12. [Practical Exercises](#practical-exercises)
13. [Common Mistakes & Fixes](#common-mistakes--fixes)

---

## Learning Philosophy

### The "Explain Like I'm Debugging" Approach

For every command, we answer:
1. **WHAT** does this command do?
2. **WHY** would I use it?
3. **HOW** does Kubernetes process it internally?
4. **WHEN** would this fail, and how do I fix it?

### Your Homelab Context

Every example uses YOUR actual setup (see [CLUSTER_STATUS.md](CLUSTER_STATUS.md) for details):
- **Nodes:** k8s-cp1 (.11), k8s-cp2 (.12), k8s-cp3 (.13) on 10.10.30.0/24
- **VIP:** 10.10.30.10 (k8s-api.home.rommelporras.com)
- **CNI:** Cilium (NetworkPolicy enabled)
- **Storage:** Longhorn on NVMe
- **NAS:** Dell 3090 OMV at 10.10.30.4 (NFS)
- **DNS:** AdGuard Home at 10.10.30.53

---

## Module 1: Core Concepts

### 1.1 Understanding the API Server

**What happens when you run `kubectl get pods`?**

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”     HTTPS/REST      â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚   kubectl   â”‚ â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â–º â”‚  API Server  â”‚
â”‚  (client)   â”‚     with auth       â”‚  (kube-api)  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜                     â””â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”˜
                                           â”‚
                                           â–¼
                                    â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
                                    â”‚     etcd     â”‚
                                    â”‚  (database)  â”‚
                                    â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

**Step-by-step flow:**
1. kubectl reads `~/.kube/config` for API server address and credentials
2. Sends HTTPS request: `GET /api/v1/namespaces/default/pods`
3. API server authenticates you (certificate or token)
4. API server authorizes you (RBAC check)
5. API server queries etcd for pod data
6. Response formatted and returned

**Try this to see the raw API:**
```bash
# See what kubectl is actually doing
kubectl get pods -v=8

# Call API directly (from control plane node)
kubectl proxy &
curl http://localhost:8001/api/v1/namespaces/default/pods
```

### 1.2 Namespaces - Logical Isolation

**What is a namespace?**
- A virtual cluster inside your physical cluster
- Provides scope for names (pod "nginx" can exist in multiple namespaces)
- Enables resource quotas and RBAC per team/environment

**System namespaces in your cluster:**
```bash
kubectl get namespaces
```

| Namespace | Purpose |
|-----------|---------|
| `default` | Where your workloads go if unspecified |
| `kube-system` | Control plane components (API server, scheduler, etc.) |
| `kube-public` | Public readable data (cluster-info) |
| `kube-node-lease` | Node heartbeat leases |

**Creating namespaces for your homelab:**
```bash
# Create namespaces for organization
kubectl create namespace monitoring    # Prometheus, Grafana, Loki
kubectl create namespace databases     # PostgreSQL, Redis
kubectl create namespace media         # Immich, ARR stack
kubectl create namespace home          # Homepage, AdGuard

# Verify
kubectl get ns
```

**What happens internally:**
```yaml
# This is what gets stored in etcd
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  uid: abc123...
  resourceVersion: "12345"
  creationTimestamp: "2026-01-03T10:00:00Z"
spec:
  finalizers:
  - kubernetes
status:
  phase: Active
```

### 1.3 Labels and Selectors - The Matching System

**Why labels matter:**
- Kubernetes is a **declarative** system
- You describe WHAT you want, not HOW to do it
- Labels are how Kubernetes knows which objects belong together

**Example: How a Service finds its Pods**
```yaml
# This Deployment creates Pods with labels
apiVersion: apps/v1
kind: Deployment
metadata:
  name: immich-server
spec:
  selector:
    matchLabels:
      app: immich           # Deployment manages pods with this label
      component: server
  template:
    metadata:
      labels:
        app: immich         # Pods get these labels
        component: server
        version: v1.123.0
    spec:
      containers:
      - name: immich
        image: ghcr.io/immich-app/immich-server:v1.123.0
---
# This Service routes traffic to those Pods
apiVersion: v1
kind: Service
metadata:
  name: immich-server
spec:
  selector:
    app: immich             # "Find all pods with app=immich"
    component: server       # "AND component=server"
  ports:
  - port: 3001
```

**The matching is evaluated continuously:**
```
Every few seconds:
  1. Service controller asks: "Which pods match my selector?"
  2. Finds pods with app=immich AND component=server
  3. Updates Endpoints object with pod IPs
  4. kube-proxy updates iptables/nftables rules
  5. Traffic flows to correct pods
```

**Useful label queries:**
```bash
# Show labels on all pods
kubectl get pods --show-labels

# Filter by label
kubectl get pods -l app=immich
kubectl get pods -l 'app in (immich, postgres)'
kubectl get pods -l 'app=immich,component!=ml'

# Show specific label as column
kubectl get pods -L app,version
```

### 1.4 Annotations - Metadata That Doesn't Select

**Labels vs Annotations:**
| Feature | Labels | Annotations |
|---------|--------|-------------|
| Used for selection | âœ… Yes | âŒ No |
| Max size | 63 chars | 256KB |
| Purpose | Grouping, filtering | Metadata, config hints |

**Real examples from your homelab:**
```yaml
metadata:
  annotations:
    # For Longhorn - storage hints
    longhorn.io/volume-scheduling-error: ""
    
    # For Ingress - routing config
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "50m"
    
    # For ArgoCD - sync config
    argocd.argoproj.io/sync-wave: "1"
    
    # For documentation
    description: "Immich photo management server"
    owner: "rommel"
```

---

## Module 2: Workloads

### 2.1 Pods - The Atomic Unit

**What is a Pod really?**
- One or more containers that share:
  - Network namespace (same IP, can use localhost)
  - IPC namespace (shared memory)
  - Storage volumes
- The smallest deployable unit in Kubernetes

**Anatomy of a Pod:**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: debug-pod
  namespace: default
spec:
  containers:
  - name: main
    image: nginx:latest
    ports:
    - containerPort: 80
    resources:
      requests:           # "I need at least this much"
        memory: "64Mi"
        cpu: "100m"       # 100 millicores = 0.1 CPU
      limits:             # "Never give me more than this"
        memory: "128Mi"
        cpu: "500m"
    livenessProbe:        # "Is the container alive?"
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 10
    readinessProbe:       # "Can it accept traffic?"
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 5
      periodSeconds: 5
  restartPolicy: Always
```

**Pod lifecycle phases:**
```
Pending â”€â”€â–º Running â”€â”€â–º Succeeded
    â”‚           â”‚
    â”‚           â””â”€â”€â–º Failed
    â”‚
    â””â”€â”€â–º [Stuck: No node available, image pull failed, etc.]
```

**What happens when you create a Pod:**
```bash
kubectl apply -f pod.yaml
```

1. **API Server** receives request, validates, stores in etcd
2. **Scheduler** notices unscheduled pod, picks best node
3. **Kubelet** on chosen node sees assignment
4. **Container Runtime** (containerd) pulls image, creates container
5. **CNI** (Cilium) assigns IP, sets up networking
6. **Probes** start checking health
7. Pod status updated to `Running`

**Debug a pod:**
```bash
# Get pod details
kubectl describe pod <pod-name>

# Check logs
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>  # Multi-container
kubectl logs <pod-name> --previous           # Previous crash

# Execute into pod
kubectl exec -it <pod-name> -- /bin/sh

# Port forward for local testing
kubectl port-forward pod/<pod-name> 8080:80
```

### 2.2 Deployments - Declarative Updates

**Why not just create Pods directly?**
- Pods are mortal - they die and don't come back
- Deployments manage Pod lifecycle:
  - Ensures desired replica count
  - Rolling updates
  - Rollback capability
  - Self-healing

**Deployment â†’ ReplicaSet â†’ Pods hierarchy:**
```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                   Deployment                         â”‚
â”‚  "I want 3 replicas of nginx:1.25"                  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                       â”‚ creates/manages
                       â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                   ReplicaSet                         â”‚
â”‚  "I maintain exactly 3 pods matching my template"   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                       â”‚ creates/manages
         â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¼â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
         â–¼             â–¼             â–¼
    â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”
    â”‚  Pod 1  â”‚   â”‚  Pod 2  â”‚   â”‚  Pod 3  â”‚
    â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜   â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

**Real example - Homepage Dashboard:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: homepage
  namespace: home
spec:
  replicas: 2                    # Run 2 instances for HA
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1                # Can have 3 during update
      maxUnavailable: 0          # Never go below 2
  selector:
    matchLabels:
      app: homepage
  template:
    metadata:
      labels:
        app: homepage
    spec:
      containers:
      - name: homepage
        image: ghcr.io/gethomepage/homepage:latest
        ports:
        - containerPort: 3000
        volumeMounts:
        - name: config
          mountPath: /app/config
      volumes:
      - name: config
        configMap:
          name: homepage-config
```

**Deployment operations:**
```bash
# Create/update
kubectl apply -f deployment.yaml

# Scale
kubectl scale deployment homepage --replicas=3

# Update image (triggers rolling update)
kubectl set image deployment/homepage homepage=ghcr.io/gethomepage/homepage:v0.9.0

# Watch rollout
kubectl rollout status deployment/homepage

# Rollback
kubectl rollout undo deployment/homepage
kubectl rollout undo deployment/homepage --to-revision=2

# View history
kubectl rollout history deployment/homepage
```

### 2.3 StatefulSets - For Databases

**When to use StatefulSet vs Deployment:**

| Feature | Deployment | StatefulSet |
|---------|------------|-------------|
| Pod names | Random (nginx-7b4d5-x2k) | Ordered (postgres-0, postgres-1) |
| Scaling | Parallel | Sequential |
| Storage | Shared or none | Dedicated PVC per pod |
| Network identity | Dynamic | Stable DNS name |
| Use case | Stateless apps | Databases, Kafka, etc. |

**PostgreSQL StatefulSet for Immich:**
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: databases
spec:
  serviceName: postgres          # Required for DNS
  replicas: 1                    # Single instance (HA needs operator)
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_DB
          value: immich
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: username
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: password
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            memory: "256Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "1000m"
  volumeClaimTemplates:          # Creates PVC for each pod
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn
      resources:
        requests:
          storage: 10Gi
---
# Headless service for stable DNS
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: databases
spec:
  clusterIP: None               # Headless!
  selector:
    app: postgres
  ports:
  - port: 5432
```

**What makes StatefulSet special:**

1. **Stable network identity:**
   - Pod: `postgres-0`
   - DNS: `postgres-0.postgres.databases.svc.cluster.local`
   - Even after pod restart, same name and DNS

2. **Stable storage:**
   - PVC: `data-postgres-0` 
   - Pod always gets same PVC, even after reschedule

3. **Ordered operations:**
   - Scale up: 0, then 1, then 2
   - Scale down: 2, then 1, then 0
   - Each pod must be Running before next starts

**Debugging StatefulSet:**
```bash
# Check status
kubectl get statefulset postgres -n databases

# Check PVCs
kubectl get pvc -n databases

# Connect to specific pod
kubectl exec -it postgres-0 -n databases -- psql -U postgres

# Check if DNS works
kubectl run -it --rm debug --image=busybox -- nslookup postgres-0.postgres.databases
```

### 2.4 DaemonSets - One Per Node

**What is a DaemonSet?**
- Ensures one pod runs on every (or selected) node
- When node joins â†’ pod automatically scheduled
- When node leaves â†’ pod removed

**Use cases in your homelab:**
- Node exporters (monitoring)
- Log collectors
- Longhorn storage manager
- Cilium agent

**Example - Node Exporter for Prometheus:**
```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true          # Use node's network
      hostPID: true              # See node's processes
      containers:
      - name: node-exporter
        image: prom/node-exporter:latest
        ports:
        - containerPort: 9100
          hostPort: 9100
        securityContext:
          privileged: true
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
      tolerations:               # Run on control plane too
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
```

**Check DaemonSet status:**
```bash
kubectl get daemonset -n monitoring
# NAME            DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
# node-exporter   3         3         3       3            3
#                 ^ one per node
```

### 2.5 Jobs and CronJobs - Batch Work

**Job - Run to completion:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: database-backup
  namespace: databases
spec:
  ttlSecondsAfterFinished: 3600  # Cleanup after 1 hour
  template:
    spec:
      containers:
      - name: backup
        image: postgres:16
        command:
        - /bin/sh
        - -c
        - |
          pg_dump -h postgres -U $PGUSER -d immich > /backup/immich-$(date +%Y%m%d).sql
          echo "Backup completed"
        env:
        - name: PGUSER
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: username
        - name: PGPASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: password
        volumeMounts:
        - name: backup
          mountPath: /backup
      volumes:
      - name: backup
        nfs:
          server: 10.10.30.4
          path: /export/backups/postgres
      restartPolicy: OnFailure   # Retry on failure
```

**CronJob - Scheduled tasks:**
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: database-backup
  namespace: databases
spec:
  schedule: "0 3 * * *"          # 3 AM daily
  concurrencyPolicy: Forbid      # Don't run if previous still running
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: postgres:16
            # ... same as Job above
          restartPolicy: OnFailure
```

**Monitor jobs:**
```bash
# List jobs
kubectl get jobs -n databases

# List cronjobs
kubectl get cronjobs -n databases

# See job history
kubectl get jobs -n databases --sort-by=.status.startTime

# Manually trigger cronjob
kubectl create job --from=cronjob/database-backup manual-backup -n databases
```

---

## Module 3: Networking

### 3.1 Services - Internal Load Balancing

**The Problem Services Solve:**
- Pods are ephemeral (IPs change)
- Need stable endpoint for communication
- Need load balancing across replicas

**Service Types:**

| Type | Scope | Use Case |
|------|-------|----------|
| `ClusterIP` | Internal only | Default, inter-service communication |
| `NodePort` | External (node IP:port) | Development, testing |
| `LoadBalancer` | External (cloud LB or MetalLB) | Production external access |
| `ExternalName` | DNS alias | Access external services |

**ClusterIP (Default):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-server
  namespace: media
spec:
  type: ClusterIP              # Default, can omit
  selector:
    app: immich
    component: server
  ports:
  - name: http
    port: 3001                 # Service port
    targetPort: 3001           # Container port
```

**What happens:**
```
1. Service gets cluster IP (e.g., 10.96.45.123)
2. DNS entry created: immich-server.media.svc.cluster.local
3. Endpoints object tracks pod IPs
4. kube-proxy creates iptables/nftables rules
5. Traffic to 10.96.45.123:3001 â†’ load balanced to pods
```

**NodePort (External via node IP):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-nodeport
  namespace: media
spec:
  type: NodePort
  selector:
    app: immich
  ports:
  - port: 3001
    targetPort: 3001
    nodePort: 30001            # External port (30000-32767)
```

Access via: `http://10.10.30.11:30001` (any node IP works)

**LoadBalancer (with MetalLB for bare-metal):**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: immich-lb
  namespace: media
  annotations:
    metallb.universe.tf/loadBalancerIPs: 10.10.30.100
spec:
  type: LoadBalancer
  selector:
    app: immich
  ports:
  - port: 80
    targetPort: 3001
```

**Debugging services:**
```bash
# Check service
kubectl get svc -n media
kubectl describe svc immich-server -n media

# Check endpoints (pod IPs)
kubectl get endpoints immich-server -n media

# Test from within cluster
kubectl run -it --rm debug --image=busybox -- wget -qO- http://immich-server.media:3001

# DNS lookup
kubectl run -it --rm debug --image=busybox -- nslookup immich-server.media
```

### 3.2 DNS - Service Discovery

**How DNS works in your cluster:**

```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                    CoreDNS (kube-system)                     â”‚
â”‚  Watches Services â†’ Creates DNS records automatically        â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

Service: immich-server (namespace: media)
Creates these DNS records:

  immich-server.media.svc.cluster.local    â†’ 10.96.45.123 (ClusterIP)
  immich-server.media.svc                  â†’ 10.96.45.123
  immich-server.media                      â†’ 10.96.45.123
  immich-server                            â†’ 10.96.45.123 (if in same namespace)
```

**Pod DNS configuration:**
```bash
# Check pod's DNS config
kubectl exec -it <pod> -- cat /etc/resolv.conf

# Output:
# nameserver 10.96.0.10           â† CoreDNS service IP
# search media.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```

**The `ndots:5` setting:**
- If hostname has fewer than 5 dots, try search domains first
- `immich-server` â†’ tries `immich-server.media.svc.cluster.local`
- This is why short names work within cluster

### 3.3 Ingress - HTTP Routing

**What Ingress does:**
- Layer 7 (HTTP/HTTPS) routing
- Host-based and path-based routing
- TLS termination
- Single entry point for multiple services

**Ingress with your NPM replacement (Traefik or Nginx Ingress):**
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: immich
  namespace: media
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"  # No limit for photos
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  ingressClassName: nginx
  tls:
  - hosts:
    - immich.home.rommelporras.com
    secretName: immich-tls
  rules:
  - host: immich.home.rommelporras.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: immich-server
            port:
              number: 3001
```

**Traffic flow:**
```
External Request: https://immich.home.rommelporras.com/api/upload
         â”‚
         â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚              Ingress Controller (Nginx/Traefik)              â”‚
â”‚  - Terminates TLS                                            â”‚
â”‚  - Matches host: immich.home.rommelporras.com               â”‚
â”‚  - Routes to Service: immich-server:3001                    â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
         â”‚
         â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚    Service      â”‚
â”‚  immich-server  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”˜
         â”‚ Load balances to pods
    â”Œâ”€â”€â”€â”€â”´â”€â”€â”€â”€â”
    â–¼         â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â” â”Œâ”€â”€â”€â”€â”€â”€â”€â”
â”‚ Pod 1 â”‚ â”‚ Pod 2 â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”˜ â””â”€â”€â”€â”€â”€â”€â”€â”˜
```

### 3.4 Network Policies - Firewall Rules

**Why NetworkPolicies matter:**
- By default, all pods can talk to all pods (flat network)
- NetworkPolicies restrict traffic
- **Required for CKA exam**
- Cilium enforces these (Flannel does NOT)

**Default deny all ingress:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: databases
spec:
  podSelector: {}              # Apply to all pods in namespace
  policyTypes:
  - Ingress                    # Block all incoming traffic
```

**Allow specific traffic:**
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-allow-immich
  namespace: databases
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: media          # From media namespace
      podSelector:
        matchLabels:
          app: immich          # Only immich pods
    ports:
    - protocol: TCP
      port: 5432
```

**Common patterns:**
```yaml
# Allow from same namespace only
ingress:
- from:
  - podSelector: {}

# Allow from specific namespace
ingress:
- from:
  - namespaceSelector:
      matchLabels:
        name: monitoring

# Allow from IP range (external)
ingress:
- from:
  - ipBlock:
      cidr: 10.10.20.0/24      # Your TRUSTED_WIFI VLAN
      except:
      - 10.10.20.50/32         # Block specific IP
```

**Test NetworkPolicies:**
```bash
# Create test pods
kubectl run source --image=busybox -n media -- sleep 3600
kubectl run target --image=nginx -n databases

# Test connectivity (should fail after deny policy)
kubectl exec -n media source -- wget -qO- --timeout=2 http://postgres.databases:5432

# Check Cilium policy enforcement
kubectl -n kube-system exec ds/cilium -- cilium policy get
```

---

## Module 4: Storage

### 4.1 Volumes, PVs, and PVCs - The Storage Stack

**The relationship:**
```
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                    Storage Admin                             â”‚
â”‚  Creates PersistentVolumes (actual storage)                  â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                             â”‚
                             â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚               PersistentVolume (PV)                          â”‚
â”‚  "I am 100GB of storage on Longhorn"                        â”‚
â”‚  Cluster-wide resource (not namespaced)                      â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                             â”‚ binds to
                             â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚           PersistentVolumeClaim (PVC)                        â”‚
â”‚  "I want 50GB of storage"                                   â”‚
â”‚  Namespaced - belongs to workload                           â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
                             â”‚ mounted by
                             â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚                         Pod                                  â”‚
â”‚  Mounts PVC as volume                                       â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
```

### 4.2 StorageClasses - Dynamic Provisioning

**Without StorageClass (static provisioning):**
1. Admin manually creates PV
2. User creates PVC
3. Kubernetes matches them

**With StorageClass (dynamic provisioning):**
1. User creates PVC referencing StorageClass
2. StorageClass tells provisioner to create PV automatically
3. Much easier!

**Longhorn StorageClass:**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Delete
volumeBindingMode: Immediate
parameters:
  numberOfReplicas: "3"          # Replicate across 3 nodes
  staleReplicaTimeout: "2880"
  fromBackup: ""
  fsType: "ext4"
```

**Using the StorageClass:**
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: databases
spec:
  accessModes:
  - ReadWriteOnce                # One pod can write
  storageClassName: longhorn     # Use Longhorn
  resources:
    requests:
      storage: 20Gi
```

**What Longhorn does:**
1. Receives PVC request
2. Creates volume on SATA SSDs across nodes
3. Replicates data 3 times (one per node)
4. Creates PV and binds to PVC
5. Pod can now mount the volume

### 4.3 Access Modes

| Mode | Abbrev | Description | Use Case |
|------|--------|-------------|----------|
| ReadWriteOnce | RWO | One node can mount read-write | Databases, single-pod apps |
| ReadOnlyMany | ROX | Many nodes can mount read-only | Shared config, static assets |
| ReadWriteMany | RWX | Many nodes can mount read-write | Shared data (NFS) |
| ReadWriteOncePod | RWOP | One pod can mount read-write | Strict single-writer |

**Longhorn supports:** RWO, RWOP  
**NFS supports:** RWO, ROX, RWX

### 4.4 NFS for Media Storage

**NFS PV for Immich photos (from your Dell 3090):**
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: immich-photos-nfs
spec:
  capacity:
    storage: 1Ti
  accessModes:
  - ReadWriteMany                # Multiple pods can access
  persistentVolumeReclaimPolicy: Retain
  storageClassName: nfs
  nfs:
    server: 10.10.30.4          # Your OMV NAS
    path: /export/photos
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-photos
  namespace: media
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: nfs
  resources:
    requests:
      storage: 1Ti
  volumeName: immich-photos-nfs  # Bind to specific PV
```

**Using in Immich deployment:**
```yaml
spec:
  containers:
  - name: immich
    volumeMounts:
    - name: photos
      mountPath: /usr/src/app/upload
  volumes:
  - name: photos
    persistentVolumeClaim:
      claimName: immich-photos
```

### 4.5 Storage Debugging

```bash
# List storage classes
kubectl get storageclass

# List PVs (cluster-wide)
kubectl get pv

# List PVCs (namespaced)
kubectl get pvc -A

# Describe PVC (shows binding status, events)
kubectl describe pvc postgres-data -n databases

# Check Longhorn volumes
kubectl get volumes.longhorn.io -n longhorn-system

# Longhorn UI (port-forward)
kubectl port-forward svc/longhorn-frontend -n longhorn-system 8080:80
```

**Common issues:**
| Symptom | Cause | Fix |
|---------|-------|-----|
| PVC stuck `Pending` | No matching PV or StorageClass | Check SC exists, PV capacity |
| PVC stuck `Pending` | Node doesn't have storage | Check Longhorn node status |
| Pod stuck `ContainerCreating` | Volume not attached | Check Longhorn volume status |
| Pod `CrashLoopBackOff` | Permission denied on volume | Check fsGroup, runAsUser |

---

## Module 5: Configuration

### 5.1 ConfigMaps - Non-Sensitive Config

**Creating ConfigMaps:**
```bash
# From literal values
kubectl create configmap app-config \
  --from-literal=LOG_LEVEL=info \
  --from-literal=DATABASE_HOST=postgres

# From file
kubectl create configmap nginx-config --from-file=nginx.conf

# From directory
kubectl create configmap app-configs --from-file=./configs/
```

**ConfigMap YAML:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: homepage-config
  namespace: home
data:
  # Simple key-value
  HOMEPAGE_VAR: "value"
  
  # File content
  settings.yaml: |
    providers:
      openweathermap: true
    language: en
  
  services.yaml: |
    - Group:
      - Immich:
          href: https://immich.home.rommelporras.com
          icon: immich.png
```

**Using ConfigMaps in Pods:**

**Method 1: Environment variables**
```yaml
spec:
  containers:
  - name: app
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL
```

**Method 2: All keys as env vars**
```yaml
spec:
  containers:
  - name: app
    envFrom:
    - configMapRef:
        name: app-config
```

**Method 3: Volume mount**
```yaml
spec:
  containers:
  - name: app
    volumeMounts:
    - name: config
      mountPath: /app/config
  volumes:
  - name: config
    configMap:
      name: homepage-config
```

### 5.2 Secrets - Sensitive Data

**âš ï¸ Secrets are NOT encrypted by default!**
- Base64 encoded (NOT encrypted)
- Anyone with API access can read them
- Enable encryption at rest for production

**Creating Secrets:**
```bash
# From literal (recommended - avoids shell history)
kubectl create secret generic postgres-credentials \
  --from-literal=username=immich \
  --from-literal=password='SuperSecretP@ss!'

# From file (for certificates, keys)
kubectl create secret tls immich-tls \
  --cert=tls.crt \
  --key=tls.key

# Docker registry credentials
kubectl create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=rommelporras \
  --docker-password='ghp_xxxxx'
```

**Secret YAML (values must be base64):**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: databases
type: Opaque
data:
  username: aW1taWNo                    # echo -n 'immich' | base64
  password: U3VwZXJTZWNyZXRQQHNzIQ==    # echo -n 'SuperSecretP@ss!' | base64
```

**Using stringData (auto-encodes):**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
type: Opaque
stringData:                    # Plain text, auto-encoded on apply
  username: immich
  password: SuperSecretP@ss!
```

**Using Secrets in Pods:**
```yaml
spec:
  containers:
  - name: postgres
    env:
    - name: POSTGRES_USER
      valueFrom:
        secretKeyRef:
          name: postgres-credentials
          key: username
    - name: POSTGRES_PASSWORD
      valueFrom:
        secretKeyRef:
          name: postgres-credentials
          key: password
```

### 5.3 Resource Requests and Limits

**Why resources matter:**
- **Requests:** Scheduler uses this to find node with capacity
- **Limits:** kubelet enforces maximum (OOM kill if exceeded)

**Quality of Service (QoS) Classes:**
| Class | Condition | Eviction Priority |
|-------|-----------|-------------------|
| Guaranteed | requests == limits for all containers | Last (protected) |
| Burstable | At least one request set, not Guaranteed | Middle |
| BestEffort | No requests or limits | First (most vulnerable) |

**Example with proper resources:**
```yaml
spec:
  containers:
  - name: immich
    resources:
      requests:
        memory: "512Mi"      # Scheduler: "Node needs 512Mi free"
        cpu: "250m"          # 0.25 CPU cores
      limits:
        memory: "2Gi"        # OOM killed if exceeds
        cpu: "2000m"         # Throttled if exceeds (not killed)
```

**Memory vs CPU behavior:**
- **CPU limit exceeded:** Container is throttled (slowed down)
- **Memory limit exceeded:** Container is OOM killed!

**v1.35 In-Place Resize:**
```yaml
spec:
  containers:
  - name: app
    resources:
      requests:
        cpu: "500m"
        memory: "256Mi"
    resizePolicy:
    - resourceName: cpu
      restartPolicy: NotRequired    # CPU changes don't restart
    - resourceName: memory
      restartPolicy: NotRequired    # Try memory change without restart
```

### 5.4 Probes - Health Checks

**Three types of probes:**

| Probe | Purpose | Failure Action |
|-------|---------|----------------|
| livenessProbe | Is container alive? | Restart container |
| readinessProbe | Can it accept traffic? | Remove from Service endpoints |
| startupProbe | Has container started? | Delay liveness checks |

**Complete probe example:**
```yaml
spec:
  containers:
  - name: immich
    ports:
    - containerPort: 3001
    
    startupProbe:                # Wait for app to start
      httpGet:
        path: /api/server-info/ping
        port: 3001
      failureThreshold: 30       # 30 * 10s = 5 minutes to start
      periodSeconds: 10
    
    livenessProbe:               # Is it still alive?
      httpGet:
        path: /api/server-info/ping
        port: 3001
      initialDelaySeconds: 0     # Start after startupProbe succeeds
      periodSeconds: 30
      timeoutSeconds: 5
      failureThreshold: 3        # 3 failures = restart
    
    readinessProbe:              # Can it handle traffic?
      httpGet:
        path: /api/server-info/ping
        port: 3001
      periodSeconds: 10
      failureThreshold: 3
```

**Probe methods:**
```yaml
# HTTP GET
httpGet:
  path: /healthz
  port: 8080
  httpHeaders:
  - name: Custom-Header
    value: Awesome

# TCP Socket (for databases)
tcpSocket:
  port: 5432

# Exec command
exec:
  command:
  - /bin/sh
  - -c
  - pg_isready -U postgres
```

---

## Module 6: Security

### 6.1 Pod Security Standards

**Three security levels:**

| Level | Restrictions | Use Case |
|-------|--------------|----------|
| Privileged | None | System components |
| Baseline | Blocks known exploits | Default for most workloads |
| Restricted | Maximum security | Untrusted workloads |

**Apply at namespace level:**
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: media
  labels:
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

**Modes:**
- `enforce`: Reject pods that violate
- `warn`: Allow but warn
- `audit`: Log violations

### 6.2 Security Contexts

**Pod-level security context:**
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000              # Volume ownership
    seccompProfile:
      type: RuntimeDefault
```

**Container-level security context:**
```yaml
spec:
  containers:
  - name: app
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
        add:
        - NET_BIND_SERVICE     # Only if needed
```

**Restricted profile example (most secure):**
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:latest
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: var-run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: var-run
    emptyDir: {}
```

### 6.3 RBAC - Role-Based Access Control

**RBAC components:**
```
                   Who                    What                    Where
                    â”‚                      â”‚                        â”‚
        â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”´â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”          â”‚                        â”‚
        â–¼                       â–¼          â–¼                        â–¼
â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”    â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”   â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”         â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”
â”‚ ServiceAccountâ”‚    â”‚    User      â”‚   â”‚   Role   â”‚         â”‚ Namespace â”‚
â”‚   (in-cluster)â”‚    â”‚ (kubeconfig) â”‚   â”‚ (rules)  â”‚         â”‚ (scope)   â”‚
â””â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”˜    â””â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”˜   â””â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”˜         â””â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”˜
        â”‚                   â”‚                â”‚                     â”‚
        â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”¬â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜                â”‚                     â”‚
                  â–¼                          â–¼                     â”‚
         â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”          â”Œâ”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”              â”‚
         â”‚   RoleBinding   â”‚â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”‚    Role     â”‚â—„â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜
         â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜          â””â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”˜

  For cluster-wide: ClusterRole + ClusterRoleBinding
```

**Role (namespaced permissions):**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: media
rules:
- apiGroups: [""]              # Core API group
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
```

**RoleBinding (assigns Role to user/SA):**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: media
subjects:
- kind: ServiceAccount
  name: monitoring
  namespace: monitoring
- kind: User
  name: rommel
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

**Check permissions:**
```bash
# Can I do this?
kubectl auth can-i create pods --namespace media
kubectl auth can-i delete pods --namespace media --as=system:serviceaccount:monitoring:default

# What can I do?
kubectl auth can-i --list --namespace media
```

### 6.4 Service Accounts

**Every pod runs as a ServiceAccount:**
```yaml
spec:
  serviceAccountName: my-app    # If not specified, uses "default"
  automountServiceAccountToken: false  # Security: disable if not needed
```

**Create ServiceAccount for app:**
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: immich
  namespace: media
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: immich-role
  namespace: media
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: immich-binding
  namespace: media
subjects:
- kind: ServiceAccount
  name: immich
  namespace: media
roleRef:
  kind: Role
  name: immich-role
  apiGroup: rbac.authorization.k8s.io
```

---

## Module 7: Scheduling

### 7.1 Node Selection

**nodeSelector (simple):**
```yaml
spec:
  nodeSelector:
    kubernetes.io/hostname: k8s-cp1    # Specific node
    # Or custom labels:
    disk: ssd
    zone: rack-1
```

**Node Affinity (advanced):**
```yaml
spec:
  affinity:
    nodeAffinity:
      # MUST be satisfied
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
      # PREFERRED but not required
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
          - key: zone
            operator: In
            values:
            - rack-1
```

### 7.2 Taints and Tolerations

**Taints are on nodes:**
```bash
# Control plane taint (prevents regular pods)
kubectl taint nodes k8s-cp1 node-role.kubernetes.io/control-plane:NoSchedule

# Add custom taint
kubectl taint nodes k8s-cp1 dedicated=database:NoSchedule

# Remove taint
kubectl taint nodes k8s-cp1 dedicated=database:NoSchedule-
```

**Tolerations are on pods:**
```yaml
spec:
  tolerations:
  # Tolerate control plane
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  # Tolerate specific taint
  - key: dedicated
    operator: Equal
    value: database
    effect: NoSchedule
```

**Taint effects:**
| Effect | Behavior |
|--------|----------|
| NoSchedule | Don't schedule new pods (existing stay) |
| PreferNoSchedule | Try to avoid, but allow if needed |
| NoExecute | Evict existing pods without toleration |

### 7.3 Pod Topology Spread

**Spread pods across nodes:**
```yaml
spec:
  topologySpreadConstraints:
  - maxSkew: 1                         # Max difference between zones
    topologyKey: kubernetes.io/hostname # Spread across nodes
    whenUnsatisfiable: DoNotSchedule   # Hard requirement
    labelSelector:
      matchLabels:
        app: immich
```

### 7.4 Pod Anti-Affinity

**Don't schedule on same node:**
```yaml
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: postgres
        topologyKey: kubernetes.io/hostname
```

---

## Module 8: Cluster Operations

### 8.1 Upgrading Clusters

**kubeadm upgrade process:**
```bash
# On first control plane node
sudo apt update
sudo apt-cache madison kubeadm

# Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt install -y kubeadm=1.35.1-1.1
sudo apt-mark hold kubeadm

# Plan upgrade
sudo kubeadm upgrade plan

# Apply upgrade
sudo kubeadm upgrade apply v1.35.1

# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt install -y kubelet=1.35.1-1.1 kubectl=1.35.1-1.1
sudo apt-mark hold kubelet kubectl

# Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

**Upgrade other control plane nodes:**
```bash
sudo kubeadm upgrade node
# Then upgrade kubelet/kubectl same as above
```

**Upgrade worker nodes:**
```bash
# Drain node first
kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data

# On worker node: upgrade kubeadm, kubelet, kubectl
sudo kubeadm upgrade node

# Uncordon
kubectl uncordon k8s-worker1
```

### 8.2 Node Maintenance

**Drain (safe eviction):**
```bash
# Graceful pod eviction
kubectl drain k8s-cp1 --ignore-daemonsets --delete-emptydir-data

# Force (use carefully)
kubectl drain k8s-cp1 --force --grace-period=0
```

**Cordon/Uncordon:**
```bash
# Mark unschedulable (existing pods stay)
kubectl cordon k8s-cp1

# Mark schedulable again
kubectl uncordon k8s-cp1
```

### 8.3 etcd Backup and Restore

**Backup:**
```bash
# On control plane node
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify backup
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-20260103.db --write-out=table
```

**Restore (disaster recovery):**
```bash
# Stop control plane
sudo mv /etc/kubernetes/manifests/*.yaml /tmp/

# Restore snapshot
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-20260103.db \
  --data-dir=/var/lib/etcd-new \
  --name=k8s-cp1 \
  --initial-cluster=k8s-cp1=https://10.10.30.11:2380 \
  --initial-advertise-peer-urls=https://10.10.30.11:2380

# Update etcd manifest to use new data dir
sudo vim /tmp/etcd.yaml
# Change: --data-dir=/var/lib/etcd-new

# Move manifests back
sudo mv /tmp/*.yaml /etc/kubernetes/manifests/
```

### 8.4 Certificate Management

**Check expiration:**
```bash
kubeadm certs check-expiration
```

**Renew certificates:**
```bash
# Renew all
sudo kubeadm certs renew all

# Restart control plane components
sudo crictl pods --name kube-apiserver -q | xargs sudo crictl stopp
sudo crictl pods --name kube-controller-manager -q | xargs sudo crictl stopp
sudo crictl pods --name kube-scheduler -q | xargs sudo crictl stopp
```

---

## Module 9: Troubleshooting

### 9.1 Debugging Pods

**Pod not starting:**
```bash
# Check events
kubectl describe pod <pod-name>

# Common issues:
# - ImagePullBackOff: Wrong image name, no credentials
# - Pending: No node has enough resources
# - CrashLoopBackOff: Container crashes on start
```

**ImagePullBackOff:**
```bash
# Check if image exists
crictl pull <image>

# Check secret for private registry
kubectl get secret ghcr -o yaml
kubectl describe pod <pod> | grep -A5 "Events"
```

**CrashLoopBackOff:**
```bash
# Check logs
kubectl logs <pod> --previous
kubectl logs <pod> -c <container> --previous

# Common causes:
# - Missing env vars
# - Config file errors
# - Dependency not ready
```

**Pending pod:**
```bash
# Check scheduler events
kubectl describe pod <pod> | grep -A10 "Events"

# Check node resources
kubectl describe nodes | grep -A5 "Allocated resources"

# Common causes:
# - Insufficient CPU/memory
# - No matching node for nodeSelector
# - PVC not bound
```

### 9.2 Debugging Services

**Service not routing:**
```bash
# Check endpoints exist
kubectl get endpoints <service>

# If empty: selector doesn't match any pods
kubectl get pods -l <selector-from-service>

# Test from inside cluster
kubectl run -it --rm debug --image=busybox -- wget -qO- http://<service>:<port>
```

### 9.3 Debugging Nodes

**Node not ready:**
```bash
# Check node status
kubectl describe node <node>

# SSH to node and check kubelet
sudo journalctl -xeu kubelet -f

# Check container runtime
sudo crictl ps -a
sudo crictl logs <container-id>

# Common causes:
# - Disk pressure
# - Memory pressure
# - Network issues
# - Container runtime down
```

### 9.4 Debugging Network

**DNS not working:**
```bash
# Test CoreDNS
kubectl run -it --rm debug --image=busybox -- nslookup kubernetes.default

# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

**Pods can't communicate:**
```bash
# Check NetworkPolicies
kubectl get networkpolicy -A

# Check Cilium status
kubectl -n kube-system exec ds/cilium -- cilium status
kubectl -n kube-system exec ds/cilium -- cilium endpoint list
```

### 9.5 Quick Diagnostic Commands

```bash
# Overall cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running
kubectl get events --sort-by='.lastTimestamp' -A | tail -20

# Resource pressure
kubectl top nodes
kubectl top pods -A --sort-by=memory

# Component status
kubectl get componentstatuses  # Deprecated but works
kubectl get --raw='/healthz?verbose'

# API server health
kubectl get --raw='/livez?verbose'
kubectl get --raw='/readyz?verbose'
```

---

## Module 10: CKA New Topics (2025)

### 10.1 Helm Basics

**What Helm does:**
- Package manager for Kubernetes
- Charts = packaged applications
- Values = configuration

**Basic commands:**
```bash
# Add repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Search charts
helm search repo prometheus

# Install chart
helm install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --create-namespace \
  --set server.persistentVolume.size=10Gi

# List releases
helm list -A

# Upgrade
helm upgrade prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --set server.persistentVolume.size=20Gi

# Rollback
helm rollback prometheus 1 -n monitoring

# Uninstall
helm uninstall prometheus -n monitoring
```

**Custom values file:**
```yaml
# values-custom.yaml
server:
  persistentVolume:
    size: 20Gi
    storageClass: longhorn
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
```

```bash
helm install prometheus prometheus-community/prometheus \
  -f values-custom.yaml \
  -n monitoring
```

### 10.2 Kustomize Basics

**What Kustomize does:**
- Template-free customization
- Overlay-based (base + patches)
- Built into kubectl

**Directory structure:**
```
â”œâ”€â”€ base/
â”‚   â”œâ”€â”€ kustomization.yaml
â”‚   â”œâ”€â”€ deployment.yaml
â”‚   â””â”€â”€ service.yaml
â””â”€â”€ overlays/
    â”œâ”€â”€ dev/
    â”‚   â””â”€â”€ kustomization.yaml
    â””â”€â”€ prod/
        â””â”€â”€ kustomization.yaml
```

**Base kustomization.yaml:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- deployment.yaml
- service.yaml
commonLabels:
  app: myapp
```

**Prod overlay:**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- ../../base
namePrefix: prod-
namespace: production
replicas:
- name: myapp
  count: 3
patches:
- target:
    kind: Deployment
    name: myapp
  patch: |
    - op: replace
      path: /spec/template/spec/containers/0/resources/requests/memory
      value: 512Mi
```

**Using Kustomize:**
```bash
# Preview
kubectl kustomize overlays/prod/

# Apply
kubectl apply -k overlays/prod/
```

### 10.3 Gateway API

**Why Gateway API:**
- Replacement for Ingress
- More expressive routing
- Role-oriented (infra vs app teams)

**Components:**
```
GatewayClass (infra admin)
     â”‚
     â–¼
  Gateway (cluster operator)
     â”‚
     â–¼
 HTTPRoute (app developer)
     â”‚
     â–¼
  Service â†’ Pods
```

**Example:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: homelab-gateway
  namespace: gateway-system
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    port: 80
    protocol: HTTP
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: immich-route
  namespace: media
spec:
  parentRefs:
  - name: homelab-gateway
    namespace: gateway-system
  hostnames:
  - immich.home.rommelporras.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: immich-server
      port: 3001
```

### 10.4 Horizontal Pod Autoscaler (HPA)

**HPA basics:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: immich-hpa
  namespace: media
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: immich-server
  minReplicas: 2
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # Wait 5 min before scaling down
```

**Check HPA status:**
```bash
kubectl get hpa -A
kubectl describe hpa immich-hpa -n media
```

### 10.5 Custom Resource Definitions (CRDs)

**What CRDs do:**
- Extend Kubernetes API
- Add new resource types
- Used by operators

**Example CRD:**
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: backups.homelab.rommelporras.com
spec:
  group: homelab.rommelporras.com
  versions:
  - name: v1
    served: true
    storage: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              schedule:
                type: string
              retention:
                type: integer
  scope: Namespaced
  names:
    plural: backups
    singular: backup
    kind: Backup
    shortNames:
    - bk
```

**Using the CRD:**
```yaml
apiVersion: homelab.rommelporras.com/v1
kind: Backup
metadata:
  name: postgres-backup
spec:
  schedule: "0 3 * * *"
  retention: 7
```

---

## Practical Exercises

### Exercise 1: Deploy a Complete Application

**Goal:** Deploy Immich with PostgreSQL, Redis, and proper storage

```bash
# Create namespace
kubectl create namespace media

# Apply Pod Security Standards
kubectl label namespace media pod-security.kubernetes.io/enforce=baseline

# Create secrets
kubectl create secret generic postgres-credentials \
  --from-literal=username=immich \
  --from-literal=password='YourSecurePassword!' \
  -n media

# Deploy PostgreSQL (StatefulSet)
kubectl apply -f postgres-statefulset.yaml

# Deploy Redis
kubectl apply -f redis-deployment.yaml

# Deploy Immich
kubectl apply -f immich-deployment.yaml

# Create services
kubectl apply -f services.yaml

# Create ingress
kubectl apply -f ingress.yaml

# Verify
kubectl get all -n media
kubectl get pvc -n media
```

### Exercise 2: Implement Network Policies

**Goal:** Secure database access

```bash
# Default deny in databases namespace
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: databases
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF

# Allow Immich to access PostgreSQL
# Allow PostgreSQL to access DNS

# Test: Try to access from wrong namespace (should fail)
kubectl run -it --rm test --image=busybox -n default -- nc -zv postgres.databases 5432
```

### Exercise 3: Perform Rolling Update

**Goal:** Update Immich with zero downtime

```bash
# Current version
kubectl get deployment immich-server -n media -o jsonpath='{.spec.template.spec.containers[0].image}'

# Update to new version
kubectl set image deployment/immich-server immich=ghcr.io/immich-app/immich-server:v1.124.0 -n media

# Watch rollout
kubectl rollout status deployment/immich-server -n media

# If issues, rollback
kubectl rollout undo deployment/immich-server -n media
```

### Exercise 4: Backup and Restore etcd

**Goal:** Practice disaster recovery

```bash
# Create test data
kubectl create configmap test-config --from-literal=key=value

# Backup etcd
sudo etcdctl snapshot save /tmp/etcd-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Delete test data
kubectl delete configmap test-config

# Restore (follow full restore procedure)
# ...

# Verify data is back
kubectl get configmap test-config
```

---

## Common Mistakes & Fixes

### Mistake 1: Forgetting namespace

```bash
# Wrong
kubectl get pods  # Only shows default namespace

# Right
kubectl get pods -A               # All namespaces
kubectl get pods -n media         # Specific namespace
kubectl config set-context --current --namespace=media  # Set default
```

### Mistake 2: Wrong label selector

```yaml
# Service selector doesn't match deployment labels
# Service:
selector:
  app: immich-server    # Wrong

# Deployment labels:
labels:
  app: immich           # Right
```

### Mistake 3: Resource requests too high

```yaml
# Pod stuck pending because no node has 100Gi RAM
resources:
  requests:
    memory: "100Gi"    # Way too much

# Fix: Right-size based on actual needs
resources:
  requests:
    memory: "256Mi"
```

### Mistake 4: ReadOnlyRootFilesystem without tmpfs

```yaml
# Container needs to write to /tmp but root is read-only
securityContext:
  readOnlyRootFilesystem: true

# Fix: Add emptyDir for writable paths
volumes:
- name: tmp
  emptyDir: {}
volumeMounts:
- name: tmp
  mountPath: /tmp
```

### Mistake 5: Missing imagePullSecrets

```bash
# ImagePullBackOff for private registry

# Fix: Create secret and reference it
kubectl create secret docker-registry ghcr \
  --docker-server=ghcr.io \
  --docker-username=rommelporras \
  --docker-password='ghp_xxx'

# In pod spec:
spec:
  imagePullSecrets:
  - name: ghcr
```

---

## Quick Reference Card

### Most Used Commands

```bash
# Create/Apply
kubectl apply -f file.yaml
kubectl create deployment NAME --image=IMAGE

# Get/List
kubectl get pods,svc,deploy -A
kubectl get events --sort-by=.lastTimestamp

# Describe/Logs
kubectl describe pod NAME
kubectl logs NAME -f

# Debug
kubectl exec -it NAME -- /bin/sh
kubectl port-forward svc/NAME 8080:80

# Edit/Patch
kubectl edit deployment NAME
kubectl patch deployment NAME -p '{"spec":{"replicas":3}}'

# Delete
kubectl delete pod NAME
kubectl delete -f file.yaml
```

### CKA Exam Tips

1. **Use kubectl explain:** `kubectl explain pod.spec.containers`
2. **Use --dry-run:** `kubectl run nginx --image=nginx --dry-run=client -o yaml`
3. **Bookmark docs:** kubernetes.io/docs is allowed
4. **Practice imperative commands:** Faster than writing YAML
5. **Master ETCDCTL:** Backup/restore is guaranteed

---

## Document History

| Date | Change |
|------|--------|
| 2026-01-03 | Initial creation as interactive learning companion |
