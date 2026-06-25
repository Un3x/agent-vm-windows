#!/usr/bin/env bash
#
# setup-wsl2.sh: provisioning script that runs INSIDE the WSL2 distro during
# "agent-vm setup". Ported from agent-vm's macOS/Linux agent-vm.setup.sh
# (https://github.com/sylvinus/agent-vm) with WSL-specific adaptations:
#
#   - enables systemd (so docker/redis/postgres run as services)
#   - creates a non-root 'agent' user with passwordless sudo and makes it the
#     default WSL user (Lima ships a sudo-capable user out of the box)
#
# It is piped in as root: `wsl -d agent-vm -u root -- bash -l < setup-wsl2.sh`.
#
# NOT yet validated on a real Windows host. See README.md.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

AGENT_USER="agent"

echo "==> Configuring WSL (systemd + default user)..."
# Enable systemd and set the default login user. Takes effect after the
# `wsl --terminate` that agent-vm.ps1 runs at the end of provisioning.
cat > /etc/wsl.conf <<EOF
[boot]
systemd=true

[user]
default=${AGENT_USER}
EOF

# Create the agent user with passwordless sudo if it does not exist yet.
if ! id "$AGENT_USER" &>/dev/null; then
  useradd -m -s /usr/bin/zsh "$AGENT_USER" || useradd -m "$AGENT_USER"
fi
echo "${AGENT_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent-vm
chmod 0440 /etc/sudoers.d/agent-vm

echo "==> Installing base packages..."
apt-get update
apt-get install -y \
  git curl jq zsh \
  wget build-essential \
  python3 python3-pip python3-venv \
  ripgrep fd-find htop \
  unzip zip \
  ca-certificates \
  iptables \
  libssl-dev libreadline-dev zlib1g-dev libyaml-dev libffi-dev

echo "==> Installing Docker (runs as a systemd service after restart)..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
usermod -aG docker "$AGENT_USER"
systemctl enable docker 2>/dev/null || true

echo "==> Installing Node.js 24..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

echo "==> Installing Chromium (headless browsing)..."
apt-get install -y chromium-browser fonts-liberation xvfb 2>/dev/null \
  || apt-get install -y chromium fonts-liberation xvfb
CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || echo /usr/bin/chromium)"
ln -sf "$CHROMIUM_BIN" /usr/bin/google-chrome || true
ln -sf "$CHROMIUM_BIN" /usr/bin/google-chrome-stable || true

echo "==> Installing GitHub CLI..."
mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg > /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
apt-get update
apt-get install -y gh

# Everything below installs into the agent user's home.
echo "==> Installing user toolchain (mise, Claude, OpenCode, Codex)..."
sudo -u "$AGENT_USER" -H bash -l <<'USERSETUP'
set -euo pipefail

# mise (polyglot version manager: Ruby, Python, Node, ...)
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

# Claude Code
curl -fsSL https://claude.ai/install.sh | bash
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$PATH' >> ~/.zshrc
echo 'export PS1="vm:%1~%% "' >> ~/.zshrc

# OpenCode
curl -fsSL https://opencode.ai/install | bash
echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshrc

# Make tools visible to non-interactive shells too (zsh -lc "...").
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$HOME/.opencode/bin:$PATH' >> ~/.zshenv

# Chrome DevTools MCP server for Claude
CONFIG="$HOME/.claude.json"
if [ -f "$CONFIG" ]; then
  jq '.mcpServers["chrome-devtools"] = {"command":"npx","args":["-y","chrome-devtools-mcp@latest","--headless=true","--isolated=true"]}' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
else
  cat > "$CONFIG" <<'JSON'
{"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest","--headless=true","--isolated=true"]}}}
JSON
fi

# Chrome DevTools MCP server for OpenCode
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
mkdir -p "$OPENCODE_CONFIG_DIR"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
if [ -f "$OPENCODE_CONFIG" ]; then
  jq '.mcp["chrome-devtools"] = {"type":"local","command":["npx","-y","chrome-devtools-mcp@latest","--headless=true","--isolated=true"],"enabled":true}' "$OPENCODE_CONFIG" > "$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
else
  cat > "$OPENCODE_CONFIG" <<'JSON'
{"$schema":"https://opencode.ai/config.json","mcp":{"chrome-devtools":{"type":"local","command":["npx","-y","chrome-devtools-mcp@latest","--headless=true","--isolated=true"],"enabled":true}}}
JSON
fi
USERSETUP

# Codex CLI (global npm install, needs root)
echo "==> Installing Codex CLI..."
npm i -g @openai/codex

echo "==> Distro provisioning complete."
