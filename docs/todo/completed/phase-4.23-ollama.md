# Phase 4.23: Ollama Local AI

> **Status:** Complete
> **Target:** v0.20.0
> **Prerequisite:** Longhorn storage running, sufficient node resources
> **Priority:** Medium (foundation for Karakeep AI tagging)
> **DevOps Topics:** LLM inference, CPU-only ML workloads, resource management, quantization
> **CKA Topics:** Deployment, Service, PVC, ResourceQuota, resource limits, probes

> **Purpose:** Deploy Ollama for local LLM inference, primarily to support Karakeep's AI-powered bookmark tagging (Phase 4.24).
>
> **Constraint:** No GPU — all inference runs on CPU (Intel i5-10400T, 6c/12t, 16GB RAM per node). Model selection is critical.

---

## Hardware Constraint Analysis

| Resource | Per Node | Available (est.) |
|----------|----------|-----------------|
| CPU | 6 cores / 12 threads (AVX2, no AVX-512) | ~4-6 cores free |
| RAM | 16GB | ~8-10GB free (after K8s + existing workloads) |
| Memory bandwidth | ~35-40 GB/s (DDR4 dual-channel) | Primary inference bottleneck |
| GPU | None | CPU-only inference |

**Key insight:** Memory bandwidth is the bottleneck for LLM inference on CPU, not compute. Smaller models that fit entirely in RAM will perform dramatically better than models that cause swapping.

---

## Model Selection

### Recommended: `qwen3:1.7b` (Primary Text Model)

| Attribute | Value |
|-----------|-------|
| Parameters | 1.7B (2.03B actual) |
| Quantization | Q4_K_M (Ollama default) |
| Disk size | ~1.4 GB |
| RAM usage | ~1.8-2.2 GB |
| Est. speed on i5-10400T | 10-15 tokens/sec |
| Per-bookmark processing | ~10-20 seconds |
| Training data | 36T tokens (2x Qwen 2.5) |

**Why this model:**
- Qwen officially states: "Qwen3-1.7B performs as well as Qwen2.5-3B-Base" — same quality at half the size
- 36T training tokens across 119 languages (vs 18T for Qwen 2.5)
- Native structured output support — works with `INFERENCE_OUTPUT_SCHEMA=structured` (Karakeep default)
- Thinking/non-thinking mode — use `/nothink` prefix for tagging to skip chain-of-thought overhead
- Leaves ~6-8 GB RAM free for vision model + other workloads
- ~600MB less RAM than qwen2.5:3b, enabling comfortable coexistence with vision model

**Why not qwen2.5:3b (original plan):** Qwen3:1.7b matches its quality benchmarks while being nearly half the size, faster on CPU, and using less RAM. There is no reason to use the older, larger model.

### Recommended: `moondream` (Vision Model for Image Tagging)

| Attribute | Value |
|-----------|-------|
| Parameters | 1.8B |
| Quantization | Q4_K_M |
| Disk size | ~1.7 GB |
| RAM usage | ~2.0-2.5 GB |
| Est. speed on i5-10400T | 8-12 tokens/sec |
| Per-image processing | ~20-40 seconds |

**Why this model:**
- Designed for edge/constrained hardware — "run anywhere" philosophy
- 3x smaller than LLaVA (1.8B vs 7B), ~3 GB less RAM
- Karakeep sends images to any Ollama vision model via `INFERENCE_IMAGE_MODEL` — moondream works
- Practical for CPU: LLaVA at 7B would run at ~3-5 tok/s and consume 5-6 GB RAM

**Why not llava (original plan):** LLaVA (7B) + qwen2.5:3b (3B) loaded simultaneously = ~9 GB RAM, leaving almost nothing on a 16GB node. Moondream (1.8B) + qwen3:1.7b loaded simultaneously = ~4.5 GB RAM — dramatically better.

**Alternative vision model:** `granite3.2-vision:2b` (IBM) — ranked 2nd on OCRBench, excels at document/screenshot understanding. Same size class as moondream. Consider if bookmarks are mostly screenshots/documents rather than photos.

### Fallback: `gemma3:1b` (Ultra-lightweight Text)

| Attribute | Value |
|-----------|-------|
| Parameters | 1B |
| Quantization | Q4_K_M |
| Disk size | ~0.8 GB |
| RAM usage | ~1.2-1.5 GB |
| Est. speed on i5-10400T | 12-18 tokens/sec |
| Per-bookmark processing | ~5-15 seconds |

**When to use:** If qwen3:1.7b produces poor tags or node resources are too tight.

**Caveat:** Known memory leak with Gemma3 + structured output in Ollama ([issue #10688](https://github.com/ollama/ollama/issues/10688)). If using gemma3, set `INFERENCE_OUTPUT_SCHEMA=plain` in Karakeep. Alternative fallback: `qwen3:0.6b` (no memory leak concern, works with structured output).

### Not Recommended

| Model | Why Not |
|-------|---------|
| LLaVA 7B | 5-6 GB RAM, 3-5 tok/s — too heavy for CPU alongside text model |
| Mistral 7B / Qwen 2.5:7B | 5.5-7 GB RAM, 3-5 tok/s — too slow, too heavy |
| Gemma 2:9B | 6.5-8 GB RAM, 2-3 tok/s — impractical on i5-10400T |
| Qwen 2.5:0.5B | Tags will be unreliable — too small for classification |
| Phi-4-mini (3.8B) | Strengths are math/logic, not tagging — qwen3:1.7b is better at half the size |
| Gemma3n:e2b | 5.6 GB disk despite "2B effective" — edge optimizations target GPU memory, not CPU speed |

### Quantization

Use **Q4_K_M** for all models (Ollama's default). This is already what `ollama pull` downloads — no special configuration needed.

**Why Q4_K_M is optimal for tagging:**
- Classification/tagging is the **least sensitive** task to quantization — confidence gaps between categories are wide enough that reduced precision doesn't change results
- Red Hat tested 500,000+ evaluations: 4-bit models retain **96-99% accuracy** across all benchmarks
- Q4_K_M is ~2.5x faster than FP16 on CPU (less data to read from RAM = faster inference)
- Q4_K_M uses ~30% of FP16 disk/RAM — critical for 16GB nodes
- Quality difference vs Q5_K_M or Q8_0 is negligible for structured output tasks

| Quant Level | Bits | Disk (1.7B model) | RAM | Speed vs FP16 | Quality Loss |
|---|---|---|---|---|---|
| FP16 | 16 | ~4.1 GB | ~5 GB | 1.0x | None |
| Q8_0 | 8 | ~2.2 GB | ~3 GB | ~1.8x faster | <0.1% |
| **Q4_K_M** | 4.8 | **~1.4 GB** | **~2 GB** | **~2.5x faster** | **~0.6%** |
| Q2_K | 3 | ~0.8 GB | ~1.2 GB | ~3.2x faster | ~11% (avoid) |

**Golden rule:** A bigger model at Q4_K_M almost always beats a smaller model at Q8_0 — the extra parameters contribute more to quality than extra precision per weight.

### Combined Resource Budget

| Configuration | Text RAM | Vision RAM | Both Loaded | Fits in 8-10 GB? |
|---|---|---|---|---|
| **Updated plan** (qwen3:1.7b + moondream) | ~2.0 GB | ~2.5 GB | **~4.5 GB** | Comfortable |
| Original plan (qwen2.5:3b + llava) | ~3.0 GB | ~5.5 GB | ~8.5 GB | Barely / dangerous |

---

## Architecture

```
┌─────────────────────────────────────┐
│  ai namespace                       │
│                                     │
│  ┌──────────────────────┐          │
│  │ Ollama (Deployment)  │          │
│  │ - Text: qwen3:1.7b   │          │
│  │ - Vision: moondream   │          │
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

- [x] 4.23.1.1 Pin Ollama Docker image → `ollama/ollama:0.15.6` (Feb 7, 2026 — latest stable, no breaking changes since 0.14.x)
- [x] 4.23.1.2 Verify Ollama Kubernetes deployment patterns — volume mount at `/root/.ollama`, ClusterIP on 11434, Recreate strategy for RWO PVC (confirmed standard practice, matches otwld Helm chart defaults)
- [x] 4.23.1.3 Decide: dedicated `ai` namespace — isolates ML workloads, allows separate ResourceQuotas
- [x] 4.23.1.4 Research model selection — qwen3:1.7b replaces qwen2.5:3b (same quality, half size), moondream replaces llava (3x smaller vision model)
- [x] 4.23.1.5 Research quantization — Q4_K_M (Ollama default) is optimal for classification/tagging, no configuration needed

### 4.23.2 Create Manifests

- [x] 4.23.2.1 Create `manifests/ai/namespace.yaml`
  - PSS labels: `enforce: baseline`, `warn: restricted`, `audit: restricted`
  - Ollama runs as root (PR #8259 not merged). `warn`/`audit` restricted logs violations for future non-root compatibility visibility
- [x] 4.23.2.2 Create `manifests/ai/ollama-deployment.yaml`
  - Image: `ollama/ollama:0.15.6`
  - PVC: 10Gi Longhorn for `/root/.ollama` (model storage — qwen3:1.7b 1.4G + moondream 1.7G + gemma3:1b 0.8G = ~4G total, 60% headroom)
  - `strategy: Recreate` (RWO volume, single replica — Deployment is correct, not StatefulSet)
  - Environment variables:
    - `OLLAMA_HOST=0.0.0.0` (required for container networking, default is 127.0.0.1)
    - `OLLAMA_KEEP_ALIVE=5m` (keeps model loaded between requests, avoids 5-10s cold start)
    - `OLLAMA_MAX_LOADED_MODELS=1` (conserve RAM on 16GB nodes — Ollama auto-unloads when switching between text/vision)
    - `OLLAMA_NUM_PARALLEL=1` (avoid memory thrashing on CPU)
    - `OLLAMA_KV_CACHE_TYPE=q8_0` (saves RAM with minimal quality impact vs default f16)
  - Resource limits: `cpu: 1/4`, `memory: 2Gi/6Gi`
  - Note: 6Gi limit required because Ollama mmap's model files into memory, and the kernel page cache from model storage also counts against the cgroup limit. With 3Gi, page cache filled the limit leaving no room for model loading. 6Gi fits one loaded model (~2 GB mmap) + Ollama overhead (~200 Mi) + page cache comfortably.
  - Health probes (endpoint: `GET /` on port 11434, returns "Ollama is running"):
    ```yaml
    startupProbe:
      httpGet:
        path: /
        port: 11434
      initialDelaySeconds: 10
      periodSeconds: 10
      failureThreshold: 30  # up to 310s for first startup
    livenessProbe:
      httpGet:
        path: /
        port: 11434
      initialDelaySeconds: 60
      periodSeconds: 10
      timeoutSeconds: 5
      failureThreshold: 6
    readinessProbe:
      httpGet:
        path: /
        port: 11434
      initialDelaySeconds: 30
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 6
    ```
- [x] 4.23.2.3 Create `manifests/ai/ollama-service.yaml` — ClusterIP (port 11434)
  - No HTTPRoute needed — internal service only (Karakeep connects via cluster DNS)
- [x] 4.23.2.4 Security context:
  - `runAsNonRoot: false` — official Ollama image runs as root (PR #8259 not merged as of Feb 2026)
  - `allowPrivilegeEscalation: false`
  - `capabilities.drop: [ALL]`
  - `seccompProfile.type: RuntimeDefault`
  - `readOnlyRootFilesystem: false` — Ollama writes to model cache and temp files
  - Pod-level: `fsGroup: 0` (root group, required for `/root/.ollama` volume access)

### 4.23.3 Deploy & Load Model

- [x] 4.23.3.1 Apply manifests and verify pod running
- [x] 4.23.3.2 Pull the primary text model:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull qwen3:1.7b
  ```
- [x] 4.23.3.3 Pull the vision model for Karakeep image tagging:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull moondream
  ```
- [x] 4.23.3.4 Pull the fallback text model (optional):
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama pull gemma3:1b
  ```
- [x] 4.23.3.5 Verify models loaded:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama list
  ```
  Expected: qwen3:1.7b (~1.4 GB), moondream (~1.7 GB), gemma3:1b (~0.8 GB) — total ~3.9 GB on 10Gi PVC

### 4.23.4 Verify Inference

- [x] 4.23.4.1 Test text inference:
  ```bash
  kubectl-homelab exec -n ai deploy/ollama -- ollama run qwen3:1.7b "Classify this text into 3 tags: Kubernetes is a container orchestration platform"
  ```
- [x] 4.23.4.2 Test vision inference:
  ```bash
  # From a pod with an image file, or via API:
  kubectl-homelab exec -n ai deploy/ollama -- ollama run moondream "Describe this image"
  ```
- [x] 4.23.4.3 Measure inference speed — should be 10-15 tok/s for qwen3:1.7b, 8-12 tok/s for moondream
- [x] 4.23.4.4 Monitor node resource usage during inference:
  ```bash
  kubectl-homelab top pod -n ai
  kubectl-homelab top node
  ```
- [x] 4.23.4.5 Verify model stays loaded in RAM for `OLLAMA_KEEP_ALIVE` duration
- [x] 4.23.4.6 Verify service accessible from other namespaces:
  ```bash
  kubectl-homelab run curl-test --rm -it --image=curlimages/curl -- curl http://ollama.ai.svc.cluster.local:11434
  # Should return: "Ollama is running"
  ```

### 4.23.5 Documentation & Release

> Second commit: documentation updates and audit.

- [x] 4.23.5.1 Security audit (`/audit-security`)
- [x] 4.23.5.2 `/commit` (infrastructure)
- [x] 4.23.5.3 Update `docs/todo/README.md` — add Phase 4.23 to phase index + namespace table
- [x] 4.23.5.4 Update `README.md` (root) — add Ollama to services list
- [x] 4.23.5.5 Update `VERSIONS.md` — add Ollama version + model versions
- [x] 4.23.5.6 Update `docs/reference/CHANGELOG.md` — add model selection + CPU inference + quantization decision entry
- [x] 4.23.5.7 Update `docs/context/Cluster.md` — add `ai` namespace
- [x] 4.23.5.8 Update `docs/context/Architecture.md` — document `ai` namespace + cross-namespace pattern for Ollama consumers
- [x] 4.23.5.9 Create `docs/rebuild/v0.20.0-ollama.md`
- [x] 4.23.5.10 `/audit-docs`
- [x] 4.23.5.11 `/commit` (documentation)
- [x] 4.23.5.12 `/release v0.20.0 "Ollama Local AI"`
- [x] 4.23.5.13 Move this file to `docs/todo/completed/`

---

## Operational Tips

### Ollama Configuration
1. **`OLLAMA_MAX_LOADED_MODELS=1`** — prevents loading text + vision simultaneously on 16GB nodes
2. **`OLLAMA_KV_CACHE_TYPE=q8_0`** — reduces KV cache memory usage with negligible quality impact
3. **`OLLAMA_KEEP_ALIVE=5m`** — keeps model loaded between requests (cold start is 5-10s on CPU)
4. **Models persist on PVC** — only need to pull once, survives pod restarts. Only PVC loss requires re-pull.

### Karakeep Configuration (Phase 4.24 reference)
1. **Set `INFERENCE_TEXT_MODEL=qwen3:1.7b`** — default is `gpt-4.1-mini` which will fail against Ollama
2. **Set `INFERENCE_IMAGE_MODEL=moondream`** — default is `gpt-4o-mini`
3. **Increase `INFERENCE_JOB_TIMEOUT_SEC=180`** — default 30s will timeout on CPU
4. **Increase `INFERENCE_FETCH_TIMEOUT_SEC=600`** — separate Ollama HTTP timeout, default 300s may not be enough
5. **Keep `INFERENCE_NUM_WORKERS=1`** — concurrent CPU inference thrashes memory
6. **Start with `INFERENCE_CONTEXT_LENGTH=2048`** — increase gradually (higher = more RAM, slower)
7. **Do NOT set `OPENAI_API_KEY`** — it takes precedence over `OLLAMA_BASE_URL` and ignores Ollama entirely
8. **Disable auto-tagging during bulk imports** — CPU Ollama cannot keep up with large queues
9. **Add custom prompts in Karakeep** — normalize tags (capitalize proper nouns, lowercase otherwise, no underscores)

---

## Karakeep Gotchas (Phase 4.24 reference)

| Issue | Detail |
|-------|--------|
| Default text model is `gpt-4.1-mini` | Must explicitly set `INFERENCE_TEXT_MODEL` — won't auto-detect Ollama models |
| `OLLAMA_BASE_URL` must not be `localhost` | Use `http://ollama.ai.svc.cluster.local:11434` |
| Gemma3 + structured output = memory leak | Ollama [issue #10688](https://github.com/ollama/ollama/issues/10688) — use `INFERENCE_OUTPUT_SCHEMA=plain` with Gemma3 |
| Two timeout values | Both `INFERENCE_JOB_TIMEOUT_SEC` AND `INFERENCE_FETCH_TIMEOUT_SEC` must be increased for CPU |
| v0.30.0 switched to `generate` endpoint | Karakeep now uses Ollama `generate` instead of `chat` — improves compatibility |
| No Ollama option passthrough | Can't set temperature/top_k from Karakeep — use custom Ollama Modelfile if needed ([issue #1806](https://github.com/karakeep-app/karakeep/issues/1806)) |

---

## Files to Create

| File | Type | Purpose |
|------|------|---------|
| `manifests/ai/namespace.yaml` | Namespace | AI workloads namespace |
| `manifests/ai/ollama-deployment.yaml` | Deployment + PVC | Ollama server + model storage |
| `manifests/ai/ollama-service.yaml` | Service | ClusterIP for internal access |

---

## Verification Checklist

- [x] Ollama pod running in `ai` namespace
- [x] `qwen3:1.7b` model loaded and listed
- [x] `moondream` model loaded and listed
- [x] Text inference produces reasonable output (10-15 tok/s)
- [x] Vision inference produces reasonable image descriptions (8-12 tok/s)
- [x] Node memory usage stays within safe limits during inference (<3 GB per model)
- [x] Model stays loaded between requests (OLLAMA_KEEP_ALIVE working)
- [x] Service accessible from other namespaces: `ollama.ai.svc.cluster.local:11434`
- [x] Health probes passing (startup, liveness, readiness)

---

## Rollback

```bash
kubectl-homelab delete namespace ai
```

---

## Research Sources

| Topic | Source |
|-------|--------|
| Ollama releases | [github.com/ollama/ollama/releases](https://github.com/ollama/ollama/releases) |
| Qwen3 announcement | [qwenlm.github.io/blog/qwen3](https://qwenlm.github.io/blog/qwen3/) |
| Moondream | [github.com/vikhyat/moondream](https://github.com/vikhyat/moondream) |
| Karakeep AI config | [docs.karakeep.app/configuration/different-ai-providers](https://docs.karakeep.app/configuration/different-ai-providers/) |
| Karakeep env vars | [docs.karakeep.app/configuration/environment-variables](https://docs.karakeep.app/configuration/environment-variables/) |
| Ollama non-root status | [github.com/ollama/ollama/issues/5986](https://github.com/ollama/ollama/issues/5986) |
| Ollama health endpoint | [github.com/ollama/ollama/issues/1378](https://github.com/ollama/ollama/issues/1378) |
| Gemma3 memory leak | [github.com/ollama/ollama/issues/10688](https://github.com/ollama/ollama/issues/10688) |
| Quantization benchmarks | [Red Hat 500K evaluations](https://developers.redhat.com/articles/2024/10/17/we-ran-over-half-million-evaluations-quantized-llms) |
| GGUF quantization data | [Artefact2 GGUF overview](https://gist.github.com/Artefact2/b5f810600771265fc1e39442288e8ec9) |
| Karakeep CPU discussions | [#430](https://github.com/karakeep-app/karakeep/discussions/430), [#1833](https://github.com/karakeep-app/karakeep/discussions/1833) |
| otwld Helm chart | [github.com/otwld/ollama-helm](https://github.com/otwld/ollama-helm) |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Text model | `qwen3:1.7b` over `qwen2.5:3b` | Same quality (official Qwen benchmark), half the size, faster, 36T training tokens |
| Vision model | `moondream` (1.8B) over `llava` (7B) | 3x smaller, both loaded = 4.5 GB vs 8.5 GB — critical for 16GB nodes |
| Quantization | Q4_K_M (Ollama default) | Classification/tagging barely affected by quantization; 2.5x faster than FP16 |
| Namespace | `ai` (dedicated) | Isolates ML workloads, allows separate ResourceQuotas |
| Deployment pattern | Deployment + Recreate (not StatefulSet) | Single replica, no stable identity needed, RWO PVC |
| Helm vs raw manifests | Raw manifests | Consistent with repo convention, simpler, better for CKA learning |
| Non-root | Skip (run as root) | Official image requires root (PR #8259 not merged), custom Dockerfile adds maintenance burden |
| Model loading | Manual `kubectl exec` pull | Models persist on PVC, simplest approach. Future: `ollama pull --local` in init container |

---

## CKA Learnings

| Topic | Concept |
|-------|---------|
| Resource management | CPU/memory limits for unpredictable workloads (inference spikes) |
| Probes | Startup probe for slow-start containers (model loading), liveness vs readiness separation |
| PVC lifecycle | Models persist across pod restarts, only lost on PVC deletion |
| Cross-namespace access | Service DNS: `<service>.<namespace>.svc.cluster.local` |
| Pod Security Standards | `baseline` enforce with `restricted` warn/audit for future migration visibility |
| Deployment vs StatefulSet | Deployment for single-replica stateless servers with external PVC |
