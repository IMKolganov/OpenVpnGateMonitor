#!/usr/bin/env bash
# Channel-only ramp: pre-issue .ovpn sequentially, then connect without EasyRSA.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILES="${PROFILES_DIR:-/tmp/ovpn-preissued}"
RESULTS="${RESULTS:-/tmp/pi-vpn-channel-results.jsonl}"
SUMMARY="${SUMMARY:-/tmp/pi-vpn-channel-summary.txt}"
LOG="${LOG:-/tmp/pi-vpn-channel-ramp.log}"
IMAGE="${IMAGE:-local-ovpn-loadclient:latest}"
SHARDS="${SHARDS:-4}"
PREPARE_N="${PREPARE_N:-1000}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:5581}"
OPENVPN_API_URL="${OPENVPN_API_URL:-http://192.168.0.2:5011}"
VPN_HOST="${VPN_HOST:-192.168.0.2}"
VPN_PORT="${VPN_PORT:-1296}"
PI_HOST="${PI_HOST:-192.168.0.2}"
PI_USER="${PI_USER:-rackot}"
SSHPASS="${SSHPASS:-Trinitron2005}"
LEVELS=(${LEVELS:-250 500 750 1000})

mkdir -p "$PROFILES"
exec > >(tee -a "$LOG") 2>&1
echo "=== channel ramp start $(date -u +%Y-%m-%dT%H:%M:%SZ) prepare=$PREPARE_N levels=${LEVELS[*]} ==="
: >"$RESULTS"

sample_pi() {
  local label="$1"
  docker run --rm --network host alpine:3.20 sh -c \
    "apk add --no-cache openssh-client sshpass >/dev/null && \
     sshpass -p '$SSHPASS' ssh -o StrictHostKeyChecking=no \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       ${PI_USER}@${PI_HOST} 'python3 -c \"
import json,os
load=os.getloadavg()
mem={}
for line in open(\\\"/proc/meminfo\\\"):
 k,v=line.split(\\\":\\\",1); mem[k]=int(v.strip().split()[0])
rss={}
for pid in os.listdir(\\\"/proc\\\"):
 if not pid.isdigit(): continue
 try:
  comm=open(f\\\"/proc/{pid}/comm\\\").read().strip()
  if comm not in (\\\"openvpn\\\",\\\"dotnet\\\"): continue
  for line in open(f\\\"/proc/{pid}/status\\\"):
   if line.startswith(\\\"VmRSS:\\\"):
    rss[f\\\"{comm}:{pid}\\\"]=int(line.split()[1]); break
 except Exception: pass
print(json.dumps({\\\"label\\\":\\\"$label\\\",\\\"load1\\\":load[0],\\\"load5\\\":load[1],\\\"mem_avail_mb\\\":round(mem.get(\\\"MemAvailable\\\",0)/1024),\\\"rss_kb\\\":rss}))
\"'"
}

kill_mgmt_clients() {
  docker run --rm --network host alpine:3.20 sh -c \
    "apk add --no-cache openssh-client sshpass >/dev/null && \
     sshpass -p '$SSHPASS' ssh -o StrictHostKeyChecking=no \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no \
       ${PI_USER}@${PI_HOST} 'python3 - <<\"PY\"
import socket,time
s=socket.create_connection((\"127.0.0.1\",5096),3); s.settimeout(2)
def cmd(c):
 s.sendall((c+\"\\n\").encode()); time.sleep(0.2); o=b\"\"
 try:
  while True:
   b=s.recv(65536)
   if not b: break
   o+=b
   if b\"END\" in o: break
 except Exception: pass
 return o.decode(errors=\"ignore\")
st=cmd(\"status 2\")
n=0
for line in st.splitlines():
 if line.startswith(\"CLIENT_LIST,\"):
  cn=line.split(\",\")[1]
  if cn not in (\"Common Name\",\"UNDEF\"):
   cmd(\"kill \"+cn); n+=1
print(\"killed\", n)
s.close()
PY'"
}

have=$(find "$PROFILES" -name '*.ovpn' | wc -l)
if [ "$have" -lt "$PREPARE_N" ]; then
  echo "===== PREPARE $PREPARE_N profiles (have $have) ISSUE_PARALLELISM=1 ====="
  sample_pi "before_prepare" | tee -a "$RESULTS"
  docker run --rm --network host \
    -v "$ROOT:/loadtests" -v "$PROFILES:/profiles" -w /loadtests \
    -e BACKEND_URL="$BACKEND_URL" \
    -e OPENVPN_API_URL="$OPENVPN_API_URL" \
    -e VPN_HOST="$VPN_HOST" -e VPN_PORT="$VPN_PORT" -e VPN_PROTO=udp \
    -e CONCURRENCY="$PREPARE_N" -e ISSUE_PARALLELISM=1 \
    -e SOAK_MODE=prepare \
    -e RUN_ID="chan$(date +%s)" \
    -e PROFILES_DIR=/profiles \
    -e EASY_RSA_PATH=/openvpn-loadtest/easy-rsa \
    -e VPN_ROUTE=10.50.96.0/22 \
    --name ovpn-channel-prepare \
    "$IMAGE" test_ovpn_vpn_soak.py | tee /tmp/pi-vpn-prepare.json
  have=$(find "$PROFILES" -name '*.ovpn' | wc -l)
  echo "prepared=$have"
  sample_pi "after_prepare" | tee -a "$RESULTS"
else
  echo "===== PREPARE skip, already have $have profiles ====="
fi

run_level() {
  local N="$1"
  echo "===== CHANNEL CONNECT N=$N shards=$SHARDS (no EasyRSA) ====="
  sample_pi "before_$N" | tee -a "$RESULTS"
  kill_mgmt_clients || true

  local pids=()
  local outs=()
  local i=0
  while [ "$i" -lt "$SHARDS" ]; do
    local out="/tmp/pi-vpn-chan-${N}-${i}.json"
    outs+=("$out")
    rm -f "$out"
    docker run --rm --network host --cap-add NET_ADMIN --device /dev/net/tun \
      -v "$ROOT:/loadtests" -v "$PROFILES:/profiles:ro" -w /loadtests \
      -e SOAK_MODE=connect \
      -e SKIP_TRAFFIC=0 -e SKIP_REVOKE=1 \
      -e TRAFFIC_HOST=10.50.96.1 -e TRAFFIC_PORT=9200 \
      -e TRAFFIC_SECONDS=20 -e TRAFFIC_TIMEOUT_S=40 \
      -e LOG_DIR=/tmp/ovpn-logs -e TUN_BASE=2000 \
      -e CONNECT_TOTAL="$N" -e SHARD_INDEX="$i" -e SHARD_COUNT="$SHARDS" \
      -e CONCURRENCY="$N" \
      -e HOLD_SECONDS=20 -e CONNECT_TIMEOUT_S=120 \
      -e VPN_HOST="$VPN_HOST" -e VPN_PORT="$VPN_PORT" -e VPN_PROTO=udp \
      -e PROFILES_DIR=/profiles \
      -e VPN_ROUTE=10.50.96.0/22 \
      --name "ovpn-chan-${N}-s${i}" \
      "$IMAGE" test_ovpn_vpn_soak.py >"$out" 2>/tmp/pi-vpn-chan-${N}-${i}.err &
    pids+=("$!")
    i=$((i + 1))
  done

  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  python3 - "$N" "$RESULTS" "${outs[@]}" <<'PY'
import json, sys
N = int(sys.argv[1])
results_path = sys.argv[2]
outs = sys.argv[3:]
connected = started = errors = 0
traffic_ok = traffic_bytes = 0
walls = []
shards = []
for path in outs:
    try:
        d = json.loads(open(path).read().strip() or "{}")
    except Exception as e:
        d = {"error": str(e), "path": path}
    shards.append(d)
    connected += int(d.get("connected") or 0)
    started += int(d.get("started") or 0)
    errors += int(d.get("errors") or 0)
    traffic_ok += int(d.get("traffic_ok") or 0)
    traffic_bytes += int(d.get("traffic_bytes") or 0)
    if d.get("traffic_wall_s"):
        walls.append(float(d["traffic_wall_s"]))
wall = max(walls) if walls else 0.0
agg = {
    "phase": "channel_connect",
    "N": N,
    "connected": connected,
    "started": started,
    "errors": errors,
    "ok_ratio": round(connected / N, 4) if N else 0,
    "traffic_ok": traffic_ok,
    "traffic_bytes": traffic_bytes,
    "traffic_agg_mbps": round(traffic_bytes * 8 / max(wall, 1e-6) / 1_000_000, 3) if traffic_bytes else None,
    "shards": len(outs),
    "shard_results": shards,
}
print(json.dumps(agg))
with open(results_path, "a") as f:
    f.write(json.dumps(agg) + "\n")
PY

  sample_pi "after_$N" | tee -a "$RESULTS"
  kill_mgmt_clients || true
  docker ps -aq --filter "name=ovpn-chan-${N}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
}

for N in "${LEVELS[@]}"; do
  run_level "$N" || echo "level $N failed (continuing)"
done

python3 - "$RESULTS" "$SUMMARY" <<'PY'
import json, sys
from pathlib import Path
results = Path(sys.argv[1])
summary = Path(sys.argv[2])
rows = []
for line in results.read_text().splitlines():
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("phase") == "channel_connect":
        rows.append(d)
lines = ["VPN channel ramp (pre-issued, no EasyRSA during connect)", "=" * 50]
for d in rows:
    lines.append(
        f"N={d['N']}: connected={d.get('connected')}/{d['N']} "
        f"started={d.get('started')} errors={d.get('errors')} "
        f"ratio={d.get('ok_ratio')} traffic_ok={d.get('traffic_ok')} "
        f"agg_mbps={d.get('traffic_agg_mbps')}"
    )
best = max(rows, key=lambda x: (x.get("connected") or 0, -(x.get("N") or 0)), default=None)
if best:
    lines.append("-" * 50)
    lines.append(f"best concurrent tunnels: {best.get('connected')} at target N={best.get('N')}")
text = "\n".join(lines) + "\n"
summary.write_text(text)
print(text)
PY

echo "=== channel ramp done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "results=$RESULTS summary=$SUMMARY"
