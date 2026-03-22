# Vault & External Secrets Runbook

Covers: HashiCorp Vault health, External Secrets Operator sync, Vault snapshots

## VaultSealed

**Severity:** critical

Vault has been sealed for more than 2 minutes. When sealed, all ESO syncs fail and no new secrets can be read. The vault-unsealer pod should auto-recover within 30 seconds of a seal event - if this alert fires, the unsealer is likely broken or missing its keys.

### Triage Steps

1. Check unsealer pod: kubectl-homelab get pods -n vault -l app=vault-unsealer
2. Check unsealer logs: kubectl-homelab logs -n vault -l app=vault-unsealer --tail=50
3. Check vault seal status: kubectl-homelab exec -n vault vault-0 -- vault status
4. If unsealer is CrashLooping: check vault-unseal-keys secret exists
5. Manual unseal (break-glass): get keys from 1Password "Vault Unseal Keys"

## VaultMetricsMissing

**Severity:** warning

Vault is reachable (Blackbox probe succeeds) but no `vault_*` metrics are being scraped by Prometheus. This degrades alerting - VaultSealed, VaultAuditFailure, and VaultHighLatency cannot fire without metrics.

### Triage Steps

1. Check ServiceMonitor: kubectl-homelab get servicemonitor -n vault
2. Check Prometheus targets: port-forward prometheus:9090, check /targets for vault-metrics
3. Test metrics endpoint: kubectl-homelab exec -n vault vault-0 -- wget -qO- 'http://127.0.0.1:8200/v1/sys/metrics?format=prometheus' | head
4. Verify listener.telemetry.unauthenticated_metrics_access = true in Vault HCL config

## VaultAuditFailure

**Severity:** critical

Vault's audit device is logging failures. Every Vault operation must be audited for compliance - failures here represent a compliance risk and may indicate the audit log target (stdout) is unavailable.

### Triage Steps

1. Check audit devices: kubectl-homelab exec -n vault vault-0 -- vault audit list
2. Check pod logs for audit errors: kubectl-homelab logs -n vault vault-0 --tail=100 | grep audit
3. Re-enable if needed: vault audit enable file file_path=stdout

## VaultDown

**Severity:** warning

The Blackbox HTTP probe to Vault's `/v1/sys/health` endpoint has been failing for more than 5 minutes. Vault returns 503 when sealed, so this alert can fire for either a sealed or a fully unreachable Vault. ESO may lose connectivity to its secret store.

### Triage Steps

1. Check vault pod: kubectl-homelab get pods -n vault
2. Check vault logs: kubectl-homelab logs -n vault vault-0 --tail=50
3. Check HTTPRoute: kubectl-homelab get httproute -n vault
4. Try port-forward: kubectl-homelab port-forward -n vault vault-0 8200:8200

## VaultHighLatency

**Severity:** warning

Vault's median request latency (p50) has exceeded 500ms for more than 10 minutes. This can slow or time out ESO syncs and any workloads reading secrets at runtime. Common causes are Longhorn volume I/O pressure or resource contention on the vault-0 pod.

### Triage Steps

1. Check pod resources: kubectl-homelab top pods -n vault
2. Check Longhorn volume: kubectl-homelab get volumes.longhorn.io -n longhorn-system | grep vault
3. Check Raft state: kubectl-homelab exec -n vault vault-0 -- vault operator raft list-peers

## ESOSecretNotSynced

**Severity:** critical

An ExternalSecret object has been in `SecretSynced=False` state for more than 10 minutes. The Kubernetes Secret it manages may be stale or absent, which can break pods that mount or reference it.

### Triage Steps

1. Describe the ES: kubectl-homelab describe externalsecret {{ $labels.name }} -n {{ $labels.namespace }}
2. Check ESO logs: kubectl-homelab logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=50
3. Verify ClusterSecretStore: kubectl-homelab get clustersecretstores
4. Verify Vault is unsealed: kubectl-homelab exec -n vault vault-0 -- vault status
5. Check if Vault path exists: vault kv get secret/{{ $labels.namespace }}/...

## ESOSyncErrors

**Severity:** warning

ESO has logged sync errors against Vault in the last 15 minutes. This may be transient (Vault restarting or briefly sealed) or permanent (missing KV path, revoked token, or policy gap).

### Triage Steps

1. Check ESO pod logs: kubectl-homelab logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100
2. Check if Vault is sealed: kubectl-homelab exec -n vault vault-0 -- vault status
3. Verify Vault KV path exists: vault kv get secret/<path>
4. Force re-sync: kubectl-homelab annotate externalsecret <name> -n <ns> force-sync=$(date +%s) --overwrite

## VaultSnapshotFailing

**Severity:** warning

The daily Vault Raft snapshot CronJob has been in a failed state for more than 30 minutes. Without successful snapshots, Vault data cannot be restored from backup in a disaster scenario. The most common cause is the NFS NAS being unreachable from the cluster nodes.

### Triage Steps

1. Check CronJob: kubectl-homelab get cronjobs -n vault
2. Check latest job: kubectl-homelab get jobs -n vault --sort-by=.metadata.creationTimestamp
3. Check pod logs: kubectl-homelab logs -n vault -l job-name=vault-snapshot-<date>
4. Check NFS mount: verify 10.10.30.4:/Kubernetes/Backups/vault is accessible from k8s nodes

## ESOWebhookDown

**Severity:** critical

External Secrets Operator webhook is unreachable. ExternalSecret create and update operations are rejected by the API server. Existing synced secrets are unaffected until they need refresh; new deployments relying on ExternalSecrets will fail.

### Triage Steps

1. Check webhook pod status: kubectl-homelab get pods -n external-secrets -l app.kubernetes.io/name=external-secrets-webhook
2. Check webhook logs: kubectl-homelab logs -n external-secrets -l app.kubernetes.io/name=external-secrets-webhook --tail=50
3. Check cert-controller pod (manages webhook TLS - expired cert breaks webhook): kubectl-homelab get pods -n external-secrets -l app.kubernetes.io/name=external-secrets-cert-controller
