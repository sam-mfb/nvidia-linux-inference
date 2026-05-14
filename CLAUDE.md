# Inference Machine — Claude Instructions

This repo lives at `/home/sam/inference` on `4090x2`, a headless dual-RTX-4090 inference server.
See `SYSTEM.md` for full hardware specs.

## What's in this repo

Config files that are deployed to system paths. The repo is the source of truth;
copy files to their destinations after editing (see paths below).

| File | Deployed to |
|------|------------|
| `tailscale-up.service` | `/etc/systemd/system/tailscale-up.service` |
| `ollama-override.conf` | `/etc/systemd/system/ollama.service.d/override.conf` |
| `inference-monitor.sh` | `/usr/local/bin/inference-monitor.sh` |
| `inference-monitor.service` | `/etc/systemd/system/inference-monitor.service` |
| `inference-monitor.timer` | `/etc/systemd/system/inference-monitor.timer` |
| `inference.logrotate` | `/etc/logrotate.d/inference` |
| `journald-persistence.conf` | `/etc/systemd/journald.conf.d/persistence.conf` |
| `it87/` | submodule — built and installed via `make && sudo make install` |

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

Both RTX 4090s are compute-only (no display connected).

```bash
nvidia-smi                          # status snapshot
nvidia-smi dmon -s pcut            # live: power, utilisation, temp per GPU
watch -n2 nvidia-smi               # refresh every 2s
```

Driver: 595.58.03 (nvidia-headless-no-dkms-595-server-open)
CUDA: 13.2

## Monitoring

A systemd timer runs `/usr/local/bin/inference-monitor.sh` every 30 seconds and appends
a CSV row to `/var/log/inference/metrics.csv`. Columns:

```
timestamp, gpu0_temp, gpu0_power_w, gpu0_mem_mib, gpu0_util_pct,
gpu1_temp, gpu1_power_w, gpu1_mem_mib, gpu1_util_pct,
cpu_temp, nvme_temp, load1, mem_used_mib, ollama_status
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
sensors        # all sensors (it87 + k10temp + nvme + NICs)
```

Fan sensors require the `it87` module (out-of-tree, loaded via `/etc/modules-load.d/it87.conf`
with `ignore_resource_conflict=1`). Source is the `it87/` submodule.

## Tailscale

Node name: `4090x2` | Tailscale IP: `100.88.241.33`

```bash
tailscale status     # see all nodes
tailscale ping 4090x2
```

Auth key stored at `/etc/tailscale/authkey` (root:root, 600) — not in this repo.
SSH via Tailscale: `ssh sam@4090x2` from any tailnet node.

## Storage / LVM

Root LV was expanded from 100 GB to fill the VG. If disk fills again:
```bash
df -h /
sudo vgs                                        # check VG free space
sudo lvextend -L +<size>G /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```
