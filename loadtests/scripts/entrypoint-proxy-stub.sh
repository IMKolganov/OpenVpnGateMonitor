#!/bin/bash
# Run OpenVPN manager .NET API with an echo stub on PORT (no openvpn daemon).
set -euo pipefail

API_PORT=${API_PORT:-5009}
PORT=${PORT:-1194}
PROTO=${PROTO:-tcp}

if [ -n "${API_PORT}" ]; then
  export ASPNETCORE_HTTP_PORTS="$API_PORT"
fi

echo "[proxy-stub] Starting echo stub on ${PROTO}/${PORT}"
python3 /loadtests/scripts/echo_stub.py &
ECHO_PID=$!

echo "[proxy-stub] Starting DataGateOpenVpnManager"
cd /app
dotnet DataGateOpenVpnManager.dll &
DOTNET_PID=$!

wait -n "$ECHO_PID" "$DOTNET_PID"
EXIT_CODE=$?
kill "$ECHO_PID" "$DOTNET_PID" 2>/dev/null || true
exit "$EXIT_CODE"
