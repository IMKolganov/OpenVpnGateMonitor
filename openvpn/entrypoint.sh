#!/bin/bash
set -e

EASYRSA_DIR="/etc/openvpn/easy-rsa"

if [ ! -f "$EASYRSA_DIR/pki/ca.crt" ]; then
    echo "No certificates found, generating new ones..."
    make-cadir $EASYRSA_DIR
    cd $EASYRSA_DIR
    ./easyrsa init-pki
    ./easyrsa build-ca nopass
    ./easyrsa gen-req server nopass
    ./easyrsa sign-req server server
    ./easyrsa gen-dh
    cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/dh.pem /etc/openvpn/
fi

exec openvpn --config /etc/openvpn/server.conf