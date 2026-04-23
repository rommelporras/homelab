# CLAUDE.md

Kubernetes homelab for CKA prep. 3-node HA cluster (kubeadm, Cilium CNI, Longhorn storage, kube-vip ARP) on Ubuntu 24.04 LTS.

## Source of Truth

**docs/context/Cluster.md** has all canonical values (IPs, MACs, hostnames, hardware). Don't duplicate — reference it.

| When you need... | Read... |
|------------------|---------|
| IPs, MACs, hardware specs | docs/context/Cluster.md |
| Component versions | VERSIONS.md |
| Architecture decisions | docs/context/Architecture.md |
| Network/switch setup | docs/context/Networking.md |
| Storage setup | docs/context/Storage.md |
| Backup schedules, restore, off-site | docs/context/Backups.md |
| Gateway, HTTPRoutes, TLS | docs/context/Gateway.md |
| Cloudflare, GA4, SMTP | docs/context/ExternalServices.md |
| 1Password items | docs/context/Secrets.md |
| Prometheus, Grafana, alerts | docs/context/Monitoring.md |
| PSS, ESO hardening, SA tokens | docs/context/Security.md |
| UPS, graceful shutdown | docs/context/UPS.md |
| Commands, rules, repo layout | docs/context/Conventions.md |
| Upgrade/rollback procedures | docs/context/Upgrades.md |
| Phase plans | docs/todo/ (active) or docs/todo/completed/ (done) |
| Decision history | docs/reference/CHANGELOG.md |
| Rebuild from scratch | docs/rebuild/ (one guide per release) |

## Architecture

- **3 nodes** — etcd quorum minimum
- **Longhorn on NVMe** — 2x replication, no extra hardware
- **kube-vip (ARP)** — VIP without OPNsense changes
- **Cilium CNI** — NetworkPolicy for CKA
- **kubeadm** — CKA exam alignment

## GitOps (ArgoCD)

All services are managed declaratively via ArgoCD. Changes flow through Git, not `kubectl apply` or `helm upgrade`.

- **Adding a service:** create manifests in `manifests/<service>/`, create Application YAML in `manifests/argocd/apps/<service>.yaml`, push to main. Root app-of-apps auto-discovers it.
- **Modifying a service:** edit manifests or Helm values in Git, push. ArgoCD auto-syncs within 3 minutes.
- **Never `kubectl apply` managed resources** - ArgoCD selfHeal reverts manual changes. All changes go through Git.
- **Never `helm upgrade` handed-over releases** - only `cilium` is still Helm-managed (manual-sync via ArgoCD). All others are ArgoCD-managed.
- **Helm-to-ArgoCD handover:** use Secret deletion (`kubectl delete secrets -n <ns> -l name=<release>,owner=helm`), NEVER `helm uninstall` (deletes resources, causes outages).
- **AppProjects (6 custom):** `infrastructure` (platform), `homelab-apps` (general), `arr-stack` (media), `gitlab`, `cicd-apps`, `argocd-self`. Each restricts namespaces and cluster-scoped resources. ArgoCD's built-in `default` AppProject also exists but is unused - all Applications reference one of the six above.
- **Still on Helm (1):** `cilium` (CNI chicken-and-egg deadlock). Prometheus handed over via ESO configSecret + ArgoCD.
- **ArgoCD Application patterns:** Git-type (directory source), Helm multi-source ($values ref), Kustomize (auto-detected from kustomization.yaml).

## Conventions

- **Phase files:** 1 service = 1 phase in `docs/todo/`. Done phases move to `docs/todo/completed/`.
- **Infra + docs = 2 commits:** Infrastructure first (`/audit-security` → `/commit`), then docs (`/audit-docs` → `/commit`).
- **No direct git/gh commands** - never run `git add`, `git commit`, `git tag`, `git push`, `gh release create`, or `gh release delete` outside of `/commit` or `/ship`. These slash commands exist to enforce format, confirmation gates, and secret scanning. Running git/gh directly bypasses all of that.
- **No em dashes** — use regular hyphens (`-`) in commit messages, release titles, and documentation. Em dashes (`—`) are an AI writing signal. Write: `infra: phase 5.2 - etcd encryption` not `infra: phase 5.2 — etcd encryption`.
- **Observability for every service:** alerts in `manifests/monitoring/alerts/`, dashboards in `manifests/monitoring/dashboards/`, probes in `manifests/monitoring/probes/`.
- **Timezone:** `Asia/Manila` everywhere — never UTC or America/Chicago.
- **Grafana dashboards:** Pod Status row → Network Traffic row → Resource Usage row (CPU/Memory with dashed request/limit lines). Descriptions on every panel and row. ConfigMap: `grafana_dashboard: "1"` label, `grafana_folder: "Homelab"` annotation.

## Secrets

- **1Password vault:** `Kubernetes` only. Format: `op://Kubernetes/<item>/<field>`. Full inventory: `docs/context/Secrets.md`.
- **1Password plan is FAMILY** — Connect is NOT available (requires Business/Teams).
- **Never run `op` commands** — this terminal has no `op` access. Includes `op read`, `op item create/edit`.
- **Never write or read secret values** — no `kubectl create secret` with literal values, no `kubectl get secret -o json/yaml`, no `kubectl describe secret`. Values would flow through Anthropic's servers. To check existence: `kubectl-homelab get secret <name> -n <ns>` (no `-o json`). Note: `kubectl-homelab` RBAC blocks `get` on secrets — enforcement is technical, not just policy.
- **Safe automation pattern:** generate scripts with `op://` references, user runs in safe terminal. Never design workflows where Claude sees credential values.

## Rules

- **Use `kubectl-homelab` and `helm-homelab`** — plain `kubectl`/`helm` connect to work AWS EKS.
  - `kubectl-homelab` → `~/.kube/homelab-claude.yaml` (restricted: read-only, no secret `get`)
  - `kubectl-admin` → `~/.kube/homelab.yaml` (full cluster-admin — use only when write access needed)
  - `helm-homelab` → uses `~/.kube/homelab.yaml` (Helm needs admin access for installs/upgrades)
- **`kubectl-homelab` is zsh-only** — scripts that need admin access must use `kubectl --kubeconfig ~/.kube/homelab.yaml`.
- **`argocd` CLI via controller pod `--core` mode** — the `argocd-application-controller` image ships the `argocd` binary. From inside that pod, `argocd <cmd> --core` uses the in-cluster kubeconfig directly — no login, no token, no port-forward. Essential for `terminate-op`, `sync --force`, and debugging stuck apps when the UI is unresponsive. Example: `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app terminate-op gitlab --core`.
- **Verify container images before deploying** — check the registry for the exact tag. Many images drop version tags without notice.
- **PUBLIC repository** — security review before every commit. Once pushed, secrets cannot be revoked.
- **GitHub is the primary remote for this repo** — ArgoCD syncs from GitHub. Self-hosted GitLab hosts invoicetron/portfolio CI/CD. Use `glab` CLI with `--hostname gitlab.k8s.rommelporras.com` for GitLab API calls.

## NAS Access

- **SSH user:** `wawashi` (not `admin`). Hostname: `omv.home.rommelporras.com` (10.10.30.4).
- **No direct SSH from WSL** — SSH to a k8s node first (`ssh wawashi@10.10.30.11`), then NFS mount from there.
- **Create NFS directories via mount:** `sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && sudo mkdir -p /tmp/nfs/<path> && sudo umount /tmp/nfs`
- **No SSH keys from k8s nodes to NAS** — use NFS mount approach, not `ssh wawashi@10.10.30.4`.

## Longhorn PVC Safety

- **NEVER delete a PVC to fix mount errors** — mount failures are almost always node-level (multipathd, CSI plugin, stale mount). Deleting a PVC destroys the Longhorn volume AND its replicas permanently. Diagnose root cause first.
- **Before ANY destructive storage operation** — take a Longhorn snapshot via UI or `kubectl-admin`. This includes: deleting PVCs, deleting StatefulSets, scaling down pods with RWO volumes.
- **Mount failure triage order:** (1) Check Longhorn node conditions (`multipathd`, `Ready`), (2) Check CSI plugin pods on the affected node, (3) Check `dmesg` on the node for filesystem/device errors, (4) Try force-detaching via Longhorn UI, (5) Only after all diagnostics fail, escalate to user.
- **multipathd blocks Longhorn mounts** — all 3 nodes have `/etc/multipath.conf` with `blacklist { devnode "^sd[a-z0-9]+" }`. If multipathd config is lost (e.g. after OS upgrade), new volume mounts will fail with `mke2fs "apparently in use by the system"`. Fix: re-add blacklist config, restart multipathd.
- **Not all volumes have Longhorn backups** — only volumes labeled with `recurring-job-group.longhorn.io/critical` or `important` get backed up. Check before assuming a volume can be recovered.
- **OOMKilled container + Longhorn RWO volume = mount deadlock** — when a container is OOMKilled inside a Running pod, kubelet tries to restart it in-place. The restart requires re-staging the PVC, but Longhorn's CSI plugin rejects the call with `MountVolume.SetUp failed: rpc error: code = Aborted desc = no Pending workload pods for volume pvc-… to be mounted: map[Running:[<pod-name>] Succeeded:[<backup-pods>]]` because from Longhorn's view, the pod is already the mount owner. The pod stays in `PHASE=Running` but container `state.terminated` with exit 137, `FailedMount` events fire every few minutes (527x over 17h observed on adguard 2026-04-24). **Deployment stays 0/1 AVAILABLE; ArgoCD shows `Progressing` indefinitely.** Fix: `kubectl-admin delete pod <stuck-pod>` forces ReplicaSet to create a fresh pod, Longhorn cleanly detaches and reattaches. Then investigate/fix the underlying OOM (bump memory limit, reduce workload, etc.) to prevent recurrence. **Do NOT delete the PVC** — the volume itself is healthy, only the mount state is stuck.

## Gotchas

- **kubeadm defaults ≠ raw component defaults** — kubeadm sets `anonymous-auth: false`, `authorization.mode: Webhook`, `rotateCertificates: true` on kubelet, and `--bind-address=0.0.0.0` on controller-manager/scheduler. CIS benchmarks reference raw defaults — verify actual state before planning changes.
- **Homepage uses kustomize** — `kubectl-homelab apply -k manifests/home/homepage/`, NOT `-f`.
- **qBittorrent CSRF blocks HTTP probes** — use `tcpSocket`, never `httpGet`.
- **PostgreSQL PGDATA** — set `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectory). Top-level mount breaks initdb.
- **Longhorn `orphan-resource-auto-deletion`** — NOT a boolean. Semicolon-separated: `replica-data;instance`.
- **Grafana RWO PVC on Helm upgrade** — new pod can't attach. Scale down first: `kubectl-admin scale deployment/prometheus-grafana -n monitoring --replicas=0`, wait for termination, then upgrade.
- **Cilium HTTPRoute `<none>` status** — `kubectl-homelab rollout restart deployment/cilium-operator -n kube-system`.
- **Cilium HTTPRoute stale `status.parents`** — gateway-controller does NOT remove stale parents when `spec.parentRefs` is edited. Old entries (lagging `observedGeneration`) accumulate; one `Accepted=False` breaks ArgoCD's HTTPRoute health check and cascades to Degraded on the parent Application. Restart of cilium-operator does NOT clean them. Surgical fix: `kubectl-admin patch httproute <name> -n <ns> --subresource=status --type=json -p='[{"op":"remove","path":"/status/parents/<index>"}]'`.
- **Sonarr/Radarr API** — external HTTPRoute returns 404. Must port-forward from WSL.
- **CiliumNP default-deny** — `ingress: [{}]` = allow-all (empty rule matches everything), `ingress: []` = deny-all. Opposite of K8s NP intuition where `{}` means deny.
- **CiliumNP CIDR vs pod traffic** — `toCIDR`/`fromCIDR` with pod CIDR `10.244.0.0/16` silently fails for pod-to-pod traffic. Cilium uses identity-based matching for managed endpoints. Use `toEndpoints`/`toEntities` instead.
- **CiliumNP `kube-apiserver` entity** — cross-node API server traffic (e.g. admission webhooks) arrives with `remote-node` identity in Cilium tunnel mode. Policies for webhook ports must allow both `kube-apiserver` and `remote-node`. Also: `toEntities: kube-apiserver` does NOT match the kube-vip VIP (10.10.30.10) - only matches in-cluster service IP and node IPs. CI deploy jobs using `api.k8s.rommelporras.com` need explicit `toCIDR: 10.10.30.10/32` on port 6443.
- **CiliumNP `toFQDNs` requires DNS inspection** — `toFQDNs` rules silently fail unless the same policy has a DNS egress rule with `rules: dns: - matchPattern: "*"`. Without it, Cilium's FQDN-to-IP cache never populates and HTTPS connections to external domains time out. Use `protocol: ANY` on port 53, not separate UDP/TCP rules.
- **rsync to NTFS (WSL2 `/mnt/c/`)** — Unix sockets and device files can't be created. Use `--no-specials --no-devices`. Root-owned NAS files need `--rsync-path="sudo rsync"`.
- **jq with large file lists** — shell `ARG_MAX` limit breaks `--argjson` with 2000+ file JSON objects. Use temp files + `--slurpfile` instead.
- **Grafana sidecar resources** — set per-sidecar (`sidecar.dashboards.resources` + `sidecar.datasources.resources`), not shared `sidecar.resources`. Shared key can cause port 8080 conflicts.
- **Loki sidecar CrashLoop** — `sidecar:` key with only `resources:` enables the rules sidecar which crashes without Ruler. Set `sidecar.rules.enabled: false` if Ruler is not in use.
- **alpine/k8s has no tzdata** — `TZ=Asia/Manila` silently falls back to UTC. Use `TZ=UTC-8` (POSIX: means UTC+8 = Manila).
- **etcd image is distroless** — `registry.k8s.io/etcd:3.6.6-0` has no shell, no cp, no coreutils. Use initContainer to copy etcdctl, run backup from alpine/k8s.
- **SQLite live backup** — never raw `cp` a live SQLite DB (WAL corruption). Use `sqlite3 <db> ".backup <dest>"` or `keinos/sqlite3:3.46.1` image.
- **MinIO is dead** — repo archived Feb 2026. Use Garage S3 (`dxflrs/garage`) as replacement.
- **Scripts REPO_ROOT after reorg** — scripts in subdirectories (`scripts/vault/`, `scripts/backup/`). `REPO_ROOT` needs double dirname: `"$(dirname "$(dirname "$SCRIPT_DIR")")"`.
- **Longhorn v1.10 backup-target** — `backup-target` setting removed. Use Helm `defaultBackupStore.backupTarget` instead.
- **version-checker `-alpine` suffix false positives** — images tagged `X.Y-alpine` get compared against `X.Y` (non-alpine), reporting outdated. Add `match-regex.version-checker.io/<container>` annotation to restrict matching (e.g. `^\d+\.\d+-alpine$` for postgres, `^\d+\.\d+\.\d+-alpine$` for python).
- **Docker Hub rate limits during bulk upgrades** — unauthenticated limit is 100 pulls/6h per IP. All 3 nodes share one IP. Workaround: `sudo ctr -n k8s.io images tag <cached-tag> <new-tag>` to re-tag cached images. Pulls will succeed after rate limit resets.
- **StatefulSet PVC expansion** — `volumeClaimTemplates` are immutable after creation. Helm upgrade can't resize existing PVCs. Procedure: (1) `kubectl-admin patch pvc` to new size, (2) delete pod to trigger filesystem resize on remount, (3) `kubectl-admin delete statefulset --cascade=orphan` + helm upgrade to sync the template. Longhorn handles online block device expansion; kubelet runs `resize2fs` on next mount.
- **GitLab migrations memory limit** — GitLab 18.x migrations container needs ≥1.5Gi limit (`gitlab.migrations.resources.limits.memory: 1536Mi` in `helm/gitlab/values.yaml`). 512Mi OOMKills the Rails+bootsnap process mid-migration; `restartPolicy: OnFailure` loops it forever without ever reaching `.status.succeeded`, so ArgoCD reports gitlab as Missing/OutOfSync even though every other gitlab pod is Running/Ready. **Signal: `Health=Missing` on the gitlab app with every workload pod healthy.** Confirm with `kubectl-admin get pod <migrations-pod> -n gitlab -o json | jq '.status.containerStatuses[].lastState.terminated'` — exit code 137 + reason `OOMKilled`.
- **ArgoCD built-in CronJob health** — marks Degraded when `lastScheduleTime > lastSuccessfulTime` (msg: "CronJob has not completed its last execution successfully"). **Investigate WHY the last run failed first** — `cluster-janitor` Task 3 deletes failed Jobs every 10 min, hiding the evidence. Check the CronJob spec for broken `secretKeyRef`/`envFrom` references, verify referenced ConfigMaps/Secrets exist, inspect logs of the newest successful run pod for context, fix root cause. ONLY after fixing, clear the stale status without waiting for next schedule: `kubectl-admin patch cronjob <name> -n <ns> --subresource=status --type=merge -p '{"status":{"lastSuccessfulTime":"<now-ISO8601>"}}'`. Controller doesn't overwrite this on reconcile.
- **ArgoCD `directory.recurse: false`** — causes permanent OutOfSync drift. `recurse:false` is the default, so the API server strips the entire `directory:` block from the stored Application spec, but git keeps declaring it → infinite re-apply loop (log: `Refreshing app status (spec.source differs)`). Omit the `directory:` block entirely for default behavior.
- **ArgoCD stuck sync recovery (ghost `operationState`)** — when a sync deadlocks (stuck PreSync hook Jobs with `argocd.argoproj.io/hook-finalizer`, `operationState.phase: Running` with `.operation: null`): (1) clear Job finalizers via `kubectl-admin patch jobs.batch/<name> -n <ns> --type=merge -p '{"metadata":{"finalizers":null}}'`, (2) re-set `.operation` on the Application so `terminate-op` recognizes it, (3) `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app terminate-op <app> --core`, (4) `argocd app sync <app> --core`. `terminate-op` checks `.operation` not `.status.operationState.phase`, so it returns "no operation in progress" when operation is nil even while phase is Running. **Restarting argocd-application-controller alone does NOT clear this — state is in etcd.**
- **`gitlab` manual-sync** — `gitlab` is the only ArgoCD app without `syncPolicy.automated:` (intentional — helm hooks fight with ArgoCD auto-prune). `ArgocdAppOutOfSync` alert covers gitlab (only `cilium` is excluded). `ArgocdAppUnhealthy` fires after 15 min when health is not Healthy/Progressing, routed to `#apps` via alertmanager fallthrough. **After any commit touching `helm/gitlab/values.yaml` or `manifests/argocd/apps/gitlab.yaml`, manually trigger sync immediately:** `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync gitlab --core`, then watch health reach Synced/Healthy within 5 min before walking away.
- **Removing/renaming a Secret or ExternalSecret: grep first** — `grep -rn '<old-name>' manifests/ helm/` before committing. Catches `envFrom`/`secretKeyRef`/`valueFrom.secretKeyRef` references in CronJobs, Deployments, Jobs that ArgoCD auto-sync would prune cleanly, then break the consumer at its next schedule (days later for weekly CronJobs). Commit `cd0beef` removed `discord-version-webhook` ExternalSecret but missed the consumer at `manifests/monitoring/version-checker/version-check-cronjob.yaml:76-77`, silently breaking the Sunday version-check Job and producing the 3-day `monitoring-manifests` Degraded window.
- **Alloy `stage.metrics` counters get `loki_process_custom_` prefix** — `loki.process` hardcodes this prefix on every counter created via `stage.metrics`, regardless of the `name` field. PrometheusRules referencing the unprefixed name silently never fire. Check Alloy's `:12345/metrics` for the real name before writing the alert expression.
- **Testing Alloy's kernel journal source** — `logger -p kern.warn` produces `_TRANSPORT=syslog`, NOT `_TRANSPORT=kernel`. To inject real kernel-transport test messages, use `echo '<msg>' | sudo tee /dev/kmsg` on the node. Required when `loki.source.journal` filters `matches = "_TRANSPORT=kernel"`. Journal cursor has no persistence across Alloy pod restarts — test events in journal history are re-read, baking the counter value in until kmsg retention rotates them out.
- **ArgoCD multi-source `$values` ref refresh lag** — Helm apps using `$values` from the homelab git repo don't always auto-detect git changes within the normal refresh interval (observed on `alloy` while single-source apps synced fine). Force pickup via the controller pod: `kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app get <app> --core --refresh` then `argocd app sync <app> --core`.
- **`kubectl-homelab logs` is also RBAC-blocked** — restricted kubeconfig has no `get` on `pods/log` (not just secrets). Use `kubectl --kubeconfig ~/.kube/homelab.yaml logs ...` for pod logs. Same applies to `--previous` log queries.
- **Cilium Gateway API HTTPRoute ingress identity** — HTTPRoute-exposed services take ingress from the Cilium Gateway envoy proxy, which has identity `reserved:ingress`. This is DIFFERENT from the LoadBalancer-service path (AdGuard DNS, GitLab SSH, OTel Collector) which uses `host`/`remote-node`/`world`. For an HTTPRoute-exposed backend, the CNP ingress rule must use `fromEntities: [ingress]`; using `[host, remote-node, world]` silently fails with "upstream connect error ... reset reason: connection timeout" in the browser. Confirmed against atuin, ghost, gitlab webservice, and argo-workflows UI patterns. CNP can add `fromEntities: [host]` as a second rule for same-node `kubectl port-forward` paths.
- **Argo Workflows SSO ServiceAccount needs a static token Secret** — k8s 1.24+ no longer auto-creates token Secrets for ServiceAccounts. Argo Workflows' SSO flow impersonates the SA selected by `workflows.argoproj.io/rbac-rule` by reading a Secret named `<sa-name>.service-account-token` of type `kubernetes.io/service-account-token`. Without it, login succeeds but every API call returns 403 with `failed to get service account secret: secrets "<sa>.service-account-token" not found` in argo-server logs, and the UI shows "Failed to load version/info Error: Forbidden". The fix is a Secret resource with `kubernetes.io/service-account.name: <sa-name>` annotation alongside the ServiceAccount — the k8s token controller populates it automatically. Applies to any future SA created for SSO-RBAC mapping.
- **Argo Workflows server mode must match SA RBAC scope** — default install is cluster-scoped: the UI calls `GET /workflows?namespace=""` (cluster-wide list), which needs a ClusterRole. If the SSO-mapped SA only has a namespace-scoped Role, the UI shows "Forbidden: Permission denied, you are not allowed to list workflows in namespace """. Fix: add `--namespaced` to BOTH `controller.extraArgs` and `server.extraArgs` in the Helm values. Server then scopes UI queries to its install namespace (matches the Role), controller only watches that namespace. Trade-off: ClusterWorkflowTemplates stop working — fine if only WorkflowTemplates are in use. The alternative (ClusterRole on the SSO SA) is more permissive than needed for a single-namespace install.
- **Argo Workflows v4.0.4 `metadata.labels` do NOT override workflow-level `podMetadata.labels` on the same key** — per-template label overrides silently lose to workflow-scope defaults when the keys collide. If a per-step label is load-bearing (CNP selector, Prometheus target filter, anything that can't be replaced by an annotation), pick a **dedicated key** that `spec.podMetadata.labels` never claims. Phase 5.9.1 smoke52/53/54 failed Prisma P1001 because migrate-step CNPs selected on `app.kubernetes.io/component=invoicetron-migrate` but the merged pod spec kept `app.kubernetes.io/component=ci-pipeline` from the workflow scope — traffic denied at Cilium L3, Prisma reported "can't reach server". Diagnostic: `kubectl-admin get pod <argo-created-pod> -o yaml | yq '.metadata.labels'` and compare vs both the WorkflowTemplate and the Workflow-level `podMetadata`.
- **GitLab webhooks from the `gitlab` namespace need a CNP egress carve-out** — `webservice-internet-egress` and `sidekiq-internet-egress` allow `0.0.0.0/0:443` with `except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]` (SSRF-protection default). In-cluster webhook destinations (e.g. `argo-events.k8s.rommelporras.com` resolving to gateway LB VIP `10.10.30.20` ∈ `10.0.0.0/8`) are blocked, and Cilium's L7 reject returns **HTTP 403 with `Server: envoy`**, which looks identical to an EventSource secret-token rejection. Two allow rules are required together (see `manifests/gitlab/networkpolicy.yaml:webservice-sidekiq-gateway-egress`): (a) `toEntities: [ingress]` on 443 (external-routable path), (b) `toEndpoints: {namespace=argo-events, controller=eventsource-controller}` on 12000 (Cilium kube-proxy-replacement rewrites the LB-VIP at the syscall, so the in-cluster path never matches the 443 allow — it hits the backend pod IP directly). Every new in-cluster webhook destination from `gitlab` ns needs an entry here.
- **Cilium kube-proxy-replacement translates LB-VIP traffic at the syscall, not at ingress** — for any service exposed via Cilium Gateway and accessed in-cluster, egress policy evaluates against the **backend pod identity + target port**, not the LB VIP + 443. A symmetric `toEntities: [ingress]:443` egress allow alone won't open the path. Add a parallel `toEndpoints` rule matching the backend pod labels on its actual target port.
- **Argo Workflows RWO PVC Multi-Attach across parallel steps** — a workflow with `volumeClaimTemplates` (ReadWriteOnce, Longhorn in this cluster) and parallel DAG tasks hits `FailedAttachVolume: Multi-Attach error for volume "pvc-…" Volume is already exclusively attached to one node` when parallel pods schedule onto different nodes. Fix: add `affinity.podAffinity.preferredDuringSchedulingIgnoredDuringExecution` at the Workflow `spec` level matching `workflows.argoproj.io/workflow={{workflow.name}}` at `topologyKey: kubernetes.io/hostname` with `weight: 100`. **Use `preferred`, NOT `required`** — the first pod has no siblings to match, and `required` with an empty match set is unsatisfiable (scheduler refuses to place the first pod). See `manifests/argo-workflows/templates/{portfolio,invoicetron}-pipeline.yaml` for the exact block.
- **Cross-namespace DB consumers must use FQDN in Vault/secrets, never the short name** — short names (`invoicetron-db:5432`) only resolve in the service's own namespace. When a consumer lives in a different namespace (e.g. migrate Job in `argo-workflows` reading from `invoicetron-prod` DB), short names fail with Prisma `P1001: Can't reach database server`. Store `<service>.<namespace>.svc.cluster.local` in Vault instead. Applies to any cross-namespace DB pattern — Argo Workflows migrate steps, cross-namespace CronJobs, etc.
- **GitLab `push_access_levels: "No one"` requires MR flow** — `gitlab.k8s.rommelporras.com/0xwsh/portfolio` `main` is fully protected; even Maintainer `git push` returns `pre-receive hook declined: You are not allowed to push code to protected branches`. Workflow: push commit to a feature branch, then open + merge MR via `glab api` (not `glab mr create` — it rejects with "None of the git remotes correspond to GITLAB_HOST" because portfolio origin is `ssh.gitlab.k8s...` while API host is `gitlab.k8s...`). See `docs/todo/phase-5.9.1-cicd-pipeline-migration.md` Notes #55 for the exact command sequence. Invoicetron `main` allows Maintainer direct push (access_level 40), so the projects are asymmetric — check `glab api projects/<path>/protected_branches/main` when in doubt.
- **Argo Events webhook EventSource puts HTTP headers under `header.*` (singular), not `headers.*`** — Sensor data-filters using `path: headers.X-Something` silently discard every legitimate event with `data filter error (path '…' does not exist)` in sensor warn logs. No 4xx from the EventSource — the webhook POST returns 200 because the EventSource accepts all payloads; filtering happens asynchronously via the event bus. Additionally: when a filter rejects, the sensor logs the **full event body including every header value in plaintext** at warn level. Any auth token placed in a header (like the `staging-promote-token` pattern) leaks to pod logs on filter failure. Recommendation: keep filter paths correct (singular `header.*`), and treat any sensor-log access as equivalent to secret-value access until a future sensor-log-redaction feature lands upstream.
- **Argo Events v1.9.10 `data` filter with `{{env.X}}` templating is a footgun** — three overlapping behaviors that make the shape `{path, type: string, value: ["{{env.SECRET}}"]}` silently reject every event: (1) `{{env.X}}` is NOT substituted anywhere in `pkg/sensors/dependencies/filter.go` — it's taken verbatim and compiled as a regex; (2) string-type filter values ARE regexes, matched against `gjson pathResult.String()` which renders arrays as JSON literals (`["value"]`, not the bare scalar); (3) HTTP header values come through as arrays. Net effect: the regex never matches the token, filter returns "not interested in dependency … (didn't pass filter)" at info level. The upstream Argo Events examples only show scalar-value filters so this trap isn't obvious. Working pattern: `filters.script: |` with gopher-lua (`lua.NewState()` opens `os` stdlib so `os.getenv` reads sensor-pod env) and auth in request BODY (flat scalar via `event.body.token`), not headers. See `manifests/argo-events/sensor-portfolio-staging-promote.yaml` and phase 5.9.1 Notes #56 for the full investigation.
