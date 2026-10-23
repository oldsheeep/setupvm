#!/bin/bash
set -eo pipefail

echo "=== v4 ==="
echo "=== 1. Update OS and install OpenSSH & dependencies ==="
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  openssh-server curl wget git screen make build-essential ca-certificates gnupg \
  libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev \
  libffi-dev liblzma-dev

sudo systemctl enable --now ssh || true

echo "=== 2. Disable SSH Password Authentication ==="
# Ensure sshd_config and config directory exist
sudo mkdir -p /etc/ssh/sshd_config.d
if [ -f /etc/ssh/sshd_config ]; then
  sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config || true
  sudo sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config || true
fi

# Force password authentication off via drop-in config
cat << 'SSHOVERRIDE' | sudo tee /etc/ssh/sshd_config.d/50-no-password.conf > /dev/null
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
SSHOVERRIDE

sudo systemctl restart ssh || sudo systemctl restart sshd || true

echo "=== 3. Install Cloudflare Tunnel (cloudflared) ==="
sudo mkdir -p --mode=0755 /etc/apt/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /etc/apt/keyrings/cloudflare-main.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared noble main" | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
sudo apt update && sudo apt install -y cloudflared

echo "=== 4. Install Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sudo sh

echo "=== 5. Install Docker & Docker Compose ==="
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER" || true

echo "=== 6. Install GitHub CLI (gh) ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install -y gh

echo "=== 7. Install Taskfile (Task) ==="
sudo sh -c "$(curl --location https://taskfile.dev/install.sh)" -- -d -b /usr/local/bin

echo "=== 8. Install Golang ==="
GO_VER=$(curl -s https://go.dev/VERSION?m=text | head -n1)
wget -q "https://go.dev/dl/${GO_VER}.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf "${GO_VER}.linux-amd64.tar.gz"
rm -f "${GO_VER}.linux-amd64.tar.gz"

echo "=== 9. Install uv ==="
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

echo "=== 10. Install nvm, Node.js (22, 24, 26), and Claude CLI ==="
export NVM_DIR="$HOME/.nvm"
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

if [ -s "$NVM_DIR/nvm.sh" ]; then
  source "$NVM_DIR/nvm.sh"
fi

nvm install 22
nvm install 24
nvm install 26
nvm default 24

npm install -g @anthropic-ai/claude-code

echo "=== 11. Install pyenv and Python 3.14 ==="
export PYENV_ROOT="$HOME/.pyenv"
if [ ! -d "$PYENV_ROOT" ]; then
  git clone https://github.com/pyenv/pyenv.git "$PYENV_ROOT"
fi
export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
pyenv install -s 3.14
pyenv global 3.14

echo "=== 12. Update ~/.bashrc ==="
cat << 'PROFILE' >> ~/.bashrc

# nvm
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"

# pyenv
export PYENV_ROOT="$HOME/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"

# Go & Local Bin PATH
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin:$HOME/.local/bin
PROFILE

echo "=== 13. Cleanup cache ==="
sudo apt clean
sudo rm -rf /var/lib/apt/lists/*

echo "=== Setup Completed Successfully ==="
