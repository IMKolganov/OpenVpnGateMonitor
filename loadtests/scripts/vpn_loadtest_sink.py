#!/usr/bin/env python3
import asyncio
import os

PORT = int(os.environ.get("SINK_PORT", "9200"))


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def main() -> None:
    server = await asyncio.start_server(handle, "0.0.0.0", PORT, backlog=2048)
    print(f"sink on 0.0.0.0:{PORT}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
