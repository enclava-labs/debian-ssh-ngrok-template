#!/bin/sh
set -eu

AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ7cAp6elwfMEiNuvLhVyb1xTceSuapftN2ijXIjJD0t lio@beast"

: "${DEBIAN_SSH_USER:=lio}"
: "${DEBIAN_SSH_HOME:=/home/lio}"
: "${DEBIAN_SSH_PORT:=2222}"
: "${DEBIAN_HEALTH_PORT:=8080}"
: "${DEBIAN_NGROK_WEB_PORT:=4040}"
: "${DEBIAN_SSH_CAP_CONFIG_DIRS:=/state/app-data/.enclava/config /state/.enclava/config /home/lio/.enclava/config}"
if [ -z "${DEBIAN_SSH_CONFIG_WAIT_SECONDS+x}" ]; then
    if [ -n "${ENCLAVA_CONTAINER_NAME:-}" ]; then
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=300
    else
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=0
    fi
fi

is_valid_env_key() {
    case "$1" in
        ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
    return 0
}

first_config_dir() {
    for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if [ -d "$dir" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done
    return 1
}

wait_for_config() {
    seconds="$DEBIAN_SSH_CONFIG_WAIT_SECONDS"
    case "$seconds" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_CONFIG_WAIT_SECONDS must be an integer" >&2
            exit 1
            ;;
    esac
    [ "$seconds" -gt 0 ] || return 0

    elapsed=0
    while [ "$elapsed" -lt "$seconds" ]; do
        for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
            if [ -f "$dir/.ready" ]; then
                return 0
            fi
        done
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "CAP config was not marked ready after ${seconds}s; continuing with current environment" >&2
}

load_cap_config() {
    dir="$(first_config_dir || true)"
    [ -n "${dir:-}" ] || return 0

    for path in "$dir"/*; do
        [ -f "$path" ] || continue
        key="${path##*/}"
        is_valid_env_key "$key" || continue
        value="$(cat "$path")"
        export "$key=$value"
    done
}

require_nonempty_env() {
    key="$1"
    eval "value=\${$key:-}"
    if [ -z "$value" ]; then
        echo "$key is required" >&2
        exit 1
    fi
}

append_authorized_key() {
    file="$1"
    if [ -f "$file" ] && grep -qxF "$AUTHORIZED_KEY" "$file"; then
        return 0
    fi
    printf '%s\n' "$AUTHORIZED_KEY" >>"$file"
}

write_sshd_config() {
    cat >"$DEBIAN_SSH_HOME/.ssh/sshd_config" <<EOF
Port ${DEBIAN_SSH_PORT}
ListenAddress 0.0.0.0
HostKey ${DEBIAN_SSH_HOME}/.ssh/ssh_host_ed25519_key
AuthorizedKeysFile ${DEBIAN_SSH_HOME}/.ssh/authorized_keys
PidFile ${DEBIAN_SSH_HOME}/.ssh/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM no
PermitRootLogin no
AllowUsers ${DEBIAN_SSH_USER}
StrictModes no
X11Forwarding no
AllowTcpForwarding yes
PermitTunnel no
PrintMotd no
Subsystem sftp internal-sftp
EOF
}

prepare_home() {
    if [ "$DEBIAN_SSH_HOME" = "/home/lio" ]; then
        mkdir -p /state/app-data/home/lio
    fi
    mkdir -p "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache/ngrok" "$DEBIAN_SSH_HOME/health"
    chmod 700 "$DEBIAN_SSH_HOME" 2>/dev/null || true
    chmod 700 "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache" "$DEBIAN_SSH_HOME/.cache/ngrok"
    touch "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
    append_authorized_key "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
    chmod 600 "$DEBIAN_SSH_HOME/.ssh/authorized_keys"

    if [ ! -f "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key" ]; then
        ssh-keygen -q -t ed25519 -N '' -f "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key"
    fi
    chmod 600 "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key"
    chmod 644 "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key.pub"

    write_sshd_config
    printf 'ok\n' >"$DEBIAN_SSH_HOME/health/healthz"
}

start_health() {
    busybox httpd -f -p "0.0.0.0:${DEBIAN_HEALTH_PORT}" -h "$DEBIAN_SSH_HOME/health" &
    HEALTH_PID="$!"
}

start_sshd() {
    /usr/sbin/sshd -D -e -f "$DEBIAN_SSH_HOME/.ssh/sshd_config" &
    SSHD_PID="$!"
}

start_ngrok() {
    export HOME="$DEBIAN_SSH_HOME"
    export XDG_CONFIG_HOME="$DEBIAN_SSH_HOME/.config"
    export XDG_CACHE_HOME="$DEBIAN_SSH_HOME/.cache"
    cat >"$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" <<EOF
version: 3
agent:
  web_addr: 127.0.0.1:${DEBIAN_NGROK_WEB_PORT}
EOF
    ngrok tcp "127.0.0.1:${DEBIAN_SSH_PORT}" \
        --authtoken "$NGROK_AUTHTOKEN" \
        --config "$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" \
        --log stdout \
        --log-format json &
    NGROK_PID="$!"
}

publish_ngrok_status() {
    (
        while :; do
            tmp="$DEBIAN_SSH_HOME/health/ngrok.json.tmp"
            if curl -fsS "http://127.0.0.1:${DEBIAN_NGROK_WEB_PORT}/api/tunnels" >"$tmp"; then
                mv "$tmp" "$DEBIAN_SSH_HOME/health/ngrok.json"
                public_url="$(jq -r '.tunnels[]?.public_url // empty' "$DEBIAN_SSH_HOME/health/ngrok.json" | awk '/^tcp:\/\// { print; exit }')"
                if [ -n "$public_url" ]; then
                    endpoint="${public_url#tcp://}"
                    host="${endpoint%:*}"
                    port="${endpoint##*:}"
                    printf '%s\n' "$public_url" >"$DEBIAN_SSH_HOME/health/ngrok-url.txt"
                    printf 'ssh -p %s %s@%s\n' "$port" "$DEBIAN_SSH_USER" "$host" >"$DEBIAN_SSH_HOME/health/ssh.txt"
                fi
            else
                rm -f "$tmp"
            fi
            sleep 5
        done
    ) &
    NGROK_STATUS_PID="$!"
}

cleanup() {
    [ -z "${HEALTH_PID:-}" ] || kill "$HEALTH_PID" 2>/dev/null || true
    [ -z "${SSHD_PID:-}" ] || kill "$SSHD_PID" 2>/dev/null || true
    [ -z "${NGROK_STATUS_PID:-}" ] || kill "$NGROK_STATUS_PID" 2>/dev/null || true
    [ -z "${NGROK_PID:-}" ] || kill "$NGROK_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

wait_for_config
load_cap_config
require_nonempty_env NGROK_AUTHTOKEN
prepare_home
start_health
start_sshd
start_ngrok
publish_ngrok_status
wait "$NGROK_PID"
