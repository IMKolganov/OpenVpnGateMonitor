# OpenVPN Gate Monitor

A monitoring tool for OpenVPN servers with a user-friendly dashboard and real-time status updates.

🔗 **Project Repository:**  
[https://github.com/IMKolganov/OpenVPNGateMonitor](https://github.com/IMKolganov/OpenVPNGateMonitor)

## 🚀 Quick Start

Make sure you have [Docker](https://www.docker.com/) and [Docker Compose](https://docs.docker.com/compose/) installed on your system.

### 1. Clone the repository

```bash
git clone https://github.com/IMKolganov/OpenVPNGateMonitor.git
cd OpenVPNGateMonitor
```

### 2. Configure environment variables

The `.env.prod.x64` file is already included in the repository. You can modify it if needed to match your environment.

### 3. Start the project

```bash
docker compose --env-file .env.prod.x64 up --force-recreate --pull always
```

This command will:

- Recreate all containers
- Always pull the latest images
- Use the environment configuration from `.env.prod.x64`

## 📦 Project Structure

- `backend/` — Backend services
- `frontend/` — React-based UI
- `.env.prod.x64` — Environment variables for Docker Compose
- `docker-compose.yml` — Service definitions

## 📈 Features

- Real-time OpenVPN server monitoring
- Dashboard interface
- API integration
- Telegram bot support (optional)

## 📝 License

This project is licensed under the MIT License.
