#!/bin/sh
set -eu

: "${DEBIAN_SSH_USER:=user}"
: "${DEBIAN_SSH_HOME:=/home/user}"
: "${DEBIAN_SSH_PORT:=2222}"
: "${DEBIAN_HEALTH_PORT:=8080}"
: "${DEBIAN_NGROK_WEB_PORT:=4040}"
: "${DEBIAN_NGROK_API_TIMEOUT_SECONDS:=3}"
: "${DEBIAN_NGROK_API_FAILURE_RESTARTS:=3}"
: "${DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS:=5}"
: "${DEBIAN_SSH_CAP_CONFIG_DIRS:=/state/app-data/.enclava/config /state/.enclava/config /home/user/.enclava/config}"
: "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:=/state/app-data/debian-ssh-ngrok/config}"
: "${DEBIAN_SSH_PERSISTED_CONFIG_KEYS:=NGROK_TCP_URL NGROK_AUTHTOKEN DEBIAN_SSH_AUTHORIZED_KEYS}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES:=32768}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS:=10}"
: "${DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS:=ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256}"
: "${NGROK_TCP_URL:=}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS:=}"
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
        if [ -f "$dir/.ready" ]; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

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

normalize_ngrok_tcp_url() {
    value="$(printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$value" ] || return 0
    value="$(printf '%s' "$value" | sed 's/^[Tt][Cc][Pp]:\/\///' | tr '[:upper:]' '[:lower:]')"
    ngrok_host="${value%:*}"
    ngrok_port="${value##*:}"
    ngrok_host="${ngrok_host%.}"
    value="${ngrok_host}:${ngrok_port}"
    ngrok_label='[a-z0-9]([a-z0-9-]*[a-z0-9])?'
    if ! printf '%s\n' "$value" | grep -Eq "^${ngrok_label}\\.tcp(\\.${ngrok_label})?\\.ngrok\\.(io|app):[0-9]{1,5}$"; then
        echo "NGROK_TCP_URL must be a reserved ngrok TCP address such as 6.tcp.eu.ngrok.io:17958" >&2
        return 1
    fi
    if ! ngrok_host_labels_within_limit "$ngrok_host"; then
        echo "NGROK_TCP_URL must be a reserved ngrok TCP address such as 6.tcp.eu.ngrok.io:17958" >&2
        return 1
    fi
    ngrok_port_number="$(printf '%s\n' "$ngrok_port" | sed 's/^0*//')"
    [ -n "$ngrok_port_number" ] || ngrok_port_number=0
    if [ "$ngrok_port_number" -lt 1 ] || [ "$ngrok_port_number" -gt 65535 ]; then
        echo "NGROK_TCP_URL port must be between 1 and 65535" >&2
        return 1
    fi
    printf '%s:%s\n' "$ngrok_host" "$ngrok_port_number"
}

ngrok_host_labels_within_limit() {
    ngrok_host_to_check="$1"
    ngrok_old_ifs="$IFS"
    IFS=.
    set -- $ngrok_host_to_check
    IFS="$ngrok_old_ifs"
    for ngrok_label_value do
        [ "${#ngrok_label_value}" -le 63 ] || return 1
    done
    return 0
}

normalize_ngrok_tcp_url_config() {
    NGROK_TCP_URL="$(normalize_ngrok_tcp_url "$NGROK_TCP_URL")" || exit 1
    export NGROK_TCP_URL
}

ngrok_public_url_matches_reserved() {
    actual="$(normalize_ngrok_tcp_url "$1")" || return 1
    if [ "$actual" = "$NGROK_TCP_URL" ]; then
        return 0
    fi
    echo "ngrok public endpoint ${actual} does not match reserved NGROK_TCP_URL ${NGROK_TCP_URL}" >&2
    return 1
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

load_persisted_config() {
    for key in $DEBIAN_SSH_PERSISTED_CONFIG_KEYS; do
        is_valid_env_key "$key" || continue
        eval "value=\${$key:-}"
        [ -n "$value" ] && continue
        path="$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key"
        [ -r "$path" ] && [ -s "$path" ] || continue
        value="$(cat "$path")" || continue
        [ -n "$value" ] || continue
        export "$key=$value"
    done
}

persist_config_key() {
    key="$1"
    value="$2"
    tmp="$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key.tmp.$$"

    mkdir -p "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" 2>/dev/null || {
        echo "could not create persisted config dir ${DEBIAN_SSH_PERSISTED_CONFIG_DIR}" >&2
        return 0
    }
    chmod 700 "$DEBIAN_SSH_PERSISTED_CONFIG_DIR" 2>/dev/null || true
    if ! (umask 077 && printf '%s\n' "$value" >"$tmp"); then
        echo "could not persist config key ${key}" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/$key" 2>/dev/null || {
        echo "could not install persisted config key ${key}" >&2
        rm -f "$tmp" 2>/dev/null || true
        return 0
    }
}

persist_runtime_config() {
    for key in $DEBIAN_SSH_PERSISTED_CONFIG_KEYS; do
        is_valid_env_key "$key" || continue
        eval "value=\${$key:-}"
        [ -n "$value" ] || continue
        persist_config_key "$key" "$value"
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

validate_uint() {
    key="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*)
            echo "$key must be an integer" >&2
            return 1
            ;;
    esac
}

validate_authorized_key_algorithm() {
    algorithm="$1"
    for allowed in $DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS; do
        [ "$algorithm" = "$allowed" ] && return 0
    done
    echo "unsupported SSH public key algorithm: ${algorithm}" >&2
    return 1
}

validate_authorized_key_line() {
    line="$1"
    key_file="$2"
    algorithm="${line%% *}"
    rest="${line#* }"
    key_body="${rest%% *}"

    [ "$algorithm" != "$line" ] || {
        echo "SSH public key is missing key material" >&2
        return 1
    }
    validate_authorized_key_algorithm "$algorithm" || return 1
    case "$key_body" in
        ''|*[!A-Za-z0-9+/=]*)
            echo "SSH public key has malformed base64" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$line" >"$key_file" || return 1
    if ! ssh-keygen -l -f "$key_file" >/tmp/debian-ssh-keygen.out 2>/tmp/debian-ssh-keygen.err; then
        echo "SSH public key could not be parsed by ssh-keygen" >&2
        cat /tmp/debian-ssh-keygen.err >&2 2>/dev/null || true
        rm -f /tmp/debian-ssh-keygen.out /tmp/debian-ssh-keygen.err
        return 1
    fi
    fingerprint="$(awk '{ print $2 }' /tmp/debian-ssh-keygen.out 2>/dev/null || true)"
    [ -z "$fingerprint" ] || echo "accepted SSH public key fingerprint ${fingerprint}" >&2
    rm -f /tmp/debian-ssh-keygen.out /tmp/debian-ssh-keygen.err
}

write_authorized_keys() {
    file="$1"
    tmp="${file}.tmp"
    key_tmp="${file}.check.$$"
    count=0

    validate_uint DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES" || return 1
    validate_uint DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS" || return 1

    input="${DEBIAN_SSH_AUTHORIZED_KEYS:-}"
    byte_count="$(printf '%s' "$input" | wc -c | tr -d ' ')"
    if [ "$byte_count" -gt "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES" ]; then
        echo "DEBIAN_SSH_AUTHORIZED_KEYS exceeds ${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES} bytes" >&2
        return 1
    fi
    case "$input" in
        *"-----BEGIN "*|*"PRIVATE KEY"*)
            echo "DEBIAN_SSH_AUTHORIZED_KEYS must contain public keys, not private keys" >&2
            return 1
            ;;
    esac
    sanitized="$(printf '%s' "$input" | tr '\r\t' '\n ')"

    : >"$tmp" || return 1
    printf '%s\n' "$sanitized" | while IFS= read -r line; do
        case "$line" in
            ''|\#*)
                continue
                ;;
        esac
        case "$line" in
            *[![:print:]]*)
                echo "SSH public key contains unsupported control characters" >&2
                exit 1
                ;;
        esac
        count=$((count + 1))
        if [ "$count" -gt "$DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS" ]; then
            echo "too many SSH public keys; max is ${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS}" >&2
            exit 1
        fi
        validate_authorized_key_line "$line" "$key_tmp" || exit 1
        if ! grep -qxF "$line" "$tmp"; then
            printf '%s\n' "$line" >>"$tmp" || exit 1
        fi
    done
    status="$?"
    rm -f "$key_tmp"
    if [ "$status" -ne 0 ]; then
        rm -f "$tmp"
        return "$status"
    fi
    if [ ! -s "$tmp" ]; then
        rm -f "$tmp"
        echo "DEBIAN_SSH_AUTHORIZED_KEYS must include at least one valid public key" >&2
        return 1
    fi
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$file"
}

prepare_home_target() {
    if [ -L "$DEBIAN_SSH_HOME" ]; then
        target="$(readlink "$DEBIAN_SSH_HOME")"
        case "$target" in
            /*)
                mkdir -p "$target"
                ;;
        esac
    fi
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
    prepare_home_target
    mkdir -p "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache/ngrok" "$DEBIAN_SSH_HOME/health"
    chmod 700 "$DEBIAN_SSH_HOME" 2>/dev/null || true
    chmod 700 "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache" "$DEBIAN_SSH_HOME/.cache/ngrok"
    write_authorized_keys "$DEBIAN_SSH_HOME/.ssh/authorized_keys"

    if [ ! -f "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key" ]; then
        ssh-keygen -q -t ed25519 -N '' -f "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key"
    fi
    chmod 600 "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key"
    chmod 644 "$DEBIAN_SSH_HOME/.ssh/ssh_host_ed25519_key.pub"

    write_sshd_config
    mark_unready
}

start_health() {
    busybox httpd -f -p "0.0.0.0:${DEBIAN_HEALTH_PORT}" -h "$DEBIAN_SSH_HOME/health" &
    HEALTH_PID="$!"
}

start_sshd() {
    rm -f "$DEBIAN_SSH_HOME/.ssh/sshd.pid"
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
        --url "$NGROK_TCP_URL" \
        --config "$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" \
        --log stdout \
        --log-format json &
    NGROK_PID="$!"
}

mark_unready() {
    rm -f \
        "$DEBIAN_SSH_HOME/health/healthz" \
        "$DEBIAN_SSH_HOME/health/ssh.txt" \
        "$DEBIAN_SSH_HOME/health/ngrok-url.txt" \
        "$DEBIAN_SSH_HOME/health/ngrok.json" \
        "$DEBIAN_SSH_HOME/health/ngrok.json.tmp"
}

mark_ready() {
    public_url="$1"
    ngrok_public_url_matches_reserved "$public_url" || return 1
    endpoint="$NGROK_TCP_URL"
    public_url="tcp://${endpoint}"
    host="${endpoint%:*}"
    port="${endpoint##*:}"

    printf '%s\n' "$public_url" >"$DEBIAN_SSH_HOME/health/ngrok-url.txt.tmp"
    printf 'ssh -p %s %s@%s\n' "$port" "$DEBIAN_SSH_USER" "$host" >"$DEBIAN_SSH_HOME/health/ssh.txt.tmp"
    printf 'ok\n' >"$DEBIAN_SSH_HOME/health/healthz.tmp"
    mv "$DEBIAN_SSH_HOME/health/ngrok-url.txt.tmp" "$DEBIAN_SSH_HOME/health/ngrok-url.txt"
    mv "$DEBIAN_SSH_HOME/health/ssh.txt.tmp" "$DEBIAN_SSH_HOME/health/ssh.txt"
    mv "$DEBIAN_SSH_HOME/health/healthz.tmp" "$DEBIAN_SSH_HOME/health/healthz"
}

process_running() {
    pid="${1:-}"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    stat="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [ -n "$stat" ] || return 1
    case "$stat" in
        *Z*)
            return 1
            ;;
    esac
    return 0
}

stop_process() {
    pid="${1:-}"
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

ssh_ready() {
    ssh-keyscan -T 2 -t ed25519 -p "$DEBIAN_SSH_PORT" 127.0.0.1 >/dev/null 2>&1
}

ngrok_public_url() {
    tmp="$DEBIAN_SSH_HOME/health/ngrok.json.tmp"
    if ! curl -fsS \
        --connect-timeout "$DEBIAN_NGROK_API_TIMEOUT_SECONDS" \
        --max-time "$DEBIAN_NGROK_API_TIMEOUT_SECONDS" \
        "http://127.0.0.1:${DEBIAN_NGROK_WEB_PORT}/api/tunnels" >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$DEBIAN_SSH_HOME/health/ngrok.json"
    jq -r '.tunnels[]?.public_url // empty' "$DEBIAN_SSH_HOME/health/ngrok.json" | awk '/^tcp:\/\// { print; exit }'
}

restart_sshd() {
    echo "sshd is not answering; restarting" >&2
    stop_process "${SSHD_PID:-}"
    start_sshd
}

restart_ngrok() {
    echo "ngrok is not running; restarting" >&2
    stop_process "${NGROK_PID:-}"
    start_ngrok
}

supervise_services() {
    ngrok_api_failures=0

    while :; do
        if ! process_running "${SSHD_PID:-}" || ! ssh_ready; then
            mark_unready
            ngrok_api_failures=0
            restart_sshd
            sleep "$DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS"
            continue
        fi

        if ! process_running "${NGROK_PID:-}"; then
            mark_unready
            ngrok_api_failures=0
            restart_ngrok
            sleep "$DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS"
            continue
        fi

        public_url="$(ngrok_public_url || true)"
        if [ -n "$public_url" ]; then
            ngrok_api_failures=0
            if ! mark_ready "$public_url"; then
                mark_unready
                restart_ngrok
            fi
        else
            ngrok_api_failures=$((ngrok_api_failures + 1))
            mark_unready
            if [ "$ngrok_api_failures" -ge "$DEBIAN_NGROK_API_FAILURE_RESTARTS" ]; then
                echo "ngrok API is not answering; restarting" >&2
                restart_ngrok
                ngrok_api_failures=0
            fi
        fi

        sleep "$DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS"
    done
}

cleanup() {
    [ -z "${HEALTH_PID:-}" ] || kill "$HEALTH_PID" 2>/dev/null || true
    [ -z "${SSHD_PID:-}" ] || kill "$SSHD_PID" 2>/dev/null || true
    [ -z "${NGROK_PID:-}" ] || kill "$NGROK_PID" 2>/dev/null || true
}

trap cleanup INT TERM EXIT

if [ "${DEBIAN_SSH_NGROK_ENTRYPOINT_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

wait_for_config
load_cap_config
load_persisted_config
require_nonempty_env NGROK_AUTHTOKEN
require_nonempty_env NGROK_TCP_URL
require_nonempty_env DEBIAN_SSH_AUTHORIZED_KEYS
normalize_ngrok_tcp_url_config
persist_runtime_config
prepare_home
start_health
start_sshd
start_ngrok
supervise_services
