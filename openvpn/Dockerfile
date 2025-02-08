FROM ubuntu:latest

RUN apt update && apt install -y openvpn easy-rsa && rm -rf /var/lib/apt/lists/*

VOLUME ["/mnt"]

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]