# vLLM

vLLM is the main inference server on both machines. Ollama is kept as a backup / for testing.
vLLM serves one model at a time, reserves ~90% of VRAM up front, and exposes an
OpenAI-compatible API on port 8000. It cannot share the GPU(s) with Ollama or the
transcription server — `inference-mode` switches between them.

- API base: `http://<host>:8000/v1`
- Model name in requests: the profile name (e.g. `qwen3-coder-next`)

---

## Profiles

A profile is one model plus its serve flags: `vllm/<hostname>/<profile>.conf` in this repo,
deployed to `/etc/vllm/<profile>.conf`, run by the templated unit `vllm@<profile>.service`.

### nvidia6000 (RTX PRO 6000, 96 GB)

| Profile | Model | Weights | Context | Speed* |
|---------|-------|---------|---------|--------|
| `qwen3-coder-next` | Qwen/Qwen3-Coder-Next-FP8 — 80B MoE, 3B active | ~75 GB | 256K | ~195 tok/s |
| `gemma4-31b` | google/gemma-4-31B-it — dense, FP8 at load | ~31 GB | 256K | ~43 tok/s |
| `gemma4-26b` | google/gemma-4-26B-A4B-it — MoE, 4B active, BF16 | ~52 GB | 256K | ~158 tok/s |

\* Single request, vLLM 0.31.0, measured 2026-10-25. Each takes ~1–2 min to start
with weights cached. Gemma 31B at BF16 ran ~25 tok/s with only 128K context, hence FP8.

### 4090x2 (2 × RTX 4090, 48 GB, tensor-parallel across both)

Untested — 4090x2 was offline when these were written.

| Profile | Model | Weights | Context |
|---------|-------|---------|---------|
| `qwen3-coder-30b` | Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 | ~31 GB | 64K |
| `gemma4-31b` | google/gemma-4-31B-it-qat-w4a16-ct — Google's 4-bit QAT | ~23 GB | 32K |
| `gemma4-26b` | google/gemma-4-26B-A4B-it, quantised to FP8 at load | ~26 GB | 32K |

Qwen3-Coder-Next doesn't fit on 4090x2 (80 GB at FP8). Gemma profiles have tool calling
and thinking mode enabled (`--reasoning-parser gemma4`); Qwen profiles have tool calling.

### Adding or changing a profile

Edit/add `vllm/<hostname>/<profile>.conf`, re-run `./install-vllm.sh`, then
`inference-mode vllm <profile>` (restarts it if already running). Weights download to
`~sam/.cache/huggingface` on first start.

---

## Setup

```bash
./install-vllm.sh                      # uv, venv at /opt/vllm/venv, profiles, unit, inference-mode
inference-mode vllm qwen3-coder-next   # stop Ollama, start + enable at boot
```

vLLM version is pinned in `install-vllm.sh` (`VLLM_VERSION`); bump and re-run to upgrade.

## Switching

```bash
inference-mode status                  # what's running, what starts at boot, vLLM ready?
inference-mode vllm                    # list profiles
inference-mode vllm gemma4-31b         # switch model
inference-mode ollama                  # fall back to Ollama
```

The chosen mode is enabled at boot and the others disabled. Loading a model takes a few
minutes (weights + CUDA graph capture); `/health` returns 200 once it's ready.

## Usage

```bash
curl http://nvidia6000:8000/health
curl http://nvidia6000:8000/v1/models

curl http://nvidia6000:8000/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "model": "qwen3-coder-next",
  "messages": [{"role": "user", "content": "Write a bash one-liner to count lines in *.py"}]
}'
```

Any OpenAI client works: base URL `http://nvidia6000:8000/v1`, any API key.

Gemma thinking mode, per request:
```json
"chat_template_kwargs": {"enable_thinking": true}
```
The reasoning comes back in the `reasoning` field, separate from `content`.

## Gotchas (all handled by `install-vllm.sh` / `vllm@.service`)

- **No C compiler → Triton fails at startup** ("Failed to find C compiler").
  Installer adds `build-essential`.
- **No CUDA toolkit (driver only) → anything that JIT-compiles with nvcc fails**
  ("Could not find nvcc"). The unit sets `VLLM_USE_DEEP_GEMM=0` and
  `VLLM_USE_FLASHINFER_SAMPLER=0` so vLLM uses its prebuilt kernels.
- **Large checkpoint shards → `unable to mmap ... Cannot allocate memory`.** Gemma 4 ships
  a single ~50 GB file; the default overcommit heuristic refuses it with ~30 GB RAM.
  Installer sets `vm.overcommit_memory=1` (`sysctl-overcommit.conf`).
- **`max_num_seqs (1024) exceeds available Mamba cache blocks`** (Qwen3-Coder-Next).
  vLLM's default concurrency is far more than a home server needs; every profile sets
  `--max-num-seqs 64`.

## Logs

```bash
journalctl -u 'vllm@*' -f
```
