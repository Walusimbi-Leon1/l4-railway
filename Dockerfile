# ================================================
#  L4 Claw Pack — Railway Dockerfile
#  Debian Bookworm + Node.js + ttyd + All Services
#  Deploy from: https://github.com/Walusimbi-Leon1/Codespace-3
# ================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV NVM_DIR=/root/.nvm
ENV NODE_VERSION=22
ENV PORT=8080
ENV USERNAME=admin
ENV PASSWORD=changeme

# ── System packages ──
RUN apt-get update &&     apt-get install -y --no-install-recommends         ca-certificates wget curl git         tini neofetch         python3 python3-pip         lsof     && apt-get clean && rm -rf /var/lib/apt/lists/*

# ── ttyd (web terminal) ──
RUN set -eux;     arch="$(uname -m)";     case "$arch" in       x86_64|amd64) ttyd_asset="ttyd.x86_64" ;;       aarch64|arm64) ttyd_asset="ttyd.aarch64" ;;       *) echo "Unsupported arch: $arch" >&2; exit 1 ;;     esac;     wget -qO /usr/local/bin/ttyd "https://github.com/tsl0922/ttyd/releases/download/1.7.7/${ttyd_asset}" &&     chmod +x /usr/local/bin/ttyd

# ── nvm + Node.js (symlink for root-level access in subsequent RUNs) ──
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash &&     . "$NVM_DIR/nvm.sh" &&     nvm install "$NODE_VERSION" &&     nvm alias default "$NODE_VERSION" &&     NV_PATH="$(. $NVM_DIR/nvm.sh && command -v node)" &&     NV_DIR="$(dirname "$NV_PATH")" &&     ln -sf "$NV_PATH" /usr/local/bin/node &&     ln -sf "$NV_DIR/npm" /usr/local/bin/npm &&     ln -sf "$NV_DIR/npx" /usr/local/bin/npx &&     node --version && npm --version

# ── Global npm packages ──
RUN npm install -g 9router@0.5.8 openclaw@latest

# ── Bashrc tweaks ──
RUN echo "neofetch || true" >> /root/.bashrc &&     echo "export NVM_DIR=\"\$HOME/.nvm\"" >> /root/.bashrc &&     echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' >> /root/.bashrc

# ── Entrypoint ──
COPY railway-entrypoint.sh /railway-entrypoint.sh
RUN chmod +x /railway-entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/railway-entrypoint.sh"]
