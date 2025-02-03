# OpenVpnGateMonitor

## 🚀 Clone the Project with Submodules
To get the full project including backend and frontend submodules, use the following command:

```sh
git clone --recurse-submodules https://github.com/IMKolganov/OpenVpnGateMonitor.git && \
cd OpenVpnGateMonitor && \
git submodule update --init --recursive
```

---

## 🛠️ Prepare Configuration
Before running the application, you need to prepare the **configuration file**:
1. Create your **`appsettings.json`** file.
2. Place it in the root directory of the **backend folder** (`OpenVPNGateMonitorBackend/`).

---

## 🚀 Run with Docker Compose
Once the project is cloned and configured, run the following command to build and start the services:

```sh
docker-compose down && \
docker-compose up -d --build
```

---

## 📌 Available Services
| Service  | Container Name | Exposed Port | Docker Network Alias |
|----------|---------------|--------------|----------------------|
| **Backend** | `openvpn-backend` | `5581` | `backend` |
| **Frontend** | `openvpn-frontend` | `5582` | `frontend` |

After running `docker-compose`, the services will be accessible at:
- **Frontend:** [http://localhost:5582](http://localhost:5582)
- **Backend:** [http://localhost:5581](http://localhost:5581)

Within the **Docker network**, they communicate as:
- **Frontend → Backend:** `http://backend:5581`
- **Backend → Frontend:** `http://frontend:5582`

---

## ✅ Summary
1. Clone the repository with all submodules.
2. Prepare `appsettings.json` and place it in `OpenVPNGateMonitorBackend/`.
3. Run `docker-compose` to start both backend and frontend.
4. Access the services via `http://localhost:5582` (Frontend) and `http://localhost:5581` (Backend).

Now your **OpenVpnGateMonitor** is fully set up and running! 🚀
