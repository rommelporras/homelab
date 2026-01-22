# Phase 3.10: Dead Man's Switch (Alertmanager Health Monitoring)

> **Status:** ⬜ Planned
> **Target:** v0.6.2
> **DevOps Topics:** Alerting reliability, external health monitoring, webhook integrations

> **Purpose:** Monitor Alertmanager health via healthchecks.io heartbeat
> **Current:** Watchdog alert disabled (noise in Discord)
> **Target:** Watchdog → healthchecks.io → Discord/Email alerts if alerting breaks

---

## Background

### What is Watchdog?

Watchdog is a "dead man's switch" alert that **always fires** to prove the alerting pipeline works.

```
Normal operation:
  Watchdog fires → External service receives heartbeat → All good

Alerting broken:
  Watchdog stops → External service detects missing heartbeat → Alerts YOU
```

### Why healthchecks.io?

| Service | Cost | Features | Issue |
|---------|------|----------|-------|
| **healthchecks.io** | Free (20 checks) | Simple ping URL, Discord integration | ✅ Best choice |
| UptimeRobot | Free tier exists | Has status page | ❌ Heartbeat requires paid plan |
| PagerDuty DeadMansSnitch | Paid | Enterprise features | ❌ Overkill for homelab |

healthchecks.io free tier:
- 20 checks
- 3 team members
- Ping URL: `https://hc-ping.com/<uuid>`
- Accepts GET/POST/HEAD requests
- Discord, Slack, Email integrations
- Rate limit: 5 pings/minute (we send 1/min - well within limit)

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Alertmanager                             │
│  Watchdog alert fires every 1 minute                        │
└─────────────────────┬───────────────────────────────────────┘
                      │ POST (webhook)
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    healthchecks.io                          │
│  Check: "K8s Alertmanager"                                  │
│  - Period: 1 minute                                         │
│  - Grace: 5 minutes                                         │
│  - If no ping within grace → marks DOWN → alerts            │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                    Notifications                            │
│  - Discord webhook (same channel as other alerts)           │
│  - Email (backup)                                           │
└─────────────────────────────────────────────────────────────┘
```

---

## 3.10.1 Create healthchecks.io Check

- [ ] 3.10.1.1 Create account at healthchecks.io
  ```
  https://healthchecks.io/
  Sign up with email or GitHub
  ```

- [ ] 3.10.1.2 Create new check
  - Click "Add Check"
  - Name: `K8s Alertmanager`
  - Period: **1 minute** (matches Watchdog repeat_interval)
  - Grace: **5 minutes** (time to wait before alerting)
  - Tags: `homelab`, `alertmanager`

- [ ] 3.10.1.3 Copy the ping URL
  ```
  Format: https://hc-ping.com/<uuid>
  Example: https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

- [ ] 3.10.1.4 Configure Discord integration
  - Go to Integrations → Discord
  - Add your Discord webhook URL (same one used for Alertmanager)
  - Test the integration

- [ ] 3.10.1.5 (Optional) Configure email integration
  - Go to Integrations → Email
  - Add your email as backup notification

---

## 3.10.2 Store Ping URL in 1Password

- [ ] 3.10.2.1 Create 1Password item
  ```
  Vault: Kubernetes
  Item Name: Healthchecks Ping URL
  Field: url
  Value: https://hc-ping.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ```

- [ ] 3.10.2.2 Verify item access
  ```bash
  op read "op://Kubernetes/Healthchecks Ping URL/url"
  ```

---

## 3.10.3 Update Alertmanager Configuration

- [ ] 3.10.3.1 Re-enable Watchdog alert in `helm/prometheus/values.yaml`
  ```yaml
  # Remove Watchdog from disabled list
  defaultRules:
    disabled:
      InfoInhibitor: true
      # Watchdog: true  ← DELETE THIS LINE
  ```

- [ ] 3.10.3.2 Add healthchecks-heartbeat receiver in `helm/prometheus/values.yaml`
  ```yaml
  # In alertmanager.config.receivers (after the 'null' receiver, ~line 230):
  - name: 'healthchecks-heartbeat'
    webhook_configs:
      - url: 'SET_VIA_HELM'  # Injected from 1Password at runtime
        send_resolved: false  # Only send firing, not resolved
  ```

  > **Note:** This is a placeholder. The real URL is injected by the upgrade script.

- [ ] 3.10.3.3 Add Watchdog route in `helm/prometheus/values.yaml`
  ```yaml
  # In alertmanager.config.route.routes
  # Add AFTER the TargetDown silence (~line 174) and BEFORE severity routes:

        # Watchdog → healthchecks.io heartbeat (dead man's switch)
        - match:
            alertname: Watchdog
          receiver: 'healthchecks-heartbeat'
          repeat_interval: 1m  # Ping every minute
          continue: false

        # Critical alerts → #incidents + Email
        - match:
            severity: critical
  ```

---

## 3.10.4 Update Upgrade Script

The upgrade script injects real secrets at runtime, overriding the `SET_VIA_HELM` placeholders in values.yaml.

- [ ] 3.10.4.1 Add ping URL to secrets reading in `scripts/upgrade-prometheus.sh`
  ```bash
  # Add after SMTP_PASSWORD line (~line 62):
  HEALTHCHECKS_PING_URL=$(op read "op://Kubernetes/Healthchecks Ping URL/url")
  ```

- [ ] 3.10.4.2 Add to confirmation output (~line 69)
  ```bash
  echo "  - Healthchecks ping URL: ****"
  ```

- [ ] 3.10.4.3 Add receiver to temp secrets file
  ```yaml
  # Add after the 'null' receiver in the TEMP_SECRETS_FILE heredoc (~line 111):
      - name: 'healthchecks-heartbeat'
        webhook_configs:
          - url: "${HEALTHCHECKS_PING_URL}"
            send_resolved: false
  ```

  > **Why both files?** values.yaml documents the config (GitOps). The script injects actual secrets at runtime, replacing placeholders.

---

## 3.10.5 Apply and Verify

- [ ] 3.10.5.1 Run upgrade script
  ```bash
  eval $(op signin)
  ./scripts/upgrade-prometheus.sh
  ```

- [ ] 3.10.5.2 Verify Watchdog is firing
  ```bash
  kubectl-homelab -n monitoring exec -it \
    $(kubectl-homelab -n monitoring get pod -l app.kubernetes.io/name=alertmanager -o name | head -1) \
    -- amtool alert query alertname=Watchdog
  ```

- [ ] 3.10.5.3 Verify webhook is being called
  ```bash
  # Check Alertmanager logs for successful webhook calls
  kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=100 | grep -i webhook
  ```

- [ ] 3.10.5.4 Check healthchecks.io dashboard
  - Check should show green "Up" status
  - Last ping time should be recent (< 2 minutes)
  - Ping history should show regular pings

- [ ] 3.10.5.5 Test dead man's switch (critical verification)
  This is the most valuable verification - proves the whole chain works.
  ```bash
  # Scale Alertmanager to 0
  kubectl-homelab -n monitoring scale statefulset alertmanager-prometheus-kube-prometheus-alertmanager --replicas=0

  # Wait 5+ minutes (grace period), check healthchecks.io shows DOWN

  # Restore Alertmanager
  kubectl-homelab -n monitoring scale statefulset alertmanager-prometheus-kube-prometheus-alertmanager --replicas=1
  ```
  - Verify healthchecks.io marks check as DOWN after ~5 minutes
  - Verify you receive Discord notification
  - Verify it recovers to UP after restore

---

## 3.10.6 Documentation Updates

- [ ] 3.10.6.1 Update VERSIONS.md
  - Add to Alerting & Notifications section:
    ```
    | healthchecks.io | K8s Alertmanager check | Configured |
    ```
  - Add version history entry

- [ ] 3.10.6.2 Update docs/context/Monitoring.md
  - Add healthchecks.io integration section

- [ ] 3.10.6.3 Update docs/context/Secrets.md
  - Add Healthchecks Ping URL 1Password item

---

## Verification Checklist

- [ ] healthchecks.io account created
- [ ] Check "K8s Alertmanager" created with 1m period, 5m grace
- [ ] Discord integration configured in healthchecks.io
- [ ] Ping URL stored in 1Password (Kubernetes vault)
- [ ] Watchdog re-enabled (removed from disabled list)
- [ ] healthchecks-heartbeat receiver added to values.yaml
- [ ] Watchdog route added to values.yaml
- [ ] Upgrade script updated with HEALTHCHECKS_PING_URL
- [ ] `upgrade-prometheus.sh` runs without errors
- [ ] Watchdog alert is firing (amtool query)
- [ ] healthchecks.io shows regular pings (green status)
- [ ] Dead man's switch test passed (scaled to 0, received alert)

---

## Final: Commit and Release

- [ ] Commit changes
  ```bash
  /commit
  ```

- [ ] Release v0.6.2
  ```bash
  /release v0.6.2
  ```

- [ ] Move this file to completed folder
  ```bash
  mv docs/todo/phase-3.10-deadman-switch.md docs/todo/completed/
  ```

---

## Rollback

If issues occur:

1. **Disable Watchdog again** (quick fix)
   ```yaml
   defaultRules:
     disabled:
       InfoInhibitor: true
       Watchdog: true  # Re-add this
   ```

2. **Run upgrade script** to apply

3. **healthchecks.io** will show DOWN (expected - no heartbeats)
   - Can pause the check in healthchecks.io dashboard

---

## Troubleshooting

### Watchdog not firing

```bash
# Check if Watchdog rule exists
kubectl-homelab -n monitoring exec -it \
  $(kubectl-homelab -n monitoring get pod -l app.kubernetes.io/name=prometheus -o name | head -1) \
  -- promtool query rules 2>/dev/null | grep -i watchdog

# Check Prometheus rules
kubectl-homelab get prometheusrules -n monitoring -o yaml | grep -A5 Watchdog
```

### healthchecks.io not receiving pings

```bash
# Check Alertmanager config is correct
kubectl-homelab -n monitoring get secret alertmanager-prometheus-kube-prometheus-alertmanager -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d | grep -A3 healthchecks

# Test ping URL manually
curl -fsS -m 10 --retry 5 "$(op read 'op://Kubernetes/Healthchecks Ping URL/url')" && echo "OK"

# Check Alertmanager logs for errors
kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=100 | grep -i error
```

### Discord notification not received

1. Check healthchecks.io Integrations → Discord is configured
2. Test the integration manually from healthchecks.io dashboard
3. Check the Discord webhook URL is valid

---

## Related Changes (Already Done)

These changes are already in the working tree, pending commit:

| Change | File | Status |
|--------|------|--------|
| Disable InfoInhibitor | helm/prometheus/values.yaml | ✅ Done |
| Disable Watchdog (temporary) | helm/prometheus/values.yaml | ✅ Done |
| Fix KUBECONFIG in script | scripts/upgrade-prometheus.sh | ✅ Done |

---

## Notes

- **Watchdog repeat_interval:** Set to 1m to match healthchecks.io period setting.
- **healthchecks.io grace period:** Set to 5 minutes. If Watchdog stops pinging, healthchecks.io waits 5 minutes before alerting (handles brief network blips).
- **send_resolved: false:** Watchdog never resolves (always firing), so no need to send resolved notifications.
- **InfoInhibitor:** Stays disabled. It's internal plumbing we don't use.
- **Rate limit:** healthchecks.io allows 5 pings/minute. We send 1 ping/minute - well within limits.
