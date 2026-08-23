#!/usr/bin/env python3
"""Issue N unique CNs, then start N openvpn client processes and wait for connect.

Requires: openvpn binary, NET_ADMIN, /dev/net/tun (see Dockerfile.client).
"""

from __future__ import annotations

import asyncio
import os
import shutil
import signal
import subprocess
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


def rewrite_remote(ovpn_text: str, host: str, port: int, proto: str) -> str:
    lines = []
    for line in ovpn_text.splitlines():
        if line.startswith("remote "):
            lines.append(f"remote {host} {port}")
        elif line.startswith("proto "):
            lines.append(f"proto {proto}")
        else:
            lines.append(line)
    return "\n".join(lines) + "\n"


def start_openvpn(config_path: Path, log_path: Path) -> subprocess.Popen:
    return subprocess.Popen(
        [
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
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def wait_connected(log_path: Path, proc: subprocess.Popen, timeout_s: float) -> bool:
    deadline = time.time() + timeout_s
    needle = "Initialization Sequence Completed"
    while time.time() < deadline:
        if log_path.exists():
            text = log_path.read_text(errors="ignore")
            if needle in text:
                return True
        if proc.poll() is not None:
            return False
        time.sleep(0.25)
    return False


async def main() -> int:
    if shutil.which("openvpn") is None:
        raise SystemExit("openvpn binary not found — use loadtests/Dockerfile.client")

    cfg = LoadConfig()
    cfg.profiles_dir.mkdir(parents=True, exist_ok=True)
    stats = LatencyStats()
    connected = 0

    timeout = aiohttp.ClientTimeout(total=180)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await fetch_openvpn_dev_token(session, cfg)
        issued: list[dict] = []

        async def one(i: int) -> None:
            cn = f"native-{cfg.run_id}-{i}"
            try:
                meta = await add_ovpn_file(session, cfg, token, cn)
                raw = await download_ovpn_file(session, cfg, token, meta)
                text = rewrite_remote(
                    raw.decode("utf-8", errors="replace"), cfg.vpn_host, cfg.vpn_port, cfg.vpn_proto
                )
                path = cfg.profiles_dir / f"{cn}.ovpn"
                path.write_text(text)
                issued.append({"meta": meta, "path": path, "cn": cn, "log": cfg.profiles_dir / f"{cn}.log"})
            except Exception as exc:  # noqa: BLE001
                stats.add_err(f"issue {cn}: {exc}")

        await bounded_gather([one(i) for i in range(cfg.concurrency)], limit=min(32, cfg.concurrency))

        wall0 = time.perf_counter()
        for item in issued:
            item["proc"] = start_openvpn(item["path"], item["log"])

        connect_timeout = float(os.getenv("CONNECT_TIMEOUT_S", "60"))
        for item in issued:
            t0 = time.perf_counter()
            ok = await asyncio.to_thread(wait_connected, item["log"], item["proc"], connect_timeout)
            if ok:
                connected += 1
                stats.add_ok(time.perf_counter() - t0)
            else:
                stats.add_err(f"connect failed: {item['cn']}")

        await asyncio.sleep(cfg.hold_seconds)

        for item in issued:
            proc: subprocess.Popen = item["proc"]
            if proc.poll() is None:
                proc.send_signal(signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()

        for item in issued:
            try:
                await revoke_ovpn_file(session, cfg, token, item["meta"])
            except Exception as exc:  # noqa: BLE001
                stats.add_err(f"revoke {item['cn']}: {exc}")

    wall = time.perf_counter() - wall0 if issued else 0.0
    summary = stats.summary("ovpn_native_connect", wall)
    summary["connected"] = connected
    summary["started"] = len(issued)
    summary["concurrency"] = cfg.concurrency
    print_summary(summary)
    return 0 if connected > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
