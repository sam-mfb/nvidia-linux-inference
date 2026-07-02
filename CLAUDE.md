# Inference Machines — Claude Instructions

This repo manages two headless inference servers on the same tailnet. See `SYSTEM.md` for full hardware specs.

| Machine | Hostname | GPU | Tailscale IP |
|---------|----------|-----|--------------|
| `nvidia6000` | nvidia6000 | RTX PRO 6000 Blackwell (96 GB) — single | 100.92.253.56 |
| `4090x2` | 4090x2 | RTX 4090 × 2 (24 GB each) | 100.88.241.33 |

Repo lives at `/home/sam/nvidia-linux-inference` on both machines.

## What's in this repo

Config files deployed to system paths. The repo is the source of truth;
copy files to their destinations after editing.

| File | Deployed to |
|------|------------|
| `tailscale-up.service` | `/etc/systemd/system/tailscale-up.service` |
| `ollama-override.conf` | `/etc/systemd/system/ollama.service.d/override.conf` |
| `inference-monitor.sh` | `/usr/local/bin/inference-monitor.sh` |
| `inference-monitor.service` | `/etc/systemd/system/inference-monitor.service` |
| `inference-monitor.timer` | `/etc/systemd/system/inference-monitor.timer` |
| `inference.logrotate` | `/etc/logrotate.d/inference` |
| `journald-persistence.conf` | `/etc/systemd/journald.conf.d/persistence.conf` |
| `it87/` | **4090x2 only** — submodule, `make && sudo make install` |
| `transcribe-server.py` | **4090x2 only** — `/opt/transcribe/transcribe-server.py` |
| `transcribe.service` | **4090x2 only** — `/etc/systemd/system/transcribe.service` |
| `inference-mode` | **4090x2 only** — `/usr/local/bin/inference-mode` |

## Ollama

Ollama listens on `0.0.0.0:11434` (all interfaces, controlled by Tailscale at network level).
Models are stored at `/usr/share/ollama/.ollama/models/`.

### Check running models / server status
```bash
ollama list
ollama ps
systemctl status ollama
```

### Pull a model
```bash
ollama pull <model>
# Resumes partial downloads automatically if interrupted
```

### Query from another tailnet node
```bash
curl http://nvidia6000:11434/api/tags
OLLAMA_HOST=http://nvidia6000:11434 ollama run <model>

curl http://4090x2:11434/api/tags
OLLAMA_HOST=http://4090x2:11434 ollama run gemma4:26b-a4b-it-q8_0
```

### Check what other nodes on the tailnet have
```bash
curl -s http://nvidia5090:11434/api/tags | python3 -m json.tool
curl -s http://m5max128:11434/api/tags | python3 -m json.tool
```

### Ollama crashes / restart
Ollama auto-restarts on failure (10s backoff). To manually restart:
```bash
sudo systemctl restart ollama
```

## GPU

### nvidia6000 — RTX PRO 6000 Blackwell (single GPU)
```bash
nvidia-smi
nvidia-smi dmon -s pcut
watch -n2 nvidia-smi
```

### 4090x2 — dual RTX 4090
```bash
nvidia-smi                          # status snapshot (shows both GPUs)
nvidia-smi dmon -s pcut            # live: power, utilisation, temp per GPU
watch -n2 nvidia-smi               # refresh every 2s
```

Driver: 595.x on both machines. **nvidia6000** uses the open kernel module (required for Blackwell — see SYSTEM.md). **4090x2** uses the server-open variant.

## Monitoring

A systemd timer runs `/usr/local/bin/inference-monitor.sh` every 30 seconds and appends
a CSV row to `/var/log/inference/metrics.csv`.

The CSV schema differs by machine:

**nvidia6000** (single GPU, ASUS board sensors):
```
timestamp, gpu0_temp, gpu0_power_w, gpu0_mem_mib, gpu0_util_pct,
cpu_temp, nvme_temp, load1, mem_used_mib, ollama_status,
asusec_cpu, asusec_pkg, asusec_mb, asusec_vrm, fan_rpm, cpu_pkg_w
```

**4090x2** (dual GPU, ITE IT8696 board sensors):
```
timestamp, gpu0_temp, gpu0_power_w, gpu0_mem_mib, gpu0_util_pct,
gpu1_temp, gpu1_power_w, gpu1_mem_mib, gpu1_util_pct,
cpu_temp, nvme_temp, load1, mem_used_mib, ollama_status,
it8696_t1, it8696_t2, it8696_t3, it8696_t4, it8696_t5, it87952_t1, it87952_t3
```

```bash
# Live tail
tail -f /var/log/inference/metrics.csv

# Pretty-print a time window
grep "2026-05-14T18" /var/log/inference/metrics.csv | column -t -s,

# Check timer is running
systemctl status inference-monitor.timer
```

Logs rotate daily, 30-day history, compressed. journald is persistent (survives reboots),
capped at 2 GB, 30-day retention.

### Post-crash investigation
```bash
# Kernel / thermal / OOM events from last boot
journalctl -b -1 -p err

# What happened in the 10 min before a reboot
journalctl -b -1 --since "10 min before reboot"

# Reboot history
last -x | grep -E "reboot|shutdown"
```

## Temperatures / fans

```bash
sensors        # all sensors (requires lm-sensors)
```

**nvidia6000**: Board sensors via in-kernel `asus-ec-sensors` driver. No extra setup needed.
The monitor script reads `asusec` via sysfs directly (not in lm-sensors chip database).

**4090x2**: Fan sensors require the `it87` module (out-of-tree, loaded via
`/etc/modules-load.d/it87.conf` with `ignore_resource_conflict=1`). Source is the `it87/` submodule.

## Tailscale

`tailscale-up.service` uses `%H` (systemd hostname specifier) so the same file works on both machines.
Auth key stored at `/etc/tailscale/authkey` (root:root, 600) — not in this repo.

```bash
tailscale status     # see all nodes
tailscale ping nvidia6000
tailscale ping 4090x2
```

SSH via Tailscale: `ssh sam@<hostname>` from any tailnet node.

## Transcription Server

WhisperX (`large-v3`) + pyannote diarization. Whisper on `cuda:0`, diarization on `cuda:1`.
**Cannot run alongside Ollama** — `Conflicts=ollama.service` is set in the unit file.

| File | Deployed to |
|------|------------|
| `transcribe-server.py` | `/opt/transcribe/transcribe-server.py` |
| `transcribe.service` | `/etc/systemd/system/transcribe.service` |

Config at `/etc/transcribe/config.env` (root:sam 640) — contains `HF_TOKEN`, not in this repo.
Data (uploads, results, SQLite DB) at `/var/lib/transcribe/`.
Virtualenv at `/opt/transcribe/venv/`.

### Install (first time)
```bash
HF_TOKEN=hf_... ./install-transcribe.sh
```

### Switch modes
```bash
inference-mode transcribe   # stop Ollama, start transcription server
inference-mode ollama       # stop transcription, start Ollama
inference-mode status       # show which is currently running
```

See `TRANSCRIBE.md` for full client usage docs.

### Usage
```bash
# Submit a file
curl -X POST http://4090x2:8765/transcribe \
  -F file=@interview.mp4 \
  -F num_speakers=2

# Poll for result
curl http://4090x2:8765/jobs/<job_id>

# Download as SRT
curl "http://4090x2:8765/jobs/<job_id>?format=srt"

# Plain text with speaker labels
curl "http://4090x2:8765/jobs/<job_id>?format=txt"

# List recent jobs
curl http://4090x2:8765/jobs

# Health / model status
curl http://4090x2:8765/health
```

Accepts: mp3, wav, flac, m4a, ogg (audio) and mp4, mkv, mov, avi, webm (video — ffmpeg extracts audio).
Optional form fields: `num_speakers` (int), `language` (ISO code e.g. `en`) — both auto-detected if omitted.

### Logs
```bash
journalctl -u transcribe -f
```

## Storage / LVM

Root LV was set to 100 GB on both machines. If disk fills:
```bash
df -h /
sudo vgs                                        # check VG free space
sudo lvextend -L +<size>G /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```
