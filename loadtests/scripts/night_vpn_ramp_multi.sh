#!/usr/bin/env bash
# Overnight VPN connect ramp using several client containers in parallel.
# Does not touch production OpenVPN. Writes JSONL + final summary.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${RESULTS:-/tmp/pi-vpn-night-results.jsonl}"
SUMMARY="${SUMMARY:-/tmp/pi-vpn-night-summary.txt}"
LOG="${LOG:-/tmp/pi-vpn-night-ramp.log}"
IMAGE="${IMAGE:-local-ovpn-loadclient:latest}"
SHARDS="${SHARDS:-4}"
BACKEND_URL="${BACKEND_URL:-http://127.0.0.1:5581}"
OPENVPN_API_URL="${OPENVPN_API_URL:-http://192.168.0.2:5011}"
VPN_HOST="${VPN_HOST:-192.168.0.2}"
VPN_PORT="${VPN_PORT:-1296}"
PI_HOST="${PI_HOST:-192.168.0.2}"
PI_USER="${PI_USER:-rackot}"
SSHPASS="${SSHPASS:-Trinitron2005}"

LEVELS=(${LEVELS:-250 500 750 1000})

exec > >(tee -a "$LOG") 2>&1
echo "=== night ramp start $(date -u +%Y-%m-%dT%H:%M:%SZ) levels=${LEVELS[*]} shards=$SHARDS ==="
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

run_level() {
  local N="$1"
  local per=$((N / SHARDS))
  local rem=$((N % SHARDS))
  local run_base
  run_base="$(date +%s)-$N"
  echo "===== LEVEL N=$N shards=$SHARDS per~$per ====="
  sample_pi "before_$N" | tee -a "$RESULTS"
  kill_mgmt_clients || true

  local pids=()
  local outs=()
  local i=0
  while [ "$i" -lt "$SHARDS" ]; do
    local c=$per
    if [ "$i" -eq $((SHARDS - 1)) ]; then
      c=$((per + rem))
    fi
    local out="/tmp/pi-vpn-shard-${N}-${i}.json"
    outs+=("$out")
    rm -f "$out"
    docker run --rm --network host --cap-add NET_ADMIN --device /dev/net/tun \
      -v "$ROOT:/loadtests" -w /loadtests \
      -e BACKEND_URL="$BACKEND_URL" \
      -e OPENVPN_API_URL="$OPENVPN_API_URL" \
      -e VPN_HOST="$VPN_HOST" -e VPN_PORT="$VPN_PORT" -e VPN_PROTO=udp \
      -e CONCURRENCY="$c" -e ISSUE_PARALLELISM=8 \
      -e HOLD_SECONDS=45 -e CONNECT_TIMEOUT_S=180 \
      -e SKIP_TRAFFIC=1 \
      -e EASY_RSA_PATH=/openvpn-loadtest/easy-rsa \
      -e RUN_ID="${run_base}-s${i}" \
      -e PROFILES_DIR="/tmp/ovpn-night-${N}-s${i}" \
      --name "ovpn-night-${N}-s${i}" \
      "$IMAGE" test_ovpn_vpn_soak.py >"$out" 2>/tmp/pi-vpn-shard-${N}-${i}.err &
    pids+=("$!")
    i=$((i + 1))
  done

  local fail=0
  for pid in "${pids[@]}"; do
    if ! wait "$pid"; then
      fail=$((fail + 1))
    fi
  done

  python3 - "$N" "$RESULTS" "${outs[@]}" <<'PY'
import json, sys
N = int(sys.argv[1])
results_path = sys.argv[2]
outs = sys.argv[3:]
connected = started = errors = 0
shards = []
for path in outs:
    try:
        with open(path) as f:
            raw = f.read().strip()
        # Soak prints pretty JSON (indent=2). Parse the whole blob, not a
        # single "{" line — json.loads("{") is what produced the 0/0 summary.
        d = json.loads(raw) if raw else {}
    except Exception as e:
        d = {"error": str(e), "path": path}
    shards.append(d)
    connected += int(d.get("connected") or 0)
    started += int(d.get("started") or 0)
    errors += int(d.get("errors") or 0)
agg = {
    "phase": "connect_multi",
    "N": N,
    "connected": connected,
    "started": started,
    "errors": errors,
    "ok_ratio": round(connected / N, 4) if N else 0,
    "shards": len(outs),
    "shard_results": shards,
}
print(json.dumps(agg))
with open(results_path, "a") as f:
    f.write(json.dumps(agg) + "\n")
PY

  sample_pi "after_$N" | tee -a "$RESULTS"
  kill_mgmt_clients || true
  # drop leftover shard containers if any
  docker ps -aq --filter "name=ovpn-night-${N}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
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
    if d.get("phase") == "connect_multi":
        rows.append(d)
lines = ["VPN night ramp summary", "=" * 40]
for d in rows:
    lines.append(
        f"N={d['N']}: connected={d.get('connected')}/{d['N']} "
        f"started={d.get('started')} errors={d.get('errors')} "
        f"ratio={d.get('ok_ratio')}"
    )
best = max(rows, key=lambda x: (x.get("connected") or 0, -(x.get("N") or 0)), default=None)
if best:
    lines.append("-" * 40)
    lines.append(f"best concurrent tunnels: {best.get('connected')} at target N={best.get('N')}")
text = "\n".join(lines) + "\n"
summary.write_text(text)
print(text)
PY

echo "=== night ramp done $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "results=$RESULTS summary=$SUMMARY"
