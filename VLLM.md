# vLLM

vLLM is the main inference server on both machines. Ollama is kept as a backup / for testing.
vLLM serves one model at a time, reserves ~90% of VRAM up front, and exposes an
OpenAI-compatible API on port 8000. It cannot share the GPU(s) with Ollama or the
transcription server — `inference-mode` switches between them.

- API base: `http://<host>:8000/v1` (`nvidia6000` or `4090x2`)
- Model name in requests: the profile name (e.g. `qwen3-coder-next`) — only the profile
  currently running is available; `curl http://<host>:8000/v1/models` shows which
- Max 64 concurrent requests per server (`--max-num-seqs 64`); more are queued

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

**Untested** — 4090x2 was offline when these were written. Sizes fit on paper; expect
to tune `--max-model-len` / `--gpu-memory-utilization` on first run. Bring-up steps are
under [Setup](#setup).

| Profile | Model | Weights | Context |
|---------|-------|---------|---------|
| `qwen3-coder-30b` | Qwen/Qwen3-Coder-30B-A3B-Instruct-FP8 | ~31 GB | 64K |
| `gemma4-31b` | google/gemma-4-31B-it-qat-w4a16-ct — Google's 4-bit QAT | ~23 GB | 32K |
| `gemma4-26b` | google/gemma-4-26B-A4B-it, quantised to FP8 at load | ~26 GB | 32K |

Qwen3-Coder-Next doesn't fit on 4090x2 (80 GB at FP8).

All profiles support OpenAI-style tool calling. Gemma profiles also support thinking mode
(off by default; enable per request — see [Usage](#usage)). Qwen coder models don't think.

### Adding or changing a profile

1. Edit/add `vllm/<hostname>/<profile>.conf` — `VLLM_MODEL` is the Hugging Face repo id,
   `VLLM_ARGS` the extra `vllm serve` flags (one line; no quotes needed).
2. `./install-vllm.sh` — copies profiles to `/etc/vllm/`.
3. `inference-mode vllm <profile>` — starts it, or restarts it if it's already running.

A new model's weights download to `~sam/.cache/huggingface` on its first start, which can
take a while for large models; the server isn't ready until that and loading finish.

---

## Setup

Both commands use sudo, so run them from a real terminal (not Claude Code's `!`).

```bash
cd ~/nvidia-linux-inference
git pull
./install-vllm.sh                      # gcc, uv, venv at /opt/vllm/venv, profiles, unit,
                                       # overcommit sysctl, inference-mode
inference-mode vllm qwen3-coder-next   # 4090x2: qwen3-coder-30b
```

The second command stops Ollama, starts the profile, and makes it the mode that starts at
boot. `install-vllm.sh` is idempotent — re-run it after any change to profiles, the unit,
or `inference-mode`. The vLLM version is pinned there (`VLLM_VERSION`); bump and re-run to
upgrade.

Check it came up: `inference-mode status` (says "ready on :8000"), or `./gpu-check`.

## Switching

```bash
inference-mode status                  # what's running, what starts at boot, vLLM ready?
inference-mode vllm                    # list profiles
inference-mode vllm gemma4-31b         # switch model
inference-mode ollama                  # fall back to Ollama
```

The chosen mode is enabled at boot and the others disabled. Choosing the profile that's
already running restarts it. Loading a model takes 1–2 min with weights cached;
`/health` returns 200 once it's ready, and requests fail until then.

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

Gemma thinking mode is off by default. Turn it on per request by adding this to the
request body:
```json
"chat_template_kwargs": {"enable_thinking": true}
```
The reasoning comes back in the message's `reasoning` field, separate from `content`.
Thinking uses extra output tokens, so raise `max_tokens`.

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
