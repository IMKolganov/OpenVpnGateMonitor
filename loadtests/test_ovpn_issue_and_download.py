#!/usr/bin/env python3
"""Concurrent create + download-while-issuing against OpenVPN manager /api/ovpn-files.

Download starts in parallel with add (predicted path). The API waits if the cert
is still being issued instead of returning a missing-file error.
"""

from __future__ import annotations

import asyncio
import time

import aiohttp

from common import (
    LoadConfig,
    LatencyStats,
    add_ovpn_file,
    bounded_gather,
    download_ovpn_file,
    fetch_openvpn_dev_token,
    predicted_ovpn_meta,
    print_summary,
    revoke_ovpn_file,
)


async def worker(
    session: aiohttp.ClientSession,
    cfg: LoadConfig,
    token: str,
    index: int,
    stats: LatencyStats,
    issued: list,
) -> None:
    cn = f"load-{cfg.run_id}-{index}"
    predicted = predicted_ovpn_meta(cfg, cn)
    t0 = time.perf_counter()
    try:
        add_task = asyncio.create_task(add_ovpn_file(session, cfg, token, cn))
        # Start download slightly after add so Begin() is registered, but still
        # while EasyRSA / file write may be in progress.
        await asyncio.sleep(0.05)
        download_task = asyncio.create_task(download_ovpn_file(session, cfg, token, predicted))

        meta, content = await asyncio.gather(add_task, download_task)
        if not content or len(content) < 64:
            raise RuntimeError(f"empty ovpn for {cn}")
        cfg.profiles_dir.mkdir(parents=True, exist_ok=True)
        path = cfg.profiles_dir / f"{cn}.ovpn"
        path.write_bytes(content)
        issued.append({"meta": meta, "path": str(path), "cn": cn})
        stats.add_ok(time.perf_counter() - t0)
    except Exception as exc:  # noqa: BLE001 — aggregate errors for load report
        stats.add_err(f"{cn}: {exc}")


async def main() -> int:
    cfg = LoadConfig()
    stats = LatencyStats()
    issued: list = []

    timeout = aiohttp.ClientTimeout(total=None, sock_connect=30, sock_read=600)
    async with aiohttp.ClientSession(timeout=timeout) as session:
        token = await fetch_openvpn_dev_token(session, cfg)
        wall0 = time.perf_counter()
        await bounded_gather(
            [worker(session, cfg, token, i, stats, issued) for i in range(cfg.concurrency)],
            limit=cfg.issue_parallelism,
        )
        wall = time.perf_counter() - wall0

        for item in issued:
            try:
                await revoke_ovpn_file(session, cfg, token, item["meta"])
            except Exception as exc:  # noqa: BLE001
                stats.add_err(f"revoke {item['cn']}: {exc}")

    summary = stats.summary("ovpn_issue_and_download", wall)
    summary["concurrency"] = cfg.concurrency
    summary["issue_parallelism"] = cfg.issue_parallelism
    summary["profiles_dir"] = str(cfg.profiles_dir)
    summary["openvpn_api_url"] = cfg.openvpn_api_url
    summary["easy_rsa_path"] = cfg.easy_rsa_path
    print_summary(summary)
    return 0 if stats.errors == [] or summary["ok"] > 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
