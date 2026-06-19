FROM debian:bookworm-slim

ARG NGROK_URL=https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        busybox \
        ca-certificates \
        curl \
        jq \
        openssh-server \
        sudo \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "${NGROK_URL}" -o /tmp/ngrok.tgz \
    && tar -xzf /tmp/ngrok.tgz -C /usr/local/bin ngrok \
    && rm -f /tmp/ngrok.tgz \
    && chmod 0755 /usr/local/bin/ngrok \
    && groupadd --gid 10001 user \
    && useradd --uid 10001 --gid 10001 --groups sudo --home-dir /home/user --shell /bin/bash user \
    && printf 'user ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/user-nopasswd \
    && chmod 0440 /etc/sudoers.d/user-nopasswd \
    && mkdir -p /home /state /run/sshd \
    && chown 10001:10001 /state \
    && ln -s /state/.enclava/config/.runtime/home-user /home/user

COPY entrypoint.sh /usr/local/bin/debian-ssh-ngrok-entrypoint
RUN chmod 0755 /usr/local/bin/debian-ssh-ngrok-entrypoint

USER 10001:10001
WORKDIR /
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/debian-ssh-ngrok-entrypoint"]
