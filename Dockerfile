FROM debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df

ARG NGROK_URL=https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz
ARG NGROK_SHA256=e5d3121eb78b97a20ec2def17a9d71d57405db1b0a14fa2125237848c072436c

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
    && echo "${NGROK_SHA256}  /tmp/ngrok.tgz" | sha256sum -c - \
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
