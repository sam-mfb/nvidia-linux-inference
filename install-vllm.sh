#!/usr/bin/env bash
# Install vLLM and this machine's model profiles.
# Run as sam (uses sudo where needed). Idempotent — safe to re-run, e.g. after
# editing a profile or bumping VLLM_VERSION.
set -euo pipefail

VLLM_VERSION=0.31.0
UV_VERSION=0.12.24
INSTALL_DIR=/opt/vllm
CONFIG_DIR=/etc/vllm
REPO="$(cd "$(dirname "$0")" && pwd)"
PROFILES_SRC="$REPO/vllm/$(hostname)"

[ -d "$PROFILES_SRC" ] || { echo "No profiles for $(hostname) in $REPO/vllm/"; exit 1; }

# ── system deps ───────────────────────────────────────────────────────────────
# Triton (used by torch.compile and some vLLM kernels) compiles small C helpers at startup
echo "→ Checking system deps..."
command -v gcc &>/dev/null || sudo apt-get install -y --no-install-recommends build-essential

echo "→ Allowing memory overcommit (large checkpoint shards)..."
sudo cp "$REPO/sysctl-overcommit.conf" /etc/sysctl.d/90-inference-overcommit.conf
sudo sysctl -q -p /etc/sysctl.d/90-inference-overcommit.conf

# ── uv ────────────────────────────────────────────────────────────────────────
# uv fetches its own Python 3.12, so no deadsnakes PPA needed
if ! command -v uv &>/dev/null; then
    echo "→ Installing uv $UV_VERSION to /usr/local/bin..."
    curl -LsSf "https://astral.sh/uv/$UV_VERSION/install.sh" \
        | sudo env UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

# ── install dir ───────────────────────────────────────────────────────────────
echo "→ Setting up $INSTALL_DIR ..."
sudo mkdir -p "$INSTALL_DIR/templates"
sudo chown -R sam:sam "$INSTALL_DIR"

# ── virtualenv ────────────────────────────────────────────────────────────────
# Keep the interpreter under /opt/vllm rather than ~/.local/share/uv
export UV_PYTHON_INSTALL_DIR="$INSTALL_DIR/python"
if [ ! -f "$INSTALL_DIR/venv/bin/python" ]; then
    echo "→ Creating virtualenv (Python 3.12)..."
    uv venv --python 3.12 "$INSTALL_DIR/venv"
fi

echo "→ Installing vLLM $VLLM_VERSION (bundles CUDA PyTorch)..."
VIRTUAL_ENV="$INSTALL_DIR/venv" uv pip install "vllm==$VLLM_VERSION"

# Gemma 4 tool-calling template ships in the vLLM repo, not the wheel
echo "→ Fetching chat templates..."
curl -fsSL -o "$INSTALL_DIR/templates/tool_chat_template_gemma4.jinja" \
    "https://raw.githubusercontent.com/vllm-project/vllm/v$VLLM_VERSION/examples/tool_chat_template_gemma4.jinja"

# ── profiles ──────────────────────────────────────────────────────────────────
echo "→ Installing profiles from vllm/$(hostname)/ ..."
sudo mkdir -p "$CONFIG_DIR"
sudo cp "$PROFILES_SRC"/*.conf "$CONFIG_DIR/"

# ── mode-switch script ────────────────────────────────────────────────────────
echo "→ Installing inference-mode..."
sudo cp "$REPO/inference-mode" /usr/local/bin/inference-mode
sudo chmod +x /usr/local/bin/inference-mode

# ── systemd ───────────────────────────────────────────────────────────────────
echo "→ Installing systemd unit..."
sudo cp "$REPO/vllm@.service" /etc/systemd/system/vllm@.service
sudo systemctl daemon-reload

echo ""
echo "Done. Profiles:"
for f in "$PROFILES_SRC"/*.conf; do echo "  $(basename "$f" .conf)"; done
echo ""
echo "Make one the default (stops Ollama, starts it now and at boot):"
echo "  inference-mode vllm <profile>"
echo ""
echo "First start downloads the weights — follow with:"
echo "  journalctl -u 'vllm@*' -f"
