#!/usr/bin/env bash
# Hardening for a DataGate VPN host: admin user + password (sudo) + SSH key + TOTP 2FA.
# Uses templates from templates/ssh/ (copied from repo ssh_configs/).
#
# Order (do this BEFORE or after VPN install — but keep a second SSH session open):
#   1) Create user, set sudo password, install authorized_keys
#   2) Enrol google-authenticator for that user
#   3) Install sshd_config + PAM (pubkey + TOTP; password login disabled)
#
# Usage:
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey /path/to/id_ed25519.pub
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey-from-user ubuntu
#   sudo ./scripts/setup-host-ssh.sh --apply-sshd-only   # after .google_authenticator exists
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_TEMPLATES="$ROOT_DIR/templates/ssh"

ADMIN_USER=""
PUBKEY_FILE=""
PUBKEY_FROM_USER=""
APPLY_SSHD_ONLY=0
SKIP_PASSWORD=0
SKIP_TOTP=0
SKIP_SSHD=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) ADMIN_USER="$2"; shift 2 ;;
    --pubkey) PUBKEY_FILE="$2"; shift 2 ;;
    --pubkey-from-user) PUBKEY_FROM_USER="$2"; shift 2 ;;
    --apply-sshd-only) APPLY_SSHD_ONLY=1; shift ;;
    --skip-password) SKIP_PASSWORD=1; shift ;;
    --skip-totp) SKIP_TOTP=1; shift ;;
    --skip-sshd) SKIP_SSHD=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
[[ -f "$SSH_TEMPLATES/sshd_config" ]] || die "missing $SSH_TEMPLATES/sshd_config"
[[ -f "$SSH_TEMPLATES/sshd" ]] || die "missing $SSH_TEMPLATES/sshd (PAM)"

install_packages() {
  info "Installing openssh-server + libpam-google-authenticator"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq openssh-server libpam-google-authenticator
}

ensure_user() {
  local u="$1"
  [[ -n "$u" ]] || die "--user is required"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $u"
  [[ "$u" != "root" ]] || die "do not use root — create a normal admin user"

  if id "$u" >/dev/null 2>&1; then
    info "User $u already exists"
  else
    info "Creating user $u (sudo group)"
    adduser --disabled-password --gecos "" "$u"
  fi

  usermod -aG sudo "$u"
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$u" || true
  fi
}

set_password() {
  local u="$1"
  [[ "$SKIP_PASSWORD" -eq 1 ]] && { warn "skipping password"; return 0; }
  info "Set a strong password for $u (used for sudo — not for SSH login)"
  passwd "$u"
}

install_authorized_keys() {
  local u="$1"
  local home key_src
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -d "$home" ]] || die "home missing for $u"

  if [[ -n "$PUBKEY_FILE" ]]; then
    key_src="$PUBKEY_FILE"
  elif [[ -n "$PUBKEY_FROM_USER" ]]; then
    key_src="$(getent passwd "$PUBKEY_FROM_USER" | cut -d: -f6)/.ssh/authorized_keys"
  else
    # Prefer current SSH session owner's keys, else root
    if [[ -n "${SUDO_USER:-}" && -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys" ]]; then
      key_src="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
    elif [[ -f /root/.ssh/authorized_keys ]]; then
      key_src=/root/.ssh/authorized_keys
    else
      die "no SSH pubkey found — pass --pubkey /path/to/id_ed25519.pub or --pubkey-from-user ubuntu"
    fi
  fi

  [[ -f "$key_src" ]] || die "pubkey source not found: $key_src"
  grep -qE '^(ssh-|ecdsa-)' "$key_src" || die "no ssh public key lines in $key_src"

  info "Installing authorized_keys for $u from $key_src"
  install -d -m 0700 -o "$u" -g "$u" "$home/.ssh"
  install -m 0600 -o "$u" -g "$u" "$key_src" "$home/.ssh/authorized_keys"
}

enrol_totp() {
  local u="$1"
  local home secret
  home="$(getent passwd "$u" | cut -d: -f6)"
  secret="$home/.google_authenticator"

  [[ "$SKIP_TOTP" -eq 1 ]] && { warn "skipping TOTP enrol"; return 0; }

  if [[ -f "$secret" ]]; then
    info "TOTP already configured: $secret"
    return 0
  fi

  info "Enrolling Google Authenticator for $u (scan QR / enter secret in your app)"
  echo
  echo "  Keep this terminal open. After enrol, open a SECOND SSH session as $u"
  echo "  and confirm login works BEFORE we lock sshd to key+TOTP."
  echo
  # Interactive: shows QR + secret + scratch codes. Run as the target user.
  sudo -u "$u" -H google-authenticator -t -d -f -r 3 -R 30 -w 3 \
    || die "google-authenticator failed for $u"
  [[ -f "$secret" ]] || die "expected $secret after enrol"
  chmod 0400 "$secret"
  chown "$u:$u" "$secret"
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

apply_sshd() {
  local u="${1:-}"
  if [[ -n "$u" ]]; then
    local secret
    secret="$(getent passwd "$u" | cut -d: -f6)/.google_authenticator"
    [[ -f "$secret" ]] || die "missing $secret — enrol TOTP before applying sshd (or use --skip-sshd)"
  fi

  info "Installing sshd_config + PAM from templates/ssh (repo ssh_configs)"
  backup_file /etc/ssh/sshd_config
  backup_file /etc/pam.d/sshd

  install -m 0644 "$SSH_TEMPLATES/sshd_config" /etc/ssh/sshd_config
  install -m 0644 "$SSH_TEMPLATES/sshd" /etc/pam.d/sshd

  # Effective policy from templates:
  #   PermitRootLogin no
  #   PasswordAuthentication no
  #   PubkeyAuthentication yes
  #   KbdInteractiveAuthentication yes + UsePAM yes
  #   AuthenticationMethods publickey,keyboard-interactive  → key + TOTP

  if command -v sshd >/dev/null 2>&1; then
    sshd -t || die "sshd -t failed — restored? check /etc/ssh/sshd_config"
  fi

  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl reload ssh.socket 2>/dev/null || systemctl restart ssh.socket
  fi
  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
  else
    service ssh reload 2>/dev/null || service ssh restart || true
  fi

  info "sshd reloaded"
  echo
  echo "======== SSH policy ========"
  echo "  Login: SSH key + Google Authenticator (TOTP)"
  echo "  Root login: disabled"
  echo "  Password SSH: disabled (password is for sudo only)"
  echo
  echo "TEST NOW from another terminal:"
  echo "  ssh ${u:-USER}@HOST"
  echo "  (enter TOTP when prompted; do not close this session until it works)"
  echo
}

print_reminder() {
  local u="$1"
  cat <<EOF

======== DONE (SSH hardening) ========
User:     $u
Home:     $(getent passwd "$u" | cut -d: -f6)
SSH:      publickey + keyboard-interactive (TOTP via pam_google_authenticator)
Sudo:     password you set with passwd

Next:
  1) Open a NEW SSH session as $u and confirm key + TOTP work
  2) Only then close the old session
  3) Continue VPN install (as $u):
       cd ~/vpns   # or copy install/vpns under /home/$u
       sudo ./scripts/install-vpn-host.sh --wizard
     Set INSTALL_HOME=/home/$u in site.env

EOF
}

main() {
  install_packages

  if [[ "$APPLY_SSHD_ONLY" -eq 1 ]]; then
    [[ -n "$ADMIN_USER" ]] || die "--apply-sshd-only needs --user (to verify .google_authenticator)"
    apply_sshd "$ADMIN_USER"
    exit 0
  fi

  [[ -n "$ADMIN_USER" ]] || die "pass --user YOURNAME"

  ensure_user "$ADMIN_USER"
  set_password "$ADMIN_USER"
  install_authorized_keys "$ADMIN_USER"
  enrol_totp "$ADMIN_USER"

  if [[ "$SKIP_SSHD" -eq 1 ]]; then
    warn "sshd/PAM not applied yet — after confirming TOTP file exists, run:"
    echo "  sudo $0 --user $ADMIN_USER --apply-sshd-only"
  else
    apply_sshd "$ADMIN_USER"
  fi

  print_reminder "$ADMIN_USER"
}

main
