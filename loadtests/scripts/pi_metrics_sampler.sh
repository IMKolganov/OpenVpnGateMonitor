#!/bin/bash
# Append Pi load/mem/rss samples to OUT as JSON lines.
set -euo pipefail
INTERVAL="${INTERVAL:-2}"
OUT="${OUT:-/tmp/pi-soak-metrics.jsonl}"
HOST="${PI_HOST:-192.168.0.2}"
USER="${PI_USER:-rackot}"
: >"$OUT"
while true; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  payload=$(SSHPASS="${SSHPASS:?}" sshpass -e ssh -o StrictHostKeyChecking=no \
    -o PreferredAuthentications=password -o PubkeyAuthentication=no \
    "${USER}@${HOST}" 'python3 -c "
import json, os
load = os.getloadavg()
mem = {}
for line in open(\"/proc/meminfo\"):
    k, v = line.split(\":\", 1)
    mem[k] = int(v.strip().split()[0])
rss = {}
for pid in os.listdir(\"/proc\"):
    if not pid.isdigit():
        continue
    try:
        comm = open(f\"/proc/{pid}/comm\").read().strip()
        if comm not in (\"openvpn\", \"dotnet\"):
            continue
        for line in open(f\"/proc/{pid}/status\"):
            if line.startswith(\"VmRSS:\"):
                rss[f\"{comm}:{pid}\"] = int(line.split()[1])
                break
    except Exception:
        pass
print(json.dumps({\"load1\": load[0], \"load5\": load[1], \"mem_avail_kb\": mem.get(\"MemAvailable\", 0), \"mem_total_kb\": mem.get(\"MemTotal\", 0), \"rss_kb\": rss}))
"')
  echo "$payload" | python3 -c "import sys,json; o=json.load(sys.stdin); o['ts']='$ts'; print(json.dumps(o))" >>"$OUT"
  sleep "$INTERVAL"
done
