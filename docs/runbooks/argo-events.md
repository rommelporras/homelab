# Argo Events runbook

> Break-glass guide for the `argo-events` namespace: the controller, the 3-replica NATS JetStream EventBus, the GitLab webhook EventSources, and the Sensors that turn pushes into CI Workflows. Use this when an `ArgoEventsControllerDown`, `EventSourceDown`, `SensorDown`, or `EventBusDegraded` alert fires, or when a `git push` to portfolio/invoicetron stops triggering a build. Related: [argo-workflows.md](argo-workflows.md) (the Workflows these Sensors create), [ci-cd.md](ci-cd.md) (the CI pipeline alerts these Sensors feed), [argocd.md](argocd.md), [apps.md](apps.md), [00-EMERGENCY.md](00-EMERGENCY.md), [vault.md](vault.md), [networking.md](networking.md).

Covers: argo-events controller health, EventBus (NATS JetStream) quorum, GitLab webhook EventSources, Sensors that create Argo Workflows.

Deployed in Phase 5.9.1 Stage 2 (v0.39.2). Controller **v1.9.10**, chart `argo-events-2.4.21`, managed by ArgoCD as two Applications: `argo-events` (Helm chart) and `argo-events-manifests` (the `manifests/argo-events/` directory: EventBus, EventSources, Sensors, HTTPRoute, CNP, ServiceMonitor, RBAC).

## The flow (know this before you triage)

```
GitLab push  ->  HTTPRoute (argo-events.k8s.rommelporras.com, Gateway VIP 10.10.30.20)
             ->  EventSource pod :12000  (validates X-Gitlab-Token, publishes event)
             ->  EventBus (NATS JetStream, 3 replicas)
             ->  Sensor pod  (filters on body.ref / body.token, creates a Workflow)
             ->  Workflow in argo-workflows namespace  (the actual CI build)
```

If any link is down, pushes stop building. GitLab retries webhook delivery with backoff, so a short EventSource outage self-heals once the pod is back; a Sensor outage means events pile up in JetStream and fire late.

### What's running (verified 2026-07-08)

| Component | Kind | Names |
|-----------|------|-------|
| Controller | Deployment | `argo-events-controller-manager` (on cp1 as of 2026-07-08) |
| EventBus | StatefulSet | `eventbus-default-js` (3 replicas, pods `eventbus-default-js-0/1/2`) |
| EventSources | Deployment | `gitlab-portfolio`, `gitlab-invoicetron`, `portfolio-staging-promote` |
| Sensors | Deployment | `gitlab-portfolio-develop`, `gitlab-portfolio-main`, `gitlab-invoicetron-develop`, `gitlab-invoicetron-main`, `portfolio-staging-promote` |
| Webhook svcs | Service (:12000) | `gitlab-portfolio-eventsource-svc`, `gitlab-invoicetron-eventsource-svc`, `portfolio-staging-promote-eventsource-svc` |

The controller-generated Deployment/pod names carry a random suffix (e.g. `gitlab-portfolio-eventsource-b6t5j-...`, `gitlab-portfolio-main-sensor-sqcqj-...`). Match by label, not by exact name. Useful selectors:

- Controller: `-l app.kubernetes.io/component=controller-manager`
- EventSource pods: `-l controller=eventsource-controller` (all) or `-l eventsource-name=<name>` (one)
- Sensor pods: `-l controller=sensor-controller` (all) or `-l sensor-name=<name>` (one)

### Quick health check

```bash
kubectl-homelab get pods -n argo-events -o wide
```

Expect: 1 controller `1/1`, 3 EventBus pods `3/3`, 3 EventSource pods `1/1`, 5 Sensor pods `1/1` (12 pods total).

> ⚠️ **Do NOT wait on `SensorDown` / `EventSourceDown` as your down-signal.** Those
> `up{}`-based alerts have no reliable scrape target in the current setup (no Service
> selects the Sensor pods; the EventSource metrics service does not expose the scraped
> port), so they likely **never fire**. This `get pods` health check is your real
> down-signal - use it directly. (Fixing the metrics wiring is tracked in
> `docs/todo/documentation-backlog.md`.) `ArgoEventsControllerDown` and
> `EventBusDegraded` are fine.

To inspect the CRs themselves you need admin (the restricted kubeconfig cannot list `eventbus`/`eventsources`/`sensors`):

```bash
kubectl-admin get eventbus,eventsource,sensor -n argo-events
```

Expect: EventBus `default`; EventSources `gitlab-portfolio`, `gitlab-invoicetron`, `portfolio-staging-promote`; Sensors `gitlab-portfolio-develop/-main`, `gitlab-invoicetron-develop/-main`, `portfolio-staging-promote`.

> WARNING: Sensor and EventSource pod logs can contain secret material. On a filter rejection, Argo Events logs the **full event body including every HTTP header value in plaintext** at warn level (X-Gitlab-Token, the staging-promote token if it were ever moved to a header, etc.). Treat any `kubectl logs` output from these pods as secret-sensitive. Do not paste it into chat/tickets/an AI assistant.

---

## ArgoEventsControllerDown

**Severity:** critical (`for: 5m`)

The `argo-events-controller-manager` has been unreachable for 5+ minutes (`up{job=~".*argo-events.*controller.*"} == 0`). The controller reconciles EventSource/Sensor/EventBus CRs into their Deployments and StatefulSet. While it is down, **existing** EventSource and Sensor pods keep running and pushes still build - but any CR change (new Sensor, edit, pod reschedule) will not take effect, and a crashed EventSource/Sensor pod will not be recreated.

### Detection

```bash
kubectl-admin get deployment argo-events-controller-manager -n argo-events
kubectl-admin logs -n argo-events deployment/argo-events-controller-manager --tail=100
```

### Common causes

- Pod evicted / OOMKilled / node drain (it ran only on cp1 as of 2026-07-08; a node reboot reschedules it).
- ArgoCD sync of the `argo-events` Helm app failed and left the controller mid-upgrade.
- CRD version mismatch after a chart bump.

### Triage / restart

1. Check the pod and its last state:
   ```bash
   kubectl-admin get pod -n argo-events -l app.kubernetes.io/component=controller-manager -o wide
   kubectl-admin describe pod -n argo-events -l app.kubernetes.io/component=controller-manager | tail -40
   ```
2. If OOMKilled, follow [oomkilled.md](oomkilled.md). Do NOT edit limits by hand - it is ArgoCD-managed; change the Helm values in git and sync.
3. Restart the controller (safe - no data, it only reconciles):
   ```bash
   kubectl-admin rollout restart deployment/argo-events-controller-manager -n argo-events
   ```
4. If the ArgoCD app is stuck, reconcile from the controller pod:
   ```bash
   kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app get argo-events --core
   kubectl-admin exec -n argocd statefulset/argocd-application-controller -- argocd app sync argo-events --core
   ```
   See [argocd.md](argocd.md) for stuck-sync recovery.

---

## EventBusDegraded

**Severity:** warning (`for: 10m`)

Fewer than 2 of the 3 NATS JetStream replicas are Ready (`count by (namespace) (kube_pod_status_ready{namespace="argo-events",pod=~"eventbus-.*",condition="true"} == 1) < 2`). The EventBus is the NATS cluster that carries events from EventSources to Sensors. It runs as StatefulSet `eventbus-default-js` with pods `eventbus-default-js-0/1/2`.

Quorum is 2 of 3 (same math as etcd). With 2 Ready, delivery still works. With 1 Ready, the EventBus halts and **no** events reach Sensors - pushes stop building even though EventSources accept the webhook.

> Note: this EventBus is **in-memory** (no Longhorn PVC) by design - see `manifests/argo-events/eventbus.yaml`. Event durability is deliberately not critical: a lost in-flight event is re-delivered by GitLab's webhook retry. So there is **no PVC to preserve** here and no Longhorn PVC-delete trap for the EventBus specifically. (The Longhorn "never delete a PVC to fix a mount error" rule still applies everywhere else.)

### Detection

```bash
kubectl-homelab get pods -n argo-events -l app.kubernetes.io/component=eventbus -o wide
kubectl-admin get statefulset eventbus-default-js -n argo-events
```

### Common causes

- A node hosting one or two JetStream pods rebooted (M80q BIOS POST is 5-7 min - expect a multi-minute gap; do not act during a known reboot). As of 2026-07-08 pods `eventbus-default-js-0` and `-2` were both on cp3 - losing cp3 drops 2 of 3 at once.
- Node `NotReady` / disk pressure evicting pods.
- Chart/version change to the EventBus mid-sync.

### Triage / restart

1. Confirm which node(s) are unhealthy:
   ```bash
   kubectl-homelab get nodes -o wide
   kubectl-admin describe pod -n argo-events -l app.kubernetes.io/component=eventbus | grep -A5 -iE 'events|state|reason'
   ```
2. If a node is down, follow [cluster.md](cluster.md) / [00-EMERGENCY.md](00-EMERGENCY.md) to bring it back. The StatefulSet reschedules the pod once the node is Ready.
3. If a pod is stuck (Pending/CrashLoop) but its node is healthy, delete it so the StatefulSet recreates it - do this **one pod at a time**, waiting for it to return `3/3` Ready before touching the next, to preserve quorum:
   ```bash
   kubectl-admin delete pod -n argo-events eventbus-default-js-0
   kubectl-homelab get pods -n argo-events -l app.kubernetes.io/component=eventbus -w
   ```
   > WARNING: Never delete more than one EventBus pod at a time. Deleting two drops below quorum and halts all event delivery.
4. If JetStream state is corrupt and the EventBus will not form a cluster, deleting the CR forces the controller to rebuild it. This is destructive of in-flight events (acceptable here - GitLab re-delivers), but only do it if the pods will not recover:
   > WARNING: DESTRUCTIVE. The `EventBus` CR is named `default` and is ArgoCD-managed (`argo-events-manifests`), so deleting it triggers ArgoCD to recreate it from `manifests/argo-events/eventbus.yaml`. Confirm with the owner first. Command (CR name verified `default` on 2026-07-08): `kubectl-admin delete eventbus default -n argo-events`. After recreation, restart the EventSource and Sensor pods so they reconnect to the new NATS cluster:
   > ```bash
   > kubectl-admin rollout restart deployment -n argo-events -l controller=eventsource-controller
   > kubectl-admin rollout restart deployment -n argo-events -l controller=sensor-controller
   > ```

---

## EventSourceDown

**Severity:** critical (`for: 5m`)

An EventSource pod has been unreachable for 5+ minutes (`up{job=~".*argo-events.*eventsource.*"} == 0`). EventSources are the webhook receivers on port `:12000`. Each is a `gitlab`-type EventSource: on startup it auto-registers the webhook on the GitLab project via the API, validates the `X-Gitlab-Token` natively, and publishes matching events to the EventBus. `$labels.instance` on the alert tells you which one.

While an EventSource is down, GitLab retries webhook delivery with exponential backoff; once the pod is back it catches up, but if the retry window exhausts, those pushes never build.

### Detection

```bash
kubectl-homelab get pods -n argo-events -l controller=eventsource-controller -o wide
kubectl-admin logs -n argo-events -l eventsource-name=gitlab-portfolio --tail=100
```

(swap `gitlab-portfolio` for `gitlab-invoicetron` or `portfolio-staging-promote`.)

### Common causes

- Pod evicted / node reboot / OOM - the controller (if healthy) recreates it.
- `gitlab-api-token` invalid/expired -> webhook auto-registration fails on startup; the pod logs an API auth error and stays unhealthy. The token comes from Vault via ESO (`externalsecret-gitlab-api.yaml` -> Secret `gitlab-api-token`).
- Per-project webhook secret missing/rotated -> `X-Gitlab-Token` validation fails; GitLab shows the webhook returning 4xx. Secrets: `portfolio-webhook-secret`, `invoicetron-webhook-secret`, `staging-promote-token` (all ESO-synced from Vault).
- Gateway/HTTPRoute problem so the webhook never reaches the pod (see below - this shows as GitLab webhook failures, not as an unhealthy pod).

### Triage / restart

1. Check the pod, then the logs (logs are secret-sensitive - see warning at top):
   ```bash
   kubectl-admin get pod -n argo-events -l controller=eventsource-controller -o wide
   kubectl-admin logs -n argo-events -l eventsource-name=<name> --tail=100
   ```
2. Restart it (controller must be up for it to come back cleanly):
   ```bash
   kubectl-admin rollout restart deployment -n argo-events -l eventsource-name=<name>
   ```
   The Deployment carries the `eventsource-name` label, so the `-l` selector targets it correctly. If you prefer the exact name, get it from `kubectl-homelab get deploy -n argo-events -l controller=eventsource-controller`.
3. If the ExternalSecret is empty/failing, fix Vault/ESO first - the pod cannot start without the API token. See [vault.md](vault.md):
   ```bash
   kubectl-admin get externalsecret -n argo-events
   kubectl-homelab get secrets -n argo-events   # list names (get-by-name is RBAC-blocked on homelab); look for gitlab-api-token
   ```
4. If pods are healthy but GitLab reports webhook 403 with `Server: envoy`, this is the **in-cluster egress CNP trap**, not a bad token. GitLab (in the `gitlab` namespace) reaching `argo-events.k8s.rommelporras.com` (resolves to Gateway VIP `10.10.30.20`, inside `10.0.0.0/8`) is blocked by GitLab's SSRF-protection default unless the carve-out exists. See CLAUDE.md and `manifests/gitlab/networkpolicy.yaml` rule `webservice-sidekiq-gateway-egress` - two rules are required together: `toEntities: [ingress]:443` and `toEndpoints:{namespace=argo-events, controller=eventsource-controller}:12000`. Cilium's kube-proxy-replacement rewrites the LB VIP at the syscall, so the in-cluster path hits the backend pod on :12000, not :443.
5. To reach the webhook endpoint directly for testing (bypass GitLab), port-forward and POST from WSL - do NOT put any real token in a header or on the URL (it will land in pod logs on filter failure):
   ```bash
   kubectl-admin port-forward -n argo-events svc/gitlab-portfolio-eventsource-svc 12000:12000
   # then, from another shell: curl -i http://localhost:12000/gitlab/portfolio
   ```
   (Endpoint paths: `/gitlab/portfolio`, `/gitlab/invoicetron`, `/staging-promote`.)
6. Verify the HTTPRoute is Accepted (a stale parent breaks it - see CLAUDE.md HTTPRoute gotchas):
   ```bash
   kubectl-admin get httproute argo-events-webhooks -n argo-events -o yaml | grep -A20 'status:'
   ```
   Expect `Accepted: "True"` and `ResolvedRefs: "True"` on parent `homelab-gateway` (section `https`).

---

## SensorDown

**Severity:** critical (`for: 5m`)

A Sensor pod has been unreachable for 5+ minutes (`up{job=~".*argo-events.*sensor.*"} == 0`). Sensors subscribe to the EventBus, apply their filters, and **create the Workflow** in the `argo-workflows` namespace. While a Sensor is down, its events accumulate in the JetStream queue and no Workflows are created - so pushes look accepted (EventSource 200s) but never build. `$labels.instance` tells you which Sensor.

Sensors and their filters:

| Sensor | Fires on | Creates Workflow |
|--------|----------|------------------|
| `gitlab-portfolio-develop` | `body.ref == refs/heads/develop` | `portfolio-pipeline` (environment=dev) |
| `gitlab-portfolio-main` | `body.ref == refs/heads/main` | `portfolio-pipeline` (environment=prod) |
| `gitlab-invoicetron-develop` | `body.ref == refs/heads/develop` | `invoicetron-pipeline` (environment=dev) |
| `gitlab-invoicetron-main` | `body.ref == refs/heads/main` | `invoicetron-pipeline` (environment=prod) |
| `portfolio-staging-promote` | Lua `script` filter: `event.body.token == os.getenv("STAGING_PROMOTE_TOKEN")` | `portfolio-staging-promote` (target_env=staging) |

### Detection

```bash
kubectl-homelab get pods -n argo-events -l controller=sensor-controller -o wide
kubectl-admin logs -n argo-events -l sensor-name=gitlab-portfolio-main --tail=100
```

### Common causes

- Pod evicted / node reboot / OOM - controller recreates it (needs the controller up).
- `argo-events-sa` RBAC broken -> the Sensor cannot `create` Workflows in `argo-workflows` (logs show a `forbidden` on the trigger). RBAC lives in `manifests/argo-events/rbac/argo-events-sa.yaml` (Role `argo-events-sa-workflow-create` in the `argo-workflows` namespace, bound to SA `argo-events-sa` in `argo-events`).
- Sensor connected to a stale EventBus after a NATS rebuild - restart the Sensor to reconnect.
- Filter never matches, so pushes silently do not build even though the Sensor is Ready (see the debugging traps below). This is a "not firing" problem, not a "down" one - the alert will NOT catch it.

### Triage / restart

1. Check pod + logs (secret-sensitive):
   ```bash
   kubectl-admin get pod -n argo-events -l controller=sensor-controller -o wide
   kubectl-admin logs -n argo-events -l sensor-name=<name> --tail=100
   ```
2. Restart it (the Deployment carries the `sensor-name` label):
   ```bash
   kubectl-admin rollout restart deployment -n argo-events -l sensor-name=<name>
   ```
3. Confirm it can create Workflows - after a real push, check the target namespace:
   ```bash
   kubectl-admin get workflows -n argo-workflows --sort-by=.metadata.creationTimestamp | tail
   ```
   If the Sensor is Ready but no Workflow appears, jump to "Sensor is up but pushes don't build" below. The Workflow side is [argo-workflows.md](argo-workflows.md); the CI pipeline alerts are in [ci-cd.md](ci-cd.md).

---

## Sensor is up but pushes don't build (filter debugging)

The alerts only catch a pod being *down*. A far more common failure is a Sensor that is `1/1 Ready` but silently rejects every event. These are the hard-won traps from Phase 5.9.1 - check them in this order.

1. **Look at the sensor log first, but treat it as a secret.** On a filter rejection the sensor logs the entire event body plus every header value at warn/info level. That is your evidence, and it is also a token leak - do not share it.
   ```bash
   kubectl-admin logs -n argo-events -l sensor-name=<name> --tail=200
   ```
   - `data filter error (path '...' does not exist)` -> the filter path is wrong (see #2).
   - `not interested in dependency ... (didn't pass filter)` -> the filter compiled but did not match (see #3/#4).

2. **Headers live under `header.*` (singular), NOT `headers.*`.** A `data` filter with `path: headers.X-Gitlab-Event` silently discards every event. The webhook still returns 200 (the EventSource accepts all payloads; filtering happens async on the Sensor side), so there is no 4xx to tip you off - only the sensor warn log. Use `header.X-...` if you must filter on a header at all.

3. **v1.9.10 `data` filter with `{{env.X}}` is a footgun - do not use it.** Three overlapping behaviors make `{path, type: string, value: ["{{env.SECRET}}"]}` reject every event: (a) `{{env.X}}` is NOT substituted anywhere in the filter code - it is compiled verbatim as a regex; (b) string-type filter values ARE regexes, matched against the gjson `pathResult.String()`, which renders arrays as JSON literals like `["value"]` rather than the bare scalar; (c) HTTP header values arrive as arrays. Net: the regex never matches and you get "didn't pass filter" at info level. The upstream examples only show scalar values, so this trap is not obvious.

4. **For token/secret matching, use a Lua `script` filter reading the request BODY, not a header.** The working pattern (see `manifests/argo-events/sensor-portfolio-staging-promote.yaml`) is:
   ```lua
   local body = event.body
   if body == nil then return false end
   return body.token == os.getenv("STAGING_PROMOTE_TOKEN")
   ```
   gopher-lua opens the `os` stdlib, so `os.getenv` reads the sensor pod's env (`STAGING_PROMOTE_TOKEN` is injected via `secretKeyRef` from Secret `staging-promote-token`). The auth token goes in the request body as a flat scalar (`event.body.token`), never in a header - both because header arrays defeat the filter and because a header value leaks to the log on any rejection.

5. **The branch Sensors filter on `body.ref`** (e.g. `refs/heads/main`). Feature branches, tags, and MR events match neither `develop` nor `main` and are dropped on purpose. If a push to a normal branch "isn't building", that is expected - only `develop` and `main` trigger a build.

6. **EventSource received it but no Workflow was created?** Split the two halves:
   - EventSource log shows the POST arrived and passed `X-Gitlab-Token` -> problem is the Sensor filter or RBAC.
   - EventSource log shows nothing -> webhook never arrived; check the HTTPRoute / GitLab webhook delivery (see EventSourceDown steps 4-6).

---

## Known dependencies and cross-links

- **Workflows created by these Sensors:** [argo-workflows.md](argo-workflows.md). The CI pipeline alerts (`CIPipelineFailed`, `CIBuildStuck`, `CIDeployMutexHeldTooLong`, `WebhookDeliveryFailed`) live in the same PrometheusRule (`manifests/monitoring/alerts/argo-events-alerts.yaml`, group `argo-events-ci-pipelines`) but route to [ci-cd.md](ci-cd.md).
- **ArgoCD apps:** `argo-events` (Helm) and `argo-events-manifests` (directory). Sync/health via [argocd.md](argocd.md). Do not `kubectl apply` or `helm upgrade` these - selfHeal reverts manual changes; change git and sync.
- **Secrets:** `gitlab-api-token`, `portfolio-webhook-secret`, `invoicetron-webhook-secret`, `staging-promote-token` are ESO ExternalSecrets from Vault (`vault-backend` ClusterSecretStore). Vault/ESO issues: [vault.md](vault.md).
- **Networking:** webhook path is GitLab -> Gateway VIP `10.10.30.20` -> HTTPRoute `argo-events-webhooks` -> EventSource svc `:12000`. Gateway/DNS/CNP issues: [networking.md](networking.md), and the `gitlab`-ns egress carve-out `webservice-sidekiq-gateway-egress` in `manifests/gitlab/networkpolicy.yaml`.
- **Manifests** (all under `manifests/argo-events/`):
  - EventBus: `eventbus.yaml`
  - EventSources: `eventsource-portfolio.yaml`, `eventsource-invoicetron.yaml`, `eventsource-staging-promote.yaml`
  - Sensors: `sensor-portfolio.yaml`, `sensor-invoicetron.yaml`, `sensor-portfolio-staging-promote.yaml`
  - Routing / networking: `httproute.yaml`, `ciliumnetworkpolicy.yaml`
  - Observability: `servicemonitor.yaml`
  - RBAC: `rbac/argo-events-sa.yaml`
  - ExternalSecrets: `externalsecret-gitlab-api.yaml`, `externalsecret-portfolio-webhook.yaml`, `externalsecret-invoicetron-webhook.yaml`, `externalsecret-staging-promote.yaml`
  - Namespace scaffolding: `namespace.yaml`, `limitrange.yaml`, `resourcequota.yaml`

> When a symptom does not match anything here, grep the incident database:
> ```bash
> grep -niE 'argo-events|eventsource|sensor|data filter' /home/wsl/personal/homelab/CLAUDE.md
> ```

