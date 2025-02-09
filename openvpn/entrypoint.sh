#!/bin/bash
set -e

echo "===== STARTING OPENVPN CONTAINER ====="

iptables -P FORWARD ACCEPT
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A FORWARD -o tun0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 10.51.28.0/24 -o eth0 -j MASQUERADE

EASYRSA_DIR="/mnt/easy-rsa"

echo "Checking contents of /mnt before starting..."
ls -l /mnt
ls -l /mnt/easy-rsa/pki

if [ ! -d "$EASYRSA_DIR/pki" ]; then
    echo "Initializing new PKI..."
    make-cadir $EASYRSA_DIR
    cd $EASYRSA_DIR
    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    ./easyrsa gen-dh
    cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/
fi

echo "===== CONFIGURATION FILES ====="
cat /mnt/server.conf || echo "server.conf NOT FOUND!"
cat /mnt/easy-rsa/pki/ta.key || echo "ta.key NOT FOUND!"

echo "Clearing logs..."
truncate -s 0 /mnt/openvpn.log
truncate -s 0 /mnt/openvpn-status.log
chmod 777 /mnt/openvpn.log
chmod 777 /mnt/openvpn-status.log

echo "===== FINAL CHECK BEFORE STARTING OPENVPN ====="
ls -l /mnt
ls -l /mnt/easy-rsa/pki

echo "Starting OpenVPN..."
tail -F /mnt/openvpn.log /mnt/openvpn-status.log &
exec openvpn --config /mnt/server.conf &
tail -F /mnt/openvpn.log /mnt/openvpn-status.log
