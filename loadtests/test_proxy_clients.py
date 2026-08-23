#!/usr/bin/env python3
"""150 concurrent WebSocket sessions on OpenVPN manager /api/proxy with distinct clientRef (=CN)."""

from __future__ import annotations

import asyncio
import time
from urllib.parse import urlencode

import aiohttp

from common import LoadConfig, LatencyStats, print_summary


async def one_client(cfg: LoadConfig, index: int, stats: LatencyStats) -> None:
    cn = f"proxy-{cfg.run_id}-{index}"
    qs = urlencode({"mode": cfg.vpn_proto if cfg.vpn_proto in ("tcp", "udp") else "udp", "clientRef": cn})
    base = cfg.openvpn_api_url.replace("http://", "ws://").replace("https://", "wss://")
    url = f"{base}/api/proxy?{qs}"
    t0 = time.perf_counter()
    try:
        timeout = aiohttp.ClientTimeout(total=cfg.hold_seconds + 30)
        async with aiohttp.ClientSession(timeout=timeout) as session:
            async with session.ws_connect(url, heartbeat=20) as ws:
                # Hold the session open; optional tiny binary probe.
                try:
                    await ws.send_bytes(b"\x00")
                except Exception:  # noqa: BLE001
                    pass
                await asyncio.sleep(cfg.hold_seconds)
                await ws.close()
        stats.add_ok(time.perf_counter() - t0)
    except Exception as exc:  # noqa: BLE001
        stats.add_err(f"{cn}: {exc}")


async def main() -> int:
    cfg = LoadConfig()
    stats = LatencyStats()
    wall0 = time.perf_counter()
    await asyncio.gather(*[one_client(cfg, i, stats) for i in range(cfg.concurrency)])
    wall = time.perf_counter() - wall0
    summary = stats.summary("proxy_clients", wall)
    summary["concurrency"] = cfg.concurrency
    summary["note"] = (
        "/api/proxy is intentionally JWT-excluded; clientRef distinguishes CNs in telemetry. "
        "In production restrict the node by network or require JWT if publicly reachable."
    )
    print_summary(summary)
    return 0 if summary["ok"] > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
