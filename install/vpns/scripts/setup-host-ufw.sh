#!/usr/bin/env bash
# Idempotent UFW + sysctl for a DataGate VPN host.
# Uses subnet/CIDR rules (not legacy tun0/tun4 names).
#
# Usage:
#   sudo ENV_FILE=~/host/.env ./scripts/setup-host-ufw.sh
#
# SAFETY: always allows SSH from ADMIN_SSH_IP and from INSTALLER_SSH_CLIENT_IP
# (the IP of the session that ran the installer), so a typo is less likely to lock you out.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-}"
if [[ -z "$ENV_FILE" ]]; then
  die "set ENV_FILE to the rendered host env, e.g. sudo ENV_FILE=~/host/.env $0"
fi

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo ENV_FILE=... $0"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  die "env file not found: $ENV_FILE"
fi

: "${TCP_VPN_SUBNET:?TCP_VPN_SUBNET required}"
: "${UDP_VPN_SUBNET:?UDP_VPN_SUBNET required}"
: "${PIHOLE_DNS_IP:?PIHOLE_DNS_IP required}"
: "${TCP_TUN_DEV:?TCP_TUN_DEV required}"
: "${UDP_TUN_DEV:?UDP_TUN_DEV required}"
: "${TCP_PORT:?TCP_PORT required}"
: "${UDP_PORT:?UDP_PORT required}"
: "${TCP_API_PORT:?TCP_API_PORT required}"
: "${UDP_API_PORT:?UDP_API_PORT required}"
: "${WAN_IF:=eth0}"
: "${ADMIN_SSH_IP:?ADMIN_SSH_IP required}"
: "${DASHBOARD_API_IP:?DASHBOARD_API_IP required}"
: "${DOCKER_BRIDGE_CIDR:=172.17.0.0/16}"

is_ipv4 "$ADMIN_SSH_IP" || die "ADMIN_SSH_IP must be IPv4 (got: $ADMIN_SSH_IP) — refusing to lock SSH"
is_ipv4 "$DASHBOARD_API_IP" || die "DASHBOARD_API_IP must be IPv4 (got: $DASHBOARD_API_IP)"

TCP_CIDR="${TCP_VPN_SUBNET}/24"
UDP_CIDR="${UDP_VPN_SUBNET}/24"

ufw_allow() {
  ufw "$@" || true
}

echo "[sysctl] enable net.ipv4.ip_forward"
install -d /etc/sysctl.d
install -m 0644 "$ROOT_DIR/templates/host/sysctl/99-datagate-vpn.conf" /etc/sysctl.d/99-datagate-vpn.conf
sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-datagate-vpn.conf

echo "[ufw] install + defaults"
export DEBIAN_FRONTEND=noninteractive
if ! command -v ufw >/dev/null; then
  apt-get update -qq
  apt-get install -y -qq ufw
fi

# Reset clears rules — SSH allow must be added before enable.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed

echo "[ufw] SSH allow-list (do this BEFORE enable)"
ufw_allow allow from "$ADMIN_SSH_IP" to any port 22 proto tcp comment 'ssh admin'
if [[ -n "${INSTALLER_SSH_CLIENT_IP:-}" ]] && is_ipv4 "$INSTALLER_SSH_CLIENT_IP"; then
  if [[ "$INSTALLER_SSH_CLIENT_IP" != "$ADMIN_SSH_IP" ]]; then
    echo "[ufw] also allowing current SSH client $INSTALLER_SSH_CLIENT_IP"
    ufw_allow allow from "$INSTALLER_SSH_CLIENT_IP" to any port 22 proto tcp comment 'ssh installer session'
  fi
fi

echo "[ufw] public ingress (nginx / openvpn)"
ufw_allow allow 80/tcp comment 'http certbot'
ufw_allow allow 443/tcp comment 'https nginx sni mux'
ufw_allow allow "${UDP_PORT}/udp" comment 'OpenVPN UDP WSS'
ufw_allow allow "${TCP_PORT}/tcp" comment 'OpenVPN TCP'

if [[ -n "${XRAY_API_HTTPS_PORT:-}" ]]; then
  echo "[ufw] Xray manager HTTPS :${XRAY_API_HTTPS_PORT} (allow-listed IPs)"
  allow_ips="${XRAY_API_ALLOW_IPS:-${DASHBOARD_API_IP}}"
  IFS=',' read -ra _ips <<<"$allow_ips"
  for ip in "${_ips[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [[ -z "$ip" || "$ip" == YOUR_* ]] && continue
    is_ipv4 "$ip" || continue
    ufw_allow allow from "$ip" to any port "$XRAY_API_HTTPS_PORT" proto tcp comment "xray-api-$ip"
  done
fi

if [[ -n "${EXTRA_TCP_PORT:-}" ]]; then
  ufw_allow allow "${EXTRA_TCP_PORT}/tcp" comment 'extra tcp'
fi

echo "[ufw] OpenVPN APIs from docker bridges (nginx → host)"
ufw_allow allow from "$DOCKER_BRIDGE_CIDR" to any port "$UDP_API_PORT" proto tcp comment 'openvpn udp api docker'
ufw_allow allow from "$DOCKER_BRIDGE_CIDR" to any port "$TCP_API_PORT" proto tcp comment 'openvpn tcp api docker'
ufw_allow allow from 172.16.0.0/12 to any port "$UDP_API_PORT" proto tcp comment 'openvpn udp api docker-range'
ufw_allow allow from 172.16.0.0/12 to any port "$TCP_API_PORT" proto tcp comment 'openvpn tcp api docker-range'

echo "[ufw] block public DNS on WAN"
ufw_allow deny in on "$WAN_IF" to any port 53 proto udp comment 'block public DNS eth0'
ufw_allow deny in on "$WAN_IF" to any port 53 proto tcp comment 'block public DNS eth0'

echo "[ufw] Pi-hole on ${TCP_TUN_DEV}"
ufw_allow allow in on "$TCP_TUN_DEV" to any port 53 proto udp comment "Pi-hole DNS ${TCP_TUN_DEV}"
ufw_allow allow in on "$TCP_TUN_DEV" to any port 53 proto tcp comment "Pi-hole DNS ${TCP_TUN_DEV}"
ufw_allow allow in on "$TCP_TUN_DEV" to any port 8080 proto tcp comment "Pi-hole admin ${TCP_TUN_DEV}"

echo "[ufw] DNS: UDP pool → Pi-hole on TCP .1"
ufw_allow allow from "$UDP_CIDR" to "$PIHOLE_DNS_IP" port 53 proto udp comment "vpn-dns-udp-${UDP_VPN_SUBNET}"
ufw_allow allow from "$UDP_CIDR" to "$PIHOLE_DNS_IP" port 53 proto tcp comment "vpn-dns-tcp-${UDP_VPN_SUBNET}"

echo "[ufw] VPN subnet forwarding (by CIDR)"
for cidr in "$TCP_CIDR" "$UDP_CIDR"; do
  ufw_allow route allow from "$cidr" to any comment "vpn-subnet-out-${cidr}"
  ufw_allow route allow from any to "$cidr" comment "vpn-subnet-in-${cidr}"
done

echo "[ufw] dashboard → OpenVPN TCP API"
ufw_allow allow from "$DASHBOARD_API_IP" to any port "$TCP_API_PORT" proto tcp comment 'openvpn tcp api dashboard'
ufw_allow allow from "$DASHBOARD_API_IP" to any port "$UDP_API_PORT" proto tcp comment 'openvpn udp api dashboard'

if [[ -n "${PROMETHEUS_IP:-}" && -n "${NODE_EXPORTER_PORT:-}" ]] && is_ipv4 "$PROMETHEUS_IP"; then
  ufw_allow allow from "$PROMETHEUS_IP" to any port "$NODE_EXPORTER_PORT" proto tcp comment 'prometheus'
fi

echo "[ufw] enable"
ufw --force enable

echo
echo "[done] UFW active. Verify SSH still works from another session before disconnecting."
ufw status verbose
