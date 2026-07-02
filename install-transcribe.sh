#!/usr/bin/env bash
# Install the transcription server.
# Run as a user with sudo access. Idempotent — safe to re-run.
set -euo pipefail

INSTALL_DIR=/opt/transcribe
DATA_DIR=/var/lib/transcribe
CONFIG_DIR=/etc/transcribe
SERVICE_SRC="$(cd "$(dirname "$0")" && pwd)/transcribe.service"
SERVER_SRC="$(cd "$(dirname "$0")" && pwd)/transcribe-server.py"

# ── system deps ───────────────────────────────────────────────────────────────
echo "→ Checking system deps..."
sudo apt-get install -y --no-install-recommends ffmpeg python3-venv python3-dev

# ── install dir ───────────────────────────────────────────────────────────────
echo "→ Setting up $INSTALL_DIR ..."
sudo mkdir -p "$INSTALL_DIR"
sudo cp "$SERVER_SRC" "$INSTALL_DIR/transcribe-server.py"
sudo chown -R sam:sam "$INSTALL_DIR"

# ── virtualenv ────────────────────────────────────────────────────────────────
if [ ! -f "$INSTALL_DIR/venv/bin/python" ]; then
    echo "→ Creating virtualenv..."
    python3 -m venv "$INSTALL_DIR/venv"
fi

echo "→ Installing PyTorch (CUDA 12.4)..."
"$INSTALL_DIR/venv/bin/pip" install --upgrade pip
"$INSTALL_DIR/venv/bin/pip" install torch --index-url https://download.pytorch.org/whl/cu124

echo "→ Installing WhisperX and server deps..."
"$INSTALL_DIR/venv/bin/pip" install whisperx fastapi "uvicorn[standard]" python-multipart

# ── data dirs ─────────────────────────────────────────────────────────────────
echo "→ Creating data dirs..."
sudo mkdir -p "$DATA_DIR/uploads" "$DATA_DIR/results"
sudo chown -R sam:sam "$DATA_DIR"

# ── config ────────────────────────────────────────────────────────────────────
if [ ! -f "$CONFIG_DIR/config.env" ]; then
    echo "→ Writing config..."
    sudo mkdir -p "$CONFIG_DIR"
    sudo tee "$CONFIG_DIR/config.env" > /dev/null <<'EOF'
HF_TOKEN=REPLACE_ME
WHISPER_MODEL=large-v3
TRANSCRIBE_PORT=8765
EOF
    sudo chmod 640 "$CONFIG_DIR/config.env"
    sudo chown root:sam "$CONFIG_DIR/config.env"
fi

# Inject HF token if provided as arg
if [ -n "${HF_TOKEN:-}" ]; then
    sudo sed -i "s|^HF_TOKEN=.*|HF_TOKEN=$HF_TOKEN|" "$CONFIG_DIR/config.env"
    echo "→ HF_TOKEN written to $CONFIG_DIR/config.env"
fi

# ── mode-switch script ────────────────────────────────────────────────────────
echo "→ Installing inference-mode..."
sudo cp "$(cd "$(dirname "$0")" && pwd)/inference-mode" /usr/local/bin/inference-mode
sudo chmod +x /usr/local/bin/inference-mode

# ── systemd ───────────────────────────────────────────────────────────────────
echo "→ Installing systemd service..."
sudo cp "$SERVICE_SRC" /etc/systemd/system/transcribe.service
sudo systemctl daemon-reload
sudo systemctl enable transcribe.service

echo ""
echo "Done. To start the transcription server:"
echo "  sudo systemctl stop ollama      # free the GPUs"
echo "  sudo systemctl start transcribe"
echo ""
echo "To switch back to Ollama:"
echo "  sudo systemctl stop transcribe"
echo "  sudo systemctl start ollama"
echo ""
echo "Health check (once running):"
echo "  curl http://localhost:8765/health"
