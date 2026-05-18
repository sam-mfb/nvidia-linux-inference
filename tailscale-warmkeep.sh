#!/usr/bin/env bash
# Keep WireGuard sessions warm so long-idle Ollama requests don't drop.
# Ollama emits no bytes during prefill; if prefill ≥90s the WireGuard
# REKEY_ATTEMPT_TIME fires and the TCP stream is dropped. Pinging each
# active peer every 25s keeps the tunnel confirmed.
set -euo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin

tailscale status --json \
  | jq -r '.Peer[] | select(.Online) | .TailscaleIPs[0]' \
  | while read -r ip; do
      tailscale ping --c 1 --timeout 3s "$ip" >/dev/null 2>&1 || true
    done
