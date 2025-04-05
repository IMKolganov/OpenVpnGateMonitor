#!/bin/bash
set -e

PORT=${PORT:-1194}
PROTO=${PROTO:-udp}
MGMT_PORT=${MGMT_PORT:-5092}
DATA_DIR=${DATA_DIR:-/mnt}

EASYRSA_DIR="$DATA_DIR/easy-rsa"

echo "===== STARTING OPENVPN CONTAINER ====="

# Enable IP forwarding
iptables -P FORWARD ACCEPT
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A FORWARD -o tun0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.51.28.0/24 -o eth0 -j MASQUERADE

echo "===== Checking contents of $DATA_DIR before starting..."
ls -l "$DATA_DIR"

if [ ! -x "$EASYRSA_DIR/easyrsa" ]; then
    echo "Copying Easy-RSA to $EASYRSA_DIR..."
    mkdir -p "$EASYRSA_DIR"
    cp -r /usr/share/easy-rsa/* "$EASYRSA_DIR"
    chmod +x "$EASYRSA_DIR/easyrsa"
fi

if [ ! -f "$EASYRSA_DIR/easyrsa" ] || [ ! -x "$EASYRSA_DIR/easyrsa" ]; then
    echo "ERROR: Easy-RSA script not found or not executable at $EASYRSA_DIR/easyrsa"
    echo "Please ensure Easy-RSA v3 is installed and placed correctly."
    exit 1
fi

if [ ! -d "$EASYRSA_DIR/pki" ]; then
    echo "PKI not found. Initializing..."
    cd "$EASYRSA_DIR"

    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="OpenVPN-Server"
    export EASYRSA_PKI="$EASYRSA_DIR/pki"

    ./easyrsa --batch init-pki
    ./easyrsa --batch build-ca nopass
    ./easyrsa --batch gen-req server nopass
    ./easyrsa --batch sign-req server server
fi

# Ensure ta.key exists
if [ ! -f "$EASYRSA_DIR/pki/ta.key" ]; then
    echo "===== Generating new ta.key (tls-crypt)..."
    openvpn --genkey secret "$EASYRSA_DIR/pki/ta.key"
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
    echo "ERROR: Required file $SRC not found, exiting."
    exit 1
  fi
done

# Generate default server.conf if not present
if [ ! -f "$DATA_DIR/server.conf" ]; then
    echo "Generating default server.conf..."
    cat <<EOF > "$DATA_DIR/server.conf"
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

status $DATA_DIR/openvpn-status.log
status-version 3
log $DATA_DIR/openvpn.log
log-append $DATA_DIR/openvpn.log

management 0.0.0.0 $MGMT_PORT

verb 4
EOF
fi

# Prepare log files
echo "Clearing logs..."
truncate -s 0 "$DATA_DIR/openvpn.log" || touch "$DATA_DIR/openvpn.log"
truncate -s 0 "$DATA_DIR/openvpn-status.log" || touch "$DATA_DIR/openvpn-status.log"
chmod 777 "$DATA_DIR/openvpn.log" "$DATA_DIR/openvpn-status.log"

# Add read/execute permissions to everything inside DATA_DIR
echo "Setting permissions for $DATA_DIR recursively..."
chmod -R a+rX "$DATA_DIR"

echo "===== FINAL CHECK BEFORE STARTING OPENVPN ====="
ls -l "$DATA_DIR"
[ -d "$EASYRSA_DIR/pki" ] && ls -l "$EASYRSA_DIR/pki"

echo "===== server.conf contents ====="
cat "$DATA_DIR/server.conf" || echo "server.conf not found!"

echo "===== Starting OpenVPN..."
tail -F "$DATA_DIR/openvpn.log" "$DATA_DIR/openvpn-status.log" &
exec openvpn --config "$DATA_DIR/server.conf"
