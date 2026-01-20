# Phase 3.9: Alertmanager Notifications (Discord + Email)

> **Status:** Complete ✅
> **Target:** v0.5.0
> **Completed:** 2026-01-20
> **Prerequisite:** Phase 3.5-3.8 complete (Alertmanager running)
> **CKA Topics:** ConfigMaps, Secrets, Alertmanager configuration

---

## Overview

Configure Alertmanager to send notifications via:
1. **Discord** - Primary channel for all alerts
2. **Email (iCloud SMTP)** - Backup for critical alerts

**Current Alertmanager:** v0.30.1 (native Discord + Email support)

---

## Discord Channel Structure

```
📬 Notifications (Category)
  ├── #incidents   → Critical alerts, action required
  └── #status      → Warnings, reports, resolved, FYI
```

| Channel | Receives | Examples |
|---------|----------|----------|
| #incidents | Critical alerts | Site down, UPS low battery, node down |
| #status | Everything else | Speedtest, warnings, resolved alerts |

**Migration:**
- Rename category: Observability → Notifications
- Rename channel: #alerts → #incidents
- Rename channel: #monitoring → #status
- Update existing webhooks (myspeed, Uptime Robot → #status or #incidents)

---

## 3.9.1 Discord Channel Setup

> **Docs:** https://support.discord.com/hc/en-us/articles/228383668-Intro-to-Webhooks

- [x] 3.9.1.1 Reorganize Discord channels
  ```
  1. Rename category: Observability → Notifications
  2. Rename channel: #alerts → #incidents
  3. Rename channel: #monitoring → #status
  4. Set descriptions:
     - #incidents: "Critical alerts - action required"
     - #status: "Informational updates, warnings, resolved"
  ```

- [x] 3.9.1.2 Create webhook for #incidents
  ```
  1. #incidents → Settings → Integrations → Webhooks
  2. New Webhook
  3. Name: "Alertmanager Critical"
  4. Copy webhook URL
  ```

- [x] 3.9.1.3 Create webhook for #status
  ```
  1. #status → Settings → Integrations → Webhooks
  2. New Webhook
  3. Name: "Alertmanager Status"
  4. Copy webhook URL
  ```

- [x] 3.9.1.4 Store webhook URLs in 1Password
  ```bash
  # Create TWO items in 1Password Kubernetes vault:
  #
  # Item 1: "Discord Webhook Incidents"
  #   Type: API Credential
  #   Field: credential (webhook URL for #incidents)
  #
  # Item 2: "Discord Webhook Status"
  #   Type: API Credential
  #   Field: credential (webhook URL for #status)
  #
  # Verify:
  op read "op://Kubernetes/Discord Webhook Incidents/credential" >/dev/null && echo "Incidents OK"
  op read "op://Kubernetes/Discord Webhook Status/credential" >/dev/null && echo "Status OK"
  ```

- [x] 3.9.1.5 Update existing webhooks
  ```
  # myspeed webhook → #status (informational)
  # Uptime Robot webhook → #incidents (site down = critical)
  ```

- [x] 3.9.1.6 Test webhooks manually
  ```bash
  # Test #incidents webhook
  curl -H "Content-Type: application/json" \
    -d '{"content": "🔴 Test incident from homelab cluster"}' \
    "$(op read 'op://Kubernetes/Discord Webhook Incidents/credential')"

  # Test #status webhook
  curl -H "Content-Type: application/json" \
    -d '{"content": "ℹ️ Test status update from homelab cluster"}' \
    "$(op read 'op://Kubernetes/Discord Webhook Status/credential')"
  ```

---

## 3.9.2 iCloud SMTP Setup

> **SMTP Server:** smtp.mail.me.com:587 (TLS)
> **From Address:** noreply@rommelporras.com
> **Authentication:** @icloud.com email + app-specific password
>
> **Note:** DKIM already configured for rommelporras.com

- [x] 3.9.2.1 Generate app-specific password for Alertmanager
  ```
  1. Go to https://appleid.apple.com
  2. Sign In & Security → App-Specific Passwords
  3. Generate new password
  4. Name: "Alertmanager Homelab"
  5. Copy the generated password
  ```

- [x] 3.9.2.2 Store SMTP credentials in 1Password
  ```bash
  # Create item in 1Password Kubernetes vault:
  #   Name: "iCloud SMTP Alertmanager"
  #   Type: Login
  #   Fields:
  #     - username: <your-icloud-email>@icloud.com
  #     - password: <app-specific-password>
  #     - server: smtp.mail.me.com
  #     - port: 587
  #
  # Verify:
  op read "op://Kubernetes/iCloud SMTP Alertmanager/username" >/dev/null && echo "Username OK"
  op read "op://Kubernetes/iCloud SMTP Alertmanager/password" >/dev/null && echo "Password OK"
  ```

- [x] 3.9.2.3 Test SMTP manually (optional)
  ```bash
  # Test with swaks if installed
  swaks --to hello@rommelporras.com \
    --from noreply@rommelporras.com \
    --server smtp.mail.me.com:587 \
    --tls \
    --auth-user "$(op read 'op://Kubernetes/iCloud SMTP Alertmanager/username')" \
    --auth-password "$(op read 'op://Kubernetes/iCloud SMTP Alertmanager/password')" \
    --header "Subject: Test from Alertmanager" \
    --body "This is a test email from your homelab cluster."
  ```

---

## 3.9.3 Configure Alertmanager

> **Docs:** https://prometheus.io/docs/alerting/latest/configuration/
>
> **kube-prometheus-stack:** Uses secret `alertmanager-prometheus-kube-prometheus-alertmanager`

- [x] 3.9.3.1 Create Alertmanager config file
  ```bash
  # Create helm/prometheus/alertmanager-config.yaml
  # This will be applied via Helm values
  ```

- [x] 3.9.3.2 Create Alertmanager configuration
  ```yaml
  # helm/prometheus/alertmanager-config.yaml
  #
  # Routing:
  #   - Critical alerts → #incidents + Email
  #   - Warning/Info alerts → #status only
  #
  # Receivers:
  #   - discord-incidents-email: #incidents + hello@rommelporras.com
  #   - discord-status: #status only
  ```

- [x] 3.9.3.3 Update Helm values for Alertmanager
  ```bash
  # Add to helm/prometheus/values.yaml:
  #
  # alertmanager:
  #   config:
  #     global:
  #       smtp_smarthost: 'smtp.mail.me.com:587'
  #       smtp_from: 'noreply@rommelporras.com'
  #       smtp_auth_username: <from-secret>
  #       smtp_auth_password: <from-secret>
  #       smtp_require_tls: true
  #     route:
  #       receiver: 'discord-status'
  #       group_by: ['alertname', 'namespace']
  #       group_wait: 30s
  #       group_interval: 5m
  #       repeat_interval: 4h
  #       routes:
  #         # Critical alerts → #incidents + Email
  #         - match:
  #             severity: critical
  #           receiver: 'discord-incidents-email'
  #           continue: false
  #         # Warning alerts → #status only
  #         - match:
  #             severity: warning
  #           receiver: 'discord-status'
  #           continue: false
  #     receivers:
  #       # #incidents channel + email (critical)
  #       - name: 'discord-incidents-email'
  #         discord_configs:
  #           - webhook_url: <incidents-webhook>
  #         email_configs:
  #           - to: 'hello@rommelporras.com'
  #       # #status channel only (warning/info)
  #       - name: 'discord-status'
  #         discord_configs:
  #           - webhook_url: <status-webhook>
  ```

- [x] 3.9.3.4 Create K8s secret for sensitive values
  ```bash
  # Alertmanager config needs secrets injected
  kubectl-homelab create secret generic alertmanager-secrets \
    --namespace monitoring \
    --from-literal=discord-incidents-webhook="$(op read 'op://Kubernetes/Discord Webhook Incidents/credential')" \
    --from-literal=discord-status-webhook="$(op read 'op://Kubernetes/Discord Webhook Status/credential')" \
    --from-literal=smtp-username="$(op read 'op://Kubernetes/iCloud SMTP Alertmanager/username')" \
    --from-literal=smtp-password="$(op read 'op://Kubernetes/iCloud SMTP Alertmanager/password')"
  ```

- [x] 3.9.3.5 Upgrade Prometheus stack with new config
  ```bash
  helm-homelab upgrade prometheus oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
    --namespace monitoring \
    --version 81.0.0 \
    --values helm/prometheus/values.yaml \
    --set grafana.adminPassword="$(op read 'op://Kubernetes/Grafana/password')"
  ```

- [x] 3.9.3.6 Verify Alertmanager reloaded config
  ```bash
  # Check Alertmanager logs
  kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=alertmanager --tail=50

  # Check config via API
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 &
  curl -s http://localhost:9093/api/v2/status | jq '.config'
  kill %1
  ```

---

## 3.9.4 Test Alerting

- [x] 3.9.4.1 Create test PrometheusRule (fires immediately)
  ```bash
  kubectl-homelab apply -f - <<EOF
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: test-alert
    namespace: monitoring
    labels:
      release: prometheus
  spec:
    groups:
      - name: test
        rules:
          - alert: TestAlertWarning
            expr: vector(1)
            for: 1m
            labels:
              severity: warning
            annotations:
              summary: "Test warning alert"
              description: "This is a test warning alert. Safe to ignore."
          - alert: TestAlertCritical
            expr: vector(1)
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "Test critical alert"
              description: "This is a test critical alert. Safe to ignore."
  EOF
  ```

- [x] 3.9.4.2 Wait for alerts to fire (~2 minutes)
  ```bash
  # Check Prometheus for firing alerts
  kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/alerts' | jq '.data.alerts[] | select(.labels.alertname | startswith("TestAlert"))'
  kill %1
  ```

- [x] 3.9.4.3 Verify Discord notifications received
  ```
  Check #incidents channel for:
  - TestAlertCritical (critical) ✓

  Check #status channel for:
  - TestAlertWarning (warning) ✓
  - (TestAlertCritical should NOT appear here)
  ```

- [x] 3.9.4.4 Verify email received (critical only)
  ```
  Check hello@rommelporras.com for:
  - TestAlertCritical email ✓
  - (TestAlertWarning should NOT send email)
  ```

- [x] 3.9.4.5 Delete test alert
  ```bash
  kubectl-homelab delete prometheusrule test-alert -n monitoring
  ```

- [x] 3.9.4.6 Verify resolved notification
  ```
  Check Discord for "RESOLVED" message
  ```

---

## 3.9.5 Fine-tune Alert Routing (Optional)

> Customize which alerts go where

- [x] 3.9.5.1 Review current alerts
  ```bash
  # List all PrometheusRules
  kubectl-homelab get prometheusrules -A

  # Current alerts:
  # - UPS alerts (ups-alerts.yaml) - 8 rules
  # - Logging alerts (logging-alerts.yaml) - 7 rules
  # - kube-prometheus-stack built-in alerts
  ```

- [x] 3.9.5.2 Categorize alerts by severity
  ```
  CRITICAL → #incidents + Email:
  - UPSLowBattery
  - UPSUnreachable
  - LokiDown
  - Node down
  - etcd issues

  WARNING → #status only:
  - UPSOnBattery
  - UPSHighLoad
  - UPSLowRuntime
  - LokiStorageLow
  - High memory/CPU

  INFO → #status (grouped):
  - UPSBackOnline
  - Resolved alerts
  ```

- [x] 3.9.5.3 Update routing rules if needed
  ```yaml
  # Add more specific routes in alertmanager config
  routes:
    - match:
        alertname: UPSOnBattery
      receiver: 'discord-all'
      repeat_interval: 10m  # More frequent for UPS
  ```

---

## 3.9.6 Documentation Updates

- [x] 3.9.6.1 Update VERSIONS.md
  ```
  # Add to Helm Charts section (if any new charts)
  # Add to Version History:
  # - Configured Alertmanager Discord + Email notifications
  ```

- [x] 3.9.6.2 Update docs/reference/CHANGELOG.md
  ```
  # Add Phase 3.9 section:
  # - Milestone
  # - Files changed
  # - Decisions made
  # - Lessons learned
  ```

- [x] 3.9.6.3 Update docs/rebuild/v0.5.0-alerting.md
  ```
  # Create new rebuild doc for alerting setup
  # Or append to v0.4.0-observability.md as optional section
  ```

- [x] 3.9.6.4 Add 1Password items documentation
  ```
  # Document new items in Kubernetes vault:
  # - Discord Alertmanager Webhook
  # - iCloud SMTP Alertmanager
  ```

---

## Verification Checklist

- [x] Discord category renamed: Observability → Notifications
- [x] Discord channels renamed: #alerts → #incidents, #monitoring → #status
- [x] Webhook created for #incidents
- [x] Webhook created for #status
- [x] Existing webhooks updated (myspeed → #status, Uptime Robot → #incidents)
- [x] iCloud app-specific password generated
- [x] 1Password items created (2 webhooks + SMTP credentials)
- [x] Alertmanager config updated via Helm
- [x] Test alerts fire correctly
- [x] Warning alerts → #status only
- [x] Critical alerts → #incidents + Email
- [x] Resolved notifications received in #status
- [x] Documentation updated

---

## Alert Routing Summary

```
                    ┌─────────────────┐
                    │   Prometheus    │
                    │  (fires alerts) │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Alertmanager   │
                    │   (routing)     │
                    └────────┬────────┘
                             │
           ┌─────────────────┴─────────────────┐
           │                                   │
    ┌──────▼──────┐                     ┌──────▼──────┐
    │  severity:  │                     │  severity:  │
    │   critical  │                     │warning/info │
    └──────┬──────┘                     └──────┬──────┘
           │                                   │
    ┌──────▼──────┐                     ┌──────▼──────┐
    │ #incidents  │                     │  #status    │
    │   + Email   │                     │   only      │
    └─────────────┘                     └─────────────┘

📬 Notifications (Discord Category)
├── #incidents  ← Critical + Email to critical@rommelporras.com
└── #status     ← Warning, Info, Resolved
```

---

## Silenced Alerts

The following alerts are silenced (routed to `null` receiver) because they are false positives caused by kubeadm binding control plane components to `127.0.0.1`:

| Alert | Reason |
|-------|--------|
| `KubeProxyDown` | kube-proxy metrics not exposed |
| `etcdInsufficientMembers` | etcd metrics not scraped |
| `etcdMembersDown` | etcd metrics not scraped |
| `TargetDown` (kube-scheduler) | Bound to localhost |
| `TargetDown` (kube-controller-manager) | Bound to localhost |
| `TargetDown` (kube-etcd) | Bound to localhost |

**Note:** The cluster is working fine. These are scraping issues, not actual component failures.

**To fix (future):** See `docs/todo/deferred.md` for instructions on exposing control plane metrics.

---

## Troubleshooting

### Discord webhook not receiving alerts

```bash
# Check Alertmanager logs
kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=alertmanager | grep -i discord

# Test webhook directly
curl -H "Content-Type: application/json" \
  -d '{"content": "Manual test"}' \
  "$(op read 'op://Kubernetes/Discord Alertmanager Webhook/credential')"
```

### Email not being sent

```bash
# Check Alertmanager logs for SMTP errors
kubectl-homelab -n monitoring logs -l app.kubernetes.io/name=alertmanager | grep -i smtp

# Common issues:
# - Wrong iCloud username (must be @icloud.com, not custom domain)
# - App-specific password expired
# - TLS handshake failure
```

### Alerts firing but no notifications

```bash
# Check Alertmanager is receiving alerts
kubectl-homelab -n monitoring port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093 &
curl -s http://localhost:9093/api/v2/alerts | jq '.[].labels.alertname'
kill %1

# Check inhibition rules aren't blocking
curl -s http://localhost:9093/api/v2/silences | jq '.[] | select(.status.state == "active")'
```

---

## Next Steps

After v0.5.0 release:
- Phase 4.0: AdGuard Home on K8s (DNS)
- Phase 4.1: GitLab + GitLab Runner (CI/CD)
