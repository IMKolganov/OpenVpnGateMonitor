#!/bin/bash
set -e

PORT=${PORT:-1194}
PROTO=${PROTO:-udp}
MGMT_PORT=${MGMT_PORT:-5092}


echo "===== STARTING OPENVPN CONTAINER ====="

# Enable IP forwarding
iptables -P FORWARD ACCEPT
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A FORWARD -o tun0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.51.28.0/24 -o eth0 -j MASQUERADE

EASYRSA_DIR="/mnt/easy-rsa"

echo "===== Checking contents of /mnt before starting..."
ls -l /mnt

if [ -d "$EASYRSA_DIR/pki" ]; then
    echo "Found existing PKI:"
    ls -l "$EASYRSA_DIR/pki"
else
    echo "PKI not found. Initializing new PKI..."
    make-cadir "$EASYRSA_DIR"
    cd "$EASYRSA_DIR"

    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="OpenVPN-Server"

    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    # Skip DH, use ECDH instead
fi

# Ensure ta.key exists
if [ ! -f "$EASYRSA_DIR/pki/ta.key" ]; then
    echo "===== Generating new ta.key (tls-crypt)..."
    openvpn --genkey --secret "$EASYRSA_DIR/pki/ta.key"
else
    echo "ta.key already exists."
fi

# Ensure all required files are in /etc/openvpn
echo "===== Copying necessary certs and keys to /etc/openvpn..."
declare -A FILES_TO_COPY=(
  ["$EASYRSA_DIR/pki/ca.crt"]="/etc/openvpn/ca.crt"
  ["$EASYRSA_DIR/pki/issued/server.crt"]="/etc/openvpn/server.crt"
  ["$EASYRSA_DIR/pki/private/server.key"]="/etc/openvpn/server.key"
  ["$EASYRSA_DIR/pki/ta.key"]="/etc/openvpn/ta.key"
)

for SRC in "${!FILES_TO_COPY[@]}"; do
  DEST=${FILES_TO_COPY[$SRC]}
  if [ -f "$SRC" ]; then
    cp "$SRC" "$DEST"
  else
    echo "WARNING: $SRC not found!"
  fi
done

# Generate default server.conf if not present
if [ ! -f /mnt/server.conf ]; then
    echo "Generating default server.conf..."
    cat <<EOF > /mnt/server.conf
port $PORT
proto $PROTO
dev tun

ca /etc/openvpn/ca.crt
cert /etc/openvpn/server.crt
key /etc/openvpn/server.key
dh none
ecdh-curve prime256v1

topology subnet
server 10.51.28.0 255.255.255.0
ifconfig-pool-persist /etc/openvpn/ipp.txt

push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
push "block-outside-dns"
push "redirect-gateway def1"

keepalive 15 120

remote-cert-tls client
tls-version-min 1.2
tls-crypt /etc/openvpn/ta.key

cipher AES-256-CBC
auth SHA256

user nobody
group nogroup

persist-key
persist-tun

status /mnt/openvpn-status.log
status-version 3
log /mnt/openvpn.log
log-append /mnt/openvpn.log

management 0.0.0.0 $MGMT_PORT

verb 4
EOF
fi

# Prepare log files
echo "Clearing logs..."
truncate -s 0 /mnt/openvpn.log || touch /mnt/openvpn.log
truncate -s 0 /mnt/openvpn-status.log || touch /mnt/openvpn-status.log
chmod 777 /mnt/openvpn.log /mnt/openvpn-status.log

echo "===== FINAL CHECK BEFORE STARTING OPENVPN ====="
ls -l /mnt
[ -d "$EASYRSA_DIR/pki" ] && ls -l "$EASYRSA_DIR/pki"

echo "===== server.conf contents ====="
cat /mnt/server.conf || echo "server.conf not found!"

echo "===== Starting OpenVPN..."
tail -F /mnt/openvpn.log /mnt/openvpn-status.log &
exec openvpn --config /mnt/server.conf