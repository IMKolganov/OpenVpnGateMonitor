#!/bin/bash
set -e

EASYRSA_DIR="/mnt/easy-rsa"

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

cat /mnt/server.conf
cat /mnt/easy-rsa/pki/ta.key

truncate -s 0 /mnt/openvpn.log
truncate -s 0 /mnt/openvpn-status.log
chmod 777 /mnt/openvpn.log
chmod 777 /mnt/openvpn-status.log

tail -F /mnt/openvpn.log /mnt/openvpn-status.log &

exec openvpn --config /mnt/server.conf &
tail -F /mnt/openvpn.log /mnt/openvpn-status.log