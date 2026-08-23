"""Shared helpers for OpenVPN manager load tests.

Auth: Development-only backend endpoint issues a microservice JWT
(POST /api/auth/dev/token {\"role\":\"OpenVpn\"}). All load traffic then hits
DataGateOpenVpnManager only — JWT on the node stays enforced.
"""

from __future__ import annotations

import asyncio
import json
import os
import statistics
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import aiohttp

DEFAULT_CONFIG_TEMPLATE = """setenv FRIENDLY_NAME "{{friendly_name}}"
client
dev tun
proto __VPN_PROTO__
remote {{server_ip}} {{server_port}}
resolv-retry infinite
nobind
remote-cert-tls server
tls-version-min 1.2
cipher AES-256-CBC
data-ciphers AES-256-CBC:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
auth-nocache
verb 3
<ca>
{{ca_cert}}
</ca>
<cert>
{{client_cert}}
</cert>
<key>
{{client_key}}
</key>
<tls-crypt>
{{tls_auth_key}}
</tls-crypt>
"""


@dataclass
class LoadConfig:
    backend_url: str = field(default_factory=lambda: os.getenv("BACKEND_URL", "http://127.0.0.1:5581").rstrip("/"))
    openvpn_api_url: str = field(
        default_factory=lambda: os.getenv("OPENVPN_API_URL", "http://127.0.0.1:5009").rstrip("/")
    )
    vpn_host: str = field(default_factory=lambda: os.getenv("VPN_HOST", "127.0.0.1"))
    vpn_port: int = field(default_factory=lambda: int(os.getenv("VPN_PORT", "1295")))
    vpn_proto: str = field(default_factory=lambda: os.getenv("VPN_PROTO", "udp").lower())
    concurrency: int = field(default_factory=lambda: int(os.getenv("CONCURRENCY", "150")))
    # EasyRSA is gated by a process-wide PKI mutex; parallel adds queue safely.
    issue_parallelism: int = field(
        default_factory=lambda: int(os.getenv("ISSUE_PARALLELISM", "10"))
    )
    # Predicted path for early download-while-issuing (must match node EASY_RSA_PATH).
    easy_rsa_path: str = field(
        default_factory=lambda: os.getenv("EASY_RSA_PATH", "/openvpn-udp/easy-rsa").rstrip("/")
    )
    hold_seconds: float = field(default_factory=lambda: float(os.getenv("HOLD_SECONDS", "5")))
    profiles_dir: Path = field(
        default_factory=lambda: Path(os.getenv("PROFILES_DIR", "/tmp/ovpn-load-profiles"))
    )
    run_id: str = field(default_factory=lambda: os.getenv("RUN_ID") or uuid.uuid4().hex[:10])

    @property
    def config_template(self) -> str:
        return DEFAULT_CONFIG_TEMPLATE.replace("__VPN_PROTO__", self.vpn_proto)


@dataclass
class LatencyStats:
    samples_ms: list[float] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def add_ok(self, elapsed_s: float) -> None:
        self.samples_ms.append(elapsed_s * 1000.0)

    def add_err(self, message: str) -> None:
        self.errors.append(message)

    def summary(self, label: str, wall_s: float) -> dict[str, Any]:
        n = len(self.samples_ms)
        ordered = sorted(self.samples_ms)
        p50 = ordered[int(0.50 * (n - 1))] if n else None
        p95 = ordered[int(0.95 * (n - 1))] if n else None
        return {
            "label": label,
            "ok": n,
            "errors": len(self.errors),
            "error_samples": self.errors[:10],
            "p50_ms": round(p50, 2) if p50 is not None else None,
            "p95_ms": round(p95, 2) if p95 is not None else None,
            "avg_ms": round(statistics.fmean(ordered), 2) if n else None,
            "rps": round(n / wall_s, 2) if wall_s > 0 else None,
            "wall_s": round(wall_s, 2),
        }


async def fetch_openvpn_dev_token(session: aiohttp.ClientSession, cfg: LoadConfig) -> str:
    """Obtain a microservice JWT for DataGateOpenVpnManager via DevAuth."""
    url = f"{cfg.backend_url}/api/auth/dev/token"
    async with session.post(url, json={"role": "OpenVpn"}) as resp:
        body = await resp.text()
        if resp.status == 404:
            raise RuntimeError(
                "Dev token endpoint returned 404. Set ASPNETCORE_ENVIRONMENT=Development "
                "and DevAuth__Enabled=true on the backend."
            )
        if resp.status >= 400:
            raise RuntimeError(f"dev/token HTTP {resp.status}: {body}")
        payload = json.loads(body)
        data = payload.get("data") or payload.get("Data") or {}
        token = data.get("token") or data.get("Token")
        if not token:
            raise RuntimeError(f"dev/token missing token: {body[:500]}")
        return token


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def unwrap_data(payload: dict[str, Any]) -> dict[str, Any]:
    return payload.get("data") or payload.get("Data") or payload


async def add_ovpn_file(
    session: aiohttp.ClientSession,
    cfg: LoadConfig,
    token: str,
    common_name: str,
) -> dict[str, Any]:
    body = {
        "commonName": common_name,
        "friendly\u039dame": common_name,
        "Friendly\u039dame": common_name,
        "ovpnFileExpireDays": 1,
        "serverIp": cfg.vpn_host,
        "serverPort": cfg.vpn_port,
        "configTemplate": cfg.config_template,
        "issuedTo": "loadtest",
    }
    url = f"{cfg.openvpn_api_url}/api/ovpn-files/add"
    async with session.post(url, json=body, headers=auth_headers(token)) as resp:
        text = await resp.text()
        if resp.status >= 400:
            raise RuntimeError(f"add {common_name}: HTTP {resp.status}: {text[:400]}")
        return unwrap_data(json.loads(text))


def predicted_ovpn_meta(cfg: LoadConfig, common_name: str) -> dict[str, Any]:
    """Path the manager will write — used to start download before add returns."""
    file_name = f"{common_name}.ovpn"
    file_path = f"{cfg.easy_rsa_path}/pki/ovpn_files/{file_name}"
    return {"commonName": common_name, "fileName": file_name, "filePath": file_path}


async def download_ovpn_file(
    session: aiohttp.ClientSession,
    cfg: LoadConfig,
    token: str,
    meta: dict[str, Any],
) -> bytes:
    body = {
        "commonName": meta.get("commonName") or meta.get("CommonName"),
        "fileName": meta.get("fileName") or meta.get("FileName"),
        "filePath": meta.get("filePath") or meta.get("FilePath"),
    }
    url = f"{cfg.openvpn_api_url}/api/ovpn-files/download"
    # Issuance wait can be long when many certs share the PKI mutex.
    timeout = aiohttp.ClientTimeout(total=max(120, int(os.getenv("DOWNLOAD_TIMEOUT_S", "600"))))
    async with session.post(url, json=body, headers=auth_headers(token), timeout=timeout) as resp:
        text = await resp.text()
        if resp.status >= 400:
            raise RuntimeError(f"download: HTTP {resp.status}: {text[:400]}")
        data = unwrap_data(json.loads(text))
        content = data.get("content") or data.get("Content")
        if content is None:
            raise RuntimeError("download response missing content")
        if isinstance(content, str):
            import base64

            return base64.b64decode(content)
        if isinstance(content, list):
            return bytes(content)
        raise RuntimeError(f"unexpected content type: {type(content)}")


async def revoke_ovpn_file(
    session: aiohttp.ClientSession,
    cfg: LoadConfig,
    token: str,
    meta: dict[str, Any],
) -> None:
    body = {
        "commonName": meta.get("commonName") or meta.get("CommonName"),
        "ovpnFileName": meta.get("fileName") or meta.get("FileName"),
        "ovpnFilePath": meta.get("filePath") or meta.get("FilePath"),
    }
    url = f"{cfg.openvpn_api_url}/api/ovpn-files/revoke"
    async with session.post(url, json=body, headers=auth_headers(token)) as resp:
        if resp.status >= 400:
            text = await resp.text()
            raise RuntimeError(f"revoke: HTTP {resp.status}: {text[:400]}")


def print_summary(stats: dict[str, Any]) -> None:
    print(json.dumps(stats, indent=2, ensure_ascii=False))


async def bounded_gather(coros: list, limit: int) -> list:
    sem = asyncio.Semaphore(limit)

    async def run(coro):
        async with sem:
            return await coro

    return await asyncio.gather(*[run(c) for c in coros], return_exceptions=True)
