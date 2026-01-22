# Phase 6: CKA Certification

> **Status:** ⬜ Planned
> **Target:** September 2026 (Exam Date)
> **Prerequisite:** Phases 1-5 complete (hands-on experience gained)

> **Goal:** Pass the Certified Kubernetes Administrator (CKA) exam
>
> **Exam Format:**
> - Duration: 2 hours
> - Format: Performance-based (hands-on tasks in live cluster)
> - Passing Score: 66%
> - Open book: kubernetes.io/docs allowed

---

## CKA Exam Domains (2025 Curriculum)

| Domain | Weight | Your Homelab Experience |
|--------|--------|------------------------|
| **Cluster Architecture** | 25% | Phase 2 (kubeadm bootstrap) |
| **Workloads & Scheduling** | 15% | Phase 4 (deployments, affinity) |
| **Services & Networking** | 20% | Phase 3-4 (Services, Gateway API) |
| **Storage** | 10% | Phase 3 (Longhorn, PV/PVC) |
| **Troubleshooting** | 30% | All phases (real problems) |

---

## 6.1 Study Resources

### Primary Resources

- [ ] 6.1.1 Enroll in courses
  ```
  □ Mumshad Mannambeth - CKA with Practice Tests (Udemy)
    https://www.udemy.com/course/certified-kubernetes-administrator-with-practice-tests/

  □ KodeKloud CKA Labs (included with above)
    https://kodekloud.com/
  ```

- [ ] 6.1.2 Bookmark official documentation
  ```
  Primary (allowed in exam):
  □ https://kubernetes.io/docs/
  □ https://kubernetes.io/docs/reference/kubectl/cheatsheet/

  Study guides:
  □ https://github.com/cncf/curriculum (official curriculum)
  □ https://kubernetes.io/docs/reference/kubectl/quick-reference/
  ```

- [ ] 6.1.3 Set up practice environment
  ```bash
  # Your homelab IS your practice environment!
  # Additional options for isolated testing:

  # Local clusters (quick experiments)
  kind create cluster --name cka-practice

  # Reset and rebuild for practice
  # (use kubeadm reset on homelab VMs)
  ```

---

## 6.2 Domain 1: Cluster Architecture (25%)

### What You Need to Know

| Topic | Practice In |
|-------|-------------|
| kubeadm cluster lifecycle | Phase 2, rebuild practice |
| RBAC (Roles, ClusterRoles) | Phase 5.2 |
| etcd backup/restore | 6.2.3 below |
| Upgrade cluster version | 6.2.2 below |

- [ ] 6.2.1 Review kubeadm commands
  ```bash
  # Commands you MUST know for exam:
  kubeadm init --help
  kubeadm join --help
  kubeadm token create --print-join-command
  kubeadm upgrade plan
  kubeadm upgrade apply
  ```

- [ ] 6.2.2 Practice kubeadm upgrade
  ```bash
  # On test VM or kind cluster, practice:
  # 1. Check current version
  kubectl version
  kubeadm version

  # 2. Plan upgrade
  kubeadm upgrade plan

  # 3. Upgrade control plane
  kubeadm upgrade apply v1.XX.Y

  # 4. Upgrade kubelet
  apt-mark unhold kubelet kubectl
  apt-get update && apt-get install -y kubelet=1.XX.Y-* kubectl=1.XX.Y-*
  apt-mark hold kubelet kubectl
  systemctl daemon-reload
  systemctl restart kubelet
  ```

- [ ] 6.2.3 **CRITICAL: Practice etcd backup/restore**
  ```bash
  # This is GUARANTEED on the exam!

  # Backup etcd
  ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup.db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key

  # Verify backup
  ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-backup.db

  # Restore etcd (practice on test cluster!)
  ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
    --data-dir=/var/lib/etcd-restored
  ```

- [ ] 6.2.4 Practice RBAC
  ```bash
  # Create ServiceAccount
  kubectl create serviceaccount deploy-bot -n default

  # Create Role (namespace-scoped)
  kubectl create role deploy-role \
    --verb=get,list,create,update \
    --resource=deployments \
    -n default

  # Bind Role to ServiceAccount
  kubectl create rolebinding deploy-binding \
    --role=deploy-role \
    --serviceaccount=default:deploy-bot \
    -n default

  # Test permissions
  kubectl auth can-i create deployments -n default \
    --as=system:serviceaccount:default:deploy-bot
  ```

---

## 6.3 Domain 2: Workloads & Scheduling (15%)

### What You Need to Know

| Topic | Practice In |
|-------|-------------|
| Deployments, ReplicaSets | Phase 4 apps |
| DaemonSets | node-exporter (Phase 3) |
| Static Pods | kubeadm components |
| Node affinity/taints | Phase 4.5 (anti-affinity) |

- [ ] 6.3.1 Master imperative commands
  ```bash
  # Fast creation (exam is timed!)

  # Deployment
  kubectl create deployment nginx --image=nginx --replicas=3

  # Expose as Service
  kubectl expose deployment nginx --port=80 --type=NodePort

  # Scale
  kubectl scale deployment nginx --replicas=5

  # Update image
  kubectl set image deployment/nginx nginx=nginx:1.19

  # Rollback
  kubectl rollout undo deployment/nginx
  kubectl rollout history deployment/nginx
  ```

- [ ] 6.3.2 Practice scheduling concepts
  ```bash
  # Node selector
  kubectl label node k8s-cp1 disktype=ssd
  # Then use nodeSelector in pod spec

  # Taints and tolerations
  kubectl taint nodes k8s-cp1 key=value:NoSchedule
  # Pod needs toleration to schedule there

  # Cordon/drain for maintenance
  kubectl cordon k8s-cp1
  kubectl drain k8s-cp1 --ignore-daemonsets --delete-emptydir-data
  kubectl uncordon k8s-cp1
  ```

- [ ] 6.3.3 Understand static pods
  ```bash
  # Static pods are managed by kubelet, not API server
  # Located in: /etc/kubernetes/manifests/

  # Create static pod
  ssh k8s-cp1 "cat > /etc/kubernetes/manifests/static-nginx.yaml << EOF
  apiVersion: v1
  kind: Pod
  metadata:
    name: static-nginx
  spec:
    containers:
    - name: nginx
      image: nginx
  EOF"

  # Pod appears automatically
  kubectl get pods | grep static-nginx
  ```

---

## 6.4 Domain 3: Services & Networking (20%)

### What You Need to Know

| Topic | Practice In |
|-------|-------------|
| Service types (ClusterIP, NodePort, LB) | All phases |
| NetworkPolicy | Phase 5.1 |
| DNS (CoreDNS) | Phase 4 (service discovery) |
| Ingress | Phase 4.9 (Tailscale) |

- [ ] 6.4.1 Practice Service creation
  ```bash
  # ClusterIP (default)
  kubectl expose deployment nginx --port=80

  # NodePort
  kubectl expose deployment nginx --port=80 --type=NodePort

  # Verify DNS resolution
  kubectl run test --rm -it --image=busybox -- nslookup nginx.default.svc.cluster.local
  ```

- [ ] 6.4.2 Practice NetworkPolicy
  ```bash
  # Default deny all ingress
  kubectl apply -f - <<EOF
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: default-deny
  spec:
    podSelector: {}
    policyTypes:
    - Ingress
  EOF

  # Allow specific traffic
  kubectl apply -f - <<EOF
  apiVersion: networking.k8s.io/v1
  kind: NetworkPolicy
  metadata:
    name: allow-nginx
  spec:
    podSelector:
      matchLabels:
        app: nginx
    ingress:
    - from:
      - podSelector:
          matchLabels:
            access: "true"
      ports:
      - port: 80
  EOF
  ```

- [ ] 6.4.3 Troubleshoot DNS
  ```bash
  # Check CoreDNS pods
  kubectl get pods -n kube-system -l k8s-app=kube-dns

  # Test DNS from pod
  kubectl run test --rm -it --image=busybox -- nslookup kubernetes.default

  # Check CoreDNS logs
  kubectl logs -n kube-system -l k8s-app=kube-dns
  ```

---

## 6.5 Domain 4: Storage (10%)

### What You Need to Know

| Topic | Practice In |
|-------|-------------|
| PV/PVC lifecycle | Phase 3 (Longhorn) |
| StorageClass | Phase 3 |
| Volume modes (RWO, RWX) | Phase 4.8 (PostgreSQL) |

- [ ] 6.5.1 Practice PV/PVC
  ```bash
  # Create PV (hostPath for exam)
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: PersistentVolume
  metadata:
    name: pv-exam
  spec:
    capacity:
      storage: 1Gi
    accessModes:
      - ReadWriteOnce
    hostPath:
      path: /data/pv-exam
  EOF

  # Create PVC
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: pvc-exam
  spec:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 1Gi
  EOF

  # Use in pod
  # volumeMounts + volumes in pod spec
  ```

- [ ] 6.5.2 Understand StorageClass
  ```bash
  # List StorageClasses
  kubectl get storageclass

  # Your homelab has "longhorn" as default
  # Exam may have different classes

  # Create PVC with specific StorageClass
  kubectl apply -f - <<EOF
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata:
    name: dynamic-pvc
  spec:
    storageClassName: longhorn
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
  EOF
  ```

---

## 6.6 Domain 5: Troubleshooting (30%)

### This is the biggest domain - practice debugging!

- [ ] 6.6.1 Master `kubectl describe`
  ```bash
  # ALWAYS check events first
  kubectl describe pod <pod-name>
  kubectl describe node <node-name>
  kubectl describe pvc <pvc-name>

  # Look for:
  # - Events section (errors, warnings)
  # - Conditions (Ready, Scheduled, etc.)
  # - Container state (Waiting, Running, Terminated)
  ```

- [ ] 6.6.2 Master log analysis
  ```bash
  # Pod logs
  kubectl logs <pod-name>
  kubectl logs <pod-name> -c <container-name>  # multi-container
  kubectl logs <pod-name> --previous  # crashed container

  # System component logs
  kubectl logs -n kube-system kube-apiserver-<node>
  kubectl logs -n kube-system kube-controller-manager-<node>
  kubectl logs -n kube-system kube-scheduler-<node>

  # Or via journalctl on nodes
  journalctl -u kubelet -f
  ```

- [ ] 6.6.3 Common troubleshooting scenarios
  ```bash
  # Pod stuck in Pending
  kubectl describe pod <name>  # Check events
  # Causes: insufficient resources, node selector, taints

  # Pod stuck in CrashLoopBackOff
  kubectl logs <pod> --previous  # Check why it crashed
  # Causes: bad command, missing config, health check failing

  # Service not accessible
  kubectl get endpoints <service>  # Check if pods are selected
  kubectl get pods -l <service-selector>  # Verify labels match

  # PVC stuck in Pending
  kubectl describe pvc <name>  # Check events
  kubectl get pv  # Check if matching PV exists
  # Causes: no matching PV, wrong StorageClass
  ```

- [ ] 6.6.4 Practice node troubleshooting
  ```bash
  # Node NotReady
  kubectl describe node <node>  # Check conditions
  ssh <node> systemctl status kubelet
  ssh <node> journalctl -u kubelet -f

  # Check static pods on node
  ssh <node> ls /etc/kubernetes/manifests/

  # Restart kubelet
  ssh <node> systemctl restart kubelet
  ```

---

## 6.7 Exam Preparation Timeline

### Months Before Exam

- [ ] 6.7.1 Month 1-2: Complete Udemy course
  ```
  □ Watch all videos
  □ Complete all KodeKloud labs
  □ Take notes on weak areas
  ```

- [ ] 6.7.2 Month 3: Practice, practice, practice
  ```
  □ Redo all labs without hints
  □ Practice in homelab with real scenarios
  □ Time yourself (2 hours for full exam)
  ```

- [ ] 6.7.3 Month 4: Final preparation
  ```
  □ killer.sh practice exam #1
  □ Review weak areas
  □ killer.sh practice exam #2
  □ Schedule real exam
  ```

### Week Before Exam

- [ ] 6.7.4 Final checklist
  ```
  □ Review kubectl cheatsheet
  □ Practice vim/nano basics
  □ Set up exam environment (quiet room, webcam, ID)
  □ Get good sleep!
  ```

---

## 6.8 Exam Day Tips

### Speed Tips

```bash
# Use aliases (allowed in exam)
alias k=kubectl
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kd='kubectl describe'

# Use kubectl completion
source <(kubectl completion bash)

# Use --dry-run=client -o yaml for templates
kubectl create deployment nginx --image=nginx --dry-run=client -o yaml > nginx.yaml

# Use kubectl explain for documentation
kubectl explain pod.spec.containers
kubectl explain deployment.spec.strategy
```

### Time Management

```
- 2 hours, ~17 questions
- ~7 minutes per question average
- Flag difficult questions, come back later
- Don't get stuck - partial credit exists
```

### Documentation Navigation

```
Bookmark these pages:
- kubectl cheatsheet
- PV/PVC examples
- NetworkPolicy examples
- RBAC examples
- kubeadm commands
```

---

## Verification Checklist

- [ ] Completed Udemy CKA course
- [ ] Completed all KodeKloud labs
- [ ] Can perform etcd backup/restore from memory
- [ ] Can create RBAC resources without documentation
- [ ] Can troubleshoot pod/node issues quickly
- [ ] killer.sh practice exam #1: score > 70%
- [ ] killer.sh practice exam #2: score > 80%
- [ ] Exam scheduled

---

## Final: After Passing

- [ ] Update LinkedIn with CKA certification
- [ ] Add to resume
- [ ] Celebrate! 🎉

- [ ] Update docs/reference/CHANGELOG.md
  ```
  ## Phase 6: CKA Certification
  **Date:** YYYY-MM-DD
  **Result:** PASSED ✅
  **Score:** XX%

  ### Key Lessons
  - What helped most in preparation
  - What to do differently next time
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-6-cka.md docs/todo/completed/
  ```
