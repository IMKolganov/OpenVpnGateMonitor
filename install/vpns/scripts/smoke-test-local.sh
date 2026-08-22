#!/usr/bin/env bash
# Local smoke test for install/vpns (no root, no OpenVPN pull).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="/tmp/datagate-vpn-install-test"
ENV_NO_XRAY="$TEST_ROOT/site.env.no-xray"
ENV_XRAY="$TEST_ROOT/site.env.xray"
RENDER_NO_XRAY="$TEST_ROOT/render-no-xray"
RENDER_XRAY="$TEST_ROOT/render-xray"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

write_test_env() {
  local dest="$1" install_home="$2" with_xray="$3"
  cat >"$dest" <<EOF
PUBLIC_IP=203.0.113.50
WAN_IF=eth0
INSTALL_HOME=${install_home}
CERTBOT_EMAIL=test@datagateapp.com
UDP_WSS_DOMAIN=s1-test.datagateapp.com
TCP_WSS_DOMAIN=s4-test.datagateapp.com
HFS_DOMAIN=
BACKEND__BASEURL=https://api.datagateapp.com/
DASHBOARD_API_IP=81.27.110.243
ADMIN_SSH_IP=164.215.15.224
PROMETHEUS_IP=
NODE_EXPORTER_PORT=9100
DOCKER_BRIDGE_CIDR=172.17.0.0/16
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
TCP_DNS1=10.51.40.1
TCP_DNS2=10.51.40.1
UDP_DNS1=10.51.40.1
UDP_DNS2=10.51.40.1
PIHOLE_DNS_IP=10.51.40.1
TCP_PORT=1297
UDP_PORT=1194
TCP_API_PORT=5011
UDP_API_PORT=5010
TCP_MANAGEMENT_PORT=5097
UDP_MANAGEMENT_PORT=5096
TCP_TUN_DEV=tun-tcp
UDP_TUN_DEV=ovpn-udp
UDP_WAN_IF=eth0
PIHOLE_WEBPASSWORD=test-pihole-secret
PIHOLE_WEB_PORT=8080
TZ=UTC
ASPNETCORE_ENVIRONMENT=Production
TCP_DCO=true
UDP_DCO=true
UDP_CIPHER=AES-128-GCM
UDP_DATA_CIPHERS=AES-128-GCM:AES-256-GCM:CHACHA20-POLY1305
TCP_VPN_NETMASK=255.255.255.0
UDP_VPN_NETMASK=255.255.255.0
INSTALL_DOCKER=false
SETUP_UFW=false
ISSUE_CERTS=false
START_STACKS=false
INSTALL_XRAY=${with_xray}
EOF
  if [[ "$with_xray" == true ]]; then
    cat >>"$dest" <<EOF
XRAY_DOMAIN=xs2-test.datagateapp.com
XRAY_MANAGER_HOST_PORT=5012
XRAY_API_HTTPS_PORT=9443
XRAY_API_ALLOW_IPS=81.27.110.243,94.237.4.29
XRAY_TRANSPORT_MODE=tls
XRAY_ACCEPT_PROXY_PROTOCOL=true
XRAY_HOST_GATEWAY=172.17.0.1
XRAY_DNS1=172.17.0.1
XRAY_DNS2=172.17.0.1
XRAY_PIHOLE_BASE_URL=http://172.17.0.1:8080
XRAY_DNS_IDENTITY_ENABLED=true
XRAY_DNS_IDENTITY_SUBNET=10.80.1.0/24
XRAY_DNS_IDENTITY_IFACE=eth0
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=10.80.1.
XRAY_PIHOLE_EXCLUDE_PREFIXES=10.51.40.,10.51.42.
NGINX_CERTBOT_CONF=${install_home}/nginx-docker/certbot/conf
EOF
  fi
}

render() {
  "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$1"
}

check_no_placeholders() {
  local dir="$1"
  if grep -rE '__[A-Z0-9_]+__|YOUR_|example\.com|CHANGE_ME' "$dir" \
    --include='*.conf' --include='*.sh' --include='*.env' --include='docker-compose.yml' 2>/dev/null; then
    fail "placeholders remain in $dir"
  else
    pass "no placeholders in $dir"
  fi
}

make_dummy_certs() {
  local cert_root="$1"
  shift
  local d
  for d in "$@"; do
    local live="$cert_root/live/$d"
    mkdir -p "$live"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -keyout "$live/privkey.pem" \
      -out "$live/fullchain.pem" \
      -subj "/CN=$d" 2>/dev/null
  done
}

write_full_nginx_for_home() {
  local home="$1"
  (
    set --
    # shellcheck disable=SC1091
    source "$ROOT/scripts/install-vpn-host.sh"
    set -a
    # shellcheck disable=SC1090
    source "$home/site.env.installed"
    set +a
    INSTALL_HOME="$home"
    write_full_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  )
}

nginx_test() {
  local home="$1" label="$2" network="${3:-}"
  local net_args=()
  if [[ -n "$network" ]]; then
    docker network create "$network" 2>/dev/null || true
    docker rm -f datagate-monitor-xray 2>/dev/null || true
    docker run -d --name datagate-monitor-xray --network "$network" alpine sleep 600 >/dev/null
    net_args=(--network "$network")
  fi
  if docker run --rm "${net_args[@]}" \
    --add-host=host.docker.internal:host-gateway \
    -v "$home/nginx-docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$home/nginx-docker/nginx/conf.d:/etc/nginx/conf.d:ro" \
    -v "$home/nginx-docker/nginx/stream.d:/etc/nginx/stream.d:ro" \
    -v "$home/nginx-docker/certbot/conf:/etc/letsencrypt:ro" \
    nginx:stable nginx -t 2>&1 | tee "/tmp/nginx-test-${label}.log" | grep -q 'test is successful'; then
    pass "nginx -t $label"
  else
    fail "nginx -t $label"
    cat "/tmp/nginx-test-${label}.log" >&2
  fi
  if [[ -n "$network" ]]; then
    docker rm -f datagate-monitor-xray >/dev/null 2>&1 || true
  fi
}

compose_config() {
  local dir="$1" name="$2"
  if (cd "$dir" && docker compose --env-file .env config -q 2>/dev/null); then
    pass "docker compose config $name"
  else
    (cd "$dir" && docker compose --env-file .env config) || fail "docker compose config $name"
  fi
}

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

write_test_env "$ENV_NO_XRAY" "$RENDER_NO_XRAY" false
write_test_env "$ENV_XRAY" "$RENDER_XRAY" true

echo "=== render OpenVPN-only ==="
render "$ENV_NO_XRAY"
check_no_placeholders "$RENDER_NO_XRAY"

echo "=== render OpenVPN + Xray ==="
render "$ENV_XRAY"
check_no_placeholders "$RENDER_XRAY"

echo "=== nginx -t OpenVPN-only ==="
make_dummy_certs "$RENDER_NO_XRAY/nginx-docker/certbot/conf" \
  s1-test.datagateapp.com s4-test.datagateapp.com
write_full_nginx_for_home "$RENDER_NO_XRAY"
nginx_test "$RENDER_NO_XRAY" openvpn-only

echo "=== nginx -t with Xray ==="
make_dummy_certs "$RENDER_XRAY/nginx-docker/certbot/conf" \
  s1-test.datagateapp.com s4-test.datagateapp.com xs2-test.datagateapp.com
write_full_nginx_for_home "$RENDER_XRAY"
nginx_test "$RENDER_XRAY" xray-stack datagate-monitor-xray_xray_network

echo "=== docker compose config ==="
compose_config "$RENDER_NO_XRAY/openvpn-tcp-wss" openvpn-tcp
compose_config "$RENDER_NO_XRAY/openvpn-udp-wss" openvpn-udp
compose_config "$RENDER_NO_XRAY/pi-hole" pihole
compose_config "$RENDER_NO_XRAY/nginx-docker" nginx-no-xray
compose_config "$RENDER_XRAY/datagate-monitor-xray" xray
compose_config "$RENDER_XRAY/nginx-docker" nginx-xray

grep -q 'datagate-monitor-xray:443' "$RENDER_XRAY/nginx-docker/nginx/stream.d/sni-xray.conf" \
  && pass "stream → xray" || fail "stream xray upstream"
grep -q 'host.docker.internal:5010' "$RENDER_NO_XRAY/nginx-docker/nginx/conf.d/udp-wss.conf" \
  && pass "udp wss upstream" || fail "udp wss upstream"
grep -q 'network_mode: "container:openvpn-tcp-wss"' "$RENDER_NO_XRAY/pi-hole/docker-compose.yml" \
  && pass "pihole netns" || fail "pihole netns"

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL SMOKE TESTS PASSED ==="
else
  echo "=== SOME TESTS FAILED ==="
  exit 1
fi
