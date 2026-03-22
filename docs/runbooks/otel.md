# OpenTelemetry Runbook

Covers: Claude Code metrics, dotctl configuration drift, OTel Collector health

---

## ClaudeCodeHighDailySpend

**Severity:** warning

Daily Claude Code API spend has exceeded $100 in the last 24 hours. The metric is derived from `claude_code_cost_usage_USD_total` (counter), aggregated with `increase()` over a 24-hour window.

### Triage Steps

1. Open the Claude Code metrics dashboard in Grafana and check the cost-per-session breakdown for the past 24 hours.
2. Review recent Claude Code sessions to identify which tasks drove the spike.
3. If spend is trending toward the critical threshold ($150), consider wrapping up active sessions and avoiding new long-running tasks until the 24-hour window resets.

---

## ClaudeCodeCriticalDailySpend

**Severity:** critical

Daily Claude Code API spend has exceeded $150 in the last 24 hours. This is above the upper cost threshold and may indicate a runaway or looping session.

### Triage Steps

1. Open the Claude Code metrics dashboard in Grafana and identify which sessions contributed the most cost.
2. Check for any long-running or looping agent sessions that may not have terminated cleanly.
3. Consider pausing active Claude Code usage until the 24-hour rolling window resets.
4. If the spend is clearly anomalous, investigate whether the OTel pipeline is double-counting (e.g. duplicate scrape targets or metric label collisions).

---

## ClaudeCodeNoActivity

**Severity:** info

No Claude Code API usage has been detected in the last 8 hours during business hours (weekdays 09:00-11:00 local). This fires when the `claude_code_cost_usage_USD_total` metric is absent - which can mean Claude Code is genuinely idle, or that the telemetry pipeline has a gap.

### Triage Steps

1. Confirm whether Claude Code has actually been used today. If it has not, this alert is expected and can be silenced.
2. If Claude Code has been used but the alert fired, the OTel pipeline may be broken. Check the `OTelCollectorDown` alert and collector pod logs.
3. Verify the OTel Collector is scraping the correct endpoint and that metrics are flowing into Prometheus.

---

## OTelCollectorDown

**Severity:** critical

Prometheus cannot scrape the OTel Collector (`up{job="otel-collector"} == 0`). All telemetry - Claude Code cost metrics and dotctl drift metrics - is not being collected while this fires.

### Triage Steps

1. Check the OTel Collector pod status:
   ```
   kubectl-homelab get pods -n monitoring -l app=otel-collector
   ```
2. Check pod logs for startup errors or configuration issues:
   ```
   kubectl-homelab logs -n monitoring -l app=otel-collector --tail=50
   ```
3. Verify the Prometheus scrape target is correctly configured and that the collector's metrics port (`:8889`) is reachable from Prometheus.
4. If the pod is in `CrashLoopBackOff`, check the collector ConfigMap for syntax errors and redeploy after fixing.

---

## DotctlCollectionStale

**Severity:** warning

No dotctl collection data has been received in over 30 minutes during business hours (weekdays 08:00-18:00 PHT). The alert uses `absent_over_time(dotctl_collect_timestamp[35m])` to avoid false positives after OTel Collector restarts (metrics are in-memory only).

### Triage Steps

1. Check the dotctl CronJob or systemd timer on the reporting machine to confirm it is still running:
   ```
   systemctl status dotctl-collect.timer
   journalctl -u dotctl-collect.service --since "1 hour ago"
   ```
2. Verify the machine can reach the OTel Collector endpoint (network connectivity, DNS, firewall).
3. If the OTel Collector was recently restarted, the in-memory metric will be missing until the next collection run completes - wait one collection interval and confirm the alert clears.
4. If the timer has stopped, re-enable it: `systemctl enable --now dotctl-collect.timer`.

---

## DotctlDriftDetected

**Severity:** info

One or more dotfiles on a tracked machine have diverged from the repository state and the drift has persisted for over 1 hour (`dotctl_drift_total > 0` for `1h`). This alert is visible in the Alertmanager UI only - it does not route to Discord.

### Triage Steps

1. Check which machine has drift and which files are affected:
   ```
   dotctl status --machine <hostname>
   ```
2. Review the diff to determine whether the change is intentional (e.g. a local override) or unintentional (e.g. an app modified a tracked config file).
3. If the change is intentional, commit it to the dotfiles repository and push so the baseline is updated.
4. If the change is unintentional, restore the file from the repository:
   ```
   dotctl apply --machine <hostname> --file <path>
   ```
