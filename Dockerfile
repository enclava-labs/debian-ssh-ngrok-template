FROM debian:bookworm-slim

ARG NGROK_URL=https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        busybox \
        ca-certificates \
        curl \
        jq \
        openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "${NGROK_URL}" -o /tmp/ngrok.tgz \
    && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin ngrok \
    && rm -f /tmp/ngrok.tgz \
    && chmod 0755 /usr/local/bin/ngrok \
    && groupadd --gid 10001 lio \
    && useradd --uid 10001 --gid 10001 --home-dir /home/lio --shell /bin/bash lio \
    && mkdir -p /home /state/home-lio /run/sshd \
    && chown -R 10001:10001 /state/home-lio \
    && ln -s /state/home-lio /home/lio

COPY entrypoint.sh /usr/local/bin/debian-ssh-ngrok-entrypoint
RUN chmod 0755 /usr/local/bin/debian-ssh-ngrok-entrypoint

USER 10001:10001
WORKDIR /
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/debian-ssh-ngrok-entrypoint"]
