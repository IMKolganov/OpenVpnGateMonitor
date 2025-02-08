FROM ubuntu:arm64

RUN apt update && apt install -y openvpn easy-rsa && rm -rf /var/lib/apt/lists/*

VOLUME ["/etc/openvpn"]

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]