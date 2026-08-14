#!/usr/bin/env python3
"""TCP (and optional UDP) echo stub bound to 0.0.0.0:PORT for proxy soak tests."""

from __future__ import annotations

import asyncio
import os
import socket


async def handle_tcp(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:  # noqa: BLE001
            pass


async def run_tcp(port: int) -> None:
    server = await asyncio.start_server(handle_tcp, "0.0.0.0", port)
    print(f"[echo-stub] TCP listening on 0.0.0.0:{port}", flush=True)
    async with server:
        await server.serve_forever()


async def run_udp(port: int) -> None:
    loop = asyncio.get_running_loop()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    sock.setblocking(False)
    print(f"[echo-stub] UDP listening on 0.0.0.0:{port}", flush=True)

    while True:
        data, addr = await loop.sock_recvfrom(sock, 65536)
        if data:
            await loop.sock_sendto(sock, data, addr)


async def main() -> None:
    port = int(os.getenv("PORT", "1194"))
    proto = os.getenv("PROTO", "tcp").lower()
    if proto == "udp":
        await run_udp(port)
    else:
        await run_tcp(port)


if __name__ == "__main__":
    asyncio.run(main())
