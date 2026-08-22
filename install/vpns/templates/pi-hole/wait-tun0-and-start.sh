#!/bin/sh
set -eu
echo "waiting for __TCP_TUN_DEV__ and __UDP_TUN_DEV__..."
i=0
while [ "$i" -lt 120 ]; do
  if ip link show __TCP_TUN_DEV__ >/dev/null 2>&1 && ip link show __UDP_TUN_DEV__ >/dev/null 2>&1; then
    echo "tunnels are up"
    exec /usr/bin/start.sh
  fi
  i=$((i + 1))
  sleep 1
done
echo "tunnels did not appear in 120s" >&2
exit 1
