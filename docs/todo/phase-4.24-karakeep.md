# Phase 4.24: Karakeep Migration

> **Status:** Planned
> **Target:** v0.20.0
> **Prerequisite:** Phase 4.23 complete (Ollama running with qwen2.5:3b)
> **Priority:** Medium (depends on Ollama)
> **DevOps Topics:** Application migration, multi-service deployment, cross-namespace communication
> **CKA Topics:** Deployment, Service, PVC, Secret, HTTPRoute, NetworkPolicy (cross-namespace)

> **Purpose:** Migrate Karakeep bookmark manager from Proxmox to Kubernetes, connected to Ollama for AI-powered bookmark tagging.
>
> **Current location:** Docker container on Proxmox at `https://karakeep.home.rommelporras.com`
>
> **Why:** Consolidate onto K8s. Connect to Ollama (Phase 4.23) for AI tagging without external API costs.

---

## Current State

| Item | Value |
|------|-------|
| Location | Proxmox (Docker container) |
| URL | `https://karakeep.home.rommelporras.com` |
| Homepage widget | type: `karakeep` with API key auth |
| Uptime Kuma | Monitored |
| AI provider | Unknown (may be using OpenAI API currently) |
| Database | Research needed (likely SQLite or PostgreSQL) |

## Target State

| Item | Value |
|------|-------|
| Namespace | `karakeep` (self-contained) |
| URL | `karakeep.k8s.rommelporras.com` |
| AI provider | Ollama at `http://ollama.ai.svc.cluster.local:11434` |
| Text model | `qwen2.5:3b` |
| Image model | `llava` |
| Storage | Longhorn PVC for data |

---

## Tasks

### 4.24.1 Research

- [ ] 4.24.1.1 Read Karakeep docs for Docker/K8s deployment requirements
- [ ] 4.24.1.2 Identify all required services (app, database, redis, workers?)
- [ ] 4.24.1.3 Identify all required environment variables
- [ ] 4.24.1.4 Check data export/import path from current Proxmox instance
- [x] 4.24.1.5 Pin Karakeep image → `ghcr.io/karakeep-app/karakeep:0.30.0` (Jan 2025, renamed from Hoarder — verify for newer at deploy time)

### 4.24.2 Create Manifests

- [ ] 4.24.2.1 Create `manifests/karakeep/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: restricted`
- [ ] 4.24.2.2 Create Karakeep deployment manifests (structure depends on 4.24.1 research):
  - `manifests/karakeep/deployment.yaml` — Main app
  - `manifests/karakeep/service.yaml` — ClusterIP
  - `manifests/karakeep/httproute.yaml` — `karakeep.k8s.rommelporras.com`
  - Database manifest if needed (PostgreSQL StatefulSet or SQLite PVC)
- [ ] 4.24.2.3 Create Secret placeholder for credentials:
  - API key for Homepage widget
  - Any app-specific secrets
- [ ] 4.24.2.4 Configure Ollama connection env vars:
  ```yaml
  env:
    - name: OLLAMA_BASE_URL
      value: "http://ollama.ai.svc.cluster.local:11434"
    - name: INFERENCE_TEXT_MODEL
      value: "qwen2.5:3b"
    - name: INFERENCE_IMAGE_MODEL
      value: "llava"
    - name: INFERENCE_CONTEXT_LENGTH
      value: "2048"
    - name: INFERENCE_JOB_TIMEOUT_SEC
      value: "120"
    - name: INFERENCE_FETCH_TIMEOUT_SEC
      value: "300"
    - name: INFERENCE_NUM_WORKERS
      value: "1"
  ```
- [ ] 4.24.2.5 Security context (full restricted profile)
- [ ] 4.24.2.6 Resource limits (TBD after research)
- [ ] 4.24.2.7 NetworkPolicy: allow egress to `ollama.ai.svc.cluster.local:11434` (cross-namespace traffic to `ai` namespace)

### 4.24.3 Deploy & Verify

- [ ] 4.24.3.1 Apply manifests and verify pod(s) running
- [ ] 4.24.3.2 Verify `karakeep.k8s.rommelporras.com` loads
- [ ] 4.24.3.3 Test: save a bookmark, verify AI tagging works
- [ ] 4.24.3.4 Test: verify tags are reasonable (qwen2.5:3b quality check)
- [ ] 4.24.3.5 If tags are poor, try fallback model:
  ```bash
  # Change INFERENCE_TEXT_MODEL to gemma3:1b and test
  ```
- [ ] 4.24.3.6 Monitor Ollama resource usage during tagging

### 4.24.4 Data Migration

- [ ] 4.24.4.1 Export bookmarks from Proxmox Karakeep instance
- [ ] 4.24.4.2 Import into K8s Karakeep instance
- [ ] 4.24.4.3 Verify bookmark count matches
- [ ] 4.24.4.4 Re-tag existing bookmarks with Ollama (if switching from OpenAI)

### 4.24.5 Cutover

- [ ] 4.24.5.1 Update Homepage widget URL + API key
- [ ] 4.24.5.2 Update Uptime Kuma to monitor new URL
- [ ] 4.24.5.3 Update AdGuard DNS rewrite if applicable
- [ ] 4.24.5.4 Soak for 1 week, then decommission Proxmox container

### 4.24.6 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.24.6.1 Update `docs/todo/README.md` — add Phase 4.24 to phase index + namespace table
- [ ] 4.24.6.2 Update `README.md` (root) — add Karakeep to services list
- [ ] 4.24.6.3 Update `VERSIONS.md` — add Karakeep version + HTTPRoute
- [ ] 4.24.6.4 Update `docs/reference/CHANGELOG.md` — add migration + Ollama integration decision entry
- [ ] 4.24.6.5 Update `docs/context/Cluster.md` — add `karakeep` namespace
- [ ] 4.24.6.6 Update `docs/context/Gateway.md` — add HTTPRoute
- [ ] 4.24.6.7 Update `docs/context/Secrets.md` — add Karakeep 1Password items (API key)
- [ ] 4.24.6.8 Update `docs/context/ExternalServices.md` — document Ollama integration as internal service
- [ ] 4.24.6.9 Create `docs/rebuild/v0.20.0-karakeep.md`
- [ ] 4.24.6.10 `/audit-docs`
- [ ] 4.24.6.11 `/commit`
- [ ] 4.24.6.12 `/release v0.20.0 "Karakeep Migration"`
- [ ] 4.24.6.13 Move this file to `docs/todo/completed/`

---

## Karakeep + Ollama Configuration Reference

From Karakeep docs, the key environment variables for Ollama integration:

| Variable | Value | Notes |
|----------|-------|-------|
| `OLLAMA_BASE_URL` | `http://ollama.ai.svc.cluster.local:11434` | Cross-namespace K8s DNS |
| `INFERENCE_TEXT_MODEL` | `qwen2.5:3b` | Primary text tagging model |
| `INFERENCE_IMAGE_MODEL` | `llava` | Vision model for image bookmarks |
| `INFERENCE_CONTEXT_LENGTH` | `2048` | Start at 512, increase if tags improve |
| `INFERENCE_MAX_OUTPUT_TOKENS` | `2048` | |
| `INFERENCE_OUTPUT_SCHEMA` | `structured` | qwen2.5 supports structured output |
| `INFERENCE_JOB_TIMEOUT_SEC` | `120` | **Must increase from default 30 for CPU** |
| `INFERENCE_FETCH_TIMEOUT_SEC` | `300` | Increase for slow inference |
| `INFERENCE_NUM_WORKERS` | `1` | **Keep at 1 for CPU-only** |

**Custom tagging prompt tip:** In Karakeep settings, add instructions to normalize tags:
- Capitalize proper nouns (e.g., "Kubernetes", "JavaScript")
- Lowercase generic terms (e.g., "tutorial", "devops")
- Use spaces not underscores
- Avoid cookie/privacy-related tags unless the page is specifically about those topics

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/karakeep/namespace.yaml` | Namespace | Karakeep namespace |
| `manifests/karakeep/deployment.yaml` | Deployment + PVC | Karakeep app |
| `manifests/karakeep/service.yaml` | Service | ClusterIP |
| `manifests/karakeep/httproute.yaml` | HTTPRoute | `karakeep.k8s.rommelporras.com` |
| Database manifests | TBD | Depends on research (4.24.1) |

## Files to Modify

| File | Change |
|------|--------|
| `manifests/home/homepage/config/services.yaml` | Update Karakeep widget URL + API key |

---

## Verification Checklist

- [ ] Karakeep pod(s) running in `karakeep` namespace
- [ ] `karakeep.k8s.rommelporras.com` loads and is functional
- [ ] AI tagging works — save a bookmark, tags appear within 30-120 seconds
- [ ] Tags are reasonable quality (check qwen2.5:3b output)
- [ ] Bookmarks migrated from Proxmox (count matches)
- [ ] Homepage widget functional with new URL
- [ ] Uptime Kuma monitoring active
- [ ] Ollama resource usage acceptable during tagging bursts

---

## Rollback

```bash
kubectl-homelab delete namespace karakeep
# Proxmox container is still running during soak period
# Ollama (Phase 4.23) stays — it's independent
```
