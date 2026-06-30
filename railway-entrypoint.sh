#!/usr/bin/env bash
set -euo pipefail

# ================================================
#  L4 Claw Pack — Railway Bootstrap
#  Run this as the Start Command on Railway.
#  Clones repo, installs Node.js, starts services.
# ================================================

WORKDIR="/root/projects/Codespace-3"
export HOME="/root"
PORT="${PORT:-8080}"
USERNAME="${USERNAME:-admin}"
PASSWORD="${PASSWORD:-changeme}"

# Detect Railway Volume (mounts are often /railway or /data)
RAILWAY_VOLUME=""
for mp in /railway /data /volumes; do
  if mount | grep -q " $mp "; then
    RAILWAY_VOLUME="$mp"
    break
  fi
done

echo "=============================================="
echo "  🐾 L4 Claw Pack — Railway Boot"
echo "  $(date)"
echo "=============================================="

# ── 1. Update apt and install basic tools ──
DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
apt-get install -y -qq --no-install-recommends ca-certificates curl git lsof 2>/dev/null
echo "  ✅ System packages"

# ── 2. Ensure the ttyd binary exists ──
if ! command -v ttyd &>/dev/null; then
  echo "📦 Installing ttyd..."
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) asset="ttyd.x86_64" ;;
    aarch64|arm64) asset="ttyd.aarch64" ;;
    *) echo "Unsupported arch: $arch"; exit 1 ;;
  esac
  curl -sL -o /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/1.7.7/${asset}"
  chmod +x /usr/local/bin/ttyd
  echo "  ✅ ttyd installed"
fi

# ── 3. Install nvm + Node.js ──
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  echo "📦 Installing nvm..."
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
fi
. "$NVM_DIR/nvm.sh"
if ! command -v node &>/dev/null || [ "$(node -v | cut -d. -f1)" != "v22" ]; then
  echo "📦 Installing Node.js 22..."
  nvm install 22 >/dev/null 2>&1 || nvm install 22
  nvm alias default 22 >/dev/null 2>&1
fi
# Symlink node/npm to PATH for non-nvm shell sessions
ln -sf "$(which node)" /usr/local/bin/node 2>/dev/null || true
ln -sf "$(which npm)" /usr/local/bin/npm 2>/dev/null || true
echo "  ✅ Node $(node -v) / npm $(npm -v)"

# ── 4. Set up GitHub credentials ──
# GITHUB_TOKEN should be set via Railway env variable
if [ -n "${GITHUB_TOKEN:-}" ]; then
  git config --global credential.helper store 2>/dev/null || true
  echo "https://${GITHUB_TOKEN}@github.com" > ~/.git-credentials 2>/dev/null || true
  chmod 600 ~/.git-credentials 2>/dev/null || true
  echo "  ✅ GitHub token configured"
fi

# ── 5. Clone or pull the private repo ──
if [ ! -d "$WORKDIR" ]; then
  echo "📦 Cloning repository..."
  mkdir -p "$(dirname "$WORKDIR")"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    git clone "https://${GITHUB_TOKEN}@github.com/Walusimbi-Leon1/Codespace-3.git" "$WORKDIR"
  else
    echo "  ⚠️  No GITHUB_TOKEN available — trying public clone (will fail for private repo)"
    git clone "https://github.com/Walusimbi-Leon1/Codespace-3.git" "$WORKDIR" || true
  fi
fi

if [ -d "$WORKDIR" ]; then
  echo "📦 Pulling latest changes..."
  cd "$WORKDIR"
  git config pull.rebase false 2>/dev/null || true
  git pull origin main --ff-only 2>/dev/null || echo "  ⚠️  Git pull failed"
  chmod +x bin/* 2>/dev/null || true
  echo "  ✅ Repo at $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
fi

# ── 5b. Fix workspace path symlink ──
if [ -d "$WORKDIR" ] && [ "$(readlink -f /workspaces/Codespace-3 2>/dev/null || echo '')" != "$WORKDIR" ]; then
  rm -rf /workspaces/Codespace-3
  mkdir -p /workspaces
  ln -sfn "$WORKDIR" /workspaces/Codespace-3
  echo "  ✅ Workspace symlink: /workspaces/Codespace-3 → $WORKDIR"
fi

# ── 6. Install global npm packages ──
if [ -d "$WORKDIR" ]; then
  cd "$WORKDIR"
  for pkg in 9router@0.5.8 openclaw@latest; do
    if ! command -v "${pkg%@*}" &>/dev/null; then
      echo "📦 Installing ${pkg}..."
      npm install -g "$pkg" 2>/dev/null || true
    fi
  done
fi

# ── 7. Set up OpenClaw config and persistence ──
if [ -d "$WORKDIR" ]; then
  mkdir -p ~/.openclaw
  [ -f "$WORKDIR/openclaw-config.json" ] && cp "$WORKDIR/openclaw-config.json" ~/.openclaw/openclaw.json

  # ── 7a. Persist OpenClaw state ──
  if [ -n "$RAILWAY_VOLUME" ]; then
    STATE_DIR="$RAILWAY_VOLUME/l4-openclaw-state"
    echo "  📦 Railway Volume detected — persisting OpenClaw state at $STATE_DIR"
  else
    STATE_DIR="$WORKDIR/.openclaw-state"
    echo "  📁 Storing OpenClaw state in workspace (no volume)"
  fi
  mkdir -p "$STATE_DIR"
  
  STATE_TARGET="$HOME/.openclaw/state"
  mkdir -p "$(dirname "$STATE_TARGET")"
  if [ -e "$STATE_TARGET" ] && [ ! -L "$STATE_TARGET" ]; then
    cp -a "$STATE_TARGET/." "$STATE_DIR/" 2>/dev/null || true
    rm -rf "$STATE_TARGET"
  fi
  ln -sfn "$STATE_DIR" "$STATE_TARGET"
  echo "  🔗 State: $STATE_TARGET → $STATE_DIR"

  # ── 7b. Session symlink ──
  SESSIONS_SRC="$HOME/.openclaw/agents/main/sessions"
  SESSIONS_DST="$WORKDIR/sessions"
  mkdir -p "$SESSIONS_DST" "$(dirname "$SESSIONS_SRC")"
  if [ -e "$SESSIONS_SRC" ] && [ ! -L "$SESSIONS_SRC" ]; then
    cp -a "$SESSIONS_SRC/." "$SESSIONS_DST/" 2>/dev/null || true
    rm -rf "$SESSIONS_SRC"
  fi
  ln -sfn "$SESSIONS_DST" "$SESSIONS_SRC"
  echo "  🔗 Sessions: $SESSIONS_SRC → $SESSIONS_DST"
fi

# ── 8. Start Tailscale (persistent mesh VPN) ──
# Installs tailscale if missing, starts daemon, connects, and launches
# a background watchdog that keeps the connection alive forever.
echo "🔗 Tailscale: setting up..."
if ! command -v tailscale &>/dev/null; then
  echo "  Installing Tailscale..."
  # Install via official script
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# Proc check helper (no ps/pgrep dependency)
proc_running() {
  local name="$1"
  for pid_dir in /proc/[0-9]*/; do
    local cmdline_file="${pid_dir}cmdline"
    if [ -r "$cmdline_file" ] && grep -q "$name" "$cmdline_file" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

TAILSCALE_AUTH_KEY="tskey-auth-kPjwrx2hmB21CNTRL-WtQZT8U4t5gB9PC9XTEm5gRAQ4xaHqhrK"

# Kill stale tailscaled if any
if proc_running "tailscaled"; then
  for _pid_dir in /proc/[0-9]*/; do
    _cmdline="${_pid_dir}cmdline"
    if [ -r "$_cmdline" ] && grep -q "tailscaled" "$_cmdline" 2>/dev/null; then
      _pid=$(basename "$_pid_dir")
      kill "$_pid" 2>/dev/null || true
    fi
  done
  sleep 2
fi

# Start tailscaled
echo "  Starting tailscaled (userspace networking)..."
tailscaled --tun=userspace-networking \
  --state=/var/lib/tailscale/tailscaled.state &>/tmp/tailscaled.log &
sleep 4

# Authenticate
echo "  Authenticating with auth key..."
tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --ssh --accept-routes
TS_IP=$(tailscale status --peers=false 2>/dev/null | head -1 | awk '{print $1}' || echo "?")
echo "  ✅ Tailscale connected ($TS_IP)"

# ── 8b. Launch tailscale watchdog (persistent keep-alive) ──
# First try the repo's script, then fall back to inline
WATCHDOG_SCRIPT="$WORKDIR/bin/tailscale-watchdog"
if [ -x "$WATCHDOG_SCRIPT" ]; then
  if [ -f /tmp/tailscale-watchdog.pid ] && [ -d "/proc/$(cat /tmp/tailscale-watchdog.pid 2>/dev/null)" ] && \
     grep -q tailscale "/proc/$(cat /tmp/tailscale-watchdog.pid 2>/dev/null)/cmdline" 2>/dev/null; then
    echo "  ✅ Tailscale watchdog already running"
  else
    echo "  🐾 Launching tailscale watchdog..."
    nohup bash "$WATCHDOG_SCRIPT" &>/dev/null &
    echo "  ✅ Watchdog launched (PID $!)"
  fi
else
  # Inline fallback watchdog — keeps tailscaled alive and reconnects
  echo "  🐾 Launching inline tailscale watchdog..."
  nohup bash -c '
    while true; do
      sleep 15
      # Check if tailscaled is alive
      alive=false
      for p in /proc/[0-9]*/cmdline; do
        if [ -r "$p" ] && grep -q tailscaled "$p" 2>/dev/null; then
          alive=true
          break
        fi
      done
      if [ "$alive" = false ]; then
        echo "[$(date)] Watchdog: tailscaled died, restarting..." >> /tmp/tailscale-watchdog.log
        tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state &>/tmp/tailscaled.log &
        sleep 4
        tailscale up --auth-key="'"$TAILSCALE_AUTH_KEY"'" --ssh --accept-routes &>/tmp/tailscale-up.log
        echo "[$(date)] Watchdog: reconnected" >> /tmp/tailscale-watchdog.log
      fi
      # Periodic health re-check every ~75s
      if [ $((SECONDS % 75)) -lt 15 ] && [ "$alive" = true ]; then
        ip=$(tailscale status --peers=false 2>/dev/null | head -1 | awk "{print \$1}" || echo "")
        if [ -z "$ip" ]; then
          echo "[$(date)] Watchdog: stale connection, re-upping..." >> /tmp/tailscale-watchdog.log
          tailscale up --auth-key="'"$TAILSCALE_AUTH_KEY"'" --ssh --accept-routes &>/tmp/tailscale-up.log
        fi
      fi
    done
  ' &>/dev/null &
  echo "  ✅ Inline watchdog launched (PID $!)"
fi

# ── 9. Start 9-router ──
if ! pgrep -f "node.*9router" >/dev/null 2>&1; then
  echo "🌐 Starting 9-router..."
  nohup 9router --port 20128 --host 127.0.0.1 --tray --skip-update &>/tmp/9router.log &
  sleep 4
  pgrep -f "node.*9router" >/dev/null 2>&1 && echo "  ✅ 9-router on port 20128" || echo "  ⚠️  9-router failed"
fi

# ── 10. Start OpenClaw Gateway ──
if ! curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1; then
  echo "🤖 Starting OpenClaw..."
  openclaw gateway run --port 18789 --bind loopback &>/tmp/openclaw-gateway.log &
  sleep 3
  curl -sf http://127.0.0.1:18789/health >/dev/null 2>&1 && echo "  ✅ OpenClaw on port 18789" || echo "  ⚠️  OpenClaw starting..."
fi

# ── 11. Start Git Dashboard ──
if ! lsof -ti :3030 >/dev/null 2>&1; then
  echo "📝 Starting Git Dashboard..."
  if [ -d "$WORKDIR/git-dashboard" ]; then
    GITHUB_TOKEN="${GITHUB_TOKEN:-}" nohup node "$WORKDIR/git-dashboard/server.js" &>/tmp/git-dashboard.log &
    echo "  ✅ Git Dashboard on port 3030"
  fi
fi

# ── 12. Update bashrc ──
echo "cd $WORKDIR" >> ~/.bashrc 2>/dev/null || true
echo "neofetch || true" >> ~/.bashrc 2>/dev/null || true

# ── 13. Summary ──
TS_IP=$(tailscale status --peers=false 2>/dev/null | head -1 | awk '{print $1}' || echo "?")
echo ""
echo "=============================================="
echo "  ✅ All services started"
echo "  🌐 9-router:     http://127.0.0.1:20128"
echo "  🤖 OpenClaw:     http://127.0.0.1:18789"
echo "  📝 Git Dashboard: http://127.0.0.1:3030"
echo "  🔗 Tailscale:    $TS_IP"
echo "  🖥️  Terminal:     http://... (Railway domain)"
echo "=============================================="
echo ""

# ── 14. Keep alive with ttyd ──
echo "🖥️  Starting ttyd web terminal..."
exec /usr/local/bin/ttyd --writable -i 0.0.0.0 -p "$PORT" -c "${USERNAME}:${PASSWORD}" /bin/bash
