# OpenVPN load tests

Target: **DataGateOpenVpnManager** (OpenVPN + .NET in one container). Dashboard is used only as a Development token mint for the microservice JWT that the node already validates — JWT on `/api/ovpn-files` stays enforced.

## Dev token (backend, Development only)

```http
POST /api/auth/dev/token
{ "role": "OpenVpn" }
```

Requires `ASPNETCORE_ENVIRONMENT=Development` and `DevAuth:Enabled=true`.

Response includes:

- `token` — Bearer JWT for OpenVPN manager (`audience=DataGateOpenVpnManager`, `purpose=cert-create`, role `backend`)
- `publicKeyPem`, `issuer`, `audience`, `purpose` — material describing how the node validates the token

Roles `App` / `Admin` also work for dashboard APIs; they are **not** accepted by OpenVPN manager.

## Scenarios

| Script | What it does |
|--------|----------------|
| `test_ovpn_issue_and_download.py` | 150× `POST /api/ovpn-files/add` + `download` (unique CN) |
| `test_ovpn_native_connect.py` | Issue profiles, start 150 `openvpn` clients, wait for connect |
| `test_proxy_clients.py` | 150× WS `/api/proxy?clientRef=<cn>` |
| `test_proxy_traffic_stub.py` | Bulk WS traffic via proxy to TCP echo on `PORT` |

## Run (against already-up VPN node)

```bash
# Backend must be Development + DevAuth enabled
export BACKEND_URL=http://127.0.0.1:5581
export OPENVPN_API_URL=http://127.0.0.1:5009
export CONCURRENCY=150
# Server waits this long on download if cert is still issuing (node env; default 10)
# OVPN_ISSUANCE_WAIT_TIMEOUT_SECONDS=120
export ISSUE_PARALLELISM=10

pip install -r loadtests/requirements.txt
python3 loadtests/test_ovpn_issue_and_download.py
python3 loadtests/test_proxy_clients.py
```

Verified locally against `openvpn/docker-compose.local.yml` + DevAuth backend:

| Scenario | Result |
|----------|--------|
| issue+download ×5 | 5/5 |
| issue+download ×150 parallel EasyRSA | ~79/150 — PKI races (`vars`/`serial`/`index.txt`) |
| issue+download ×50 with `ISSUE_PARALLELISM=1` | 50/50 |
| proxy WS ×150 | 150/150 |
| native openvpn client ×1 | connected (`Initialization Sequence Completed`) |

Note: OpenVPN manager does not bind `:API_PORT` until microservice JWT public-key fetch succeeds (`MicroserviceJwtValidator.InitAsync` blocks host start).
Native clients (privileged):

```bash
docker compose -f loadtests/docker-compose.loadtest.yml --profile load-native up --build --abort-on-container-exit
```

Proxy soak with echo stub (no EasyRSA / openvpn daemon):

```bash
# Build base OpenVPN image once if needed:
# docker build -t local-openvpn-test:2.7.4-net10 -f openvpn/Dockerfile openvpn

docker compose -f loadtests/docker-compose.loadtest.yml --profile proxy-stub up --build --abort-on-container-exit
```

## Security notes

| Surface | Auth |
|---------|------|
| `/api/ovpn-files/*` | Microservice JWT required (no bypass) |
| `/api/proxy` | Intentionally JWT-excluded today — lock down by network in prod or require JWT if public |
| `/api/auth/dev/token` | 404 outside Development / when `DevAuth:Enabled=false` |
| Local-only node paths (`/api/vpn-events/*`, `/api/info`, …) | Loopback only |

xUnit inventories: `EndpointAuthorizationInventoryTests`, `OpenVpnManagerPublicRoutesInventoryTests`, `JwtValidationMiddlewareTests`.
