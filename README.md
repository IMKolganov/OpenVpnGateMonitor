<h1 align="left">
  <img src="docs/assets/datagate.svg" width="32" height="32" alt="" />
  DataGate Monitor
</h1>

Monitoring dashboard and API for [DataGate](https://datagateapp.com/) VPN infrastructure: OpenVPN and Xray servers, live status, traffic overview, admin tools, and an optional Telegram bot.

## Links

| Resource | Link |
|----------|------|
| <img src="docs/assets/datagate.svg" width="16" height="16" alt="" /> **Product** | [datagateapp.com](https://datagateapp.com/) |
| <img src="https://cdn.simpleicons.org/googleplay/414141" width="16" height="16" alt="" /> **Download app** | [datagateapp.com/download](https://datagateapp.com/download) |
| <img src="https://cdn.simpleicons.org/grafana/F46800" width="16" height="16" alt="" /> **Dashboard (prod)** | [dash.datagateapp.com](https://dash.datagateapp.com/) |
| <img src="https://cdn.simpleicons.org/telegram/26A5E4" width="16" height="16" alt="" /> **Telegram channel** | [@datagateapp](https://t.me/datagateapp) |
| <picture><source media="(prefers-color-scheme: dark)" srcset="https://cdn.simpleicons.org/github/ffffff"><img src="https://cdn.simpleicons.org/github/181717" width="16" height="16" alt=""></picture> **Repository** | [github.com/IMKolganov/DataGateMonitor](https://github.com/IMKolganov/DataGateMonitor) |

## Quick start (production, prebuilt images)

Install [Docker](https://docs.docker.com/get-docker/) and [Docker Compose](https://docs.docker.com/compose/) first.

### 1) Clone with submodules

```bash
git clone --recurse-submodules https://github.com/IMKolganov/DataGateMonitor.git
cd DataGateMonitor
```

If you already cloned without submodules:

```bash
git submodule update --init --recursive
```

### 2) Start the stack

Use the env file for your architecture (x64 example):

```bash
docker compose --env-file .env.prod.x64 up -d --pull always
```

**Local URLs**

| Service | URL |
|---------|-----|
| Dashboard | http://localhost:5582 |
| API | http://localhost:5581 |
| PostgreSQL | localhost:5432 (container: `postgres_backend:5432`) |
| Xray manager API | http://localhost:15012 (override `XRAY_MANAGER_HOST_PORT`) |

Xray VLESS listens on **`xray:443`** inside Compose. Local dev compose exposes VLESS on **localhost:30443** — see `docker-compose-local.yml`.

### Local development (build from source)

```bash
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 up -d --build
```

See [README-DEV.md](README-DEV.md) for more dev workflows.

## Repository structure

```
backend/          # ASP.NET Core API (submodule → DataGateMonitorBackend)
frontend/         # React + Vite UI (submodule)
openvpn/          # OpenVPN sidecar + DataGateOpenVpnManager (submodule)
xray/             # Xray sidecar + DataGateXRayManager (submodule)
telegrambot/      # Optional Telegram bot (submodule)
docker-compose.yml
docker-compose-local.yml
build.sh            # Build/push datagate-monitor-* Docker images
```

## Key environment variables

Override in `.env.prod.*` / `.env.dev.*`:

- **Backend:** `DB_CONNECTION_STRING_DATAGATE`, `DB_DEFAULT_SCHEMA`, `JWT_SECRET` (≥16 chars), `ELASTIC_*`, `EmailSender__*`, `Auth__PublicWebBaseUrl` (TV QR origin), `Auth__TvLoginSessionMinutes`
- **Frontend (compose):** `BACKEND_INTERNAL_URL` — nginx proxy target inside Docker network
- **Telegram bot:** `TELEGRAMBOT_BOT_TOKEN`, `DASHBOARDAPI_*`, `ELASTIC_*`
- **OpenVPN sidecars:** `DATA_DIR`, `EASY_RSA_PATH`, `PORT`, `API_PORT`, `OpenVpnManagement__Port`, `BACKEND__BASEURL`
- **Xray sidecar:** `XRayManagement__Host`, `XRayManagement__Port`, `Backend__BaseUrl`, `XRAY_TRANSPORT_MODE` (`plain` / `tls` / `reality`)
- **PostgreSQL:** `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`

Docker images: `imkolganov/datagate-monitor-{backend,frontend,openvpn,xray,telegrambot}`.

## Volumes

```
openvpn_data_udp   openvpn_data_tcp   xray_data   postgres_data_backend   backend_data
```

## Author & support

**Ivan Kolganov**

| Contact | Link |
|---------|------|
| <img src="https://api.iconify.design/simple-icons/linkedin.svg?color=%230A66C2" width="16" height="16" alt="" /> **LinkedIn** | [linkedin.com/in/imkolganov](https://www.linkedin.com/in/imkolganov/?locale=en) |
| <img src="https://cdn.simpleicons.org/telegram/26A5E4" width="16" height="16" alt="" /> **Telegram** | [@KolganovIvan](https://t.me/KolganovIvan) |
| <img src="https://cdn.simpleicons.org/buymeacoffee/FFDD00" width="16" height="16" alt="" /> **Buy Me a Coffee** | [buymeacoffee.com/imkolganov](https://buymeacoffee.com/imkolganov) |
| <img src="https://cdn.simpleicons.org/telegram/26A5E4" width="16" height="16" alt="" /> **Product updates** | [@datagateapp](https://t.me/datagateapp) |

## License

MIT — see [LICENSE](LICENSE) if present in the repo root.
