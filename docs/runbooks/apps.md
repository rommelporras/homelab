# Applications Runbook

Covers: Ghost, Invoicetron, Portfolio, Karakeep, Ollama, Atuin, Uptime Kuma, service response time

---

## GhostDown

**Severity:** warning

Blackbox HTTP probe to `ghost.ghost-prod.svc:2368` has failed for 5+ minutes. The public blog is unavailable (served via Cloudflare Tunnel).

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n ghost-prod -l app=ghost

2. Check pod logs:
   kubectl-homelab logs -n ghost-prod deploy/ghost --tail=50

3. Check database connectivity:
   kubectl-homelab get pods -n ghost-prod -l app=ghost-mysql

4. Check events:
   kubectl-homelab describe pod -n ghost-prod -l app=ghost
```

---

## InvoicetronDown

**Severity:** warning

Blackbox HTTP probe to `invoicetron.invoicetron-prod.svc:3000/api/health` has failed for 5+ minutes. The invoicing app is unavailable (served via Cloudflare Tunnel).

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n invoicetron-prod -l app=invoicetron

2. Check pod logs:
   kubectl-homelab logs -n invoicetron-prod deploy/invoicetron --tail=50

3. Check database connectivity:
   kubectl-homelab get pods -n invoicetron-prod -l app=postgres

4. Check events:
   kubectl-homelab describe pod -n invoicetron-prod -l app=invoicetron
```

---

## PortfolioDown

**Severity:** warning

Blackbox HTTP probe to `portfolio.portfolio-prod.svc:80/health` has failed for 5+ minutes. The portfolio site is unavailable (served via HTTPRoute).

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n portfolio-prod -l app=portfolio

2. Check pod logs:
   kubectl-homelab logs -n portfolio-prod deploy/portfolio --tail=50

3. Check HTTPRoute:
   kubectl-homelab get httproute -n portfolio-prod

4. Check events:
   kubectl-homelab describe pod -n portfolio-prod -l app=portfolio
```

---

## KarakeepDown

**Severity:** warning

Blackbox HTTP probe to `karakeep.karakeep.svc /api/health` has failed for 3+ minutes. Bookmark saving and AI tagging are unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n karakeep

2. Check Karakeep logs:
   kubectl-homelab logs -n karakeep deploy/karakeep --tail=50

3. Check dependent services:
   kubectl-homelab get pods -n karakeep -l app=meilisearch
   kubectl-homelab get pods -n karakeep -l app=chrome
   kubectl-homelab get pods -n ai -l app=ollama

4. Check events:
   kubectl-homelab describe pod -n karakeep -l app=karakeep
```

---

## KarakeepHighRestarts

**Severity:** warning

Karakeep has restarted more than 3 times in the last hour. Likely OOMKilled or failing health probes.

### Triage Steps

```
1. Check for OOMKill:
   kubectl-homelab get pods -n karakeep -l app=karakeep -o jsonpath='{.items[*].status.containerStatuses[*].lastState}'

2. Check events:
   kubectl-homelab describe pod -n karakeep -l app=karakeep | tail -20

3. Check memory usage:
   kubectl-homelab top pod -n karakeep
```

---

## OllamaDown

**Severity:** warning

Blackbox HTTP probe to `ollama.ai.svc` has failed for 3+ minutes. AI tagging in Karakeep will not function.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n ai -l app=ollama

2. Check pod logs:
   kubectl-homelab logs -n ai deploy/ollama --tail=50

3. Check if model is loading (high memory during startup):
   kubectl-homelab top pod -n ai

4. If pod is CrashLooping, check events:
   kubectl-homelab describe pod -n ai -l app=ollama
```

---

## OllamaHighMemory

**Severity:** warning

Ollama is using more than 85% of its 6Gi memory limit for 5+ minutes. Risk of OOMKill if multiple models load simultaneously.

### Triage Steps

```
1. Check which models are loaded:
   kubectl-homelab run check --rm -it --image=curlimages/curl --restart=Never -- \
     curl -s http://ollama.ai.svc.cluster.local:11434/api/ps

2. If multiple models loaded, verify OLLAMA_MAX_LOADED_MODELS=1

3. Check node memory pressure:
   kubectl-homelab top node
```

---

## OllamaHighRestarts

**Severity:** warning

Ollama has restarted more than 3 times in the last hour. Likely OOMKilled or failing health probes.

### Triage Steps

```
1. Check for OOMKill:
   kubectl-homelab get pods -n ai -l app=ollama -o jsonpath='{.items[*].status.containerStatuses[*].lastState}'

2. Check events:
   kubectl-homelab describe pod -n ai -l app=ollama | tail -20

3. If OOMKilled, consider increasing memory limit or reducing loaded models
```

---

## AtuinDown

**Severity:** warning

Blackbox HTTP probe to `atuin-server.atuin.svc /healthz` has failed for 3+ minutes. Shell history sync is unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n atuin

2. Check Atuin server logs:
   kubectl-homelab logs -n atuin deploy/atuin-server --tail=50

3. Check PostgreSQL status:
   kubectl-homelab get pods -n atuin -l app=postgres

4. Check events:
   kubectl-homelab describe pod -n atuin -l app=atuin-server
```

---

## AtuinPostgresDown

**Severity:** warning

PostgreSQL deployment in the `atuin` namespace has 0 available replicas for 5+ minutes. Atuin server cannot store or retrieve history.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n atuin -l app=postgres

2. Check PostgreSQL logs:
   kubectl-homelab logs -n atuin deploy/postgres --tail=50

3. Check PVC status:
   kubectl-homelab get pvc -n atuin

4. Check events:
   kubectl-homelab describe pod -n atuin -l app=postgres
```

---

## AtuinHighRestarts

**Severity:** warning

Atuin server has restarted more than 3 times in the last hour. Likely OOMKilled or failing health probes.

### Triage Steps

```
1. Check for OOMKill:
   kubectl-homelab get pods -n atuin -l app=atuin-server -o jsonpath='{.items[*].status.containerStatuses[*].lastState}'

2. Check events:
   kubectl-homelab describe pod -n atuin -l app=atuin-server | tail -20

3. Check memory usage:
   kubectl-homelab top pod -n atuin
```

---

## AtuinHighMemory

**Severity:** warning

Atuin server is using more than 80% of its memory limit for 10+ minutes. Risk of OOMKill.

### Triage Steps

```
1. Check current memory usage:
   kubectl-homelab top pod -n atuin

2. Check for memory leaks in logs:
   kubectl-homelab logs -n atuin deploy/atuin-server --tail=100

3. Consider increasing memory limit in server-deployment.yaml
```

---

## UptimeKumaDown

**Severity:** warning

Blackbox HTTP probe to `uptime.k8s.rommelporras.com` has failed for 3+ minutes. The uptime monitoring dashboard is unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n uptime-kuma

2. Check pod logs:
   kubectl-homelab logs -n uptime-kuma statefulset/uptime-kuma --tail=50

3. Check PVC is bound:
   kubectl-homelab get pvc -n uptime-kuma

4. Check events:
   kubectl-homelab describe pod -n uptime-kuma -l app=uptime-kuma
```

---

## ServiceHighResponseTime

**Severity:** warning

An HTTP probe for a public-facing service (ghost, invoicetron, portfolio, jellyfin, seerr, or karakeep) has been returning responses above 5 seconds for 5+ minutes. The service is up but slow - possible database contention, memory pressure, or cold-start degradation.

### Triage Steps

```
1. Check response time trend in Grafana:
   Service Health dashboard → Response Time row

2. Check pod resource usage:
   kubectl-homelab top pod -n <namespace> -l app={{ $labels.job }}

3. Check pod logs for slow queries or errors:
   kubectl-homelab logs -n <namespace> deploy/{{ $labels.job }} --tail=100

4. Check if the issue is database-related:
   - Ghost: check ghost-prod PostgreSQL pod health
   - Invoicetron: check invoicetron-prod PostgreSQL pod health
   - Karakeep: check Meilisearch pod health (search indexing)

5. If the service just started, slow response may be a cold-start artifact —
   wait 5 minutes and check if it resolves automatically.
```

---

## HomepageDown

**Severity:** warning

Homepage dashboard is unreachable. The internal service portal is unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n home -l app=homepage

2. Check logs:
   kubectl-homelab logs -n home deploy/homepage --tail=50

3. Check CiliumNetworkPolicy (Homepage fetches data from many cluster services):
   kubectl-homelab get ciliumnetworkpolicy -n home
```

---

## MySpeedDown

**Severity:** warning

MySpeed speed test monitor is unreachable. Speed test history and scheduling are unavailable.

### Triage Steps

```
1. Check pod status:
   kubectl-homelab get pods -n home -l app=myspeed

2. Check logs:
   kubectl-homelab logs -n home deploy/myspeed --tail=50
```

---

## GitLabWebservice5xxHigh

**Severity:** critical

GitLab webservice 5xx error rate is above 5%. GitLab web UI and API requests are failing at a high rate.

### Triage Steps

```
1. Check webservice pod logs:
   kubectl-homelab logs -n gitlab -l app=webservice --tail=100

2. Check PostgreSQL connectivity (most 5xx errors trace to DB):
   kubectl-homelab get pods -n gitlab -l app=postgresql

3. Check Redis status (session and cache dependency):
   kubectl-homelab get pods -n gitlab -l app=redis-master
```

---

## GitLabSidekiqQueueHigh

**Severity:** warning

GitLab Sidekiq job queue is backing up. Background jobs (emails, CI triggers, webhooks) are delayed.

### Triage Steps

```
1. Check Sidekiq pod logs:
   kubectl-homelab logs -n gitlab -l app=sidekiq --tail=100

2. Check Redis memory (Sidekiq queues are stored in Redis):
   kubectl-homelab get pods -n gitlab -l app=redis-master

3. Check for stuck jobs in GitLab Admin panel:
   https://gitlab.k8s.rommelporras.com/admin/background_jobs
```

---

## GitLabPostgresDown

**Severity:** critical

GitLab PostgreSQL is unreachable. GitLab web UI, API, and all database-dependent features are unavailable.

### Triage Steps

```
1. Check PostgreSQL pod status:
   kubectl-homelab get pods -n gitlab -l app=postgresql

2. Check PostgreSQL logs:
   kubectl-homelab logs -n gitlab -l app=postgresql --tail=50

3. Check PVC status and disk space:
   kubectl-homelab get pvc -n gitlab
```

---

## GitLabPostgresConnectionsHigh

**Severity:** warning

GitLab PostgreSQL connection count is elevated. Connection pool exhaustion can cause request failures.

### Triage Steps

```
1. Check active connections (requires port-forward to PostgreSQL pod):
   kubectl-homelab port-forward -n gitlab svc/gitlab-postgresql 5432:5432

2. Identify connection sources using pg_stat_activity and look for connection leaks

3. Check connection pooling configuration in GitLab Helm values (db.pool)
```

---

## GitLabRedisDown

**Severity:** critical

GitLab Redis is unreachable. Sessions, Sidekiq queues, and caching are unavailable. GitLab will degrade severely.

### Triage Steps

```
1. Check Redis pod status:
   kubectl-homelab get pods -n gitlab -l app=redis-master

2. Check Redis logs:
   kubectl-homelab logs -n gitlab -l app=redis-master --tail=50

3. Check memory usage (OOMKill is a common Redis failure mode):
   kubectl-homelab describe pod -n gitlab -l app=redis-master | grep -A5 Limits
```

---

## GitLabRedisHighMemory

**Severity:** warning

GitLab Redis memory usage is above 200MiB. Risk of eviction or OOMKill if usage continues to grow.

### Triage Steps

```
1. Check Redis memory info (requires port-forward):
   kubectl-homelab port-forward -n gitlab svc/gitlab-redis-master 6379:6379
   redis-cli info memory

2. Check eviction policy (should be allkeys-lru or volatile-lru for GitLab):
   redis-cli config get maxmemory-policy

3. If memory is growing unbounded, check for Sidekiq queue buildup (large job payloads in Redis)
```
