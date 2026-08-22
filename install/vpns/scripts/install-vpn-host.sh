#!/usr/bin/env bash
# Install a DataGate VPN host from this folder (templates + site.env).
#
# Usage:
#   1) Copy install/vpns/ to the server
#   2) cp site.env.example site.env && nano site.env
#   3) sudo ./scripts/install-vpn-host.sh
#
# Flags:
#   --env FILE       path to site.env (default: ../site.env next to scripts/)
#   --wizard         ask for values interactively (writes site.env)
#   --render-only    only write stacks under INSTALL_HOME (no docker/ufw/start)
#   --skip-docker    do not install Docker
#   --skip-ufw       do not run UFW setup
#   --skip-certs     do not run certbot
#   --skip-start     do not docker compose up
#   --skip-preflight skip DNS / tun checks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$ROOT_DIR/templates"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/site.env}"

WIZARD=0
RENDER_ONLY=0
SKIP_DOCKER=0
SKIP_UFW=0
SKIP_CERTS=0
SKIP_START=0
SKIP_PREFLIGHT=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    --wizard) WIZARD=1; shift ;;
    --render-only) RENDER_ONLY=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --skip-ufw) SKIP_UFW=1; shift ;;
    --skip-certs) SKIP_CERTS=1; shift ;;
    --skip-start) SKIP_START=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

ask() {
  local var="$1" prompt="$2" def="${3:-}" val
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " val || true
    val="${val:-$def}"
  else
    read -r -p "$prompt: " val || true
  fi
  printf -v "$var" '%s' "$val"
}

detect_ssh_client_ip() {
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    echo "${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "${SSH_CONNECTION%% *}"
  else
    echo ""
  fi
}

detect_wan_if() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || echo "eth0"
}

detect_public_ip() {
  curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || true
}

run_wizard() {
  info "Interactive setup — fill YOUR values (Enter keeps default)"
  local public_ip default_home ssh_ip wan_if install_xray_ans

  public_ip="$(detect_public_ip)"
  wan_if="$(detect_wan_if)"
  ssh_ip="$(detect_ssh_client_ip)"
  default_home="/home/${SUDO_USER:-${USER:-ubuntu}}"

  ask PUBLIC_IP "Public IPv4" "${public_ip}"
  ask WAN_IF "WAN interface" "${wan_if:-eth0}"
  ask INSTALL_HOME "Install home (stacks go here)" "$default_home"
  ask CERTBOT_EMAIL "Let's Encrypt email" ""
  [[ -n "$CERTBOT_EMAIL" ]] || die "CERTBOT_EMAIL is required"
  ask UDP_WSS_DOMAIN "UDP WSS domain" ""
  ask TCP_WSS_DOMAIN "TCP WSS domain" ""
  [[ -n "$UDP_WSS_DOMAIN" && -n "$TCP_WSS_DOMAIN" ]] || die "WSS domains are required"
  ask HFS_DOMAIN "Optional HTTP helper domain (empty=skip)" ""
  ask BACKEND__BASEURL "Dashboard backend base URL" "https://api.datagateapp.com/"
  ask DASHBOARD_API_IP "Dashboard public IP (UFW allow API)" ""
  ask ADMIN_SSH_IP "Your SSH client IP (UFW allow 22)" "${ssh_ip}"
  ask TCP_VPN_SUBNET "TCP VPN subnet (x.y.z.0)" "10.51.40.0"
  ask UDP_VPN_SUBNET "UDP VPN subnet (x.y.z.0, unique)" "10.51.42.0"
  ask PIHOLE_WEBPASSWORD "Pi-hole web password" ""
  [[ -n "$PIHOLE_WEBPASSWORD" ]] || die "PIHOLE_WEBPASSWORD is required"
  ask install_xray_ans "Install Xray too? (true/false)" "true"

  local tcp_dns="${TCP_VPN_SUBNET%.*}.1"
  local xray_subnet="10.80.1.0"
  local xray_prefix="10.80.1."
  local xray_domain=""
  local install_xray="false"
  if is_true "$install_xray_ans"; then
    install_xray="true"
    ask XRAY_DOMAIN "Xray VLESS domain" ""
    [[ -n "$XRAY_DOMAIN" ]] || die "XRAY_DOMAIN required when installing Xray"
    ask XRAY_DNS_IDENTITY_SUBNET "Xray DNS identity subnet (unique /24)" "10.80.1.0"
    xray_subnet="${XRAY_DNS_IDENTITY_SUBNET%/*}"
    xray_subnet="${xray_subnet%.0}.0"
    [[ "$xray_subnet" == *.0 ]] || xray_subnet="${XRAY_DNS_IDENTITY_SUBNET}"
    xray_prefix="${xray_subnet%.*}."
    xray_domain="$XRAY_DOMAIN"
  fi

  cat >"$ENV_FILE" <<EOF
PUBLIC_IP=${PUBLIC_IP}
WAN_IF=${WAN_IF}
INSTALL_HOME=${INSTALL_HOME}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
UDP_WSS_DOMAIN=${UDP_WSS_DOMAIN}
TCP_WSS_DOMAIN=${TCP_WSS_DOMAIN}
HFS_DOMAIN=${HFS_DOMAIN}
BACKEND__BASEURL=${BACKEND__BASEURL}
DASHBOARD_API_IP=${DASHBOARD_API_IP}
ADMIN_SSH_IP=${ADMIN_SSH_IP}
PROMETHEUS_IP=
NODE_EXPORTER_PORT=9100
DOCKER_BRIDGE_CIDR=172.17.0.0/16
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
TCP_DNS1=${tcp_dns}
TCP_DNS2=${tcp_dns}
UDP_DNS1=${tcp_dns}
UDP_DNS2=${tcp_dns}
PIHOLE_DNS_IP=${tcp_dns}
TCP_PORT=1297
UDP_PORT=1194
TCP_API_PORT=5011
UDP_API_PORT=5010
TCP_MANAGEMENT_PORT=5097
UDP_MANAGEMENT_PORT=5096
TCP_TUN_DEV=tun-tcp
UDP_TUN_DEV=ovpn-udp
UDP_WAN_IF=${WAN_IF}
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_WEB_PORT=8080
TZ=UTC
ASPNETCORE_ENVIRONMENT=Production
TCP_DCO=true
UDP_DCO=true
UDP_CIPHER=AES-128-GCM
UDP_DATA_CIPHERS=AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305
TCP_VPN_NETMASK=255.255.255.0
UDP_VPN_NETMASK=255.255.255.0
INSTALL_DOCKER=true
SETUP_UFW=true
ISSUE_CERTS=true
START_STACKS=true
INSTALL_XRAY=${install_xray}
XRAY_DOMAIN=${xray_domain}
XRAY_MANAGER_HOST_PORT=5012
XRAY_API_HTTPS_PORT=9443
XRAY_API_ALLOW_IPS=${DASHBOARD_API_IP}
XRAY_TRANSPORT_MODE=tls
XRAY_ACCEPT_PROXY_PROTOCOL=true
XRAY_HOST_GATEWAY=172.17.0.1
XRAY_DNS1=172.17.0.1
XRAY_DNS2=172.17.0.1
XRAY_PIHOLE_BASE_URL=http://172.17.0.1:8080
XRAY_DNS_IDENTITY_ENABLED=true
XRAY_DNS_IDENTITY_SUBNET=${xray_subnet}/24
XRAY_DNS_IDENTITY_IFACE=${WAN_IF}
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=${xray_prefix}
XRAY_PIHOLE_EXCLUDE_PREFIXES=${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}.
NGINX_CERTBOT_CONF=${INSTALL_HOME}/nginx-docker/certbot/conf
EOF
  info "Wrote $ENV_FILE"
}

reject_placeholder() {
  local name="$1" val="$2"
  if [[ -z "$val" ]]; then
    die "$name is empty — edit $ENV_FILE"
  fi
  if [[ "$val" == *YOUR_* ]] || [[ "$val" == *CHANGE_ME* ]] \
    || [[ "$val" == *example.com* ]] || [[ "$val" == *yourdomain.com* ]]; then
    die "$name still looks like a placeholder ($val) — edit $ENV_FILE"
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — copy site.env.example or run with --wizard"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${PUBLIC_IP:?PUBLIC_IP required}"
  : "${INSTALL_HOME:?INSTALL_HOME required}"
  : "${UDP_WSS_DOMAIN:?UDP_WSS_DOMAIN required}"
  : "${TCP_WSS_DOMAIN:?TCP_WSS_DOMAIN required}"
  : "${TCP_VPN_SUBNET:?TCP_VPN_SUBNET required}"
  : "${UDP_VPN_SUBNET:?UDP_VPN_SUBNET required}"
  : "${BACKEND__BASEURL:?BACKEND__BASEURL required}"
  : "${ADMIN_SSH_IP:?ADMIN_SSH_IP required}"
  : "${DASHBOARD_API_IP:?DASHBOARD_API_IP required}"
  : "${PIHOLE_WEBPASSWORD:?PIHOLE_WEBPASSWORD required}"
  : "${CERTBOT_EMAIL:=}"
  : "${WAN_IF:=}"
  : "${TCP_PORT:=1297}"
  : "${UDP_PORT:=1194}"
  : "${TCP_API_PORT:=5011}"
  : "${UDP_API_PORT:=5010}"
  : "${TCP_MANAGEMENT_PORT:=5097}"
  : "${UDP_MANAGEMENT_PORT:=5096}"
  : "${TCP_TUN_DEV:=tun-tcp}"
  : "${UDP_TUN_DEV:=ovpn-udp}"
  : "${PIHOLE_WEB_PORT:=8080}"
  : "${TZ:=UTC}"
  : "${DOCKER_BRIDGE_CIDR:=172.17.0.0/16}"
  : "${INSTALL_XRAY:=false}"

  # Derive DNS from TCP subnet if missing / still placeholder
  local tcp_dns="${TCP_VPN_SUBNET%.*}.1"
  : "${TCP_DNS1:=$tcp_dns}"
  : "${TCP_DNS2:=$tcp_dns}"
  : "${UDP_DNS1:=$tcp_dns}"
  : "${UDP_DNS2:=$tcp_dns}"
  : "${PIHOLE_DNS_IP:=$tcp_dns}"
  TCP_DNS1="$tcp_dns"
  TCP_DNS2="$tcp_dns"
  UDP_DNS1="$tcp_dns"
  UDP_DNS2="$tcp_dns"
  PIHOLE_DNS_IP="$tcp_dns"

  if [[ -z "$WAN_IF" || "$WAN_IF" == YOUR_* ]]; then
    WAN_IF="$(detect_wan_if)"
    : "${WAN_IF:=eth0}"
  fi
  : "${UDP_WAN_IF:=$WAN_IF}"

  reject_placeholder PUBLIC_IP "$PUBLIC_IP"
  reject_placeholder INSTALL_HOME "$INSTALL_HOME"
  reject_placeholder UDP_WSS_DOMAIN "$UDP_WSS_DOMAIN"
  reject_placeholder TCP_WSS_DOMAIN "$TCP_WSS_DOMAIN"
  reject_placeholder BACKEND__BASEURL "$BACKEND__BASEURL"
  reject_placeholder PIHOLE_WEBPASSWORD "$PIHOLE_WEBPASSWORD"
  reject_placeholder ADMIN_SSH_IP "$ADMIN_SSH_IP"
  reject_placeholder DASHBOARD_API_IP "$DASHBOARD_API_IP"

  is_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be IPv4 (got: $PUBLIC_IP)"
  is_ipv4 "$ADMIN_SSH_IP" || die "ADMIN_SSH_IP must be IPv4 — wrong value locks you out of SSH (got: $ADMIN_SSH_IP)"
  is_ipv4 "$DASHBOARD_API_IP" || die "DASHBOARD_API_IP must be IPv4 (got: $DASHBOARD_API_IP)"

  if [[ "$TCP_VPN_SUBNET" == "$UDP_VPN_SUBNET" ]]; then
    die "TCP_VPN_SUBNET and UDP_VPN_SUBNET must be different"
  fi

  if is_true "${ISSUE_CERTS:-true}" && [[ "$SKIP_CERTS" -eq 0 ]]; then
    reject_placeholder CERTBOT_EMAIL "${CERTBOT_EMAIL:-}"
  fi

  if is_true "${INSTALL_XRAY:-false}"; then
    reject_placeholder XRAY_DOMAIN "${XRAY_DOMAIN:-}"
    : "${XRAY_DNS_IDENTITY_SUBNET:?XRAY_DNS_IDENTITY_SUBNET required when INSTALL_XRAY=true}"
    reject_placeholder XRAY_DNS_IDENTITY_SUBNET "$XRAY_DNS_IDENTITY_SUBNET"
    : "${XRAY_API_ALLOW_IPS:=$DASHBOARD_API_IP}"
    : "${NGINX_CERTBOT_CONF:=$INSTALL_HOME/nginx-docker/certbot/conf}"
    : "${XRAY_PIHOLE_EXCLUDE_PREFIXES:=${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}.}"
    : "${XRAY_PIHOLE_CLIENT_SUBNET_PREFIX:=${XRAY_DNS_IDENTITY_SUBNET%.*}.}"
    : "${XRAY_DNS_IDENTITY_IFACE:=$WAN_IF}"
  fi

  # Remember SSH client for UFW safety net
  export INSTALLER_SSH_CLIENT_IP
  INSTALLER_SSH_CLIENT_IP="$(detect_ssh_client_ip)"
}

preflight() {
  [[ "$SKIP_PREFLIGHT" -eq 1 ]] && { warn "preflight skipped"; return 0; }
  info "Preflight checks"

  if [[ ! -e /dev/net/tun ]]; then
    die "/dev/net/tun missing — load tun module: sudo modprobe tun"
  fi

  if [[ "$RENDER_ONLY" -eq 0 ]] && is_true "${ISSUE_CERTS:-true}" && [[ "$SKIP_CERTS" -eq 0 ]]; then
    local d resolved
    for d in "$UDP_WSS_DOMAIN" "$TCP_WSS_DOMAIN"; do
      resolved="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}' || true)"
      if [[ -z "$resolved" ]]; then
        warn "DNS for $d does not resolve yet — certbot will fail until A-record → $PUBLIC_IP"
      elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
        warn "DNS for $d → $resolved (expected $PUBLIC_IP) — fix A-record before certbot"
      else
        info "DNS OK: $d → $resolved"
      fi
    done
    if is_true "${INSTALL_XRAY:-false}"; then
      resolved="$(getent ahostsv4 "$XRAY_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
      if [[ -z "$resolved" ]]; then
        warn "DNS for $XRAY_DOMAIN does not resolve yet"
      elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
        warn "DNS for $XRAY_DOMAIN → $resolved (expected $PUBLIC_IP)"
      else
        info "DNS OK: $XRAY_DOMAIN → $resolved"
      fi
    fi
  fi
}

render_file() {
  local src="$1" dst="$2"
  local content k v
  content="$(cat "$src")"
  local keys=(
    PUBLIC_IP WAN_IF INSTALL_HOME CERTBOT_EMAIL
    UDP_WSS_DOMAIN TCP_WSS_DOMAIN HFS_DOMAIN XRAY_DOMAIN XRAY_API_HTTPS_PORT
    BACKEND__BASEURL DASHBOARD_API_IP ADMIN_SSH_IP
    PROMETHEUS_IP NODE_EXPORTER_PORT DOCKER_BRIDGE_CIDR
    TCP_VPN_SUBNET UDP_VPN_SUBNET TCP_DNS1 TCP_DNS2 UDP_DNS1 UDP_DNS2 PIHOLE_DNS_IP
    TCP_PORT UDP_PORT TCP_API_PORT UDP_API_PORT TCP_MANAGEMENT_PORT UDP_MANAGEMENT_PORT
    TCP_TUN_DEV UDP_TUN_DEV UDP_WAN_IF
    PIHOLE_WEBPASSWORD PIHOLE_WEB_PORT TZ
    ASPNETCORE_ENVIRONMENT TCP_DCO UDP_DCO UDP_CIPHER UDP_DATA_CIPHERS
    TCP_VPN_NETMASK UDP_VPN_NETMASK
  )
  for k in "${keys[@]}"; do
    v="${!k-}"
    content="${content//__${k}__/${v}}"
  done

  if grep -qE '__[A-Z0-9_]+__' <<<"$content"; then
    warn "unresolved placeholders in $dst:"
    grep -oE '__[A-Z0-9_]+__' <<<"$content" | sort -u >&2 || true
  fi

  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" >"$dst"
}

write_openvpn_tcp_env() {
  local dest="$1"
  cat >"$dest" <<EOF
BACKEND__BASEURL=${BACKEND__BASEURL}
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
TCP_VPN_NETMASK=${TCP_VPN_NETMASK:-255.255.255.0}
TCP_DNS1=${TCP_DNS1}
TCP_DNS2=${TCP_DNS2}
TCP_PORT=${TCP_PORT}
TCP_API_PORT=${TCP_API_PORT}
TCP_MANAGEMENT_PORT=${TCP_MANAGEMENT_PORT}
TCP_TUN_DEV=${TCP_TUN_DEV}
TCP_TUN_IF=${TCP_TUN_DEV}
TCP_DCO=${TCP_DCO:-true}
EOF
}

write_openvpn_udp_env() {
  local dest="$1"
  cat >"$dest" <<EOF
BACKEND__BASEURL=${BACKEND__BASEURL}
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
UDP_VPN_NETMASK=${UDP_VPN_NETMASK:-255.255.255.0}
UDP_DNS1=${UDP_DNS1}
UDP_DNS2=${UDP_DNS2}
UDP_PORT=${UDP_PORT}
UDP_API_PORT=${UDP_API_PORT}
UDP_MANAGEMENT_PORT=${UDP_MANAGEMENT_PORT}
UDP_TUN_DEV=${UDP_TUN_DEV}
UDP_WAN_IF=${UDP_WAN_IF:-$WAN_IF}
UDP_DCO=${UDP_DCO:-true}
UDP_CIPHER=${UDP_CIPHER:-AES-128-GCM}
UDP_DATA_CIPHERS=${UDP_DATA_CIPHERS:-AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305}
EOF
}

write_pihole_env() {
  local dest="$1"
  cat >"$dest" <<EOF
TZ=${TZ:-UTC}
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_DNS_INTERFACE=${TCP_TUN_DEV},${UDP_TUN_DEV}
PIHOLE_WEB_PORT=${PIHOLE_WEB_PORT:-8080}
EOF
}

write_host_env() {
  local dest="$1"
  cat >"$dest" <<EOF
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
PIHOLE_DNS_IP=${PIHOLE_DNS_IP}
TCP_TUN_DEV=${TCP_TUN_DEV}
UDP_TUN_DEV=${UDP_TUN_DEV}
TCP_PORT=${TCP_PORT}
UDP_PORT=${UDP_PORT}
TCP_API_PORT=${TCP_API_PORT}
UDP_API_PORT=${UDP_API_PORT}
WAN_IF=${WAN_IF}
ADMIN_SSH_IP=${ADMIN_SSH_IP}
DASHBOARD_API_IP=${DASHBOARD_API_IP}
PROMETHEUS_IP=${PROMETHEUS_IP:-}
DOCKER_BRIDGE_CIDR=${DOCKER_BRIDGE_CIDR}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT:-9100}
INSTALLER_SSH_CLIENT_IP=${INSTALLER_SSH_CLIENT_IP:-}
EXTRA_TCP_PORT=
EOF
  if is_true "${INSTALL_XRAY:-false}"; then
    cat >>"$dest" <<EOF
XRAY_API_HTTPS_PORT=${XRAY_API_HTTPS_PORT:-9443}
XRAY_API_ALLOW_IPS=${XRAY_API_ALLOW_IPS:-${DASHBOARD_API_IP}}
EOF
  fi
}

xray_api_allow_block() {
  local ips="${XRAY_API_ALLOW_IPS:-${DASHBOARD_API_IP}}" ip
  IFS=',' read -ra _ips <<<"$ips"
  for ip in "${_ips[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [[ -z "$ip" || "$ip" == YOUR_* ]] && continue
    is_ipv4 "$ip" || continue
    printf '        allow %s;\n' "$ip"
  done
}

write_stream_conf() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    render_file "$TEMPLATES/nginx-docker/nginx/stream.d/sni-xray.conf" "$dest"
  else
    cat >"$dest" <<'EOF'
upstream local_https {
    server 127.0.0.1:8443;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass local_https;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    proxy_timeout 1d;
}
EOF
  fi
}

write_acme_conf() {
  local conf_d="$1" mode="${2:-waiting}"
  local names="${UDP_WSS_DOMAIN} ${TCP_WSS_DOMAIN}"
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    names+=" ${XRAY_DOMAIN}"
  fi
  if [[ -n "${HFS_DOMAIN:-}" ]]; then
    names+=" ${HFS_DOMAIN}"
  fi

  local trailing
  if [[ "$mode" == "redirect" ]]; then
    trailing='        return 301 https://$host$request_uri;'
  else
    trailing="        return 200 'waiting for TLS cert';
        add_header Content-Type text/plain;"
  fi

  cat >"$conf_d/00-acme.conf" <<EOF
server {
    listen 80;
    server_name ${names};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
${trailing}
    }
}
EOF
}

tls_certs_ready() {
  local home="$1"
  local cert_root="$home/nginx-docker/certbot/conf/live"
  [[ -f "$cert_root/${UDP_WSS_DOMAIN}/fullchain.pem" ]] \
    && [[ -f "$cert_root/${TCP_WSS_DOMAIN}/fullchain.pem" ]]
}

write_simple_stream_conf() {
  # No Xray upstream — safe for ACME before datagate-monitor-xray exists.
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
upstream local_https {
    server 127.0.0.1:8443;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass local_https;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    proxy_timeout 1d;
}
EOF
}

write_http_only_nginx() {
  local conf_d="$1"
  local stream_d="$2"
  mkdir -p "$conf_d" "$stream_d" "$(dirname "$conf_d")/../logs"

  cp "$TEMPLATES/nginx-docker/nginx/nginx.conf" "$(dirname "$conf_d")/nginx.conf"
  # Always simple stream during ACME — Xray SNI comes after certs + start_xray
  write_simple_stream_conf "$stream_d/sni-xray.conf"
  write_acme_conf "$conf_d" waiting
  rm -f "$conf_d/udp-wss.conf" "$conf_d/tcp-wss.conf" "$conf_d/xray-api.conf" "$conf_d/00-map.conf"
}

write_full_nginx() {
  local conf_d="$1"
  local stream_d="$2"
  mkdir -p "$conf_d" "$stream_d"

  cp "$TEMPLATES/nginx-docker/nginx/nginx.conf" "$(dirname "$conf_d")/nginx.conf"
  write_stream_conf "$stream_d/sni-xray.conf"
  write_acme_conf "$conf_d" redirect

  : "${XRAY_API_HTTPS_PORT:=9443}"
  local allow_block
  allow_block="$(xray_api_allow_block)"

  render_file "$TEMPLATES/nginx-docker/nginx/conf.d/udp-wss.conf" "$conf_d/udp-wss.conf"
  render_file "$TEMPLATES/nginx-docker/nginx/conf.d/tcp-wss.conf" "$conf_d/tcp-wss.conf"

  if is_true "${INSTALL_XRAY:-false}"; then
    if [[ -z "$allow_block" ]]; then
      die "XRAY_API_ALLOW_IPS produced no allow lines — set at least DASHBOARD_API_IP"
    fi
    cat >"$conf_d/xray-api.conf" <<EOF
# Xray manager API — separate port, does not collide with VLESS on :443
server {
    listen ${XRAY_API_HTTPS_PORT:-9443} ssl;
    server_name ${XRAY_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${XRAY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${XRAY_DOMAIN}/privkey.pem;

    location / {
${allow_block}
        deny all;

        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$xray_api_upstream datagate-monitor-xray;
        proxy_pass http://\$xray_api_upstream:5010;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400s;

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    rm -f "$conf_d/xray-api.conf"
  fi
}

write_nginx_env() {
  local dest="$1"
  cat >"$dest" <<EOF
XRAY_API_HTTPS_PORT=${XRAY_API_HTTPS_PORT:-9443}
EOF
}

write_xray_env() {
  local dest="$1"
  local nginx_certs="${NGINX_CERTBOT_CONF:-$INSTALL_HOME/nginx-docker/certbot/conf}"
  local exclude="${XRAY_PIHOLE_EXCLUDE_PREFIXES:-${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}.}"
  local prefix="${XRAY_PIHOLE_CLIENT_SUBNET_PREFIX:-${XRAY_DNS_IDENTITY_SUBNET%.*}.}"
  local gw="${XRAY_HOST_GATEWAY:-172.17.0.1}"
  cat >"$dest" <<EOF
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
BACKEND__BASEURL=${BACKEND__BASEURL}
PUBLIC_IP=${PUBLIC_IP}
XRAY_DOMAIN=${XRAY_DOMAIN}
XRAY_TRANSPORT_MODE=${XRAY_TRANSPORT_MODE:-tls}
XRAY_ACCEPT_PROXY_PROTOCOL=${XRAY_ACCEPT_PROXY_PROTOCOL:-true}
XRAY_MANAGER_HOST_PORT=${XRAY_MANAGER_HOST_PORT:-5012}
XRAY_HOST_GATEWAY=${gw}
XRAY_DNS1=${XRAY_DNS1:-$gw}
XRAY_DNS2=${XRAY_DNS2:-$gw}
XRAY_PIHOLE_BASE_URL=${XRAY_PIHOLE_BASE_URL:-http://${gw}:8080}
XRAY_DNS_IDENTITY_ENABLED=${XRAY_DNS_IDENTITY_ENABLED:-true}
XRAY_DNS_IDENTITY_SUBNET=${XRAY_DNS_IDENTITY_SUBNET}
XRAY_DNS_IDENTITY_IFACE=${XRAY_DNS_IDENTITY_IFACE:-${WAN_IF}}
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=${prefix}
XRAY_PIHOLE_EXCLUDE_PREFIXES=${exclude}
PIHOLE_ENABLED=true
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
NGINX_CERTBOT_CONF=${nginx_certs}
EOF
}

ensure_xray_network() {
  docker network create datagate-monitor-xray_xray_network 2>/dev/null || true
}

write_nginx_compose() {
  local home="$1"
  if is_true "${INSTALL_XRAY:-false}"; then
    cp "$TEMPLATES/nginx-docker/docker-compose.yml" "$home/nginx-docker/docker-compose.yml"
  else
    cat >"$home/nginx-docker/docker-compose.yml" <<'EOF'
services:
  nginx:
    image: nginx:stable
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/stream.d:/etc/nginx/stream.d:ro
      - ./nginx/logs:/var/log/nginx
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt

  certbot:
    image: certbot/certbot
    container_name: certbot
    volumes:
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
EOF
  fi
  write_nginx_env "$home/nginx-docker/.env"
}

render_stacks() {
  local home="$INSTALL_HOME"
  info "Rendering stacks under $home"

  mkdir -p \
    "$home/openvpn-tcp-wss/data" \
    "$home/openvpn-udp-wss/data" \
    "$home/pi-hole/etc-pihole" \
    "$home/pi-hole/etc-dnsmasq.d" \
    "$home/nginx-docker/nginx/conf.d" \
    "$home/nginx-docker/nginx/stream.d" \
    "$home/nginx-docker/nginx/logs" \
    "$home/nginx-docker/certbot/www" \
    "$home/nginx-docker/certbot/conf" \
    "$home/host"

  cp "$TEMPLATES/openvpn-tcp-wss/docker-compose.yml" "$home/openvpn-tcp-wss/docker-compose.yml"
  write_openvpn_tcp_env "$home/openvpn-tcp-wss/.env"

  cp "$TEMPLATES/openvpn-udp-wss/docker-compose.yml" "$home/openvpn-udp-wss/docker-compose.yml"
  write_openvpn_udp_env "$home/openvpn-udp-wss/.env"

  cp "$TEMPLATES/pi-hole/docker-compose.yml" "$home/pi-hole/docker-compose.yml"
  write_pihole_env "$home/pi-hole/.env"
  render_file "$TEMPLATES/pi-hole/wait-tun0-and-start.sh" "$home/pi-hole/wait-tun0-and-start.sh"
  chmod +x "$home/pi-hole/wait-tun0-and-start.sh"

  write_nginx_compose "$home"
  if tls_certs_ready "$home"; then
    info "TLS certs found — rendering full nginx config"
    write_full_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  else
    write_http_only_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  fi

  write_host_env "$home/host/.env"
  cp "$ENV_FILE" "$home/site.env.installed"

  if is_true "${INSTALL_XRAY:-false}"; then
    mkdir -p "$home/datagate-monitor-xray/data/xray_data"
    cp "$TEMPLATES/xray/docker-compose.yml" "$home/datagate-monitor-xray/docker-compose.yml"
    write_xray_env "$home/datagate-monitor-xray/.env"
  fi

  if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown -R "$SUDO_USER:$SUDO_USER" \
      "$home/openvpn-tcp-wss" "$home/openvpn-udp-wss" "$home/pi-hole" "$home/nginx-docker" "$home/host" \
      "$home/site.env.installed" 2>/dev/null || true
    if is_true "${INSTALL_XRAY:-false}" && [[ -d "$home/datagate-monitor-xray" ]]; then
      chown -R "$SUDO_USER:$SUDO_USER" "$home/datagate-monitor-xray" 2>/dev/null || true
    fi
  fi

  # nginx in container runs as uid 101 — needs write access to log dir
  chmod 0777 "$home/nginx-docker/nginx/logs"
  chmod 0755 "$home/nginx-docker/certbot/www"

  info "Rendered openvpn-tcp-wss / openvpn-udp-wss / pi-hole / nginx-docker / host$(is_true "${INSTALL_XRAY:-false}" && echo ' / xray')"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker already installed"
    return
  fi
  info "Installing Docker (official convenience script)"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  if id "${SUDO_USER:-}" >/dev/null 2>&1; then
    usermod -aG docker "$SUDO_USER" || true
  fi
}

setup_ufw() {
  info "Applying UFW + sysctl"
  ENV_FILE="$INSTALL_HOME/host/.env" "$SCRIPT_DIR/setup-host-ufw.sh"
}

wait_openvpn_up() {
  info "Waiting for OpenVPN containers (first boot can take a few minutes for PKI)..."
  local i=0
  while [[ $i -lt 150 ]]; do
    local tcp_state udp_running
    tcp_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' openvpn-tcp-wss 2>/dev/null || echo missing)"
    udp_running="$(docker inspect --format '{{.State.Running}}' openvpn-udp-wss 2>/dev/null || echo false)"
    if { [[ "$tcp_state" == "healthy" ]] || [[ "$tcp_state" == "running" ]]; } && [[ "$udp_running" == "true" ]]; then
      # Prefer healthy; accept running after enough time if healthcheck not ready
      if [[ "$tcp_state" == "healthy" ]] || [[ $i -gt 30 ]]; then
        info "OpenVPN is up (tcp=$tcp_state udp=running)"
        return 0
      fi
    fi
    sleep 2
    i=$((i + 1))
  done
  warn "OpenVPN not healthy yet — check: docker ps -a && docker logs openvpn-tcp-wss"
  docker ps -a --filter name=openvpn || true
}

start_openvpn() {
  info "Starting OpenVPN (TCP then UDP — separate stacks)"
  (cd "$INSTALL_HOME/openvpn-tcp-wss" && docker compose pull && docker compose up -d)
  (cd "$INSTALL_HOME/openvpn-udp-wss" && docker compose pull && docker compose up -d)
  wait_openvpn_up
}

start_pihole() {
  info "Starting Pi-hole (joins openvpn-tcp-wss netns)"
  (cd "$INSTALL_HOME/pi-hole" && docker compose up -d)
  sleep 3
  if ! docker inspect --format '{{.State.Running}}' datagate-pihole 2>/dev/null | grep -q true; then
    warn "Pi-hole not running — often means OpenVPN TCP was recreated; check: docker logs datagate-pihole"
  fi
}

start_nginx() {
  info "Starting nginx (HTTP for ACME)"
  if is_true "${INSTALL_XRAY:-false}"; then
    ensure_xray_network
  fi
  (cd "$INSTALL_HOME/nginx-docker" && docker compose up -d nginx)
}

# One certificate directory per domain (nginx expects live/<domain>/...)
issue_cert_for_domain() {
  local domain="$1"
  info "Certbot: $domain"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    --cert-name "$domain" \
    -d "$domain" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring)
}

issue_certs() {
  info "Issuing Let's Encrypt certs (one cert per domain)"
  : "${CERTBOT_EMAIL:?CERTBOT_EMAIL required for ISSUE_CERTS}"

  local domains=("$UDP_WSS_DOMAIN" "$TCP_WSS_DOMAIN")
  if [[ -n "${HFS_DOMAIN:-}" ]]; then
    domains+=("$HFS_DOMAIN")
  fi
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    domains+=("$XRAY_DOMAIN")
  fi

  local d
  for d in "${domains[@]}"; do
    issue_cert_for_domain "$d" || die "certbot failed for $d — check DNS A-record → $PUBLIC_IP and port 80"
  done

  # Xray upstream must exist before nginx stream SNI config is applied
  if is_true "${INSTALL_XRAY:-false}"; then
    start_xray
  fi

  apply_full_nginx_tls
}

apply_full_nginx_tls() {
  write_full_nginx "$INSTALL_HOME/nginx-docker/nginx/conf.d" "$INSTALL_HOME/nginx-docker/nginx/stream.d"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose up -d nginx)
  (cd "$INSTALL_HOME/nginx-docker" && docker compose exec nginx nginx -t) \
    || die "nginx config test failed after certs"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose exec nginx nginx -s reload) \
    || (cd "$INSTALL_HOME/nginx-docker" && docker compose restart nginx)
  info "TLS enabled — nginx reloaded (WSS on :8443 via SNI :443)"
}

start_xray() {
  info "Starting Xray (needs certs already issued)"
  ensure_xray_network
  local cert="$INSTALL_HOME/nginx-docker/certbot/conf/live/${XRAY_DOMAIN}/fullchain.pem"
  if [[ ! -f "$cert" ]]; then
    die "missing $cert — issue certs before starting Xray"
  fi
  (cd "$INSTALL_HOME/datagate-monitor-xray" && docker compose pull && docker compose up -d)
}

print_summary() {
  cat <<EOF

======== DONE ========
Stacks under: $INSTALL_HOME

  OpenVPN UDP WSS: https://${UDP_WSS_DOMAIN}/  (SNI → :8443 → host :${UDP_API_PORT})
  OpenVPN TCP WSS: https://${TCP_WSS_DOMAIN}/  (SNI → :8443 → host :${TCP_API_PORT})
  Pi-hole DNS:     ${PIHOLE_DNS_IP}:53 (VPN clients)
  Pi-hole admin:   http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT}/ (via VPN)
EOF
  if is_true "${INSTALL_XRAY:-false}"; then
    cat <<EOF
  Xray VLESS:      ${XRAY_DOMAIN}:443 (SNI → container)
  Xray ApiUrl:     https://${XRAY_DOMAIN}:${XRAY_API_HTTPS_PORT:-9443}
  Xray DNS identity subnet: ${XRAY_DNS_IDENTITY_SUBNET}
EOF
  fi
  cat <<EOF

Dashboard registration:
  - UDP ApiUrl: https://${UDP_WSS_DOMAIN}/
  - TCP ApiUrl: https://${TCP_WSS_DOMAIN}/
$(is_true "${INSTALL_XRAY:-false}" && echo "  - Xray ApiUrl: https://${XRAY_DOMAIN}:${XRAY_API_HTTPS_PORT:-9443}")
  - Backend: ${BACKEND__BASEURL}
  - Subnets: TCP ${TCP_VPN_SUBNET}/24 , UDP ${UDP_VPN_SUBNET}/24

Useful:
  docker ps -a
  cd $INSTALL_HOME/openvpn-tcp-wss && docker compose logs -f --tail=100
  cd $INSTALL_HOME/openvpn-udp-wss && docker compose logs -f --tail=100
  cd $INSTALL_HOME/pi-hole && docker compose logs -f --tail=100
  cd $INSTALL_HOME/nginx-docker && docker compose logs -f --tail=50
EOF
}

main() {
  if [[ "$RENDER_ONLY" -eq 0 ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
  fi

  if [[ "$WIZARD" -eq 1 ]] || [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
      info "No site.env found — starting wizard"
      WIZARD=1
    fi
  fi
  [[ "$WIZARD" -eq 1 ]] && run_wizard
  load_env
  preflight

  render_stacks
  [[ "$RENDER_ONLY" -eq 1 ]] && { info "render-only complete → $INSTALL_HOME"; exit 0; }

  if [[ "$SKIP_DOCKER" -eq 0 ]] && is_true "${INSTALL_DOCKER:-true}"; then
    ensure_docker
  fi

  if [[ "$SKIP_UFW" -eq 0 ]] && is_true "${SETUP_UFW:-true}"; then
    setup_ufw
  fi

  if [[ "$SKIP_START" -eq 0 ]] && is_true "${START_STACKS:-true}"; then
    # Order: OpenVPN → Pi-hole → nginx(HTTP, no Xray upstream) → certs
    #        → start Xray → full nginx (SNI + WSS)
    start_openvpn
    start_pihole
    start_nginx
    if [[ "$SKIP_CERTS" -eq 0 ]] && is_true "${ISSUE_CERTS:-true}"; then
      issue_certs
    else
      warn "skipped certs — nginx is HTTP-only; later: re-run without --skip-certs"
      if is_true "${INSTALL_XRAY:-false}"; then
        warn "Xray skipped because certs were skipped (Xray needs TLS files)"
      fi
    fi
  fi

  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
