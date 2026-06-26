#!/usr/bin/env bash
set -euo pipefail

# ================================================
#  L4 Claw Pack — Railway Entrypoint
#  Runs on every Railway container start.
#  Starts ttyd (terminal) + all L4 services.
# ================================================

WORKDIR="/root/projects/Codespace-3"
export HOME="/root"

echo "=============================================="
echo "  🐾 L4 Claw Pack — Railway Boot"
echo "  $(date)"
echo "=============================================="

# ── 1. Ensure nvm + Node.js ──
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "📦 Installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

if ! command -v node &>/dev/null || [ "$(node -v)" != "v22"* ]; then
  echo "📦 Installing Node.js 22..."
  nvm install 22
  nvm alias default 22
fi
echo "  ✅ Node $(node -v) / npm $(npm -v)"

# ── 2. Ensure global npm packages ──
if ! command -v openclaw &>/dev/null; then
  echo "📦 Installing OpenClaw..."
  npm install -g openclaw@latest
fi
if ! command -v 9router &>/dev/null || [ "$(9router --version 2>/dev/null)" != "0.5.8" ]; then
  echo "📦 Installing 9-router 0.5.8..."
  npm install -g 9router@0.5.8
fi
echo "  ✅ openclaw $(openclaw --version | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo 'ok')"
echo "  ✅ 9router $(9router --version 2>/dev/null)"

# ── 3. Ensure repo is cloned ──
# Get GitHub token: Railway env var has priority
# (TOOLS.md won't exist yet on first clone)
REPO_TOKEN="${GITHUB_TOKEN:-}"

if [ ! -d "$WORKDIR" ]; then
  echo "📦 Cloning repository..."
  mkdir -p "$(dirname "$WORKDIR")"
  
  if [ -n "$REPO_TOKEN" ]; then
    echo "  Using token from GITHUB_TOKEN env var"
    git clone "https://${REPO_TOKEN}@github.com/Walusimbi-Leon1/Codespace-3.git" "$WORKDIR"
  else
    echo "  No token available — trying public clone"
    git clone "https://github.com/Walusimbi-Leon1/Codespace-3.git" "$WORKDIR" 2>&1 || {
      echo "  ❌ Repo is private and no GITHUB_TOKEN set."
      echo "  Set GITHUB_TOKEN as a Railway environment variable to clone private repos."
      echo "  Proceeding without repo — services may not work."
    }
  fi
fi

# ── 4. Pull latest changes ──
echo "📦 Pulling latest repo changes..."
cd "$WORKDIR"
git config pull.rebase false
git pull origin main --ff-only 2>/dev/null || echo "  ⚠️  Git pull failed (first time or conflict)"
chmod +x *.sh bin/* 2>/dev/null || true
echo "  ✅ Repo at $(git rev-parse --short HEAD)"

# ── 5. Set up GitHub credentials ──
# Priority: Railway env var > TOOLS.md > nothing
if [ -z "$REPO_TOKEN" ] && [ -f "$WORKDIR/TOOLS.md" ]; then
  REPO_TOKEN=$(grep -oP 'ghp_\w+' "$WORKDIR/TOOLS.md" 2>/dev/null | head -1 || true)
fi
if [ -n "$REPO_TOKEN" ]; then
  export GITHUB_TOKEN="$REPO_TOKEN"
  git config --global credential.helper store 2>/dev/null || true
  echo "https://${REPO_TOKEN}@github.com" > ~/.git-credentials 2>/dev/null || true
  chmod 600 ~/.git-credentials 2>/dev/null || true
  echo "  ✅ GitHub token configured"
fi

# ── 6. Set up OpenClaw config ──
mkdir -p ~/.openclaw
if [ -f "$WORKDIR/openclaw-config.json" ]; then
  cp "$WORKDIR/openclaw-config.json" ~/.openclaw/openclaw.json
fi

# Session symlink
SESSIONS_SRC="$HOME/.openclaw/agents/main/sessions"
SESSIONS_DST="$WORKDIR/sessions"
mkdir -p "$SESSIONS_DST"
mkdir -p "$(dirname "$SESSIONS_SRC")"
if [ -e "$SESSIONS_SRC" ] && [ ! -L "$SESSIONS_SRC" ]; then
  cp -a "$SESSIONS_SRC/." "$SESSIONS_DST/" 2>/dev/null || true
  rm -rf "$SESSIONS_SRC"
fi
ln -sfn "$SESSIONS_DST" "$SESSIONS_SRC"

# ── 7. Start 9-router ──
echo ""
echo "🌐 Starting 9-router..."
if pgrep -f "node.*9router" >/dev/null 2>&1; then
  echo "  ✅ Already running"
else
  nohup 9router --port 20128 --host 127.0.0.1 --tray --skip-update &>/tmp/9router.log &
  sleep 4
  if pgrep -f "node.*9router" >/dev/null 2>&1; then
    echo "  ✅ 9-router on port 20128"
  else
    echo "  ⚠️  9-router failed — check /tmp/9router.log"
  fi
fi

# ── 8. Start OpenClaw Gateway ──
echo ""
echo "🤖 Starting OpenClaw Gateway..."
if curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
  echo "  ✅ Already running"
else
  openclaw gateway run --port 18789 --bind loopback &>/tmp/openclaw-gateway.log &
  sleep 3
  if curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
    echo "  ✅ OpenClaw on port 18789"
  else
    echo "  ⚠️  OpenClaw may still be starting…"
  fi
fi

# ── 9. Start Git Dashboard ──
echo ""
echo "📝 Starting Git Dashboard..."
if lsof -ti :3030 >/dev/null 2>&1; then
  echo "  ✅ Already running"
else
  export GIT_DASHBOARD_WORKSPACE="$WORKDIR"
  nohup env GITHUB_TOKEN="$GITHUB_TOKEN" node "$WORKDIR/git-dashboard/server.js" \
    > "$WORKDIR/git-dashboard/server.log" 2>&1 &
  echo "  ✅ Git Dashboard on port 3030"
fi

# ── 10. Final status ──
echo ""
echo "=============================================="
echo "  ✅ All services started"
echo "  🌐 9-router:     http://127.0.0.1:20128"
echo "  🤖 OpenClaw:     http://127.0.0.1:18789"
echo "  📝 Git Dashboard: http://127.0.0.1:3030"
echo "  🖥️  Terminal:     \$PORT (handled by Railway)"
echo "=============================================="

# ── 11. Start ttyd terminal (foreground — keeps container alive) ──
echo ""
echo "🖥️  Starting ttyd web terminal..."
echo "    Username: \${USERNAME:-admin}"
echo "    Password: \${PASSWORD:-changeme}"
echo ""

# Source bashrc for nice prompt on login
echo "cd $WORKDIR" >> /root/.bashrc
echo "neofetch || true" >> /root/.bashrc

exec /usr/local/bin/ttyd --writable -i 0.0.0.0 -p "${PORT:-8080}" \
  -c "${USERNAME:-admin}:${PASSWORD:-changeme}" /bin/bash
