# AdGuard / Cilium L2 Resilience Improvements

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the homelab against the recurring "Cilium L2 announcement lease pinned to old node after pod migration" failure mode (Phase 5.3 incident + 2026-05-26 incident), and clean up two AdGuard config items surfaced during the latest investigation.

**Architecture:** Five independent, small improvements. Implement in priority order (highest impact first). Each task is self-contained and can ship as its own commit.

**Tech Stack:** Prometheus + kube-state-metrics (for the alert), AdGuard Home (config edits via runtime YAML on PVC), Cilium L2AnnouncementPolicy (CRD).

---

## Background: 2026-05-26 incident summary

- AdGuard pod migrated cp3 → cp2 (commit `6084ef1 infra: adguard soft-affinity to cp2`).
- Cilium L2 lease `cilium-l2announce-home-adguard-dns` stayed on **cp3** (lease only re-elects on cilium-agent restart / network partition).
- Service `home/adguard-dns` uses `externalTrafficPolicy: Local`. ARP from OPNsense resolved `10.10.30.53` → cp3 MAC; cp3 had no backend; Cilium silently dropped packets.
- LAN clients (Windows, phone) lost DNS — internet inaccessible.
- **The existing `AdGuardDNSDown` alert (`manifests/monitoring/alerts/adguard-dns-alert.yaml`) did NOT fire**, because blackbox-exporter runs in-cluster and in-cluster traffic to the VIP works regardless of lease.
- Recovery: `kubectl-admin delete pod -n kube-system cilium-dthz4` (the cilium-agent on cp3) forced lease re-election → cp2 acquired all 4 leases it had held; with Cilium 1.19+ local-backend preference, adguard lease landed on cp2 (where the pod lives).
- Side effect: gateway/gitlab-shell/otel-collector leases migrated off cp3 — they all use `Cluster` policy so this doesn't break them, but the shared `homelab-l2` `CiliumL2AnnouncementPolicy` means any cilium-agent restart shuffles all 4 leases together.

**Related artifacts:**
- CLAUDE.md gotcha: "Cilium L2 announcement lease pins to a node and does NOT re-elect when pods migrate" (project root `CLAUDE.md` — search for "L2 Announcement").
- `docs/todo/deferred.md` — existing "Cilium L2 Announcement Lease Auto-Rebalance" item (Task D below promotes this).
- `manifests/monitoring/probes/adguard-dns-probe.yaml` — the probe that should have caught this, but didn't (Task A complements it; do NOT replace it — in-cluster probe still catches CoreDNS-side breakage).

---

## File Inventory

**Files this plan touches:**

| Task | File | Operation |
|---|---|---|
| A | `manifests/monitoring/alerts/cilium-l2-lease-alerts.yaml` | Create |
| A | `docs/runbooks/networking.md` | Modify (add runbook entry) |
| B | `manifests/home/adguard/configmap.yaml` | Modify (lines 41-47, upstream_dns) |
| B | `scripts/adguard-update-upstreams.sh` | Create (runtime config patch helper) |
| C | `manifests/home/adguard/configmap.yaml` | Modify (lines 120-133, querylog block) |
| D | `manifests/cilium/l2-announcement.yaml` | Modify (replace single policy with per-service) |
| D | `docs/todo/deferred.md` | Modify (mark item complete) |
| E | Decision document only | No files — see "Task E" |

**Verified existing context (do not re-discover):**
- AdGuard config lives in `manifests/home/adguard/configmap.yaml` (embedded `AdGuardHome.yaml` key).
- `init-config` initContainer (deployment.yaml) ONLY copies the ConfigMap on first boot. Runtime edits live on the PVC at `/opt/adguardhome/conf/AdGuardHome.yaml`. **Editing the ConfigMap does NOT update a running pod** — see Task B / Task C for the propagation pattern.
- LB services with their policies (kubectl-verified 2026-05-26):
  - `home/adguard-dns` → 10.10.30.53, **Local** ← the problem child
  - `default/cilium-gateway-homelab-gateway` → 10.10.30.20, Cluster
  - `gitlab/gitlab-shell-lb` → 10.10.30.21, Cluster
  - `monitoring/otel-collector` → 10.10.30.22, Cluster
- Metric `kube_lease_owner{lease="cilium-l2announce-home-adguard-dns", lease_holder="k8s-cp2"}` is exported by kube-state-metrics — confirmed live.
- Metric `kube_service_spec_external_traffic_policy` is NOT exported by default — kube-state-metrics needs `--metric-allowlist` extension. Task A works around this by hardcoding the service in the alert; Task D consolidates.

---

## Task A: Lease-vs-pod mismatch alert (PRIORITY 1)

**Why first:** The existing probe missed the outage. This alert catches the architectural root cause (lease/pod mismatch) regardless of where probing happens. Smallest change, highest impact.

**Files:**
- Create: `manifests/monitoring/alerts/cilium-l2-lease-alerts.yaml`
- Modify: `docs/runbooks/networking.md` (add `CiliumL2LeaseMismatch` runbook section)

- [ ] **Step 1: Verify metric availability**

Run from a host with cluster access:

```bash
kubectl-admin exec -n monitoring statefulset/prometheus-prometheus-kube-prometheus-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=kube_lease_owner{lease=~"cilium-l2announce.*"}' | \
  python3 -m json.tool | head -40
```

Expected: at least 4 series (one per LB service), each with a `lease_holder` label like `k8s-cp2`.

If empty: kube-state-metrics may need restart, OR Cilium L2 announcements aren't running — STOP and investigate.

- [ ] **Step 2: Test the PromQL expression interactively (no commit yet)**

Run from the same Prometheus shell:

```bash
kubectl-admin exec -n monitoring statefulset/prometheus-prometheus-kube-prometheus-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=absent(kube_lease_owner{lease="cilium-l2announce-home-adguard-dns"} * on(lease_holder) group_left() label_replace(kube_pod_info{namespace="home",pod=~"adguard-home-.*"}, "lease_holder", "$1", "node", "(.*)"))' | \
  python3 -m json.tool
```

Expected: `"result": []` (because lease holder cp2 == pod node cp2 → join succeeds → `absent()` returns nothing).

To test the FIRING case, you can temporarily delete the cilium-agent on cp2 (which would re-elect to cp1 or cp3, causing mismatch). **DO NOT DO THIS UNTIL Step 4 is ready** — it briefly disrupts ARP. Or simulate by querying with a fake lease name:

```bash
# Sanity: absent() with a nonexistent lease returns vector(1) — confirms the metric path
kubectl-admin exec -n monitoring statefulset/prometheus-prometheus-kube-prometheus-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=absent(kube_lease_owner{lease="DOES-NOT-EXIST"})' | \
  python3 -m json.tool
```

Expected: `"result": [{"metric":{},"value":[...,"1"]}]`

- [ ] **Step 3: Create the PrometheusRule**

Write file `manifests/monitoring/alerts/cilium-l2-lease-alerts.yaml`:

```yaml
# Cilium L2 Announcement Lease Mismatch Alert
# Phase: post-Phase 5.9.7 reliability
#
# Why this matters:
#   Cilium L2 announcement lease only re-elects when the holding cilium-agent
#   restarts or partitions. When a service pod with externalTrafficPolicy: Local
#   migrates to a different node, the lease can stay on the old node. ARP
#   resolves the LB VIP to the old node's MAC, which has no local backend, and
#   Cilium silently drops external traffic.
#
#   In-cluster blackbox probe (manifests/monitoring/probes/adguard-dns-probe.yaml)
#   does NOT catch this — Cilium overlay forwards in-cluster traffic regardless
#   of Local policy. Only cross-VLAN clients (LAN devices via OPNsense) break.
#
# Incidents this catches:
#   - 2026-04-24 to 2026-04-28 Phase 5.3 outage (~6 weeks undetected)
#   - 2026-05-26 outage (caught manually after user reported no internet)
#
# Fix runbook:
#   docs/runbooks/networking.md#CiliumL2LeaseMismatch
#
# Currently restricted to AdGuard (the only Local-policy LB service).
# To extend to other services when added: append another `alert:` block per
# service, OR enable `kube_service_spec_external_traffic_policy` in
# kube-state-metrics and rewrite as a generic alert (see Task D).
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-l2-lease-alerts
  namespace: monitoring
  labels:
    release: prometheus
    app.kubernetes.io/part-of: kube-prometheus-stack
spec:
  groups:
    - name: cilium-l2-lease
      rules:
        # Fires when the AdGuard L2 lease holder node does NOT match any AdGuard pod's node.
        # With externalTrafficPolicy: Local, this means ARP resolves to a node with no
        # backend → silent packet drop for cross-VLAN clients.
        - alert: CiliumL2LeaseMismatch
          expr: |
            absent(
              kube_lease_owner{lease="cilium-l2announce-home-adguard-dns"}
              * on(lease_holder) group_left()
              label_replace(
                kube_pod_info{namespace="home", pod=~"adguard-home-.*"},
                "lease_holder", "$1", "node", "(.*)"
              )
            )
          for: 5m
          labels:
            severity: critical
            service: adguard-dns
          annotations:
            summary: "AdGuard L2 lease holder does not match pod node"
            description: |
              The Cilium L2 announcement lease for `home/adguard-dns` (VIP 10.10.30.53)
              is held by a node that has no AdGuard pod running.
              LAN clients will lose DNS resolution within ~60s as OPNsense ARP cache
              refreshes to the (dead) lease holder MAC.
            runbook_url: "https://github.com/rommelporras/homelab/blob/main/docs/runbooks/networking.md#CiliumL2LeaseMismatch"
```

- [ ] **Step 4: Apply via GitOps (ArgoCD auto-sync) and verify discovery**

Commit + push (this is GitOps managed via `monitoring-manifests` Application). ArgoCD auto-syncs within ~3 minutes.

```bash
# /commit slash command — DO NOT run git add/commit directly per project rules
```

Then verify Prometheus picked up the rule:

```bash
kubectl-admin exec -n monitoring statefulset/prometheus-prometheus-kube-prometheus-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/rules?type=alert' | \
  python3 -m json.tool | grep -A 3 CiliumL2LeaseMismatch
```

Expected: rule appears, `state: inactive`.

- [ ] **Step 5: Fire-drill test (verifies alert fires + doesn't false-positive)**

Trigger a real mismatch to confirm the alert fires:

```bash
# Identify current AdGuard pod's node
POD_NODE=$(kubectl-admin get pod -n home -l app=adguard-home -o jsonpath='{.items[0].spec.nodeName}')
echo "AdGuard pod on: $POD_NODE"

# Identify current lease holder
LEASE_HOLDER=$(kubectl-admin get lease -n kube-system cilium-l2announce-home-adguard-dns -o jsonpath='{.spec.holderIdentity}')
echo "Lease holder: $LEASE_HOLDER"

# They should match. To force a mismatch, restart the cilium-agent on the pod's node:
# (This briefly disrupts ARP for any LB on that node — choose a low-traffic window.)
CILIUM_POD=$(kubectl-admin get pods -n kube-system -l k8s-app=cilium -o jsonpath="{.items[?(@.spec.nodeName=='$POD_NODE')].metadata.name}")
kubectl-admin delete pod -n kube-system "$CILIUM_POD"

# Wait 6 minutes (for: 5m + 1m buffer), check alert state:
sleep 360
kubectl-admin exec -n monitoring statefulset/prometheus-prometheus-kube-prometheus-prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/alerts' | \
  python3 -m json.tool | grep -B 2 -A 10 CiliumL2LeaseMismatch
```

Expected: `state: firing` IF the lease re-elected to a node without the pod. If it re-elected to the same node (Cilium 1.19+ local-backend preference), alert stays inactive — that's the healthy case. Try the test again selecting a node that does NOT have the pod.

**Rollback after fire-drill:** if alert fires, delete cilium-agent on the (wrong) lease holder to re-elect:

```bash
kubectl-admin delete pod -n kube-system "$(kubectl-admin get pods -n kube-system -l k8s-app=cilium -o jsonpath='{.items[?(@.spec.nodeName=="'"$LEASE_HOLDER_NOW"'")].metadata.name}')"
```

- [ ] **Step 6: Add runbook entry**

Edit `docs/runbooks/networking.md` — append a `## CiliumL2LeaseMismatch` section:

```markdown
## CiliumL2LeaseMismatch

**Symptom:** External clients can't reach a LoadBalancer VIP, but cluster-internal traffic works fine. Affects services with `externalTrafficPolicy: Local`.

**Root cause:** Cilium L2 announcement lease holder is on a node where the backing pod no longer runs. ARP resolves the VIP to that node's MAC; with `Local` policy, Cilium drops the packet because there's no local backend.

**Diagnose:**

\`\`\`bash
# Compare lease holder vs pod location
kubectl-admin get lease -n kube-system cilium-l2announce-<ns>-<svc> -o jsonpath='{.spec.holderIdentity}'
kubectl-admin get pods -n <ns> -l <selector> -o jsonpath='{.items[*].spec.nodeName}'
\`\`\`

**Fix:** Delete the cilium-agent pod on the current lease holder node. Cilium 1.19+ has local-backend preference, so re-election picks a node with a ready endpoint.

\`\`\`bash
LEASE_HOLDER=$(kubectl-admin get lease -n kube-system cilium-l2announce-<ns>-<svc> -o jsonpath='{.spec.holderIdentity}')
CILIUM_POD=$(kubectl-admin get pods -n kube-system -l k8s-app=cilium -o jsonpath="{.items[?(@.spec.nodeName=='$LEASE_HOLDER')].metadata.name}")
kubectl-admin delete pod -n kube-system "$CILIUM_POD"
\`\`\`

**Expected impact:** ~15-30s ARP gap on all VIPs held by that cilium-agent. No data loss.

**Long-term prevention:** Task D in `docs/todo/adguard-l2-resilience.md` — split the catch-all `CiliumL2AnnouncementPolicy` so re-election only affects the targeted service.
```

- [ ] **Step 7: Commit Task A**

Run `/commit` — Claude will security-scan the changed files first, then craft the message. Suggested format:

```
infra(monitoring): add CiliumL2LeaseMismatch alert for adguard

Catches the L2 lease/pod node mismatch failure mode that the in-cluster
AdGuardDNSDown probe cannot detect (Phase 5.3 incident, 2026-05-26 outage).
```

---

## Task B: Restrict AdGuard "local upstream" to cluster.local (PRIORITY 2)

**Why:** During the 2026-05-26 spike (2,335 QPM at 10:21 UTC), AdGuard fired 621 `i/o timeout` errors trying to reach `10.96.0.10:53` (CoreDNS). LAN clients query mostly internet hostnames; those have no business hitting kube-dns. Restricting the local upstream to the `cluster.local` domain eliminates the failure mode.

**The complication:** The runtime AdGuard config lives on the PVC, not in the ConfigMap (the `init-config` initContainer only copies the ConfigMap on first boot). Editing the ConfigMap won't take effect on a running pod. Two options:

| Approach | Effort | Pros | Cons |
|---|---|---|---|
| **B1: Edit via AdGuard UI** | Trivial | Immediate, no scripting | Drift between ConfigMap and runtime; loses on PVC restore |
| **B2: Script that patches `/opt/adguardhome/conf/AdGuardHome.yaml` directly** | Medium | Reproducible, scriptable | Mutates PVC outside ArgoCD |
| **B3: Delete PVC config file + restart pod (rebootstrap from ConfigMap)** | Easy | ConfigMap becomes truth | Loses all UI-only state (filters, clients, etc.) |

**Recommendation: B1 + update ConfigMap as documentation.** This is what the project already does for runtime AdGuard settings (the ConfigMap is the first-boot template, runtime UI is the source of truth). Keep ConfigMap in sync so a future PVC rebuild produces the correct config.

**Files:**
- Modify: `manifests/home/adguard/configmap.yaml` (lines 41-47 in upstream_dns block, plus a new "Local upstreams" block under the relevant section)
- (Manual UI step on AdGuard admin)

- [ ] **Step 1: Inspect current runtime upstream config**

Open AdGuard UI at `https://adguard.k8s.rommelporras.com/`. Login (credentials in 1Password "AdGuard Home" item).

Settings → DNS settings. Note the current "Upstream DNS servers" — should include the standard DoH list (Mullvad, Quad9, Cloudflare) plus the line that's currently causing trouble. Expected pattern:

```
[/cluster.local/]10.96.0.10
# or possibly the bare upstream without domain scoping
10.96.0.10
```

If it's the bare form (no `[/cluster.local/]`), that's the bug — AdGuard tries kube-dns for EVERY query alongside DoH.

- [ ] **Step 2: Update runtime config via UI**

In Settings → DNS settings → Upstream DNS servers, ensure the kube-dns entry uses domain-scoped syntax:

```
# DNS over HTTPS (DoH) - primary upstreams (parallel mode)
https://dns.mullvad.net/dns-query
https://dns11.quad9.net/dns-query
https://dns.cloudflare.com/dns-query

# Local upstream — ONLY for cluster.local resolution
[/cluster.local/]10.96.0.10
```

Click "Apply" — AdGuard reloads dnsproxy.

- [ ] **Step 3: Verify by inspecting query routing**

```bash
# Internal name → should hit kube-dns
kubectl-admin exec -n home adguard-home-XXXXX -c adguard-home -- \
  nslookup tdarr.arr-stack.svc.cluster.local 127.0.0.1 | tail -5

# External name → should NOT touch kube-dns
# (Check error log — should not see new timeouts to 10.96.0.10)
kubectl-admin logs -n home adguard-home-XXXXX -c adguard-home --since=2m | \
  grep "10.96.0.10" | wc -l
```

Expected: internal name resolves correctly, recent log shows zero or near-zero 10.96.0.10 entries.

- [ ] **Step 4: Update ConfigMap to match (template-of-record)**

Edit `manifests/home/adguard/configmap.yaml`. Around line 41, change `upstream_dns:` block to:

```yaml
      upstream_dns:
        - '# DNS over HTTPS (DoH) - primary'
        - https://dns.mullvad.net/dns-query
        - https://dns11.quad9.net/dns-query
        - https://dns.cloudflare.com/dns-query
        - '# Local upstream - ONLY for cluster.local resolution'
        - '# Domain scoping prevents kube-dns timeouts during traffic spikes.'
        - '# Without [/cluster.local/], every internet query forks to kube-dns.'
        - '[/cluster.local/]10.96.0.10'
```

Note: this ConfigMap change only takes effect on PVC rebuild. The UI change in Step 2 is what makes it live.

- [ ] **Step 5: Commit Task B**

`/commit` with message like:

```
infra(adguard): scope kube-dns upstream to cluster.local

Without domain scoping, every external DNS query forked to kube-dns at
10.96.0.10. During the 2026-05-26 2,335 QPM spike this produced 621
timeouts in 1 minute. Domain-scoping limits kube-dns to .cluster.local
names only, eliminating the failure mode.
```

---

## Task C: AdGuard querylog rotation tuning (PRIORITY 3)

**Why:** Current querylog file is 2.0 GB after ~90 days at default settings. PVC isn't tight, but a smaller log speeds up pod cold starts (initial scan) and reduces the per-restart memory footprint.

**Files:**
- Modify: `manifests/home/adguard/configmap.yaml` (lines 120-133, `querylog:` block)
- (Manual UI step to apply at runtime — same PVC vs ConfigMap pattern as Task B)

- [ ] **Step 1: Decide retention window**

Currently `interval: 2160h` (90 days). Options:
- `720h` (30 days) — common middle ground
- `168h` (7 days) — aggressive, only useful for live debugging

**Recommendation: 720h (30 days).** Strikes a balance between forensics and disk usage.

- [ ] **Step 2: Update via AdGuard UI**

Settings → General settings → Query log retention → set to "30 days". Click Save.

Settings → General settings → Statistics retention → also "30 days" (separate setting, keep consistent).

- [ ] **Step 3: Update ConfigMap to match**

Edit `manifests/home/adguard/configmap.yaml` line 130:

```yaml
    querylog:
      dir_path: ""
      ignored:
        - gnar.grammarly.com
        - treatment.grammarly.com
        - '*.grammarly.io'
        - api.segment.io
        - '*.gvt2.com'
        - '*.gvt3.com'
        - wpad.rommelporras.com
      interval: 720h          # was 2160h (90d), reduced 2026-XX-XX
      size_memory: 1000
      enabled: true
      file_enabled: true
```

Also check `statistics:` block (line 134-ish) — change its `interval:` similarly.

- [ ] **Step 4: Verify size shrinks**

AdGuard rotates the querylog when the existing file exceeds the new retention window. After ~24h, file size should drop. Check:

```bash
kubectl-admin exec -n home adguard-home-XXXXX -c adguard-home -- \
  ls -lh /opt/adguardhome/work/data/querylog*.json
```

Expected: file size noticeably smaller within 1-2 days (old entries trimmed).

- [ ] **Step 5: Commit Task C**

`/commit` with message:

```
infra(adguard): reduce querylog retention to 30 days

90-day retention produced a 2GB log file. 30 days is sufficient for
typical investigation windows and reduces cold-start scan time.
```

---

## Task D: Split catch-all `homelab-l2` policy into per-service (PRIORITY 4)

**Why:** The single `homelab-l2` `CiliumL2AnnouncementPolicy` matches all LoadBalancer IPs. When any cilium-agent restarts, ALL leases it held re-elect together. This is observable behavior — today's fix unintentionally moved gateway/gitlab-shell/otel-collector leases off cp3 even though they were healthy there.

Per-service policies with explicit `serviceSelector` mean:
- Re-electing AdGuard's lease (the one with `Local` policy) doesn't touch others.
- Each service can have node affinity hints (e.g., "AdGuard lease should prefer the same node as the AdGuard pod").

**This task supersedes the existing "Cilium L2 Announcement Lease Auto-Rebalance" item in `docs/todo/deferred.md`.**

**Files:**
- Modify: `manifests/cilium/l2-announcement.yaml` (replace single resource with 4)
- Modify: `docs/todo/deferred.md` (mark item complete, link to this plan)

- [ ] **Step 1: Read current policy**

```bash
cat manifests/cilium/l2-announcement.yaml
```

Note the existing single `homelab-l2` resource matches all LBs on all linux nodes.

- [ ] **Step 2: Plan per-service replacements**

Inventory (verified 2026-05-26):
- `default/cilium-gateway-homelab-gateway` (10.10.30.20) — Cluster
- `gitlab/gitlab-shell-lb` (10.10.30.21) — Cluster
- `monitoring/otel-collector` (10.10.30.22) — Cluster
- `home/adguard-dns` (10.10.30.53) — **Local** (the sensitive one)

- [ ] **Step 3: Rewrite the manifest**

Replace `manifests/cilium/l2-announcement.yaml` with:

```yaml
# Cilium L2 Announcement Policies — one per LoadBalancer service.
#
# Why one-per-service instead of a single catch-all:
#   The lease for each L2-announced VIP is independent. With a catch-all
#   policy, restarting a cilium-agent re-elects ALL leases that node held,
#   even ones working fine. With per-service policies, you can target a
#   single service's re-election without disturbing others.
#
# Each policy uses `serviceSelector` to match a specific Service by
# namespace + label, so adding a new LB service requires a new policy
# (intentional — explicit > implicit).
#
# Docs: https://docs.cilium.io/en/stable/network/l2-announcements/
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: adguard-dns-l2
spec:
  serviceSelector:
    matchLabels:
      app: adguard-home
  interfaces:
    - ^eno.*
    - ^eth.*
    - ^enp.*
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  loadBalancerIPs: true
  externalIPs: true
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: cilium-gateway-l2
spec:
  serviceSelector:
    matchLabels:
      io.cilium.gateway/owning-gateway: homelab-gateway
  interfaces:
    - ^eno.*
    - ^eth.*
    - ^enp.*
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  loadBalancerIPs: true
  externalIPs: true
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: gitlab-shell-l2
spec:
  serviceSelector:
    matchLabels:
      app: gitlab
      component: gitlab-shell
  interfaces:
    - ^eno.*
    - ^eth.*
    - ^enp.*
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  loadBalancerIPs: true
  externalIPs: true
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: otel-collector-l2
spec:
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: opentelemetry-collector
  interfaces:
    - ^eno.*
    - ^eth.*
    - ^enp.*
  nodeSelector:
    matchLabels:
      kubernetes.io/os: linux
  loadBalancerIPs: true
  externalIPs: true
```

**Verify the labels before applying** — each `serviceSelector.matchLabels` must actually match the corresponding Service. Run:

```bash
for svc in "default/cilium-gateway-homelab-gateway" "gitlab/gitlab-shell-lb" "monitoring/otel-collector" "home/adguard-dns"; do
  ns="${svc%/*}"; name="${svc#*/}"
  echo "=== $svc ==="
  kubectl-admin get svc -n "$ns" "$name" -o jsonpath='{.metadata.labels}' | python3 -m json.tool
  echo
done
```

Use the actual labels returned. If `cilium-gateway-homelab-gateway` doesn't carry the `io.cilium.gateway/owning-gateway` label (depends on Cilium version), substitute with whatever it actually has.

- [ ] **Step 4: Apply + verify leases stable**

Commit via `/commit`. ArgoCD auto-syncs `cilium` Application within 3 min (note: `cilium` is the only manual-sync Helm app per CLAUDE.md, BUT the `l2-announcement.yaml` is in `manifests/cilium/` which may be its own Application — check `manifests/argocd/apps/` for the routing).

After sync, verify:

```bash
kubectl-admin get ciliuml2announcementpolicy
# Expected: 4 policies (adguard-dns-l2, cilium-gateway-l2, gitlab-shell-l2, otel-collector-l2)
# Old: homelab-l2 should be gone.

kubectl-admin get lease -n kube-system | grep cilium-l2announce
# Expected: still 4 leases, holders may have shuffled (one-time re-election on policy change).
```

Confirm each lease holder makes sense (matches a Cluster-policy backend's location, or matches the AdGuard pod for the Local policy).

- [ ] **Step 5: Update deferred.md**

Edit `docs/todo/deferred.md`. Find the "Cilium L2 Announcement Lease Auto-Rebalance" item. Replace its body with:

```markdown
## Cilium L2 Announcement Lease Auto-Rebalance — RESOLVED 2026-XX-XX

Implemented per-service `CiliumL2AnnouncementPolicy` (see git history of
`manifests/cilium/l2-announcement.yaml`). Re-electing one service's lease
no longer disturbs others. Combined with `CiliumL2LeaseMismatch` alert
(`manifests/monitoring/alerts/cilium-l2-lease-alerts.yaml`), the failure
mode that caused the Phase 5.3 and 2026-05-26 outages is now detected
within 5 minutes and remediable without collateral disruption.
```

- [ ] **Step 6: Commit Task D**

`/commit` with message:

```
infra(cilium): split L2 announcement policy per-service

Replaces the single homelab-l2 policy with four targeted policies
(adguard, gateway, gitlab-shell, otel-collector). Re-electing one
service's lease no longer shuffles others. Resolves the deferred item
"Cilium L2 Announcement Lease Auto-Rebalance".
```

---

## Task E: Decision — `externalTrafficPolicy: Local` vs `Cluster` for AdGuard

**This is not an implementation task — it's a design decision to make BEFORE doing Task A or D.**

AdGuard's service uses `externalTrafficPolicy: Local`. This is the root cause of the lease/pod coupling. Switching to `Cluster` eliminates the entire class of L2 lease bugs at the cost of one feature:

| Aspect | Local (current) | Cluster (alternative) |
|---|---|---|
| Client IP visible to AdGuard | Real LAN IP (e.g. 10.10.20.16) | Source-NAT'd (cluster node IP) |
| L2 lease/pod coupling | Required (broken if mismatched) | Not required (any node forwards) |
| Per-client filtering in AdGuard UI | Works | Broken (all queries look like they come from cluster nodes) |
| Per-client stats / blocklists | Works | Broken |

**Question for the user:** Do you actively use per-client rules in AdGuard? (Different filters/blocklists for phone vs Windows vs IoT devices?)

- **Yes →** Keep `Local`. Tasks A + D mitigate the operational pain. Do not do Task E.
- **No →** Switch to `Cluster`. Task E (below) is a one-line manifest change, and Tasks A + D become much lower priority (alert still useful for forensics, but lease drift no longer breaks the service).

**If switching to Cluster (only if user answered No above):**

Edit `manifests/home/adguard/service.yaml`, change:

```yaml
spec:
  externalTrafficPolicy: Local  # → change to Cluster
```

Commit via `/commit`. ArgoCD auto-syncs. Verify:

```bash
kubectl-admin get svc -n home adguard-dns -o jsonpath='{.spec.externalTrafficPolicy}'
# Expected: Cluster

# Watch a few queries — client IPs should now be cluster node IPs:
kubectl-admin exec -n home adguard-home-XXXXX -c adguard-home -- \
  sh -c 'tail -100 /opt/adguardhome/work/data/querylog.json | grep -oE "\"IP\":\"[^\"]+\"" | sort -u'
# Expected: only 10.0.x.x or 10.10.30.1[123] (cluster pod/node IPs), no 10.10.20.x
```

---

## Execution Order Recommendation

1. **Task E decision first** (5 min talk with yourself) — gates priority of A/D
2. **Task A** (lease mismatch alert) — 30 min, no risk
3. **Task C** (querylog tuning) — 10 min, no risk
4. **Task B** (local upstream scoping) — 20 min, low risk (one UI change + ConfigMap sync)
5. **Task D** (per-service L2 policies) — 1-2 hr, medium risk (causes one-time lease re-election shuffle on apply)

Total: ~3 hours of focused work, splittable across multiple sessions. Each task is independently shippable.

---

## Self-Review Notes (writing-plans skill)

- **Spec coverage:** All 4 improvements from the 2026-05-26 investigation are covered (A=alert, B=local upstream, C=querylog, D=per-service L2 policy), plus E as a design decision gate.
- **No placeholders:** Each step has the actual YAML/command/edit content. `XXXXX` in pod-name examples is intentional (real pod hash changes per restart — user fills in via `kubectl get pod`).
- **Type consistency:** Lease name `cilium-l2announce-home-adguard-dns` is identical across Tasks A and D. Label selectors in Task D require runtime verification before apply (Step 3 includes the verification command).
- **TDD note:** This plan is operational/infra (no unit tests). Task A has a fire-drill verification step which is the closest analog to "test fails first, then passes."

---

## Quick Resume Checklist (for future sessions)

When picking this up in a new session, paste this into Claude:

```
We're continuing the AdGuard/L2 resilience plan at docs/todo/adguard-l2-resilience.md.

Status:
- [ ] Task E decided (Local vs Cluster):
- [ ] Task A (lease mismatch alert) shipped
- [ ] Task B (local upstream scoping) shipped
- [ ] Task C (querylog retention) shipped
- [ ] Task D (per-service L2 policies) shipped

Next up: <pick the next unchecked task>
```
