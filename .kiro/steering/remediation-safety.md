# Remediation Safety

## Remediation tiers

### AUTO - no confirmation required (read-only)
- `kubectl get`, `describe`, `top`, `events`, `explain`
- `kubectl logs` (admin kubeconfig required)
- `helm list`, `helm status`, `helm get`
- `curl` the Prometheus/Alertmanager alert APIs
- `jq`, `grep`, `awk` parsing of above output

### CONFIRM - ask user before each action (GitOps-safe live changes)
- `kubectl delete pod <name>` - restarts a single pod
- `kubectl delete job <name>` - clears a completed or stuck Job
- `kubectl delete lease <name>` - forces leader re-election
- `kubectl rollout restart deployment|statefulset|daemonset`
- `kubectl annotate application ... argocd.argoproj.io/refresh=hard` - forces ArgoCD refresh
- ArgoCD `app sync <app> --core` for manual-sync apps (gitlab, cilium)

### NEVER - hook-blocked, no exceptions
- `kubectl delete pvc` or `kubectl delete statefulset` (without `--cascade=orphan`)
- `helm uninstall`
- `kubectl delete --all` (any resource type)
- `kubeadm reset`
- `kubectl get secret -o ...` or `kubectl describe secret` (reads secret values)
- Bare `kubectl` or `helm` (hits work AWS EKS cluster)
- `git add`, `git commit`, `git push`, `git tag` (orchestrator handles git)
- `rm -rf`

## Longhorn PVC safety

- **Never delete a PVC to fix a mount error.** Mount failures are node-level (multipathd,
  CSI plugin, stale iSCSI session), not volume-level. Deleting a PVC destroys the Longhorn
  volume and all replicas permanently.
- Take a Longhorn snapshot (via UI or manifest) before any destructive storage operation.
- **OOMKilled container + RWO volume = mount deadlock:** a container OOMKilled inside a
  still-Running pod causes kubelet to retry the PVC stage, which Longhorn rejects because
  the pod is already the mount owner. Pod shows Running but 0/1 AVAILABLE. Fix: delete the
  POD (not the PVC). The ReplicaSet creates a fresh pod; Longhorn cleanly detaches and
  reattaches.

## Golden rules

1. Make the smallest change that could fix the problem.
2. Change one thing, then re-check before doing anything else.
3. Write down every state-changing command you ran so it can be reconciled back to Git.
4. Prefer deleting a pod over deleting a lease. Prefer deleting a lease over restarting a
   DaemonSet. Prefer restarting before rebooting.
