# Certificates Runbook

Covers: cert-manager TLS certificate lifecycle

## CertificateExpiringSoon

**Severity:** warning

Certificate is expiring in less than 30 days but more than 7 days. Let's Encrypt certificates renew at ~30 days remaining, so this indicates cert-manager has not renewed the certificate yet and renewal may have failed.

### Triage Steps

1. Check certificate status:
   kubectl-homelab get certificate -A
   kubectl-homelab describe certificate {{ $labels.name }} -n {{ $labels.namespace }}

2. Check certificate request:
   kubectl-homelab get certificaterequest -n {{ $labels.namespace }}

3. Check cert-manager logs:
   kubectl-homelab logs -n cert-manager deploy/cert-manager --tail=100

4. Check ACME challenge status (if DNS challenge):
   kubectl-homelab get challenge -A

## CertificateExpiryCritical

**Severity:** critical

Certificate is expiring in less than 7 days. Immediate action is required - HTTPS will break when the certificate expires.

### Triage Steps

1. Check certificate status immediately:
   kubectl-homelab get certificate -A
   kubectl-homelab describe certificate {{ $labels.name }} -n {{ $labels.namespace }}

2. Manually trigger renewal by deleting the CertificateRequest:
   kubectl-homelab get certificaterequest -n {{ $labels.namespace }}
   kubectl-homelab delete certificaterequest -n {{ $labels.namespace }} <name-from-above>

3. Check cert-manager controller logs:
   kubectl-homelab logs -n cert-manager deploy/cert-manager --tail=200

4. Check if ClusterIssuer is healthy:
   kubectl-homelab get clusterissuer -o wide

## CertificateNotReady

**Severity:** critical

Certificate has not been in Ready state for 15+ minutes. A renewal may have failed.

### Triage Steps

1. Check certificate status:
   kubectl-homelab describe certificate {{ $labels.name }} -n {{ $labels.namespace }}

2. Check certificate requests:
   kubectl-homelab get certificaterequest -n {{ $labels.namespace }} -o wide

3. Check ACME order/challenge status:
   kubectl-homelab get order -n {{ $labels.namespace }}
   kubectl-homelab get challenge -A

4. Check cert-manager logs:
   kubectl-homelab logs -n cert-manager deploy/cert-manager --tail=200

## CertManagerWebhookDown

**Severity:** critical

cert-manager webhook is unreachable. Certificate issuance and renewal are blocked - any Certificate or CertificateRequest resource creation/update will be rejected by the API server.

### Triage Steps

1. Check webhook pod status: kubectl-homelab get pods -n cert-manager -l app=webhook
2. Check webhook logs: kubectl-homelab logs -n cert-manager -l app=webhook --tail=50
3. Check CiliumNetworkPolicy (API server must reach the webhook): kubectl-homelab get ciliumnetworkpolicy -n cert-manager
4. Check cert-manager controller logs for webhook errors: kubectl-homelab logs -n cert-manager deploy/cert-manager --tail=100
