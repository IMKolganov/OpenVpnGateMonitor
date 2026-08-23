#!/usr/bin/env python3
"""Drive bulk traffic through /api/proxy against a TCP/UDP echo stub on PORT.

Use compose profile `proxy-stub` so the OpenVPN manager container runs echo on PORT
instead of openvpn (see scripts/entrypoint-proxy-stub.sh).
"""

from __future__ import annotations

import asyncio
import os
import time
from urllib.parse import urlencode

import aiohttp

from common import LoadConfig, LatencyStats, print_summary


async def pump(cfg: LoadConfig, index: int, stats: LatencyStats, payload: bytes) -> int:
    cn = f"stub-{cfg.run_id}-{index}"
    mode = os.getenv("PROXY_MODE", "tcp")
    qs = urlencode({"mode": mode, "clientRef": cn})
    base = cfg.openvpn_api_url.replace("http://", "ws://").replace("https://", "wss://")
    url = f"{base}/api/proxy?{qs}"
    t0 = time.perf_counter()
    recv = 0
    try:
        timeout = aiohttp.ClientTimeout(total=120)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.ws_connect(url, heartbeat=20, max_msg_size=16 * 1024 * 1024) as ws:
                view = memoryview(payload)
                offset = 0
                chunk_size = 16 * 1024
                while offset < len(payload):
                    end = min(offset + chunk_size, len(payload))
                    await ws.send_bytes(view[offset:end])
                    offset = end
                remaining = len(payload)
                while remaining > 0:
                    msg = await asyncio.wait_for(ws.receive(), timeout=30)
                    if msg.type == aiohttp.WSMsgType.BINARY:
                        recv += len(msg.data)
                        remaining -= len(msg.data)
                    elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
                        break
                    else:
                        break
                await ws.close()
        stats.add_ok(time.perf_counter() - t0)
        return recv
    except Exception as exc:  # noqa: BLE001
        stats.add_err(f"{cn}: {exc}")
        return 0


async def main() -> int:
    cfg = LoadConfig()
    stats = LatencyStats()
    mb = float(os.getenv("PAYLOAD_MB", "1"))
    payload = os.urandom(max(1, int(mb * 1024 * 1024)))
    wall0 = time.perf_counter()
    results = await asyncio.gather(*[pump(cfg, i, stats, payload) for i in range(cfg.concurrency)])
    wall = time.perf_counter() - wall0
    total_bytes = sum(results)
    summary = stats.summary("proxy_traffic_stub", wall)
    summary["concurrency"] = cfg.concurrency
    summary["payload_mb"] = mb
    summary["total_bytes_echoed"] = total_bytes
    summary["approx_mbps"] = round((total_bytes * 8) / wall / 1_000_000, 2) if wall > 0 else None
    print_summary(summary)
    return 0 if summary["ok"] > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
