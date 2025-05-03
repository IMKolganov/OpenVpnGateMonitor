# Use lightweight Alpine as base image
FROM alpine:latest

LABEL maintainer="Ivan Kolganov with ❤️ via Kyle Manna's template"

# Add edge testing repo for pamtester and others
RUN echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories && \
    apk add --no-cache \
    bash \
    curl \
    ca-certificates \
    openvpn \
    iptables \
    easy-rsa \
    openvpn-auth-pam \
    google-authenticator \
    pamtester \
    file \
    libqrencode && \
    ln -s /usr/share/easy-rsa/easyrsa /usr/local/bin && \
    rm -rf /tmp/* /var/tmp/* /var/cache/apk/* /var/cache/distfiles/*

# Environment for easy-rsa and OpenVPN
ENV OPENVPN=/etc/openvpn
ENV EASYRSA=/usr/share/easy-rsa \
    EASYRSA_CRL_DAYS=3650 \
    EASYRSA_PKI=$OPENVPN/pki

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh

# Ensure LF endings and execution permissions
RUN sed -i 's/\r$//' /entrypoint.sh && \
    chmod +x /entrypoint.sh && \
    file /entrypoint.sh && \
    head -1 /entrypoint.sh | cat -A

ENTRYPOINT ["/entrypoint.sh"]