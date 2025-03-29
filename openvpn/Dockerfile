FROM ubuntu:latest

RUN apt update && apt install -y \
    file \
    iproute2 \
    iptables \
    tcpdump \
    openvpn \
    easy-rsa && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    file /entrypoint.sh && \
    head -1 /entrypoint.sh | cat -A

ENTRYPOINT ["/entrypoint.sh"]