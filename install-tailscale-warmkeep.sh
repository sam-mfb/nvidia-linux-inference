#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing tailscale-warmkeep..."

install -m 755 "$REPO_DIR/tailscale-warmkeep.sh" /usr/local/bin/tailscale-warmkeep.sh
install -m 644 "$REPO_DIR/tailscale-warmkeep.service" /etc/systemd/system/tailscale-warmkeep.service
install -m 644 "$REPO_DIR/tailscale-warmkeep.timer" /etc/systemd/system/tailscale-warmkeep.timer

systemctl daemon-reload
systemctl enable --now tailscale-warmkeep.timer

echo "==> Waiting for first timer fire..."
sleep 32

echo ""
echo "==> Timer status:"
systemctl list-timers tailscale-warmkeep.timer

echo ""
echo "==> Manual one-shot run:"
systemctl start tailscale-warmkeep.service
echo "OK"

echo ""
echo "==> Journal (last 60s):"
journalctl -u tailscale-warmkeep.service --since "60 seconds ago" --no-pager
