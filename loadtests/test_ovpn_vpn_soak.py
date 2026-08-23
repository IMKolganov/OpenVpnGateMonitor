#!/usr/bin/env python3
"""VPN soak against OpenVPN manager node.

Modes (SOAK_MODE):
  full     — issue N profiles, connect, optional traffic, revoke (default)
  prepare  — issue N .ovpn files only (sequential-friendly; no tunnels)
  connect  — start clients from existing .ovpn in PROFILES_DIR (no EasyRSA)

Env:
  CONCURRENCY, ISSUE_PARALLELISM, CONNECT_TIMEOUT_S, HOLD_SECONDS
  SKIP_TRAFFIC=1, SKIP_REVOKE=1
  CONNECT_TOTAL, SHARD_INDEX, SHARD_COUNT  — slice a pre-issued pool
  VPN_ROUTE (default 10.50.96.0/22)
  TRAFFIC_HOST (default 10.50.96.1), TRAFFIC_PORT (9200), TRAFFIC_MB (4)
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path

import aiohttp

from common import (
    LoadConfig,
    LatencyStats,
    add_ovpn_file,
    bounded_gather,
    download_ovpn_file,
    fetch_openvpn_dev_token,
    print_summary,
    revoke_ovpn_file,
)

TUN_RE = re.compile(r"TUN/TAP device (tun\d+) opened")


def cidr_netmask(cidr: str) -> tuple[str, str]:
    net, bits_s = cidr.split("/", 1)
    bits = int(bits_s)
    mask_int = (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
    mask = ".".join(str((mask_int >> s) & 0xFF) for s in (24, 16, 8, 0))
    return net, mask


def rewrite_remote(ovpn_text: str, host: str, port: int, proto: str) -> str:
    lines = []
    for line in ovpn_text.splitlines():
        if line.startswith("remote "):
            lines.append(f"remote {host} {port}")
        elif line.startswith("proto "):
            lines.append(f"proto {proto}")
        else:
            lines.append(line)
    joined = "\n".join(lines)
    # Avoid fighting over default route when many clients share one host.
    if "route-nopull" not in joined:
        lines.append("route-nopull")
    if "pull-filter ignore redirect-gateway" not in joined:
        lines.append("pull-filter ignore redirect-gateway")
    vpn_route = os.getenv("VPN_ROUTE", "10.50.96.0/22").strip()
    if vpn_route:
        net, mask = cidr_netmask(vpn_route)
        route_line = f"route {net} {mask}"
        if not any(l.startswith("route ") and net in l for l in lines):
            lines.append(route_line)
    return "\n".join(lines) + "\n"


def start_openvpn(config_path: Path, log_path: Path, dev: str | None = None) -> subprocess.Popen:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "openvpn",
        "--config",
        str(config_path),
        "--log",
        str(log_path),
        "--verb",
        "3",
        "--connect-retry-max",
        "3",
        "--connect-timeout",
        "15",
    ]
    if dev:
        cmd.extend(["--dev", dev, "--dev-type", "tun"])
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_connected(log_path: Path, proc: subprocess.Popen, timeout_s: float) -> tuple[bool, str | None]:
    deadline = time.time() + timeout_s
    needle = "Initialization Sequence Completed"
    while time.time() < deadline:
        if log_path.exists():
            text = log_path.read_text(errors="ignore")
            if needle in text:
                m = TUN_RE.search(text)
                return True, (m.group(1) if m else None)
        if proc.poll() is not None:
            return False, None
        time.sleep(0.25)
    return False, None


def wait_all_connected(items: list[dict], timeout_s: float) -> None:
    """Poll every client log until connected, dead, or timeout — not one-by-one."""
    needle = "Initialization Sequence Completed"
    deadline = time.time() + timeout_s
    pending = list(items)
    while pending and time.time() < deadline:
        still: list[dict] = []
        for item in pending:
            log: Path = item["log"]
            proc: subprocess.Popen = item["proc"]
            text = log.read_text(errors="ignore") if log.exists() else ""
            if needle in text:
                m = TUN_RE.search(text)
                item["connected"] = True
                item["tun"] = m.group(1) if m else None
            elif proc.poll() is not None:
                item["connected"] = False
            else:
                still.append(item)
        pending = still
        if pending:
            time.sleep(0.25)
    for item in pending:
        item["connected"] = False


def tun_ipv4(tun: str) -> str | None:
    try:
        out = subprocess.check_output(["ip", "-4", "-o", "addr", "show", "dev", tun], text=True)
    except Exception:  # noqa: BLE001
        return None
    # 2: tun0    inet 10.50.99.2/24 ...
    parts = out.split()
    for i, p in enumerate(parts):
        if p == "inet" and i + 1 < len(parts):
            return parts[i + 1].split("/")[0]
    return None


def upload_via_tun(tun: str, host: str, port: int, nbytes: int) -> dict:
    src = tun_ipv4(tun)
    if not src:
        return {"ok": False, "error": f"no ipv4 on {tun}"}
    # Ensure host route via this tun (32-bit) so bind+connect works with many clients.
    subprocess.run(
        ["ip", "route", "replace", f"{host}/32", "dev", tun, "src", src],
        check=False,
        capture_output=True,
    )
    chunk = os.urandom(min(65536, max(nbytes, 65536)))
    sent = 0
    t0 = time.perf_counter()
    duration = float(os.getenv("TRAFFIC_SECONDS", "0"))
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, tun.encode() + b"\0")
        sock.settimeout(max(float(os.getenv("TRAFFIC_TIMEOUT_S", "60")), duration + 15.0))
        sock.bind((src, 0))
        sock.connect((host, port))
        if duration > 0:
            deadline = t0 + duration
            while time.perf_counter() < deadline:
                n = sock.send(chunk)
                if n <= 0:
                    break
                sent += n
            ok = sent > 0
        else:
            while sent < nbytes:
                n = sock.send(chunk[: min(len(chunk), nbytes - sent)])
                if n <= 0:
                    break
                sent += n
            ok = sent == nbytes
        sock.close()
        elapsed = max(time.perf_counter() - t0, 1e-6)
        return {
            "ok": ok,
            "bytes": sent,
            "mbps": round(sent * 8 / elapsed / 1_000_000, 3),
            "tun": tun,
            "src": src,
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)[:200], "tun": tun, "src": src, "bytes": sent}


def load_preissued(cfg: LoadConfig) -> list[dict]:
    files = sorted(cfg.profiles_dir.glob("*.ovpn"))
    shard_count = max(1, int(os.getenv("SHARD_COUNT", "1")))
    shard_index = int(os.getenv("SHARD_INDEX", "0"))
    total = int(os.getenv("CONNECT_TOTAL", str(cfg.concurrency)))
    pool = files[:total]
    start = 0
    if shard_count > 1:
        per = len(pool) // shard_count
        start = shard_index * per
        end = len(pool) if shard_index == shard_count - 1 else start + per
        pool = pool[start:end]
    log_dir = Path(os.getenv("LOG_DIR", "/tmp/ovpn-logs"))
    log_dir.mkdir(parents=True, exist_ok=True)
    tun_base = int(os.getenv("TUN_BASE", "2000"))
    items = []
    for j, path in enumerate(pool):
        cn = path.stem
        gi = start + j
        items.append(
            {
                "path": path,
                "cn": cn,
                "log": log_dir / f"{cn}.log",
                "dev": f"tun{tun_base + gi}",
                "meta": None,
            }
        )
    return items


async def issue_profiles(session, cfg: LoadConfig, stats: LatencyStats) -> list[dict]:
    issued: list[dict] = []
    parallelism = min(int(os.getenv("ISSUE_PARALLELISM", "1")), max(1, cfg.concurrency))
    tok: list[str] = [await fetch_openvpn_dev_token(session, cfg)]
    last_refresh = [time.monotonic()]

    async def refresh_token() -> None:
        tok[0] = await fetch_openvpn_dev_token(session, cfg)
        last_refresh[0] = time.monotonic()
        print("prepare refreshed JWT", file=sys.stderr, flush=True)

    async def one(i: int) -> None:
        cn = f"vpnsoak-{cfg.run_id}-{i}"
        path = cfg.profiles_dir / f"{cn}.ovpn"
        if path.exists():
            issued.append({"meta": None, "path": path, "cn": cn, "log": cfg.profiles_dir / f"{cn}.log"})
            return
        last_exc: Exception | None = None
        for attempt in range(3):
            if time.monotonic() - last_refresh[0] > 180:
                try:
                    await refresh_token()
                except Exception as exc:  # noqa: BLE001
                    last_exc = exc
                    continue
            try:
                meta = await add_ovpn_file(session, cfg, tok[0], cn)
                raw = await download_ovpn_file(session, cfg, tok[0], meta)
                text = rewrite_remote(
                    raw.decode("utf-8", errors="replace"), cfg.vpn_host, cfg.vpn_port, cfg.vpn_proto
                )
                path.write_text(text)
                issued.append({"meta": meta, "path": path, "cn": cn, "log": cfg.profiles_dir / f"{cn}.log"})
                if (len(issued) % 25) == 0 or len(issued) == 1:
                    print(f"prepare {len(issued)}/{cfg.concurrency}", file=sys.stderr, flush=True)
                return
            except Exception as exc:  # noqa: BLE001
                last_exc = exc
                if "401" in str(exc) and attempt < 2:
                    print(f"prepare 401, refresh JWT ({cn})", file=sys.stderr, flush=True)
                    try:
                        await refresh_token()
                    except Exception as refresh_exc:  # noqa: BLE001
                        last_exc = refresh_exc
                    continue
                break
        stats.add_err(f"issue {cn}: {last_exc}")
        print(f"prepare FAIL {cn}: {last_exc}", file=sys.stderr, flush=True)

    await bounded_gather([one(i) for i in range(cfg.concurrency)], limit=parallelism)
    return issued


async def main() -> int:
    mode = os.getenv("SOAK_MODE", "full").strip().lower()
    if mode != "prepare" and shutil.which("openvpn") is None:
        raise SystemExit("openvpn binary not found")

    cfg = LoadConfig()
    cfg.profiles_dir.mkdir(parents=True, exist_ok=True)
    stats = LatencyStats()
    connected = 0
    traffic_ok = 0
    traffic_mbps: list[float] = []
    traffic_bytes = 0
    traffic_wall = 0.0

    skip_traffic = os.getenv("SKIP_TRAFFIC", "0") == "1"
    skip_revoke = os.getenv("SKIP_REVOKE", "1" if mode == "connect" else "0") == "1"
    traffic_host = os.getenv("TRAFFIC_HOST", "10.50.96.1")
    traffic_port = int(os.getenv("TRAFFIC_PORT", "9200"))
    traffic_mb = float(os.getenv("TRAFFIC_MB", "4"))
    nbytes = max(1, int(traffic_mb * 1024 * 1024))

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=600)
    issued: list[dict] = []
    wall0 = time.perf_counter()

    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = None
        if mode != "connect":
            token = await fetch_openvpn_dev_token(session, cfg)

        if mode == "connect":
            issued = load_preissued(cfg)
            if not issued:
                raise SystemExit(f"no .ovpn files in {cfg.profiles_dir}")
        else:
            issued = await issue_profiles(session, cfg, stats)

        if mode == "prepare":
            wall = time.perf_counter() - wall0
            summary = stats.summary("ovpn_prepare", wall)
            summary["connected"] = 0
            summary["started"] = len(issued)
            summary["concurrency"] = cfg.concurrency
            summary["mode"] = mode
            print_summary(summary)
            return 0 if issued else 1

        wall0 = time.perf_counter()
        for i, item in enumerate(issued):
            item["proc"] = start_openvpn(item["path"], item["log"], item.get("dev"))
            if i % 20 == 19:
                time.sleep(0.05)

        connect_timeout = float(os.getenv("CONNECT_TIMEOUT_S", "90"))
        await asyncio.to_thread(wait_all_connected, issued, connect_timeout)

        live: list[dict] = []
        for item in issued:
            if item.get("connected"):
                connected += 1
                live.append(item)
                stats.add_ok(0.0)
            else:
                stats.add_err(f"connect failed: {item['cn']}")
        print(f"connected {connected}/{len(issued)}", file=sys.stderr, flush=True)

        hold = float(os.getenv("HOLD_SECONDS", str(cfg.hold_seconds)))
        await asyncio.sleep(max(0.0, hold))

        if not skip_traffic and live:
            parallel = int(os.getenv("TRAFFIC_PARALLEL", str(len(live))))
            parallel = max(0, min(parallel, len(live)))
            runners = [x for x in live[:parallel] if x.get("tun")]
            t_tr = time.perf_counter()

            async def traffic_one(item: dict) -> None:
                nonlocal traffic_ok, traffic_bytes
                res = await asyncio.to_thread(
                    upload_via_tun, item["tun"], traffic_host, traffic_port, nbytes
                )
                item["traffic"] = res
                if res.get("ok"):
                    traffic_ok += 1
                    traffic_mbps.append(float(res["mbps"]))
                    traffic_bytes += int(res.get("bytes") or 0)
                else:
                    stats.add_err(f"traffic {item['cn']}: {res.get('error')}")

            await asyncio.gather(*[traffic_one(it) for it in runners])
            traffic_wall = time.perf_counter() - t_tr

        for item in issued:
            proc: subprocess.Popen | None = item.get("proc")
            if proc is None or proc.poll() is not None:
                continue
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

        if not skip_revoke and token is not None:
            for item in issued:
                if not item.get("meta"):
                    continue
                try:
                    await revoke_ovpn_file(session, cfg, token, item["meta"])
                except Exception as exc:  # noqa: BLE001
                    stats.add_err(f"revoke {item['cn']}: {exc}")

    wall = time.perf_counter() - wall0 if issued else 0.0
    summary = stats.summary("ovpn_vpn_soak", wall)
    summary["connected"] = connected
    summary["started"] = len(issued)
    summary["concurrency"] = cfg.concurrency
    summary["mode"] = mode
    summary["traffic_ok"] = traffic_ok
    summary["traffic_bytes"] = traffic_bytes
    summary["traffic_wall_s"] = round(traffic_wall, 2)
    summary["traffic_mbps_sum"] = round(sum(traffic_mbps), 3) if traffic_mbps else None
    summary["traffic_mbps_avg"] = round(sum(traffic_mbps) / len(traffic_mbps), 3) if traffic_mbps else None
    ordered = sorted(traffic_mbps)
    ntr = len(ordered)
    summary["traffic_mbps_p50"] = round(ordered[int(0.50 * (ntr - 1))], 3) if ntr else None
    summary["traffic_mbps_p95"] = round(ordered[int(0.95 * (ntr - 1))], 3) if ntr else None
    summary["traffic_agg_mbps"] = (
        round(traffic_bytes * 8 / max(traffic_wall, 1e-6) / 1_000_000, 3) if traffic_bytes else None
    )
    print_summary(summary)
    result_file = os.getenv("RESULT_FILE")
    if result_file:
        Path(result_file).write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
    return 0 if connected > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
