# VPN host install — copy folder, fill site.env, run one script

Installs **OpenVPN TCP/UDP WSS + nginx (SNI) + Pi-hole + optional Xray** on a fresh Ubuntu host.

## Before you start

1. Fresh Ubuntu server with SSH access (cloud image / root or `ubuntu`)
2. DNS **A-records** already pointing to the server IP:
   - `UDP_WSS_DOMAIN`
   - `TCP_WSS_DOMAIN`
   - `XRAY_DOMAIN` (if Xray enabled)
3. Know your office/home IP (for SSH UFW allow-list)
4. Your SSH **public** key on the laptop (`~/.ssh/id_ed25519.pub`)

## Recommended order

Do **SSH hardening first**, then the VPN stack. Keep a second SSH session open until the new login works.

| Step | What |
|------|------|
| 1 | Copy `install/vpns` to the server |
| 2 | Create admin user + sudo password + SSH key + Google Authenticator (`setup-host-ssh.sh`) |
| 3 | Confirm login as the new user (key + TOTP) |
| 4 | Fill `site.env` / wizard and run `install-vpn-host.sh` |

SSH policy comes from `templates/ssh/` (same as repo `ssh_configs/`):

- `PermitRootLogin no`
- `PasswordAuthentication no` (password is for **sudo** only)
- `AuthenticationMethods publickey,keyboard-interactive` → **SSH key + TOTP**

### 1) Get installer on the server

```bash
# first time (public repo)
git clone https://github.com/IMKolganov/DataGateMonitor.git
cd DataGateMonitor/install/vpns

# updates (on branch that has install/vpns)
cd ~/DataGateMonitor && git pull
cd install/vpns
chmod +x scripts/*.sh
```

Or copy only the folder:

```bash
scp -r install/vpns user@NEW_VPN_HOST:~/
```

### 2) Admin user + password + 2FA

```bash
# on the server (as root or ubuntu)
cd ~/vpns
chmod +x scripts/*.sh

# Creates user, asks for sudo password, copies SSH keys, enrols TOTP, installs sshd + PAM
sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey-from-user ubuntu
# or: --pubkey /path/to/id_ed25519.pub
```

Then **open a new SSH session** as `YOURNAME` and enter the authenticator code. Only after that close the old session.

Re-apply sshd/PAM later (if you skipped it):

```bash
sudo ./scripts/setup-host-ssh.sh --user YOURNAME --apply-sshd-only
```

### 3) VPN install

```bash
# as YOURNAME
cd ~/vpns
cp site.env.example site.env
nano site.env          # INSTALL_HOME=/home/YOURNAME — replace EVERY YOUR_* / example.com / CHANGE_ME
sudo ./scripts/install-vpn-host.sh
```

Or answer prompts (recommended first time):

```bash
sudo ./scripts/install-vpn-host.sh --wizard
```

The installer **refuses to run** while placeholders remain (`YOUR_*`, `example.com`, `CHANGE_ME`).

## Layout on the server

```
~/install/vpns/           # installer kit (scripts, templates, site.env)
~/openvpn-tcp-wss/        # TCP OpenVPN only
~/openvpn-udp-wss/        # UDP OpenVPN only
~/pi-hole/
~/nginx-docker/
~/datagate-monitor-xray/  # if Xray enabled
~/host/
```

## What the script does

1. Validates `site.env` (IPs, domains, unique subnets)
2. Preflight: `/dev/net/tun`, DNS → `PUBLIC_IP` warnings
3. Renders stacks under `INSTALL_HOME` (`openvpn-tcp-wss`, `openvpn-udp-wss`, `pi-hole`, `nginx-docker`, optional `datagate-monitor-xray`, `host/`)
4. Installs Docker (optional)
5. UFW + `ip_forward` (SSH allowed for `ADMIN_SSH_IP` **and** your current SSH session IP)
6. Starts in order: OpenVPN → Pi-hole → nginx (HTTP) → **one Let's Encrypt cert per domain** → HTTPS configs → Xray (if enabled)

## Required `site.env` fields

| Variable | Notes |
|----------|--------|
| `PUBLIC_IP` | Server public IPv4 |
| `INSTALL_HOME` | e.g. `/home/YOURNAME` — sibling folders for each stack |
| `CERTBOT_EMAIL` | Real email (not `@example.com`) |
| `UDP_WSS_DOMAIN` / `TCP_WSS_DOMAIN` | DNS A → `PUBLIC_IP` |
| `BACKEND__BASEURL` | e.g. `https://api.datagateapp.com/` |
| `DASHBOARD_API_IP` | Dashboard host IPv4 |
| `ADMIN_SSH_IP` | **Your** IPv4 — wrong value risks SSH lockout |
| `TCP_VPN_SUBNET` / `UDP_VPN_SUBNET` | Different `/24` per host |
| `PIHOLE_WEBPASSWORD` | Strong password |

If `INSTALL_XRAY=true` also set `XRAY_DOMAIN`, `XRAY_DNS_IDENTITY_SUBNET`, `XRAY_API_ALLOW_IPS`.

Two new servers → **different** VPN + Xray identity subnets on each.

## Useful flags

```bash
sudo ./scripts/install-vpn-host.sh --render-only      # write files only (no root needed)
sudo ./scripts/install-vpn-host.sh --skip-ufw
sudo ./scripts/install-vpn-host.sh --skip-certs
sudo ./scripts/install-vpn-host.sh --skip-start
sudo ./scripts/install-vpn-host.sh --skip-preflight
sudo ./scripts/install-vpn-host.sh --env /path/to/site.env
```

Safe first dry-run on a new VPS:

```bash
sudo ./scripts/install-vpn-host.sh --skip-ufw --skip-certs --skip-start
# inspect ~/openvpn ~/pi-hole ~/nginx-docker
# then full run once DNS is ready:
sudo ./scripts/install-vpn-host.sh
```

## After install — dashboard

| Service | ApiUrl |
|---------|--------|
| OpenVPN UDP | `https://UDP_WSS_DOMAIN/` |
| OpenVPN TCP | `https://TCP_WSS_DOMAIN/` |
| Xray | `https://XRAY_DOMAIN:9443` |

## Traffic path (full stack)

```
:443  nginx stream (SNI)
        ├─ XRAY_DOMAIN → xray:443 + PROXY protocol
        └─ default     → :8443 OpenVPN WSS + PROXY → host :5010/:5011

:9443 nginx → xray:5010 (manager, IP allow-list)
:80   ACME + redirect
```

## Troubleshooting

| Symptom | Check |
|---------|--------|
| certbot fails | `dig +short DOMAIN` must equal `PUBLIC_IP`; port 80 open |
| Pi-hole exits | OpenVPN TCP must be Up first; `docker logs datagate-pihole` |
| no SSH after UFW | reconnect from `ADMIN_SSH_IP` or console; installer also allows session IP |
| no SSH after 2FA | console/VNC: restore `/etc/ssh/sshd_config.bak.*` and `/etc/pam.d/sshd.bak.*`, `systemctl restart ssh` |
| Xray won't start | certs must exist under `nginx-docker/certbot/conf/live/XRAY_DOMAIN/` |
| OpenVPN slow first boot | PKI generation — wait; `docker logs openvpn-tcp-wss` |

Local smoke test (developer machine):

```bash
./scripts/smoke-test-local.sh
```
