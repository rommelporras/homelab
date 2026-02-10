# Phase 4.23: Ollama Local AI

> **Status:** Planned
> **Target:** v0.20.0
> **Prerequisite:** Longhorn storage running, sufficient node resources
> **Priority:** Medium (foundation for Karakeep AI tagging)
> **DevOps Topics:** LLM inference, CPU-only ML workloads, resource management
> **CKA Topics:** Deployment, Service, PVC, ResourceQuota, resource limits

> **Purpose:** Deploy Ollama for local LLM inference, primarily to support Karakeep's AI-powered bookmark tagging (Phase 4.24).
>
> **Constraint:** No GPU — all inference runs on CPU (Intel i5-10400T, 6c/12t, 16GB RAM per node). Model selection is critical.

---

## Hardware Constraint Analysis

| Resource | Per Node | Available (est.) |
|----------|----------|-----------------|
| CPU | 6 cores / 12 threads | ~4-6 cores free |
| RAM | 16GB | ~8-10GB free (after K8s + existing workloads) |
| Memory bandwidth | ~35-40 GB/s (DDR4 dual-channel) | Primary inference bottleneck |
| GPU | None | CPU-only inference |

**Key insight:** Memory bandwidth is the bottleneck for LLM inference on CPU, not compute. Smaller models that fit entirely in RAM will perform dramatically better than models that cause swapping.

---

## Model Selection

### Recommended: `qwen2.5:3b` (Primary)

| Attribute | Value |
|-----------|-------|
| Parameters | 3B |
| Quantization | Q4_K_M (default) |
| Disk size | ~2.0 GB |
| RAM usage | ~2.5-3.0 GB |
| Est. speed on i5-10400T | 7-10 tokens/sec |
| Per-bookmark processing | ~10-30 seconds |

**Why this model:**
- Community-proven with Karakeep on CPU-only hardware (NUC i5 users report good results)
- Strong instruction following — critical for consistent, well-formatted tags
- Qwen 2.5 series excels at structured output and classification tasks
- Leaves ~5-7 GB RAM free for other workloads on the node
- Supports structured output natively (no `INFERENCE_OUTPUT_SCHEMA=plain` needed)

### Fallback: `gemma3:1b` (Ultra-lightweight)

| Attribute | Value |
|-----------|-------|
| Parameters | 1B |
| Quantization | Q4_K_M |
| Disk size | ~0.8 GB |
| RAM usage | ~1.2-1.5 GB |
| Est. speed on i5-10400T | 15-20 tokens/sec |
| Per-bookmark processing | ~5-15 seconds |

**When to use:** If node resources are tight or you want minimal impact on other workloads. Trade-off: less nuanced tags than 3B models.

### Not Recommended

| Model | Why Not |
|-------|---------|
| Mistral 7B / Qwen 2.5:7B | 5.5-7 GB RAM, 3-5 tok/s — too slow, too heavy |
| Gemma 2:9B | 6.5-8 GB RAM, 2-3 tok/s — impractical on i5-10400T |
| Qwen 2.5:0.5B | Tags will be unreliable — too small for classification |

### Quantization

Use **Q4_K_M** for all models (Ollama's default). The quality difference vs Q5_K_M is negligible for tagging/classification tasks. Q4_K_M gives the best speed/quality tradeoff on CPU.

---

## Architecture

```
┌─────────────────────────────────────┐
│  ai namespace                       │
│                                     │
│  ┌──────────────────────┐          │
│  │ Ollama (Deployment)  │          │
│  │ - Model: qwen2.5:3b  │          │
│  │ - Port: 11434         │          │
│  │ - PVC: models (10Gi)  │          │
│  └──────────┬───────────┘          │
│             │                       │
│  ClusterIP Service                  │
│  ollama.ai.svc.cluster.local:11434  │
└─────────────┬───────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│  karakeep namespace (Phase 4.24)    │
│  Karakeep → OLLAMA_BASE_URL=        │
│    http://ollama.ai.svc:11434       │
└─────────────────────────────────────┘
```

---

## Tasks

### 4.23.1 Research & Prepare

- [x] 4.23.1.1 Pin Ollama Docker image → `ollama/ollama:0.15.5` (Feb 2026, verify for newer at deploy time — very active release cadence)
- [ ] 4.23.1.2 Verify Ollama Kubernetes deployment patterns — volume mount for models (`/root/.ollama`)
- [ ] 4.23.1.3 Decide: dedicated `ai` namespace or `home` namespace
  - Recommendation: `ai` — isolates ML workloads, allows separate ResourceQuotas

### 4.23.2 Create Manifests

- [ ] 4.23.2.1 Create `manifests/ai/namespace.yaml`
  - PSS label: `pod-security.kubernetes.io/enforce: baseline` (Ollama runs as root by default — see security context notes below)
  - If non-root confirmed working at deploy time, upgrade to `restricted`
- [ ] 4.23.2.2 Create `manifests/ai/ollama-deployment.yaml`
  - Image: `ollama/ollama:0.15.5`
  - PVC: 10Gi Longhorn for `/root/.ollama` (model storage)
  - `strategy: Recreate` (RWO volume)
  - Env: `OLLAMA_KEEP_ALIVE=5m` (keeps model loaded between requests)
  - Resource limits: `cpu: 1/4`, `memory: 3Gi/4Gi`
  - Note: qwen2.5:3b uses ~2.5-3GB RAM when loaded. The 4Gi limit fits one model at a time — running `llava` concurrently with `qwen2.5:3b` may require increasing the limit or relying on Ollama's auto-unload
  - Note: Ollama loads model into RAM on first request — memory usage spikes during inference
- [ ] 4.23.2.3 Create `manifests/ai/ollama-service.yaml` — ClusterIP (port 11434)
  - No HTTPRoute needed — internal service only (Karakeep connects via cluster DNS)
- [ ] 4.23.2.4 Security context:
  - `runAsNonRoot: true` — **Known blocker:** official Ollama image runs as root with models in `/root/.ollama`. Test at deploy time; if it fails, fall back to `runAsNonRoot: false` and keep PSS at `baseline`
  - `allowPrivilegeEscalation: false`
  - `capabilities.drop: [ALL]`
  - `seccompProfile.type: RuntimeDefault`
  - `readOnlyRootFilesystem` — NOT compatible (Ollama writes to model cache and temp files)

### 4.23.3 Deploy & Load Model

- [ ] 4.23.3.1 Apply manifests and verify pod running
- [ ] 4.23.3.2 Pull the primary model:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull qwen2.5:3b
  ```
- [ ] 4.23.3.3 Pull the fallback model (optional):
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull gemma3:1b
  ```
- [ ] 4.23.3.4 Pull vision model for Karakeep image tagging:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull llava
  ```
- [ ] 4.23.3.5 Verify models loaded:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama list
  ```

### 4.23.4 Verify Inference

- [ ] 4.23.4.1 Test text inference:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama run qwen2.5:3b "Classify this text into 3 tags: Kubernetes is a container orchestration platform"
  ```
- [ ] 4.23.4.2 Measure inference speed — should be 7-10 tok/s for qwen2.5:3b
- [ ] 4.23.4.3 Monitor node resource usage during inference:
  ```bash
  kubectl-homelab top pod -n ai
  kubectl-homelab top node
  ```
- [ ] 4.23.4.4 Verify model stays loaded in RAM for `OLLAMA_KEEP_ALIVE` duration

### 4.23.5 Documentation & Release

> Second commit: documentation updates and audit.

- [ ] 4.23.5.1 Update `docs/todo/README.md` — add Phase 4.23 to phase index + namespace table
- [ ] 4.23.5.2 Update `README.md` (root) — add Ollama to services list
- [ ] 4.23.5.3 Update `VERSIONS.md` — add Ollama version + model versions
- [ ] 4.23.5.4 Update `docs/reference/CHANGELOG.md` — add model selection + CPU inference decision entry
- [ ] 4.23.5.5 Update `docs/context/Cluster.md` — add `ai` namespace
- [ ] 4.23.5.6 Update `docs/context/Architecture.md` — document `ai` namespace + cross-namespace pattern for Ollama consumers
- [ ] 4.23.5.7 Create `docs/rebuild/v0.20.0-ollama.md`
- [ ] 4.23.5.8 `/audit-docs`
- [ ] 4.23.5.9 `/commit`
- [ ] 4.23.5.10 `/release v0.20.0 "Ollama Local AI"`
- [ ] 4.23.5.11 Move this file to `docs/todo/completed/`

---

## Operational Tips

1. **Increase `INFERENCE_JOB_TIMEOUT_SEC`** in Karakeep to 120+ — default 30s will timeout on CPU
2. **Start with `INFERENCE_CONTEXT_LENGTH=512`** — increase gradually (higher = more RAM, slower)
3. **Keep `INFERENCE_NUM_WORKERS=1`** — concurrent CPU inference thrashes memory
4. **Model loading takes 5-10s cold start** — `OLLAMA_KEEP_ALIVE=5m` avoids this between requests
5. **Add custom prompts in Karakeep** — normalize tags (capitalize proper nouns, lowercase otherwise, no underscores)

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/ai/namespace.yaml` | Namespace | AI workloads namespace |
| `manifests/ai/ollama-deployment.yaml` | Deployment + PVC | Ollama server + model storage |
| `manifests/ai/ollama-service.yaml` | Service | ClusterIP for internal access |

---

## Verification Checklist

- [ ] Ollama pod running in `ai` namespace
- [ ] `qwen2.5:3b` model loaded and listed
- [ ] Text inference produces reasonable output
- [ ] Inference speed: 7-10 tok/s (qwen2.5:3b) or 15-20 tok/s (gemma3:1b)
- [ ] Node memory usage stays within safe limits during inference
- [ ] Model stays loaded between requests (OLLAMA_KEEP_ALIVE working)
- [ ] Service accessible from other namespaces: `ollama.ai.svc.cluster.local:11434`

---

## Rollback

```bash
kubectl-homelab delete namespace ai
```
