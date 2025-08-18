# OpenVPN Gate Monitor

A monitoring suite for OpenVPN servers with a dashboard, real‑time status, and optional Telegram bot.

🔗 **Repository**
```
https://github.com/IMKolganov/OpenVPNGateMonitor
```

## 🚀 Run (Production, prebuilt images)

> Install Docker & Docker Compose first (use official docs).

### 1) Clone
```bash
git clone https://github.com/IMKolganov/OpenVPNGateMonitor.git
cd OpenVPNGateMonitor
```

### 2) Start
Use the env file for your architecture (x64 shown here):
```bash
docker compose --env-file .env.prod.x64 up -d --pull always
```

**Services**
- Dashboard: `http://localhost:5582`
- API: `http://localhost:5581`
- PostgreSQL: `localhost:5432` (container: `postgres_backend:5432`)

**Note for development / building locally**
If you don’t want to use prebuilt images (or you’re developing), run:
```bash
docker compose -f docker-compose-local.yml --env-file .env.dev.x64 up -d --build
```

## 📦 Structure
```
backend/          # ASP.NET Core API & services
frontend/         # React UI
openvpn/          # OpenVPN TCP/UDP sidecars + EasyRSA paths
telegrambot/      # Optional ASP.NET Core Telegram bot
docker-compose.yml
docker-compose-local.yml
.env.prod.x64 / .env.prod.arm64
.env.dev.x64  / .env.dev.arm64
```

## ⚙️ Key Environment Variables (override in your .env.*)
- Backend: `DB_CONNECTION_STRING_DATAGATE`, `DB_DEFAULT_SCHEMA`, `DB_MIGRATION_TABLE`, `JWT_SECRET`, `ELASTIC_*`
- Frontend: `BACKEND_URL`
- Telegram bot (optional): `TELEGRAMBOT_BOT_TOKEN`, `HOST_ADDRESS`, `USE_CERTIFICATE`, `AUTO_GENERATE_CERTIFICATE`, `CERTIFICATE_*`, `DASHBOARDAPI_*`, `ELASTIC_*`
- OpenVPN sidecars: `DATA_DIR`, `EASY_RSA_PATH`, `PORT`, `API_PORT`, `OpenVpnManagement__Port`, `BACKEND__BASEURL`
- PostgreSQL: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`

## 🔐 Volumes
```
openvpn_data_udp   openvpn_data_tcp   postgres_data_backend   backend_data
```

## 📝 License
MIT

## 🧩 Example `.env.dev.x64`
```env
ASPNETCORE_ENVIRONMENT=Development
TARGETARCH=x64
BUILD_CONFIGURATION=Debug
```

**Parameters**
- **ASPNETCORE_ENVIRONMENT** – Runtime environment (`Development`, `Staging`, `Production`). Use `Development` for local debugging.
- **TARGETARCH** – Target architecture for build (`x64` or `arm64`). Must match your host or target system.
- **BUILD_CONFIGURATION** – .NET build configuration (`Debug` for development, `Release` for production-like build).
