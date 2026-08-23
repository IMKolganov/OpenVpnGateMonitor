#!/usr/bin/env bash
# Diagnostic: separate session capacity vs shared throughput vs path ceiling.
#
# Phases:
#   A  LAN baseline     — TCP to Pi:9200 without VPN (raw path Mbps)
#   B  VPN fat flows    — N=1,2,4 max traffic via tunnels (crypto/VPN ceiling)
#   C  Session capacity — connect/hold only at N=100,250,500 (no traffic)
#   D  Fairness         — N=50 all clients traffic 12s (shared pie)
#
# Writes JSONL + verdict to OUT_DIR (default /tmp/ovpn-diag).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/ovpn-diag}"
PROFILES_DIR="${PROFILES_DIR:-/tmp/ovpn-preissued}"
IMAGE="${IMAGE:-local-ovpn-loadclient:latest}"
PI_HOST="${PI_HOST:-192.168.0.2}"
VPN_HOST="${VPN_HOST:-$PI_HOST}"
VPN_PORT="${VPN_PORT:-1296}"
SINK_LAN="${SINK_LAN:-$PI_HOST}"
SINK_VPN="${SINK_VPN:-10.50.96.1}"
SINK_PORT="${SINK_PORT:-9200}"
VPN_ROUTE="${VPN_ROUTE:-10.50.96.0/22}"

mkdir -p "$OUT_DIR"
: >"$OUT_DIR/events.jsonl"
SUMMARY="$OUT_DIR/summary.txt"
: >"$SUMMARY"

log() { printf '%s\n' "$*" | tee -a "$SUMMARY"; }
event() {
  python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1" >>"$OUT_DIR/events.jsonl"
}

need_profiles() {
  local n="$1"
  local have
  have=$(ls "$PROFILES_DIR"/*.ovpn 2>/dev/null | wc -l)
  if (( have < n )); then
    log "FAIL: need >=$n profiles, have $have in $PROFILES_DIR"
    exit 1
  fi
}

lan_baseline() {
  local secs="${1:-12}"
  log ""
  log "===== A  LAN baseline (no VPN) → ${SINK_LAN}:${SINK_PORT} ${secs}s ====="
  python3 - "$SINK_LAN" "$SINK_PORT" "$secs" "$OUT_DIR/lan_baseline.json" <<'PY'
import json, os, socket, sys, time, urllib.request
host, port, secs, out = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
chunk = os.urandom(65536)
sent = 0
err = None
mode = "tcp_sink"
t0 = time.perf_counter()
try:
    s = socket.create_connection((host, port), timeout=3)
    s.settimeout(5)
    deadline = t0 + secs
    while time.perf_counter() < deadline:
        n = s.send(chunk)
        if n <= 0:
            break
        sent += n
    s.close()
except Exception as e:
    err = str(e)[:200]
    # Port 9200 often firewalled on LAN while reachable via VPN subnet.
    mode = "http_fallback"
    sent = 0
    t0 = time.perf_counter()
    deadline = t0 + secs
    http_err = None
    while time.perf_counter() < deadline:
        try:
            with urllib.request.urlopen(f"http://{host}:5011/swagger/index.html", timeout=5) as r:
                while True:
                    b = r.read(65536)
                    if not b:
                        break
                    sent += len(b)
        except Exception as he:
            http_err = str(he)[:160]
            break
    if sent <= 0:
        err = f"tcp_sink:{err}; http:{http_err}"
    else:
        err = f"tcp_sink_blocked:{err}; used_http_get_swagger"

wall = max(time.perf_counter() - t0, 1e-6)
mbps = round(sent * 8 / wall / 1_000_000, 3)
res = {
    "phase": "A_lan",
    "mode": mode,
    "ok": sent > 0,
    "bytes": sent,
    "wall_s": round(wall, 2),
    "agg_mbps": mbps,
    "error": err,
    "target": f"{host}:{port}",
    "note": "tcp_sink = raw fill of VPN sink on LAN; http_fallback = weak lower bound (small responses)",
}
json.dump(res, open(out, "w"), indent=2)
print(json.dumps(res))
PY
  event "$(cat "$OUT_DIR/lan_baseline.json")"
  python3 - "$OUT_DIR/lan_baseline.json" <<'PY' | tee -a "$SUMMARY"
import json,sys
d=json.load(open(sys.argv[1]))
print(f"LAN mode={d.get('mode')} agg_mbps={d.get('agg_mbps')} bytes={d.get('bytes')} ok={d.get('ok')} err={d.get('error')}")
if d.get("mode") == "tcp_sink":
    print("→ потолок пути workstation→Pi БЕЗ OpenVPN (линк/CPU sink/стек).")
else:
    print("→ TCP :9200 с LAN недоступен (firewall?). HTTP fallback — слабая оценка, не сравнивать с VPN fill.")
    print("→ для сравнения «канал vs VPN» опирайся на фазу B (1–4 туннеля) и прошлый channel-ramp ~60–75 Mbps.")
PY
}

run_soak() {
  local label="$1" n="$2" skip_traffic="$3" traffic_parallel="$4" tun_base="$5" hold="$6" traffic_secs="$7"
  local out="$OUT_DIR/$label"
  rm -rf "$out"
  mkdir -p "$out/logs"
  docker rm -f "ovpn-diag-$label" 2>/dev/null || true
  docker run --rm --network host --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$ROOT:/loadtests" \
    -v "$PROFILES_DIR:/profiles:ro" \
    -v "$out:/out" \
    -w /loadtests \
    -e SOAK_MODE=connect \
    -e SKIP_TRAFFIC="$skip_traffic" \
    -e SKIP_REVOKE=1 \
    -e TRAFFIC_HOST="$SINK_VPN" \
    -e TRAFFIC_PORT="$SINK_PORT" \
    -e TRAFFIC_SECONDS="$traffic_secs" \
    -e TRAFFIC_TIMEOUT_S=$((traffic_secs + 20)) \
    -e TRAFFIC_PARALLEL="$traffic_parallel" \
    -e LOG_DIR=/out/logs \
    -e TUN_BASE="$tun_base" \
    -e RESULT_FILE=/out/result.json \
    -e CONNECT_TOTAL="$n" \
    -e SHARD_INDEX=0 -e SHARD_COUNT=1 \
    -e CONCURRENCY="$n" \
    -e HOLD_SECONDS="$hold" \
    -e CONNECT_TIMEOUT_S=120 \
    -e VPN_HOST="$VPN_HOST" -e VPN_PORT="$VPN_PORT" -e VPN_PROTO=udp \
    -e PROFILES_DIR=/profiles -e VPN_ROUTE="$VPN_ROUTE" \
    --name "ovpn-diag-$label" \
    "$IMAGE" test_ovpn_vpn_soak.py \
    >"$out/stdout.json" 2>"$out/stderr.log" || true
  if [[ ! -f "$out/result.json" ]]; then
    log "$label NO_JSON stderr=$(tr '\n' ' ' <"$out/stderr.log" | head -c 200)"
    return 1
  fi
  python3 - "$out/result.json" "$label" "$n" <<'PY' | tee -a "$SUMMARY"
import json,sys
d=json.load(open(sys.argv[1])); label,n=sys.argv[2],sys.argv[3]
print(f"{label} connected={d.get('connected')}/{d.get('started')} err={d.get('errors')} "
      f"traffic_ok={d.get('traffic_ok')} agg_mbps={d.get('traffic_agg_mbps')} "
      f"p50={d.get('traffic_mbps_p50')} p95={d.get('traffic_mbps_p95')} wall={d.get('wall_s')}")
open(sys.argv[1].replace("result.json","event.json"),"w").write(json.dumps({
  "phase": label, "n": int(n), **{k:d.get(k) for k in
    ["connected","started","errors","traffic_ok","traffic_agg_mbps","traffic_mbps_p50","traffic_mbps_p95","traffic_bytes","wall_s"]}
}))
PY
  event "$(cat "$out/event.json")"
}

verdict() {
  log ""
  log "===== VERDICT ====="
  python3 - "$OUT_DIR" <<'PY' | tee -a "$SUMMARY"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
lan = json.loads((root/"lan_baseline.json").read_text()) if (root/"lan_baseline.json").exists() else None
events = []
for p in sorted(root.glob("*/event.json")):
    events.append(json.loads(p.read_text()))
fat = [e for e in events if e["phase"].startswith("B_vpn")]
cap = [e for e in events if e["phase"].startswith("C_cap")]
fair = [e for e in events if e["phase"].startswith("D_fair")]

print()
if lan and lan.get("ok") and lan.get("mode") == "tcp_sink":
    print(f"1) Сырой канал (LAN TCP→sink): ~{lan['agg_mbps']} Mbps")
    print("   Если здесь уже ~70–100 — узкое место путь/NIC/sink, не OpenVPN.")
elif lan and lan.get("ok"):
    print(f"1) LAN TCP→sink закрыт; HTTP fallback ~{lan['agg_mbps']} Mbps (не потолок канала).")
    print("   Сравнивай канал с фазой B (VPN fill), не с HTTP.")
elif lan:
    print(f"1) LAN baseline FAILED: {lan.get('error')}")
else:
    print("1) LAN baseline: нет данных")

if fat:
    best = max((e.get("traffic_agg_mbps") or 0) for e in fat)
    print(f"2) Потолок через VPN (1–4 туннеля): ~{best} Mbps суммарно")
    if lan and lan.get("ok") and lan.get("mode") == "tcp_sink" and lan.get("agg_mbps"):
        ratio = best / lan["agg_mbps"]
        print(f"   VPN/LAN ≈ {ratio:.0%} — остаток уходит в шифрование OpenVPN + tun + Pi CPU.")
    for e in fat:
        print(f"   {e['phase']}: connected={e.get('connected')}/{e.get('started')} agg={e.get('traffic_agg_mbps')} p50={e.get('traffic_mbps_p50')}")

if fair:
    e = fair[0]
    print(f"3) Fairness N={e.get('n')}: agg={e.get('traffic_agg_mbps')} p50={e.get('traffic_mbps_p50')} Mbps/client")
    print("   Если agg ≈ как у 1–4 потоков, а p50 падает — это дележ одного пирога, не «каждый туннель сам тормозит».")

if cap:
    print("4) Ёмкость сессий (без трафика):")
    for e in cap:
        ok = e.get("connected") or 0
        n = e.get("n") or e.get("started") or 0
        pct = (100*ok/n) if n else 0
        print(f"   N={n}: {ok}/{n} ({pct:.0f}%)")
    print("   Падение ratio при росте N — лимит процессов/fd/CPU handshake на Pi, не Mbps.")

print()
print("Интерпретация:")
print("  • скорость на клиента ↓ при N↑ при стабильном agg → канал (shared throughput)")
print("  • connect fail ↑ при N↑ без трафика → ёмкость туннелей")
print("  • LAN >> VPN agg → узкое место OpenVPN/CPU на Pi")
print("  • LAN ≈ VPN agg → узкое место уже до VPN (линк/путь)")
print(f"Артефакты: {root}")
PY
}

need_profiles 500
log "profiles=$(ls "$PROFILES_DIR"/*.ovpn | wc -l) OUT_DIR=$OUT_DIR"
docker rm -f ovpn-diag-B_vpn1 ovpn-diag-B_vpn2 ovpn-diag-B_vpn4 ovpn-diag-C_cap100 ovpn-diag-C_cap250 ovpn-diag-C_cap500 ovpn-diag-D_fair50 2>/dev/null || true

lan_baseline 12

log ""
log "===== B  VPN fat flows (max traffic) ====="
run_soak B_vpn1 1 0 1 20000 3 15
run_soak B_vpn2 2 0 2 20100 3 15
run_soak B_vpn4 4 0 4 20200 3 15

log ""
log "===== C  Session capacity (SKIP_TRAFFIC=1) ====="
run_soak C_cap100 100 1 0 21000 8 0
run_soak C_cap250 250 1 0 22000 8 0
run_soak C_cap500 500 1 0 23000 8 0

log ""
log "===== D  Fairness N=50 all traffic ====="
run_soak D_fair50 50 0 50 24000 5 12

verdict
log "DONE"
