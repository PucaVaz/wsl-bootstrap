#!/usr/bin/env bash
# WSL2 Ubuntu bootstrap for an always-on agent box (Telepatia monobloco).
# Run inside WSL as your normal user:  bash wsl-bootstrap.sh
# Idempotent: safe to re-run. Interactive logins are listed at the end, not done here.
set -euo pipefail

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- wsl.conf
log "Enabling systemd (needed for docker + sshd services)"
if ! grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null; then
  printf '[boot]\nsystemd=true\n' | sudo tee /etc/wsl.conf >/dev/null
  NEEDS_WSL_RESTART=1
fi

# ---------------------------------------------------------------- apt base
log "Base packages"
sudo apt-get update -y
sudo apt-get install -y \
  build-essential curl wget ca-certificates gnupg unzip zip jq ripgrep \
  git git-lfs make tmux mosh openssh-server python3 python3-venv pkg-config

git lfs install --skip-repo

# ---------------------------------------------------------------- gh cli
if ! command -v gh >/dev/null; then
  log "GitHub CLI"
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -y && sudo apt-get install -y gh
fi

# ---------------------------------------------------------------- docker
if ! command -v docker >/dev/null; then
  log "Docker engine (databases only, per repo rules)"
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER"
fi
sudo systemctl enable docker 2>/dev/null || true

# ---------------------------------------------------------------- uv (python)
if ! command -v uv >/dev/null; then
  log "uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# ---------------------------------------------------------------- node + pnpm
if ! command -v fnm >/dev/null; then
  log "fnm + Node LTS + pnpm"
  curl -fsSL https://fnm.vercel.app/install | bash
  export PATH="$HOME/.local/share/fnm:$PATH"
  eval "$(fnm env)"
fi
fnm install --lts && fnm default lts-latest
corepack enable && corepack prepare pnpm@latest --activate

# ---------------------------------------------------------------- doppler
if ! command -v doppler >/dev/null; then
  log "Doppler CLI"
  curl -Ls https://cli.doppler.com/install.sh | sudo sh
fi

# ---------------------------------------------------------------- claude code
if ! command -v claude >/dev/null; then
  log "Claude Code"
  npm install -g @anthropic-ai/claude-code
fi

# ---------------------------------------------------------------- sshd
log "sshd: password auth enabled (box is Tailscale-only; harden to key-only later)"
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl enable ssh 2>/dev/null || true
sudo service ssh restart || sudo service ssh start
mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

# ---------------------------------------------------------------- boot.sh
log "boot.sh for the Windows Task Scheduler startup task"
cat > ~/boot.sh <<'EOF'
#!/usr/bin/env bash
# Called by Windows Task Scheduler at startup: wsl -d Ubuntu -- ~/boot.sh
sudo service ssh start
sudo service docker start
tmux has-session -t main 2>/dev/null || tmux new-session -d -s main
EOF
chmod +x ~/boot.sh
# allow the two service starts without a password prompt (required non-interactive)
echo "$USER ALL=(root) NOPASSWD: /usr/sbin/service ssh start, /usr/sbin/service docker start" \
  | sudo tee /etc/sudoers.d/boot-services >/dev/null
sudo chmod 440 /etc/sudoers.d/boot-services

# ---------------------------------------------------------------- done
log "DONE. Manual steps left (in order):"
cat <<'EOF'
 1. gh auth login              (GitHub; pick SSH, let it mint the key)
 2. git config --global user.name "Puca Vaz"; git config --global user.email <your email>
 3. doppler login
 4. claude                      (login on first run)
 5. (later, optional hardening) phone SSH key -> ~/.ssh/authorized_keys, then set
    PasswordAuthentication no in /etc/ssh/sshd_config and: sudo service ssh restart
 6. gh repo clone Telepatia-AI/monobloco ~/monobloco && cd ~/monobloco && make setup
 7. Windows side: Tailscale (sign in, "run unattended"), Cloudflare WARP (enroll telepatia org),
    .wslconfig with [wsl2] networkingMode=mirrored, then: wsl --shutdown
 8. Windows Task Scheduler: task "At startup", action:
       wsl -d Ubuntu -- /home/<user>/boot.sh
 9. Playwright (after clone): cd ~/monobloco/js && pnpm exec playwright install --with-deps chromium
EOF
[ "${NEEDS_WSL_RESTART:-0}" = "1" ] && echo "NOTE: systemd was just enabled — run 'wsl --shutdown' from Windows, reopen Ubuntu, re-run this script once."
