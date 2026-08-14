---
name: homelab-alert-triage
description: |
  Triggered by: "investigate alerts", "what is firing", "why am I getting alerts",
  "triage", "cluster health". Enumerates firing alerts via Prometheus/Alertmanager
  APIs, collapses them to root causes, drills with kubectl, cross-references runbooks,
  and reports a tiered remediation plan. Read-only by default; defers to
  cluster-access.md and remediation-safety.md.
---

# homelab-alert-triage

Read-only by default. All kubectl commands use the restricted kubeconfig unless
logs are needed (admin kubeconfig required). Defers to `cluster-access.md` and
`remediation-safety.md` for command forms and action tiers.

## Step 1 - Verify connectivity

```bash
getent hosts api.k8s.rommelporras.com
```

If the hostname does not resolve, append `--server=https://10.10.30.10:6443` to all
subsequent `kubectl` commands (the VIP is a SAN on the API cert, TLS validates).

Confirm cluster is reachable:

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get nodes --no-headers | wc -l
```

If 0 or error, report "Cannot reach cluster" and stop.

## Step 2 - Enumerate firing alerts

Fetch from both sources and parse with jq:

```bash
curl -sS https://prometheus.k8s.rommelporras.com/api/v1/alerts \
  | jq -r '.data.alerts[] | select(.state=="firing") | [.labels.alertname, .labels.severity, (.labels.namespace // "-")] | @tsv' \
  | sort | uniq -c | sort -rn
```

```bash
curl -sS https://alertmanager.k8s.rommelporras.com/api/v2/alerts \
  | jq -r '.[] | [.labels.alertname, .labels.severity, (.labels.namespace // "-")] | @tsv' \
  | sort | uniq -c | sort -rn
```

Group by alertname, severity, and namespace. Produce a count-sorted summary table.

## Step 3 - Correlate to root causes

Do not triage alerts one by one. Look for a single root cause that explains a cluster
of alerts. Real example: 16 active alerts collapsed to 3 real problems; `loki-0` PVC
full ("no space left on device", 680 restarts) explained ~9 of them - LokiDown,
LokiIngestionStopped, AlloyNotSendingLogs, and several TargetDown alerts all traced
to that one volume.

Collapse correlated alerts and name the dominant root cause(s) before drilling.

## Step 4 - Drill for root cause

Start with read-only restricted kubeconfig:

```bash
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get pods -n <namespace> -o wide
kubectl --kubeconfig ~/.kube/homelab-claude.yaml describe pod <pod> -n <namespace>
kubectl --kubeconfig ~/.kube/homelab-claude.yaml get events -n <namespace> --sort-by='.lastTimestamp' | tail -20
```

If pod logs are needed for root cause (e.g., confirming "no space left on device"),
use the admin kubeconfig:

```bash
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n <namespace> <pod> --tail=50
kubectl --kubeconfig ~/.kube/homelab.yaml logs -n <namespace> <pod> --previous --tail=50
```

## Step 5 - Cross-reference runbooks

Look up each root-cause alert in `docs/runbooks/alert-index.md` using the `#AlertName`
anchor. Example: `docs/runbooks/alert-index.md#LokiDown` lands on the Loki section.

Also grep `CLAUDE.md` for symptom keywords - the Gotchas section is an incident
database:

```bash
grep -niE '<symptom keyword>' CLAUDE.md
```

Key gotchas relevant to alert triage:
- OOMKilled + RWO volume = mount deadlock; fix by deleting the POD, not the PVC
- StatefulSet PVC expansion requires `kubectl patch pvc` + pod delete + `--cascade=orphan` delete of SS + helm upgrade
- Loki sidecar CrashLoop: check `sidecar.rules.enabled: false` if Ruler is not in use
- gitlab `Health=Missing` with healthy pods = migrations container OOMKilled (needs >=1536Mi)

## Step 6 - Report

Produce a structured report:

1. **Firing alert count** - total and breakdown by severity
2. **Root cause(s)** - named, with the evidence (log line, event, pod state)
3. **Correlated alerts** - which alerts this root cause explains
4. **Remediation options**, classified by tier:
   - Live-safe (CONFIRM tier): pod restart, lease deletion, rollout restart
   - Structural/Git (requires homelab-deploy + homelab-orchestrator): manifest or Helm
     values change (PVC expansion, retention cut, resource limit bump, etc.)

## Step 7 - Act or hand off

- **Live-safe fix AND user confirms:** proceed using the CONFIRM-tier actions from
  `remediation-safety.md`. One action at a time; re-check after each.
- **Structural fix needed (manifest/Helm values change):** do not make the change
  directly. Report the exact diff needed and hand it to `homelab-deploy` via the
  orchestrator. Structural fixes go through Git so ArgoCD stays the source of truth.

Never act on NEVER-tier operations. Never make imperative changes to ArgoCD-managed
resources (selfHeal reverts them within ~3 minutes).
