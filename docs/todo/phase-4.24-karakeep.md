# Phase 4.24: Karakeep Migration

> **Status:** Planned
> **Target:** v0.21.0
> **Prerequisite:** Phase 4.23 complete (Ollama running in `ai` namespace)
> **Priority:** Medium (depends on Ollama)
> **DevOps Topics:** Application migration, multi-service deployment, cross-namespace communication, SQLite workloads
> **CKA Topics:** Deployment, Service, PVC, Secret, HTTPRoute, CiliumNetworkPolicy (cross-namespace)

> **Purpose:** Migrate Karakeep bookmark manager from Proxmox to Kubernetes, connected to Ollama for AI-powered bookmark tagging.
>
> **Current location:** Docker container on Proxmox at `https://karakeep.home.rommelporras.com`
>
> **Why:** Consolidate onto K8s. Connect to Ollama (Phase 4.23) for AI tagging without external API costs.

---

## Architecture

Karakeep (formerly Hoarder, renamed v0.23.1) is a Next.js 15 bookmark manager with background workers (s6-overlay). It requires **3 containers**:

```
┌──────────────────────────────────────────────────────────┐
│  karakeep namespace                                      │
│                                                          │
│  ┌─────────────────────┐  ┌───────────────────────────┐ │
│  │ Karakeep (AIO)      │  │ Chrome                    │ │
│  │ web + workers        │─→│ Headless browser          │ │
│  │ Port: 3000           │  │ Port: 9222                │ │
│  │ PVC: /data (2Gi)     │  │ (no persistent storage)   │ │
│  └──────────┬───────────┘  └───────────────────────────┘ │
│             │                                            │
│  ┌──────────▼───────────┐                                │
│  │ Meilisearch          │                                │
│  │ Full-text search      │                                │
│  │ Port: 7700            │                                │
│  │ PVC: /meili_data (1Gi)│                                │
│  └──────────────────────┘                                │
└──────────────┬───────────────────────────────────────────┘
               │ Cross-namespace (CiliumNetworkPolicy)
               ▼
┌──────────────────────────────────────────────────────────┐
│  ai namespace (Phase 4.23)                               │
│  Ollama → ollama.ai.svc.cluster.local:11434              │
│  Models: qwen2.5:3b (text), moondream (vision)           │
└──────────────────────────────────────────────────────────┘
```

### Key Architecture Facts

| Item | Value |
|------|-------|
| Database | **SQLite** (embedded, WAL mode) — no external DB needed |
| Job queue | **liteque** (SQLite-based) — no Redis needed (dropped in v0.16.0) |
| Replicas | **1** (SQLite = single writer, AIO image = one pod) |
| Strategy | **Recreate** (RWO PVC, single replica) |
| Health endpoint | `GET /api/health` on port 3000 |
| Workers | Crawling, AI inference, search indexing, OCR, video, webhooks, backups (all in-process via s6-overlay) |

---

## Current State

| Item | Value |
|------|-------|
| Location | Proxmox (Docker container) |
| URL | `https://karakeep.home.rommelporras.com` |
| Homepage widget | type: `karakeep` with API key auth |
| Uptime Kuma | Monitored |
| AI provider | Check during migration (may be OpenAI or disabled) |
| Database | SQLite (embedded in `/data/db.db`) |

## Target State

| Item | Value |
|------|-------|
| Namespace | `karakeep` (self-contained) |
| URL | `karakeep.k8s.rommelporras.com` |
| AI provider | Ollama at `http://ollama.ai.svc.cluster.local:11434` |
| Text model | `qwen2.5:3b` (pull on Ollama before deploying Karakeep) |
| Vision model | `moondream` (already on Ollama from Phase 4.23) |
| Storage | 2x Longhorn PVCs (Karakeep data + Meilisearch index) |

---

## Model Selection Decision

### Why qwen2.5:3b (not qwen3:1.7b)

Phase 4.23 deployed `qwen3:1.7b` as primary text model, but **qwen3 is incompatible with Karakeep's structured output**:

- Ollama's structured output suppresses the `<think>` token, breaking qwen3 models ([Ollama #10538](https://github.com/ollama/ollama/issues/10538))
- `/nothink` doesn't reliably disable thinking ([Ollama #11032](https://github.com/ollama/ollama/issues/11032), [#12917](https://github.com/ollama/ollama/issues/12917))
- Karakeep uses `INFERENCE_OUTPUT_SCHEMA=structured` by default — qwen3 returns empty `{}` or broken JSON

**qwen2.5:3b** is proven working with Karakeep on CPU-only hardware (NUC12 i5, similar to our i5-10400T). It supports structured output natively.

| Model | Size | Compatibility | Notes |
|-------|------|--------------|-------|
| **qwen2.5:3b** | ~1.9 GB | Proven | Recommended for Karakeep structured output |
| qwen3:1.7b | ~1.4 GB | Broken | Thinking mode + structured output conflict |
| gemma3:1b | ~0.8 GB | Risky | Known GGML crash ([Karakeep #1310](https://github.com/karakeep-app/karakeep/issues/1310)) |
| moondream | ~1.7 GB | Supported | Official vision model support |

**Action:** Pull `qwen2.5:3b` on Ollama before deploying Karakeep. Keep existing models — qwen3:1.7b is still useful for non-Karakeep workloads.

Ollama PVC impact: current ~3.9 GB + qwen2.5:3b 1.9 GB = ~5.8 GB on 10Gi PVC (58% usage).

### Fallback Strategy

If qwen2.5:3b tags are poor:
1. Try `qwen2.5:1.5b` (lighter, faster, may sacrifice quality)
2. Try `gemma3:1b` with `INFERENCE_OUTPUT_SCHEMA=plain` (avoids structured output, avoids GGML crash path)
3. Try `llama3.2:1b` (pull separately, ~1.3 GB)

---

## Container Images

| Service | Image | Port | Storage |
|---------|-------|------|---------|
| Karakeep (AIO) | `ghcr.io/karakeep-app/karakeep:0.30.0` | 3000 | PVC: 2Gi at `/data` |
| Chrome | `gcr.io/zenika-hub/alpine-chrome:124` | 9222 | None (stateless) |
| Meilisearch | `getmeili/meilisearch:v1.13.3` | 7700 | PVC: 1Gi at `/meili_data` |

---

## Environment Variables

### Required (Karakeep)

| Variable | Value | Source |
|----------|-------|--------|
| `NEXTAUTH_SECRET` | Random 48-char string | 1Password: `op://Kubernetes/Karakeep/nextauth-secret` |
| `NEXTAUTH_URL` | `https://karakeep.k8s.rommelporras.com` | Hardcoded |
| `DATA_DIR` | `/data` | Hardcoded (do NOT change) |
| `MEILI_ADDR` | `http://meilisearch:7700` | In-namespace service DNS |
| `MEILI_MASTER_KEY` | Random 36-char string | 1Password: `op://Kubernetes/Karakeep/meili-master-key` |
| `BROWSER_WEB_URL` | `http://chrome:9222` | In-namespace service DNS |

### Ollama Integration

| Variable | Value | Notes |
|----------|-------|-------|
| `OLLAMA_BASE_URL` | `http://ollama.ai.svc.cluster.local:11434` | Cross-namespace K8s DNS |
| `INFERENCE_TEXT_MODEL` | `qwen2.5:3b` | Must set explicitly (default is `gpt-4-mini` which fails against Ollama) |
| `INFERENCE_IMAGE_MODEL` | `moondream` | Officially supported vision model |
| `INFERENCE_CONTEXT_LENGTH` | `2048` | Default, good starting point |
| `INFERENCE_MAX_OUTPUT_TOKENS` | `2048` | Default |
| `INFERENCE_OUTPUT_SCHEMA` | `structured` | qwen2.5 supports structured output natively |
| `INFERENCE_JOB_TIMEOUT_SEC` | `300` | Default 30s will timeout on CPU (expect 30-90s per tag) |
| `INFERENCE_FETCH_TIMEOUT_SEC` | `600` | HTTP timeout to Ollama (critical fix added in Karakeep v0.23.0) |
| `INFERENCE_NUM_WORKERS` | `1` | Keep at 1 for CPU-only (parallel = memory thrashing) |
| `INFERENCE_LANG` | `english` | Tag language |
| `INFERENCE_ENABLE_AUTO_TAGGING` | `true` | Enable auto-tagging on new bookmarks |
| `INFERENCE_ENABLE_AUTO_SUMMARIZATION` | `false` | Disable initially — tagging is faster, more useful; enable later |

### Security

| Variable | Value | Notes |
|----------|-------|-------|
| `DISABLE_SIGNUPS` | `true` | Set after creating first account |

**Do NOT set `OPENAI_API_KEY`** — it takes precedence over `OLLAMA_BASE_URL` and ignores Ollama entirely.

### Meilisearch

| Variable | Value | Notes |
|----------|-------|-------|
| `MEILI_NO_ANALYTICS` | `true` | Disable telemetry |
| `MEILI_MASTER_KEY` | Same as Karakeep's `MEILI_MASTER_KEY` | Must match |

---

## Resource Limits

| Container | CPU Req/Limit | Memory Req/Limit | Notes |
|-----------|---------------|------------------|-------|
| Karakeep | 250m / 1000m | 256Mi / 1Gi | Next.js + workers + s6-overlay |
| Chrome | 250m / 1000m | 128Mi / 1Gi | Spikes during page crawling/screenshots |
| Meilisearch | 100m / 500m | 128Mi / 512Mi | Scales with bookmark count; 512Mi generous for personal use |

---

## Security

### PSS Labels

```yaml
pod-security.kubernetes.io/enforce: baseline
pod-security.kubernetes.io/audit: restricted
pod-security.kubernetes.io/warn: restricted
```

Baseline enforce because Chrome requires `--no-sandbox` flag (standard for containerized Chromium). Restricted warn/audit logs violations for future tightening.

### Container Security Contexts

**Karakeep (UID 1000):**
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
automountServiceAccountToken: false
```

**Chrome (UID 1000):**
```yaml
securityContext:
  runAsUser: 1000
  runAsGroup: 1000
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

Chrome runs with `--no-sandbox` flag (removes need for `SYS_ADMIN` capability). This is the standard pattern for containerized Chromium (matches official docker-compose).

**Meilisearch (UID 997):**
```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

### Network Policies

**Karakeep ingress:** Allow from Gateway (HTTPRoute traffic) and monitoring namespace (probes).

**Karakeep egress:** Allow to Chrome (9222), Meilisearch (7700), Ollama in `ai` namespace (11434), and DNS (53).

**Chrome egress:** Allow to external internet (website crawling) but restrict internal cluster access. Chrome can be abused to probe internal endpoints — use CiliumNetworkPolicy to block access to cluster CIDRs except DNS.

**Meilisearch ingress:** Allow only from Karakeep pods (port 7700).

---

## 1Password Items

Create before deployment:

```bash
# Create 1Password item
op item create \
  --vault "Kubernetes" \
  --category "Login" \
  --title "Karakeep" \
  --field "nextauth-secret=$(openssl rand -base64 36)" \
  --field "meili-master-key=$(openssl rand -base64 36)"
```

After first login, add API key (generated in Karakeep UI → Settings → API Keys):
```bash
op item edit "Karakeep" --vault "Kubernetes" \
  --field "api-key=<generated-api-key>"
```

---

## Tasks

### 4.24.1 Prepare Ollama

- [ ] 4.24.1.1 Pull `qwen2.5:3b` on Ollama for Karakeep text tagging:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull qwen2.5:3b
  ```
- [ ] 4.24.1.2 Verify model loaded:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama list
  # Expected: qwen2.5:3b (~1.9 GB) alongside existing models
  ```
- [ ] 4.24.1.3 Test inference with structured output:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama run qwen2.5:3b \
    "Classify this text into 3 tags as JSON: Kubernetes is a container orchestration platform"
  ```

### 4.24.2 Create 1Password Secrets

- [ ] 4.24.2.1 Create "Karakeep" item in Kubernetes vault with `nextauth-secret` and `meili-master-key`
- [ ] 4.24.2.2 Verify secrets readable:
  ```bash
  op read "op://Kubernetes/Karakeep/nextauth-secret"
  op read "op://Kubernetes/Karakeep/meili-master-key"
  ```

### 4.24.3 Create Manifests

- [ ] 4.24.3.1 Create `manifests/karakeep/namespace.yaml`
  - PSS labels: `enforce: baseline`, `warn: restricted`, `audit: restricted`
- [ ] 4.24.3.2 Create `manifests/karakeep/karakeep-deployment.yaml`
  - Image: `ghcr.io/karakeep-app/karakeep:0.30.0`
  - PVC: 2Gi Longhorn at `/data` (SQLite + crawled assets)
  - Strategy: Recreate (RWO, single replica)
  - All env vars from tables above (Ollama, Meilisearch, Chrome, auth)
  - Secrets via `op read` at apply time (or K8s Secret with `op` injection)
  - Health probes: `GET /api/health` port 3000
  - Security context: UID 1000, runAsNonRoot, drop ALL caps
  - `automountServiceAccountToken: false`
- [ ] 4.24.3.3 Create `manifests/karakeep/karakeep-service.yaml`
  - ClusterIP on port 3000
- [ ] 4.24.3.4 Create `manifests/karakeep/httproute.yaml`
  - Host: `karakeep.k8s.rommelporras.com`
  - Parent: `homelab-gateway` (sectionName: `https`)
  - Backend: karakeep service port 3000
- [ ] 4.24.3.5 Create `manifests/karakeep/chrome-deployment.yaml`
  - Image: `gcr.io/zenika-hub/alpine-chrome:124`
  - Command args: `--no-sandbox`, `--disable-gpu`, `--disable-dev-shm-usage`, `--remote-debugging-address=0.0.0.0`, `--remote-debugging-port=9222`, `--hide-scrollbars`
  - No PVC (stateless)
  - Security context: UID 1000, runAsNonRoot, drop ALL caps
- [ ] 4.24.3.6 Create `manifests/karakeep/chrome-service.yaml`
  - ClusterIP on port 9222
- [ ] 4.24.3.7 Create `manifests/karakeep/meilisearch-deployment.yaml`
  - Image: `getmeili/meilisearch:v1.13.3`
  - PVC: 1Gi Longhorn at `/meili_data`
  - Strategy: Recreate (RWO, single replica)
  - Env: `MEILI_NO_ANALYTICS=true`, `MEILI_MASTER_KEY` from Secret
  - Security context: runAsNonRoot, drop ALL caps
- [ ] 4.24.3.8 Create `manifests/karakeep/meilisearch-service.yaml`
  - ClusterIP on port 7700
- [ ] 4.24.3.9 Create `manifests/karakeep/networkpolicy.yaml`
  - CiliumNetworkPolicy for Karakeep, Chrome, and Meilisearch
  - Karakeep egress: Chrome (9222), Meilisearch (7700), Ollama cross-namespace (11434), DNS (53)
  - Chrome egress: external internet (website crawling), DNS — block internal cluster CIDRs
  - Meilisearch ingress: only from Karakeep pods
- [ ] 4.24.3.10 Dry-run validate all manifests:
  ```bash
  kubectl-homelab apply --dry-run=client -f manifests/karakeep/
  ```

### 4.24.4 Deploy & Verify

- [ ] 4.24.4.1 Apply namespace and manifests:
  ```bash
  kubectl-homelab apply -f manifests/karakeep/
  ```
- [ ] 4.24.4.2 Wait for all pods ready:
  ```bash
  kubectl-homelab -n karakeep wait --for=condition=Ready pod -l app=karakeep --timeout=120s
  kubectl-homelab -n karakeep wait --for=condition=Ready pod -l app=chrome --timeout=60s
  kubectl-homelab -n karakeep wait --for=condition=Ready pod -l app=meilisearch --timeout=60s
  ```
- [ ] 4.24.4.3 Verify `karakeep.k8s.rommelporras.com` loads in browser
- [ ] 4.24.4.4 Create first user account, then set `DISABLE_SIGNUPS=true` and re-apply
- [ ] 4.24.4.5 Generate API key in Karakeep UI (Settings → API Keys) and save to 1Password
- [ ] 4.24.4.6 Test: save a URL bookmark, verify:
  - Page content is crawled (screenshot appears) — confirms Chrome working
  - AI tags appear within 30-120 seconds — confirms Ollama connection
  - Bookmark is searchable — confirms Meilisearch working
- [ ] 4.24.4.7 Test: save an image bookmark, verify moondream vision tags appear
- [ ] 4.24.4.8 If tags are poor, try fallback:
  ```bash
  # Option 1: Switch to gemma3:1b with plain output
  # Set INFERENCE_TEXT_MODEL=gemma3:1b, INFERENCE_OUTPUT_SCHEMA=plain

  # Option 2: Pull lighter model
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull qwen2.5:1.5b
  # Set INFERENCE_TEXT_MODEL=qwen2.5:1.5b
  ```
- [ ] 4.24.4.9 Monitor resource usage during tagging:
  ```bash
  kubectl-homelab top pod -n karakeep
  kubectl-homelab top pod -n ai
  kubectl-homelab top node
  ```
- [ ] 4.24.4.10 Verify network policies:
  ```bash
  # Karakeep → Ollama (should work)
  kubectl-homelab exec -n karakeep deploy/karakeep -- wget -q -O- http://ollama.ai.svc.cluster.local:11434

  # Default namespace → Karakeep (should be blocked)
  kubectl-homelab run blocked-test --rm -it --image=curlimages/curl --restart=Never -- \
    curl -s --max-time 5 http://karakeep.karakeep.svc.cluster.local:3000
  ```

### 4.24.5 Data Migration (Manual — after everything works)

> **Do this LAST** — only after deploy, verify, and monitoring are all confirmed working.
> This is a manual step performed by the user.

- [ ] 4.24.5.1 Check current Proxmox instance for AI provider config (OpenAI key? Ollama? None?)
- [ ] 4.24.5.2 Export bookmarks from Proxmox Karakeep UI → Settings → Export → Download JSON/HTML
- [ ] 4.24.5.3 Import into K8s Karakeep UI → Settings → Import → upload file
  - **Fallback:** If UI export/import loses data (tags, lists, assets), use CLI migration instead:
    ```bash
    docker run --rm ghcr.io/karakeep-app/karakeep-cli:release \
      --server-addr https://karakeep.home.rommelporras.com --api-key OLD_KEY migrate \
      --dest-server https://karakeep.k8s.rommelporras.com --dest-api-key NEW_KEY \
      --batch-size 50
    ```
- [ ] 4.24.5.4 Verify bookmark count matches between old and new
- [ ] 4.24.5.5 In admin panel, click "Reindex all bookmarks" to rebuild Meilisearch index
- [ ] 4.24.5.6 Re-tag existing bookmarks with Ollama (if previously using OpenAI or no AI):
  - In Karakeep UI: select all bookmarks → Actions → Re-tag with AI
  - **Warning:** This queues ALL bookmarks for CPU inference — will take hours for large collections. Do this overnight.

### 4.24.6 Monitoring

- [ ] 4.24.6.1 Create `manifests/monitoring/karakeep-probe.yaml` — Blackbox HTTP probe targeting `http://karakeep.karakeep.svc.cluster.local:3000/api/health`
- [ ] 4.24.6.2 Create `manifests/monitoring/karakeep-alerts.yaml` — PrometheusRule (KarakeepDown, KarakeepHighRestarts)
- [ ] 4.24.6.3 Apply and verify:
  ```bash
  kubectl-homelab apply -f manifests/monitoring/karakeep-probe.yaml -f manifests/monitoring/karakeep-alerts.yaml
  ```

### 4.24.7 Cutover

- [ ] 4.24.7.1 Update Homepage widget URL + API key (point to `karakeep.k8s.rommelporras.com`)
- [ ] 4.24.7.2 Update Uptime Kuma to monitor new URL
- [ ] 4.24.7.3 Update AdGuard DNS rewrite if applicable (remove old `karakeep.home.rommelporras.com` rewrite)
- [ ] 4.24.7.4 Soak for 1 week, verify everything stable
- [ ] 4.24.7.5 Decommission Proxmox container after soak period

### 4.24.8 Security & Commit

- [ ] 4.24.8.1 `/audit-security`
- [ ] 4.24.8.2 `/commit` (infrastructure)

### 4.24.9 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.24.9.1 Update `docs/todo/README.md` — add Phase 4.24 to phase index + namespace table
- [ ] 4.24.9.2 Update `README.md` (root) — add Karakeep to services list
- [ ] 4.24.9.3 Update `VERSIONS.md` — add Karakeep + Chrome + Meilisearch versions + HTTPRoute
- [ ] 4.24.9.4 Update `docs/reference/CHANGELOG.md` — add migration + Ollama integration + model decision entry
- [ ] 4.24.9.5 Update `docs/context/Cluster.md` — add `karakeep` namespace
- [ ] 4.24.9.6 Update `docs/context/Gateway.md` — add HTTPRoute
- [ ] 4.24.9.7 Update `docs/context/Secrets.md` — add Karakeep 1Password items
- [ ] 4.24.9.8 Update `docs/context/Monitoring.md` — add karakeep-probe.yaml and karakeep-alerts.yaml
- [ ] 4.24.9.9 Create `docs/rebuild/v0.21.0-karakeep.md`
- [ ] 4.24.9.10 `/audit-docs`
- [ ] 4.24.9.11 `/commit` (documentation)
- [ ] 4.24.9.12 `/release v0.21.0 "Karakeep Migration"`
- [ ] 4.24.9.13 Move this file to `docs/todo/completed/`

---

## Karakeep Gotchas

| Issue | Detail |
|-------|--------|
| Default text model is `gpt-4-mini` | Must explicitly set `INFERENCE_TEXT_MODEL` — won't auto-detect Ollama models |
| `OPENAI_API_KEY` overrides Ollama | If both are set, OpenAI wins — do NOT set `OPENAI_API_KEY` |
| `OLLAMA_BASE_URL` must not be `localhost` | Use `http://ollama.ai.svc.cluster.local:11434` |
| qwen3 + structured output = broken | Thinking mode conflicts with Ollama structured output ([#10538](https://github.com/ollama/ollama/issues/10538)) |
| gemma3 + structured output = GGML crash | Memory allocation assertion failure ([Karakeep #1310](https://github.com/karakeep-app/karakeep/issues/1310)) |
| Two timeout values | Both `INFERENCE_JOB_TIMEOUT_SEC` AND `INFERENCE_FETCH_TIMEOUT_SEC` must be increased for CPU |
| Node.js 5-min fetch timeout | Fixed in Karakeep v0.23.0 — use v0.30.0+ |
| v0.30.0 `/api/generate` endpoint | Summaries now use Ollama `/api/generate` for better quality |
| Chrome can probe internal endpoints | Restrict Chrome egress via NetworkPolicy — block cluster CIDRs |
| No Ollama option passthrough | Can't set temperature/top_k from Karakeep ([#1806](https://github.com/karakeep-app/karakeep/issues/1806)) — use custom Modelfile if needed |
| `DISABLE_SIGNUPS` timing | Must create first account BEFORE setting `DISABLE_SIGNUPS=true` |
| Special tokens in content | Websites with `<\|endoftext\|>` cause inference failure ([#2014](https://github.com/karakeep-app/karakeep/issues/2014)) |

---

## CPU Performance Expectations

Based on real-world reports with similar hardware (i5 CPUs, 16GB RAM):

| Model | Task | Expected Time | Notes |
|-------|------|--------------|-------|
| qwen2.5:3b | Text tagging | 30-90 seconds | Per bookmark |
| moondream | Image tagging | 20-45 seconds | Per image |
| qwen2.5:3b | Summarization | 60-180 seconds | Disabled initially |

- Disable auto-summarization initially (`INFERENCE_ENABLE_AUTO_SUMMARIZATION=false`)
- Do NOT bulk re-tag during work hours — queue all bookmarks for overnight processing
- `INFERENCE_NUM_WORKERS=1` is critical — parallel CPU inference causes memory thrashing and timeouts

---

## Custom Tagging Prompt

In Karakeep UI (Settings → Custom Prompt), add:
- Capitalize proper nouns (e.g., "Kubernetes", "JavaScript")
- Lowercase generic terms (e.g., "tutorial", "devops")
- Use spaces not underscores
- Avoid cookie/privacy-related tags unless the page is specifically about those topics

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/karakeep/namespace.yaml` | Namespace | karakeep namespace (PSS baseline) |
| `manifests/karakeep/karakeep-deployment.yaml` | Deployment + PVC | Karakeep AIO (web + workers) |
| `manifests/karakeep/karakeep-service.yaml` | Service | ClusterIP port 3000 |
| `manifests/karakeep/httproute.yaml` | HTTPRoute | `karakeep.k8s.rommelporras.com` |
| `manifests/karakeep/chrome-deployment.yaml` | Deployment | Headless Chrome for crawling |
| `manifests/karakeep/chrome-service.yaml` | Service | ClusterIP port 9222 |
| `manifests/karakeep/meilisearch-deployment.yaml` | Deployment + PVC | Meilisearch search engine |
| `manifests/karakeep/meilisearch-service.yaml` | Service | ClusterIP port 7700 |
| `manifests/karakeep/networkpolicy.yaml` | CiliumNetworkPolicy | Ingress/egress rules |
| `manifests/monitoring/karakeep-probe.yaml` | Probe | Blackbox HTTP probe |
| `manifests/monitoring/karakeep-alerts.yaml` | PrometheusRule | Down + HighRestarts alerts |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Update Karakeep widget URL + API key |

---

## Verification Checklist

- [ ] All 3 pods running in `karakeep` namespace (karakeep, chrome, meilisearch)
- [ ] `karakeep.k8s.rommelporras.com` loads and is functional
- [ ] User account created and signups disabled
- [ ] URL bookmark: page crawled (screenshot), AI tags appear within 30-120 seconds
- [ ] Image bookmark: moondream vision tags appear
- [ ] Search: bookmarks are searchable (Meilisearch working)
- [ ] Bookmarks migrated from Proxmox (count matches)
- [ ] Meilisearch index rebuilt after migration
- [ ] Homepage widget functional with new URL
- [ ] Uptime Kuma monitoring active
- [ ] Blackbox probe shows `probe_success 1`
- [ ] Network policy: Chrome can reach external sites, blocked from internal cluster
- [ ] Network policy: Karakeep can reach Ollama, blocked from default namespace
- [ ] Ollama resource usage acceptable during tagging bursts
- [ ] Node memory stays below 70% during concurrent crawling + inference

---

## Rollback

```bash
kubectl-homelab delete namespace karakeep
kubectl-homelab delete probe karakeep -n monitoring
kubectl-homelab delete prometheusrule karakeep-alerts -n monitoring
# Proxmox container is still running during soak period
# Ollama (Phase 4.23) stays — it's independent
```

---

## Research Sources

| Topic | Source |
|-------|--------|
| Karakeep releases | [github.com/karakeep-app/karakeep/releases](https://github.com/karakeep-app/karakeep/releases) |
| Docker installation | [docs.karakeep.app/installation/docker](https://docs.karakeep.app/installation/docker/) |
| Kubernetes installation | [docs.karakeep.app/installation/kubernetes](https://docs.karakeep.app/installation/kubernetes/) |
| Environment variables | [docs.karakeep.app/configuration/environment-variables](https://docs.karakeep.app/configuration/environment-variables/) |
| AI providers | [docs.karakeep.app/configuration/different-ai-providers](https://docs.karakeep.app/configuration/different-ai-providers/) |
| Server migration | [docs.karakeep.app/guides/server-migration](https://docs.karakeep.app/guides/server-migration/) |
| Official Helm chart | [github.com/karakeep-app/helm-charts](https://github.com/karakeep-app/helm-charts) |
| Architecture (DeepWiki) | [deepwiki.com/karakeep-app/karakeep/2-architecture](https://deepwiki.com/karakeep-app/karakeep/2-architecture) |
| qwen3 structured output bug | [Ollama #10538](https://github.com/ollama/ollama/issues/10538) |
| qwen3 nothink bug | [Ollama #11032](https://github.com/ollama/ollama/issues/11032) |
| gemma3 GGML crash | [Karakeep #1310](https://github.com/karakeep-app/karakeep/issues/1310) |
| CPU timeout issues | [Karakeep #1129](https://github.com/karakeep-app/karakeep/issues/1129) |
| Best Ollama models discussion | [Karakeep Discussion #430](https://github.com/karakeep-app/karakeep/discussions/430) |
| Fetch timeout fix (v0.23.0) | [Karakeep #224](https://github.com/karakeep-app/karakeep/issues/224) |
| Ollama options passthrough | [Karakeep #1806](https://github.com/karakeep-app/karakeep/issues/1806) |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | `qwen2.5:3b` over `qwen3:1.7b` | qwen3 thinking mode breaks structured output in Ollama ([#10538](https://github.com/ollama/ollama/issues/10538)) |
| Vision model | `moondream` (1.8B) | Already deployed (Phase 4.23), officially supported by Karakeep |
| Architecture | AIO image (not split web/workers) | SQLite = single writer, no benefit to splitting |
| Database | SQLite (embedded) | No external DB needed — Redis dropped in v0.16.0 |
| Helm vs raw manifests | Raw manifests | Consistent with repo convention, better for CKA learning |
| PSS | baseline enforce, restricted warn/audit | Chrome requires `--no-sandbox` (standard for containerized Chromium) |
| Chrome sandbox | `--no-sandbox` (no `SYS_ADMIN` cap) | Matches official docker-compose, avoids PSS restricted violation |
| Auto-summarization | Disabled initially | CPU inference is slow — enable after tagging is validated |
| Migration | CLI tool (`@karakeep/cli migrate`) | Server-to-server API migration preserves all data |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| Multi-container workloads | 3 Deployments in one namespace (app, browser, search engine) |
| Cross-namespace networking | Karakeep → Ollama via `svc.cluster.local` DNS |
| CiliumNetworkPolicy | Restricting Chrome egress to prevent internal cluster probing |
| Secret management | Multiple secrets (auth, search key) injected via 1Password |
| PVC lifecycle | SQLite persistence — single-writer constraint means 1 replica max |
| Health probes | Application-level health endpoint (`/api/health`) vs TCP probes |
| Service discovery | In-namespace (`chrome:9222`) vs cross-namespace (`ollama.ai.svc.cluster.local:11434`) |
