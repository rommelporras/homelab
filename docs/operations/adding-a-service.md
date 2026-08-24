# Adding a New Service (Worked Example: Immich)

> **What this is:** the complete, end-to-end procedure to add a new self-hosted
> service to the cluster, following this repo's actual conventions. It uses
> **Immich** (self-hosted photo library) as a concrete, not-yet-deployed example.
> Copy the patterns, swap the names.
>
> **Prerequisite reading:** [argocd-guide.md](argocd-guide.md) (how deploys work),
> [managing-secrets.md](managing-secrets.md) (Vault + ESO).

---

## Mental model: what "adding a service" means here

You are **not** running `kubectl apply` or `helm install`. You are:

1. Writing a set of manifests under `manifests/<service>/`
2. Writing one ArgoCD Application under `manifests/argocd/apps/<service>.yaml`
3. Committing to `main`

ArgoCD's root app discovers the new Application and deploys it. That's the whole
deploy. Everything below is about writing those files *correctly* so the service
is secure, observable, reachable, and backed up like every other service here.

### The standard file set for one service

Look at `manifests/karakeep/` or `manifests/atuin/` - every service follows the
same shape. For Immich you'll create `manifests/immich/` with:

| File | Purpose | Required? |
|------|---------|-----------|
| `namespace.yaml` | Namespace with PSS + `eso-enabled` labels | yes |
| `<app>-deployment.yaml` | The workload(s) | yes |
| `<app>-service.yaml` | ClusterIP service(s) | yes |
| `pvc.yaml` | Longhorn volume(s) for config/data | if it has state |
| `httproute.yaml` | Exposes it at `<app>.k8s.rommelporras.com` | if it has a UI |
| `externalsecret.yaml` | Pulls secrets from Vault | if it needs secrets |
| `networkpolicy.yaml` | CiliumNetworkPolicy ingress + egress | yes |
| `resourcequota.yaml` | Namespace resource ceiling | yes |
| `limitrange.yaml` | Default per-container limits | yes |
| `backup-cronjob.yaml` | App-consistent backup (DB dump etc.) | if it has a DB |

Plus, outside the service dir:

| File | Purpose |
|------|---------|
| `manifests/argocd/apps/immich.yaml` | The ArgoCD Application |
| `manifests/argocd/appprojects.yaml` | Add `immich` namespace to a project |
| `manifests/monitoring/probes/immich-probe.yaml` | Blackbox uptime probe |
| `manifests/monitoring/alerts/immich-alerts.yaml` | ImmichDown etc. |
| `manifests/monitoring/dashboards/...` | Grafana dashboard (optional but expected) |

---

## Step 0: Plan it (before writing YAML)

Answer these first - they determine the manifests:

- **Images & versions?** Pin exact tags, never `latest`. Immich needs the server
  (`ghcr.io/immich-app/immich-server:<ver>`), machine-learning
  (`immich-machine-learning:<ver>`), a **PostgreSQL with the vector extension
  Immich currently requires** (recent releases use **VectorChord** via
  `ghcr.io/immich-app/postgres:<ver>`; older ones used pgvecto.rs - check the
  Immich release notes / docker-compose for the exact DB image your server version
  expects), and **Redis** (`docker.io/redis:<ver>`). Verify each tag exists in the
  registry before use.
- **Storage?** Immich photos are large - decide NFS (NAS) vs Longhorn. Convention
  here: **media on NFS** (like the ARR stack), **config/DB on Longhorn**. The NAS
  has one drive, so bulk photo storage on NFS, Postgres data on Longhorn (2x
  replication).
- **Secrets?** DB password, JWT/secret. These go to Vault (Step 4).
- **Namespace?** `immich`. Pick which AppProject owns it - a general app fits
  `homelab-apps` (Step 6).
- **Resource budget?** Immich ML is memory-hungry. Set the ResourceQuota
  accordingly (Step 7).

> **Reality check:** Immich is a multi-component app (server + ML + Postgres +
> Redis). It's a *hard* first service. The pattern below is complete, but if you
> want to learn the flow on something simple first, a single-container app (one
> deployment + service + httproute + networkpolicy) uses the exact same steps
> minus the DB pieces.

---

## Step 1: Namespace

Every namespace carries Pod Security Standard labels and `eso-enabled: "true"`
(so ExternalSecrets work). Copy `manifests/karakeep/namespace.yaml`:

```yaml
# manifests/immich/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: immich
  labels:
    app.kubernetes.io/part-of: immich
    pod-security.kubernetes.io/enforce: baseline   # restricted if the app allows
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
    eso-enabled: "true"
```

Prefer `enforce: restricted` if the containers can run non-root with no extra
caps. Immich's images may need `baseline` - start there, check
`docs/context/Security.md` for the accepted-exceptions policy, and tighten later.

## Step 2: Workloads + Services

Use `manifests/atuin/server-deployment.yaml` as the **non-root** security-baseline
template to copy (it runs `runAsNonRoot: true`). Do **not** copy
`manifests/karakeep/karakeep-deployment.yaml`'s security context - karakeep sets
`runAsNonRoot: false` / `fsGroup: 0` because s6-overlay needs root at init, which
is a documented exception, not the baseline. Immich's images run non-root, so set
`runAsNonRoot: true`.

Every container **must** have (see `.claude/rules/manifests.md`):

- Pod: `securityContext.seccompProfile.type: RuntimeDefault`
- Container: `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`,
  `runAsNonRoot: true` (unless it genuinely needs root - comment why, like karakeep)
- `resources.limits` (cpu + memory) on every container
- `automountServiceAccountToken: false` unless it calls the K8s API
- `namespace: immich` in every `metadata` (never rely on the default)

One deployment per component (immich-server, immich-machine-learning,
immich-postgres, immich-redis), each with a matching ClusterIP Service:

```yaml
# manifests/immich/immich-server-service.yaml (pattern)
apiVersion: v1
kind: Service
metadata:
  name: immich-server
  namespace: immich
spec:
  selector:
    app: immich-server
  ports:
    - port: 2283          # Immich server port
      targetPort: 2283
```

DB and Redis get their own services (`immich-postgres:5432`, `immich-redis:6379`),
reachable only from within the namespace via NetworkPolicy (Step 5).

> **Cross-namespace / DB URL gotcha:** if anything outside `immich` ever connects
> to the DB, use the FQDN `immich-postgres.immich.svc.cluster.local`, never the
> short name - short names only resolve inside the same namespace.

## Step 3: Storage (PVC)

Config/DB on Longhorn:

```yaml
# manifests/immich/pvc.yaml (pattern - one per stateful component)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: immich-postgres-data
  namespace: immich
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 10Gi
```

For the **photo library on NFS**, follow the ARR stack pattern (an NFS PV/PVC or
a direct NFS volume in the deployment). Create the NFS subdirectory first via the
mount method (you can't SSH WSL->NAS directly):

```bash
# On a node: mount, mkdir, unmount (per CLAUDE.md NAS Access rules)
ssh wawashi@10.10.30.11 \
  'sudo mount -t nfs4 10.10.30.4:/Kubernetes /tmp/nfs && \
   sudo mkdir -p /tmp/nfs/Immich && sudo umount /tmp/nfs'
```

> **Longhorn safety:** to back up a volume it must be labeled
> `recurring-job-group.longhorn.io/critical` (or `important`). Postgres data
> should be. And never delete a PVC to fix a mount error - see
> [../runbooks/storage.md](../runbooks/storage.md).

## Step 4: Secrets (Vault -> ESO)

Full procedure in [managing-secrets.md](managing-secrets.md). Short version:

1. Put the values in 1Password (vault "Kubernetes", item "Immich").
2. Add a block to `scripts/vault/seed-vault-from-1password.sh`:
   ```bash
   echo "  immich/secrets"
   vault kv put secret/immich/secrets \
     DB_PASSWORD="$(op read 'op://Kubernetes/Immich/db-password')" \
     JWT_SECRET="$(op read 'op://Kubernetes/Immich/jwt-secret')"
   ```
   Run it **yourself in a safe terminal** (`op` is not available here).
3. Create the ExternalSecret (copy `manifests/karakeep/externalsecret.yaml`):
   ```yaml
   # manifests/immich/externalsecret.yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: immich-secrets
     namespace: immich
   spec:
     refreshInterval: 1h
     secretStoreRef:
       name: vault-backend
       kind: ClusterSecretStore
     target:
       name: immich-secrets
     dataFrom:
       - extract:
           key: immich/secrets
   ```
4. Consume it in the deployment via `envFrom: [secretRef: {name: immich-secrets}]`
   or individual `secretKeyRef`s.

> The Immich Postgres password is a **DB password** - if you ever rotate it you
> must `ALTER USER` on the DB pod in lockstep with re-seeding Vault, or the app
> loses connectivity on next restart. See the warning in the seed script.

## Step 5: Network policy (CiliumNetworkPolicy)

**This is the step people forget, and it's why services silently don't work.**
Default posture is restrictive; you must explicitly allow every path. Copy the
shape from `manifests/karakeep/networkpolicy.yaml`. The load-bearing rules:

- **Ingress to the UI from the Gateway** uses the `reserved:ingress` identity -
  NOT host/remote-node/world. Getting this wrong gives a browser
  `upstream connect error ... connection timeout`:
  ```yaml
  ingress:
    - fromEntities: [ingress]           # Cilium Gateway envoy proxy
      toPorts: [{ports: [{port: "2283", protocol: TCP}]}]
    - fromEntities: [host]              # kubelet health probes
      toPorts: [{ports: [{port: "2283", protocol: TCP}]}]
    - fromEndpoints:                    # blackbox uptime probes
        - matchLabels: {k8s:io.kubernetes.pod.namespace: monitoring}
      toPorts: [{ports: [{port: "2283", protocol: TCP}]}]
  ```
- **Egress to DNS** (kube-dns) is required or nothing resolves:
  ```yaml
  egress:
    - toEndpoints:
        - matchLabels: {k8s:io.kubernetes.pod.namespace: kube-system, k8s-app: kube-dns}
      toPorts: [{ports: [{port: "53", protocol: UDP}]}]
  ```
- **Egress from server to its DB/Redis/ML** (in-namespace, by pod label).
- **Egress to external internet** for maps/updates, with the SSRF-safe CIDR
  exclusion (block RFC1918):
  ```yaml
    - toCIDRSet:
        - cidr: 0.0.0.0/0
          except: [10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16]
      toPorts: [{ports: [{port: "443", protocol: TCP}]}]
  ```
- **DB/Redis ingress**: only `fromEndpoints` matching the immich-server pod label
  (+ host for probes). Don't expose them wider.

> **CiliumNP gotchas** (from CLAUDE.md - burn these in):
> - `ingress: [{}]` = allow-all; `ingress: []` = deny-all. Opposite of vanilla K8s.
> - `toFQDNs` needs a DNS-inspection rule in the same policy or it silently fails.
> - `toCIDR` with the pod CIDR won't match pod-to-pod - use `toEndpoints`.

## Step 6: The ArgoCD Application

Copy `manifests/argocd/apps/karakeep.yaml`:

```yaml
# manifests/argocd/apps/immich.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: immich
  namespace: argocd
  annotations:
    notifications.argoproj.io/subscribe.on-sync-succeeded.discord: ""
    notifications.argoproj.io/subscribe.on-sync-failed.discord: ""
spec:
  project: homelab-apps
  source:
    repoURL: https://github.com/rommelporras/homelab.git
    path: manifests/immich
    targetRevision: main
  destination:
    server: https://kubernetes.default.svc
    namespace: immich
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
      - CreateNamespace=false
      - PrunePropagationPolicy=foreground
      - ServerSideDiff=true
      - RespectIgnoreDifferences=true
    automated:
      prune: true
      selfHeal: true
```

**Then authorize the namespace in the project.** Edit
`manifests/argocd/appprojects.yaml`, under the `homelab-apps` project's
`destinations:`, add:

```yaml
    - namespace: immich
      server: https://kubernetes.default.svc
```

Skip this and the sync fails with a project-permission error - a very common
first-time miss.

## Step 7: Guardrails (ResourceQuota + LimitRange)

Copy `manifests/karakeep/{resourcequota,limitrange}.yaml`. Size the quota to the
app. Immich ML wants headroom:

```yaml
# manifests/immich/resourcequota.yaml
apiVersion: v1
kind: ResourceQuota
metadata: {name: resource-quota, namespace: immich}
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "6"
    limits.memory: 10Gi
    pods: "12"
    persistentvolumeclaims: "6"
```

```yaml
# manifests/immich/limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata: {name: default-limits, namespace: immich}
spec:
  limits:
    - type: Container
      default: {cpu: 500m, memory: 512Mi}
      defaultRequest: {cpu: 100m, memory: 128Mi}
```

## Step 8: Observability (expected for every service here)

Project convention (CLAUDE.md): **every service gets alerts, a probe, and a
dashboard.**

- **Probe** - `manifests/monitoring/probes/immich-probe.yaml` (copy an existing
  probe like `karakeep`/`ghost`). This is what makes `ImmichDown` possible.
- **Alerts** - `manifests/monitoring/alerts/immich-alerts.yaml`
  (`ImmichDown`, high-restart, high-memory - copy `atuin-alerts.yaml`).
- **Dashboard** - a ConfigMap in `manifests/monitoring/dashboards/` with label
  `grafana_dashboard: "1"` and annotation `grafana_folder: "Homelab"`. Follow the
  row order convention: Pod Status -> Network Traffic -> Resource Usage (with
  dashed request/limit lines), descriptions on every panel and row.
- **Runbook** - add an `ImmichDown` section to
  [../runbooks/apps.md](../runbooks/apps.md) so future-you (or no-AI-you) has a
  triage path.

## Step 9: Backup (if it has a DB)

Copy `manifests/karakeep/backup-cronjob.yaml` or `atuin/backup-cronjob.yaml`. For
Postgres, dump with `pg_dump` (never raw-copy a live DB). Timezone must be
`Asia/Manila` (or `TZ=UTC-8` on alpine/k8s images that lack tzdata). Write dumps
to the NFS `Backups/` path.

## Step 10: DNS - usually nothing to do

The wildcard DNS record `*.k8s.rommelporras.com -> 10.10.30.20` (Gateway) already
covers `immich.k8s.rommelporras.com`. **You do not add a per-service DNS record**
for a normal web app. Only edit `manifests/home/adguard/configmap.yaml` rewrites
if you need a non-wildcard host or a non-Gateway target (rare).

TLS is also automatic - the wildcard cert `wildcard-k8s-tls` covers it.

---

## Step 11: Ship it

```bash
# Security scan + commit (use the slash commands, not raw git - see CLAUDE.md):
/audit-security      # scan changed files for leaked secrets
/commit              # infra commit for the manifests
```

> `/audit-security` and `/commit` are AI-CLI slash commands. **Without the AI CLI**,
> do it manually: scan the diff for secrets (`git diff`), then
> `git commit` with a conventional message (`infra: add immich`) and push.

Then watch it come up (`get applications` needs `kubectl-admin` - homelab RBAC
can't list Applications):

```bash
kubectl-admin get applications -n argocd | grep immich       # Synced + Healthy?
kubectl-homelab get pods -n immich -o wide                   # all Running/Ready?
kubectl-homelab get httproute -n immich                      # Accepted?
```

If it doesn't go healthy, work through
[../runbooks/00-EMERGENCY.md §5 (pod won't start)](../runbooks/00-EMERGENCY.md#5-a-pod-wont-start)
and [§4 (web app down)](../runbooks/00-EMERGENCY.md#4-a-single-web-app-is-down).
99% of first-deploy failures here are (a) missing NetworkPolicy egress/ingress,
(b) namespace not added to the AppProject, or (c) a secret not in Vault yet.

Finally, verify the browser can actually reach `https://immich.k8s.rommelporras.com`
from a real LAN device, and wire up the Homepage tile
(`manifests/home/homepage/`, kustomize - `apply -k`, not `-f`).

> **Heads-up on the existing Homepage Immich entry:** there's already an Immich
> block in `manifests/home/homepage/config/services.yaml`, but it points `href`,
> `siteMonitor`, and the widget `url` at `immich.home.rommelporras.com` (the
> external-appliance `.home` domain). This guide deploys Immich **in-cluster** at
> `immich.k8s.rommelporras.com`, so you must **update those three URLs** to the
> `.k8s` host or the tile links/monitors a non-existent host. The
> `HOMEPAGE_VAR_IMMICH_KEY` placeholder exists, but confirm the value is actually
> in Vault (`homepage/secrets`) - a placeholder in config doesn't guarantee it's
> seeded.

---

## Quick copy-paste: the whole checklist

```
[ ] manifests/immich/namespace.yaml            (PSS + eso-enabled labels)
[ ] manifests/immich/*-deployment.yaml         (securityContext + limits + ns)
[ ] manifests/immich/*-service.yaml
[ ] manifests/immich/pvc.yaml                  (Longhorn) + NFS dir for photos
[ ] Vault: 1P item + seed script block + run in safe terminal
[ ] manifests/immich/externalsecret.yaml
[ ] manifests/immich/networkpolicy.yaml        (ingress: [ingress]! + egress DNS)
[ ] manifests/immich/resourcequota.yaml + limitrange.yaml
[ ] manifests/immich/backup-cronjob.yaml       (pg_dump, Asia/Manila)
[ ] manifests/argocd/apps/immich.yaml
[ ] manifests/argocd/appprojects.yaml          (add immich ns to homelab-apps)
[ ] manifests/monitoring/probes/immich-probe.yaml
[ ] manifests/monitoring/alerts/immich-alerts.yaml
[ ] manifests/monitoring/dashboards/...        (Grafana)
[ ] docs/runbooks/apps.md                       (ImmichDown section)
[ ] /audit-security -> /commit
[ ] verify: app Healthy, pods Ready, HTTPRoute Accepted, browser loads, Homepage tile
```

## Related

- [argocd-guide.md](argocd-guide.md) - how the deploy actually happens
- [managing-secrets.md](managing-secrets.md) - Vault + ESO detail
- `manifests/karakeep/` and `manifests/atuin/` - the closest complete templates
- `.claude/rules/manifests.md` - the manifest security checklist
