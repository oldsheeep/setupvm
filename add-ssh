#!/usr/bin/env bash
# sheep への SSH 接続環境（Cloudflare Access + 短命証明書）をセットアップする
#
#   curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/setup.sh | bash
#
# 対応: macOS / Linux（Windows は setup.ps1 を使う）
# やること:
#   1. cloudflared をインストール（無ければ）
#   2. ~/.ssh/config に sheep 用の設定を書き込む（再実行しても重複しない）
#   3. ブラウザで GitHub ログインして短命証明書を発行
#   4. ssh sheep で接続テスト
#
# 環境変数で上書き可能: SHEEP_HOSTNAME / SHEEP_ALIAS / SHEEP_USER / INSTALL_DIR
set -euo pipefail

SHEEP_HOSTNAME="${SHEEP_HOSTNAME:-sheep-ssh.sheeplab.net}"
SHEEP_ALIAS="${SHEEP_ALIAS:-sheep}"
SHEEP_USER="${SHEEP_USER:-sshu}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
CERT_FILE="$HOME/.cloudflared/${SHEEP_HOSTNAME}-cf_key-cert.pub"
BEGIN_MARK="# >>> ${SHEEP_ALIAS} (managed by sheep setup) >>>"
END_MARK="# <<< ${SHEEP_ALIAS} (managed by sheep setup) <<<"
RELEASE_URL="https://github.com/cloudflare/cloudflared/releases/latest/download"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin) OS=darwin ;;
    Linux)  OS=linux ;;
    MINGW* | MSYS* | CYGWIN*) die "Windows では PowerShell で setup.ps1 を実行してください" ;;
    *) die "未対応の OS です: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    arm64 | aarch64) ARCH=arm64 ;;
    *) die "未対応の CPU です: $(uname -m)" ;;
  esac
}

require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "$c が見つかりません。先にインストールしてください"
  done
}

install_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    CLOUDFLARED="$(command -v cloudflared)"
    info "cloudflared はインストール済みです: $CLOUDFLARED"
    return
  fi

  if [ "$OS" = darwin ] && command -v brew >/dev/null 2>&1; then
    info "Homebrew で cloudflared をインストールします"
    brew install cloudflared </dev/null
    CLOUDFLARED="$(brew --prefix)/bin/cloudflared"
    return
  fi

  info "cloudflared を $INSTALL_DIR にダウンロードします"
  local tmp
  tmp="$(mktemp -d)"
  if [ "$OS" = darwin ]; then
    curl -fsSL "$RELEASE_URL/cloudflared-darwin-$ARCH.tgz" -o "$tmp/cloudflared.tgz"
    tar -xzf "$tmp/cloudflared.tgz" -C "$tmp"
  else
    curl -fsSL "$RELEASE_URL/cloudflared-linux-$ARCH" -o "$tmp/cloudflared"
  fi
  mkdir -p "$INSTALL_DIR"
  install -m 755 "$tmp/cloudflared" "$INSTALL_DIR/cloudflared"
  rm -rf "$tmp"
  CLOUDFLARED="$INSTALL_DIR/cloudflared"

  case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) warn "$INSTALL_DIR が PATH に入っていません（ssh の設定はフルパスで書くので接続には影響しません）" ;;
  esac
}

check_cloudflared_path() {
  case "$CLOUDFLARED" in
    *[[:space:]]*) die "cloudflared のパスに空白が含まれていて ssh の設定に使えません: $CLOUDFLARED（INSTALL_DIR=<空白のない場所> を付けて再実行してください）" ;;
  esac
  "$CLOUDFLARED" --version >/dev/null || die "cloudflared を実行できません: $CLOUDFLARED"
}

render_block() {
  cat <<EOF
$BEGIN_MARK
Host $SHEEP_ALIAS
  HostName $SHEEP_HOSTNAME
  User $SHEEP_USER

Match host $SHEEP_HOSTNAME exec "$CLOUDFLARED access ssh-gen --hostname %h"
  ProxyCommand $CLOUDFLARED access ssh --hostname %h
  IdentityFile ~/.cloudflared/$SHEEP_HOSTNAME-cf_key
  CertificateFile ~/.cloudflared/$SHEEP_HOSTNAME-cf_key-cert.pub
  IdentitiesOnly yes
  ServerAliveInterval 30

# reset scope so the rest of this file applies to all hosts
Host *
$END_MARK

EOF
}

# 既存の管理ブロック（と直後の空行 1 つ）を取り除いた残りを出力する
strip_managed_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; eat = 1; next }
    eat && $0 == "" { eat = 0; next }
    { eat = 0 }
    !skip
  ' "$SSH_CONFIG"
}

update_ssh_config() {
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$SSH_CONFIG"

  if [ -s "$SSH_CONFIG" ]; then
    local backup
    backup="$SSH_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$SSH_CONFIG" "$backup"
    info "既存の ssh config をバックアップしました: $backup"
  fi

  local rest tmp
  rest="$(strip_managed_block)"

  # ブロックはファイル先頭に置く（ssh_config は先に書いた値が優先されるため）
  tmp="$(mktemp "$SSH_DIR/config.XXXXXX")"
  {
    render_block
    if [ -n "$rest" ]; then printf '%s\n' "$rest"; fi
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$SSH_CONFIG"
  info "~/.ssh/config に '$SHEEP_ALIAS' の設定を書き込みました"

  if printf '%s\n' "$rest" | grep -Eiq "^[[:space:]]*host([[:space:]]+[^[:space:]]+)*[[:space:]]+${SHEEP_ALIAS}([[:space:]]|\$)" \
    || printf '%s\n' "$rest" | grep -Fq "$SHEEP_HOSTNAME"; then
    warn "~/.ssh/config に以前の '$SHEEP_ALIAS' / $SHEEP_HOSTNAME の設定が残っています。今回の設定が優先されますが、不要なら削除してください"
  fi
}

issue_cert() {
  info "ブラウザが開くので GitHub でログインしてください（開かない場合は表示される URL を開く）"
  rm -f "$CERT_FILE"
  "$CLOUDFLARED" access ssh-gen --hostname "$SHEEP_HOSTNAME" || true
  if [ ! -f "$CERT_FILE" ]; then
    warn "短命証明書を発行できませんでした。次を確認してください:"
    warn "  - GitHub の team への招待を Accept しているか"
    warn "  - GitHub の Authorize 画面で組織へのアクセスを Grant / Request したか"
    die "証明書の発行に失敗しました"
  fi
  info "短命証明書を発行しました"
}

test_connection() {
  info "接続テスト: ssh $SHEEP_ALIAS"
  # shellcheck disable=SC2016  # $(...) はリモート側で展開する
  if ssh -n -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 \
    "$SHEEP_ALIAS" 'echo "OK: $(whoami)@$(hostname)"'; then
    info "完了！ これからは 'ssh $SHEEP_ALIAS' で接続できます"
  else
    die "接続テストに失敗しました。'ssh -v $SHEEP_ALIAS' の出力を管理者に送ってください"
  fi
}

main() {
  detect_platform
  require_cmds curl ssh tar awk
  install_cloudflared
  check_cloudflared_path
  update_ssh_config
  issue_cert
  test_connection
}

# source されたときは実行しない（curl | bash では実行される）
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
