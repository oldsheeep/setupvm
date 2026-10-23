#!/bin/bash
set -eo pipefail

echo "=== v5 ==="

# Determine target user
TARGET_USER="${1:-${SUDO_USER:-$USER}}"
if [ "$TARGET_USER" = "root" ]; then
  # Fallback to the first non-root user with UID >= 1000 if not specified
  TARGET_USER=$(id -nu 1000 2>/dev/null || echo "ubuntu")
fi

TARGET_HOME=$(eval echo "~$TARGET_USER")

echo "=== Target User: $TARGET_USER (Home: $TARGET_HOME) ==="

echo "=== 1. Update OS and install OpenSSH & dependencies ==="
apt update && apt upgrade -y
apt install -y \
  openssh-server curl wget git screen make build-essential ca-certificates gnupg \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev

systemctl enable --now ssh || true

echo "=== 2. Disable SSH Password Authentication ==="
mkdir -p /etc/ssh/sshd_config.d
if [ -f /etc/ssh/sshd_config ]; then
  sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config || true
fi

cat << 'SSHOVERRIDE' | tee /etc/ssh/sshd_config.d/50-no-password.conf > /dev/null
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSHOVERRIDE

systemctl restart ssh || systemctl restart sshd || true

echo "=== 3. Install Cloudflare Tunnel (cloudflared) ==="
mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /etc/apt/keyrings/cloudflare-main.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" | tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
apt update && apt install -y cloudflared

echo "=== 4. Install Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

echo "=== 5. Install Docker & Docker Compose ==="
curl -fsSL https://get.docker.com | sh
usermod -aG docker "$TARGET_USER" || true

echo "=== 6. Install GitHub CLI (gh) ==="
mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt update && apt install -y gh

echo "=== 7. Install Taskfile (Task) ==="
sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin

echo "=== 8. Install Golang ==="
GO_VER=$(curl -s https://go.dev/VERSION?m=text | head -n1)
wget -q "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz"
rm -rf /usr/local/go && tar -C /usr/local -xzf "${GO_VER}.linux-amd64.tar.gz"
rm -f "${GO_VER}.linux-amd64.tar.gz"

echo "=== 9. Install uv ==="
# Global installation for system-wide access
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

echo "=== 10. Install nvm, Node.js (22, 24, 26), and Claude CLI for $TARGET_USER ==="
sudo -u "$TARGET_USER" bash -c "
  export NVM_DIR=\"\$HOME/.nvm\"
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
  [ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
  nvm install 22
  nvm install 24
  nvm install 26
  nvm default 24
  npm install -g @anthropic-ai/claude-code
"

echo "=== 11. Install pyenv and Python 3.14 for $TARGET_USER ==="
sudo -u "$TARGET_USER" bash -c "
  export PYENV_ROOT=\"\$HOME/.pyenv\"
  if [ ! -d \"\$PYENV_ROOT\" ]; then
    git clone https://github.com/pyenv/pyenv.git \"\$PYENV_ROOT\"
  fi
  export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
  eval \"\$(pyenv init -)\"
  pyenv install -s 3.14
  pyenv global 3.14
"

echo "=== 12. Update ~/.bashrc for $TARGET_USER ==="
sudo -u "$TARGET_USER" bash -c "
cat << 'PROFILE' >> \"\$HOME/.bashrc\"

# nvm
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && \. \"\$NVM_DIR/nvm.sh\"
[ -s \"\$NVM_DIR/bash_completion\" ] && \. \"\$NVM_DIR/bash_completion\"

# pyenv
export PYENV_ROOT=\"\$HOME/.pyenv\"
[[ -d \$PYENV_ROOT/bin ]] && export PATH=\"\$PYENV_ROOT/bin:\$PATH\"
eval \"\$(pyenv init -)\"

# Go & Local Bin PATH
export PATH=\$PATH:/usr/local/go/bin:\$HOME/go/bin:\$HOME/.local/bin
PROFILE
"

echo "=== 13. Cleanup cache ==="
apt clean
rm -rf /var/lib/apt/lists/*

echo "=== Setup Completed Successfully for $TARGET_USER ==="
