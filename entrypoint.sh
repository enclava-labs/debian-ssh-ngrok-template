#!/bin/sh
set -u

: "${DEBIAN_SSH_USER:=user}"
: "${DEBIAN_SSH_HOME:=/home/user}"
: "${DEBIAN_SSH_PORT:=2222}"
: "${DEBIAN_HEALTH_PORT:=8080}"
: "${DEBIAN_NGROK_WEB_PORT:=4040}"
: "${DEBIAN_NGROK_API_TIMEOUT_SECONDS:=3}"
: "${DEBIAN_NGROK_API_FAILURE_RESTARTS:=3}"
: "${DEBIAN_NGROK_UNREADY_EXIT_SECONDS:=300}"
: "${DEBIAN_NGROK_UNREADY_ACTION:=exit}"
: "${DEBIAN_SSH_RESTART_WRAPPER:=0}"
: "${DEBIAN_SSH_RESTART_DELAY_SECONDS:=2}"
: "${DEBIAN_SSH_RESTART_WRAPPER_CHECK_SECONDS:=5}"
: "${DEBIAN_SSH_RESTART_WRAPPER_UNREADY_SECONDS:=60}"
: "${DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS:=5}"
: "${DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS:=60}"
: "${DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS:=0}"
: "${DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS:=15}"
: "${DEBIAN_SSH_WRAPPED:=0}"
: "${DEBIAN_SSH_WRAPPER_RESTART_COUNT:=0}"
: "${DEBIAN_SSH_READY_MARKER:=/tmp/debian-ssh-ngrok-ready-seen}"
: "${DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS:=5}"
: "${DEBIAN_STOP_TIMEOUT_SECONDS:=5}"
: "${DEBIAN_SSH_DEBUG_FILE:=$DEBIAN_SSH_HOME/health/debug.txt}"
: "${DEBIAN_SSH_READY_KEY:=$DEBIAN_SSH_HOME/.ssh/ssh_ready_ed25519_key}"
: "${DEBIAN_SSH_HOST_KEY:=$DEBIAN_SSH_HOME/.ssh/dropbear_ed25519_host_key}"
: "${DEBIAN_SSH_PID_FILE:=$DEBIAN_SSH_HOME/.ssh/ssh_daemon.pid}"
: "${DEBIAN_SSH_NGROK_API_STATUS_FILE:=$DEBIAN_SSH_HOME/health/ngrok-api-last.txt}"
: "${DEBIAN_SSH_NGROK_LOG_FILE:=/tmp/debian-ssh-ngrok-agent.log}"
: "${DEBIAN_SSH_NGROK_LOG_LINES:=80}"
: "${ENCLAVA_REQUIRED_CONFIG_KEYS:=NGROK_AUTHTOKEN,DEBIAN_SSH_AUTHORIZED_KEYS}"
: "${NGROK_TCP_URL:=}"
: "${DEBIAN_SSH_CAP_CONFIG_DIRS:=/state/app-data/.enclava/config /state/.enclava/config /home/user/.enclava/config}"
: "${DEBIAN_SSH_PERSISTED_CONFIG_DIR:=/state/app-data/debian-ssh-ngrok/config}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES:=32768}"
: "${DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS:=10}"
: "${DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS:=ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256}"
if [ -z "${DEBIAN_SSH_CONFIG_WAIT_SECONDS+x}" ]; then
    if [ -n "${ENCLAVA_CONTAINER_NAME:-}" ]; then
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=300
    else
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=0
    fi
fi

run_restart_wrapper() {
    child_pid=""

    wrapper_child_running() {
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

    wrapper_health_ready() {
        [ -f "$DEBIAN_SSH_HOME/health/healthz" ] || return 1
        [ -f "$DEBIAN_SSH_HOME/health/ssh.txt" ] || return 1
        curl -fsS \
            --connect-timeout 2 \
            --max-time 2 \
            "http://127.0.0.1:${DEBIAN_HEALTH_PORT}/healthz" >/dev/null 2>&1
    }

    wrapper_ready_seen() {
        [ -f "$DEBIAN_SSH_READY_MARKER" ] || [ -f "$DEBIAN_SSH_HOME/health/.ready-seen" ]
    }

    stop_wrapper_child() {
        pid="${1:-}"
        [ -n "$pid" ] || return 0
        kill "$pid" 2>/dev/null || true
        elapsed=0
        while wrapper_child_running "$pid"; do
            if [ "$elapsed" -ge "$DEBIAN_STOP_TIMEOUT_SECONDS" ]; then
                kill -KILL "$pid" 2>/dev/null || true
                break
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done

        elapsed=0
        while wrapper_child_running "$pid"; do
            if [ "$elapsed" -ge 2 ]; then
                echo "wrapper child ${pid} still running after SIGKILL" >&2
                return 1
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done

        return 0
    }

    terminate_wrapper() {
        status="$1"
        trap - INT TERM
        if [ -n "${child_pid:-}" ]; then
            stop_wrapper_child "$child_pid" || exit "$status"
            wait "$child_pid" 2>/dev/null || true
        fi
        exit "$status"
    }

    trap 'terminate_wrapper 130' INT
    trap 'terminate_wrapper 143' TERM

    restart_count=0
    while :; do
        rm -f "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
        DEBIAN_SSH_WRAPPED=1 DEBIAN_SSH_WRAPPER_RESTART_COUNT="$restart_count" "$0" "$@" &
        child_pid="$!"
        wrapper_seen_ready=0
        wrapper_unready_seconds=0
        while wrapper_child_running "$child_pid"; do
            if wrapper_health_ready; then
                wrapper_seen_ready=1
                wrapper_unready_seconds=0
            else
                if wrapper_ready_seen; then
                    wrapper_seen_ready=1
                fi
                if [ "$wrapper_seen_ready" = "1" ]; then
                    wrapper_unready_seconds=$((wrapper_unready_seconds + DEBIAN_SSH_RESTART_WRAPPER_CHECK_SECONDS))
                    if [ "$wrapper_unready_seconds" -ge "$DEBIAN_SSH_RESTART_WRAPPER_UNREADY_SECONDS" ]; then
                        echo "debian SSH entrypoint stayed unready for ${wrapper_unready_seconds}s; restarting child" >&2
                        if ! stop_wrapper_child "$child_pid"; then
                            echo "wrapper child ${child_pid} did not stop; exiting for container restart" >&2
                            exit 1
                        fi
                        break
                    fi
                fi
            fi
            sleep "$DEBIAN_SSH_RESTART_WRAPPER_CHECK_SECONDS"
        done
        wait "$child_pid"
        status="$?"
        child_pid=""
        echo "debian SSH entrypoint exited with status ${status}; restarting in ${DEBIAN_SSH_RESTART_DELAY_SECONDS}s" >&2
        sleep "$DEBIAN_SSH_RESTART_DELAY_SECONDS"
        restart_count=$((restart_count + 1))
    done
}

if [ "$DEBIAN_SSH_RESTART_WRAPPER" = "1" ] && [ "$DEBIAN_SSH_WRAPPED" != "1" ]; then
    run_restart_wrapper "$@"
fi
rm -f "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
rm -f "$DEBIAN_SSH_HOME/health/.ready-seen" 2>/dev/null || true

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
        if [ -d "$dir" ] && required_config_present_in_dir "$dir"; then
            printf '%s\n' "$dir"
            return 0
        fi
    done

    for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
        if config_dir_ready "$dir"; then
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

config_dir_ready() {
    dir="$1"
    [ -f "$dir/.ready" ] && return 0

    case "$dir" in
        */.enclava/config)
            [ -f "${dir%/config}/luks-ready" ] && return 0
            ;;
    esac
    return 1
}

required_config_present_in_env() {
    keys="$(required_config_keys)"
    [ -n "$keys" ] || return 0

    for key in $keys; do
        is_valid_env_key "$key" || return 1
        eval "value=\${$key:-}"
        [ -n "$value" ] || return 1
    done
    return 0
}

required_config_present_in_dir() {
    dir="$1"
    keys="$(required_config_keys)"
    [ -n "$keys" ] || return 0

    for key in $keys; do
        is_valid_env_key "$key" || return 1
        eval "value=\${$key:-}"
        [ -n "$value" ] && continue
        [ -r "$dir/$key" ] && [ -s "$dir/$key" ] || return 1
    done
    return 0
}

wait_for_config() {
    seconds="$DEBIAN_SSH_CONFIG_WAIT_SECONDS"
    case "$seconds" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_CONFIG_WAIT_SECONDS must be an integer" >&2
            return 1
            ;;
    esac
    required_config_present_in_env && return 0
    [ "$seconds" -gt 0 ] || return 0

    elapsed=0
    while [ "$elapsed" -lt "$seconds" ]; do
        for dir in $DEBIAN_SSH_CAP_CONFIG_DIRS; do
            if config_dir_ready "$dir" && required_config_present_in_dir "$dir"; then
                return 0
            fi
        done
        sleep 1
        elapsed=$((elapsed + 1))
    done

    echo "CAP config was not marked ready after ${seconds}s; continuing with current environment" >&2
}

required_config_keys() {
    printf '%s' "${ENCLAVA_REQUIRED_CONFIG_KEYS:-}" | tr ',' ' '
}

load_cap_config() {
    dir="$(first_config_dir || true)"
    [ -n "${dir:-}" ] || return 0

    for path in "$dir"/*; do
        [ -f "$path" ] || continue
        [ -r "$path" ] || continue
        key="${path##*/}"
        is_valid_env_key "$key" || continue
        value="$(cat "$path")" || return 1
        export "$key=$value"
    done
}

load_persisted_config() {
    keys="$(required_config_keys)"
    [ -n "$keys" ] || return 0

    for key in $keys; do
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

persist_required_config() {
    keys="$(required_config_keys)"
    [ -n "$keys" ] || return 0

    for key in $keys; do
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
        return 1
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
    if printf '%s' "$input" | LC_ALL=C grep -q '[[:cntrl:]]' 2>/dev/null; then
        sanitized="$(printf '%s' "$input" | tr '\r\t' '\n  ')"
    else
        sanitized="$input"
    fi

    tmp="$DEBIAN_SSH_HOME/.ssh/authorized_keys.tmp.$$"
    key_tmp="$DEBIAN_SSH_HOME/.ssh/authorized_key_check.$$"
    count=0
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
    [ "$status" -eq 0 ] || {
        rm -f "$tmp"
        return "$status"
    }
    if [ ! -s "$tmp" ]; then
        echo "DEBIAN_SSH_AUTHORIZED_KEYS must include at least one valid public key" >&2
        rm -f "$tmp"
        return 1
    fi
    chmod 600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
}

append_authorized_key_line() {
    file="$1"
    key="$2"
    if [ -f "$file" ] && grep -qxF "$key" "$file"; then
        return 0
    fi
    printf '%s\n' "$key" >>"$file"
}

prepare_ssh_ready_key() {
    if [ ! -f "$DEBIAN_SSH_READY_KEY" ]; then
        ssh-keygen -q -t ed25519 -N '' -C 'debian-ssh-ngrok-readiness' -f "$DEBIAN_SSH_READY_KEY" || return 1
    fi
    if [ ! -f "$DEBIAN_SSH_READY_KEY.pub" ]; then
        ssh-keygen -y -f "$DEBIAN_SSH_READY_KEY" >"$DEBIAN_SSH_READY_KEY.pub" || return 1
    fi
    chmod 600 "$DEBIAN_SSH_READY_KEY" || return 1
    chmod 644 "$DEBIAN_SSH_READY_KEY.pub" || return 1
    append_authorized_key_line "$DEBIAN_SSH_HOME/.ssh/authorized_keys" "$(cat "$DEBIAN_SSH_READY_KEY.pub")"
}

prepare_home_target() {
    if [ -L "$DEBIAN_SSH_HOME" ]; then
        target="$(readlink "$DEBIAN_SSH_HOME")"
        case "$target" in
            /*)
                mkdir -p "$target" || return 1
                ;;
        esac
    fi
}

prepare_home() {
    prepare_home_target || return 1
    mkdir -p "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache/ngrok" "$DEBIAN_SSH_HOME/health" || return 1
    chmod 700 "$DEBIAN_SSH_HOME" 2>/dev/null || true
    chmod 700 "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/.config" "$DEBIAN_SSH_HOME/.config/ngrok" "$DEBIAN_SSH_HOME/.cache" "$DEBIAN_SSH_HOME/.cache/ngrok" || return 1
    cat >"$DEBIAN_SSH_HOME/.profile" <<'EOF' || return 1
echo "Welcome to Enclava Debian SSH."
echo
echo "Persistent data lives in /state."
echo "The root filesystem is platform-managed and may show Kata implementation details."
EOF
    chmod 644 "$DEBIAN_SSH_HOME/.profile" || return 1

    if [ ! -f "$DEBIAN_SSH_HOST_KEY" ]; then
        dropbearkey -t ed25519 -f "$DEBIAN_SSH_HOST_KEY" >/dev/null 2>&1 || return 1
    fi
    chmod 600 "$DEBIAN_SSH_HOST_KEY" || return 1

    mark_unready "prepare_home" || return 1
}

start_health() {
    busybox httpd -f -p "0.0.0.0:${DEBIAN_HEALTH_PORT}" -h "$DEBIAN_SSH_HOME/health" &
    HEALTH_PID="$!"
}

start_sshd() {
    rm -f "$DEBIAN_SSH_PID_FILE"
    /usr/sbin/dropbear \
        -F \
        -E \
        -s \
        -w \
        -p "0.0.0.0:${DEBIAN_SSH_PORT}" \
        -P "$DEBIAN_SSH_PID_FILE" \
        -r "$DEBIAN_SSH_HOST_KEY" &
    SSHD_PID="$!"
}

start_ngrok() {
    export HOME="$DEBIAN_SSH_HOME"
    export XDG_CONFIG_HOME="$DEBIAN_SSH_HOME/.config"
    export XDG_CACHE_HOME="$DEBIAN_SSH_HOME/.cache"
    rm -rf "$DEBIAN_SSH_HOME/.cache/ngrok"
    mkdir -p "$DEBIAN_SSH_HOME/.cache/ngrok" || return 1
    chmod 700 "$DEBIAN_SSH_HOME/.cache/ngrok" || return 1
    mkdir -p "${DEBIAN_SSH_NGROK_LOG_FILE%/*}" || return 1
    : >"$DEBIAN_SSH_NGROK_LOG_FILE" || return 1
    chmod 600 "$DEBIAN_SSH_NGROK_LOG_FILE" || return 1
    cat >"$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" <<EOF
version: 3
agent:
  web_addr: 127.0.0.1:${DEBIAN_NGROK_WEB_PORT}
  log: ${DEBIAN_SSH_NGROK_LOG_FILE}
  log_format: json
  log_level: debug
EOF
    if [ -n "$NGROK_TCP_URL" ]; then
        ngrok tcp "127.0.0.1:${DEBIAN_SSH_PORT}" \
            --url "$NGROK_TCP_URL" \
            --authtoken "$NGROK_AUTHTOKEN" \
            --config "$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" &
    else
        ngrok tcp "127.0.0.1:${DEBIAN_SSH_PORT}" \
            --authtoken "$NGROK_AUTHTOKEN" \
            --config "$DEBIAN_SSH_HOME/.config/ngrok/ngrok.yml" &
    fi
    NGROK_PID="$!"
}

mark_unready() {
    write_debug_snapshot "${1:-mark_unready}"
    rm -f \
        "$DEBIAN_SSH_HOME/health/healthz" \
        "$DEBIAN_SSH_HOME/health/ssh.txt" \
        "$DEBIAN_SSH_HOME/health/ngrok-url.txt" \
        "$DEBIAN_SSH_HOME/health/ngrok.json" \
        "$DEBIAN_SSH_HOME/health/ngrok.json.tmp"
}

redact_debug_stream() {
    sed -E \
        -e 's/--authtoken[= ]+[^ ]+/--authtoken <redacted>/g' \
        -e 's/NGROK_AUTHTOKEN=[^ ]+/NGROK_AUTHTOKEN=<redacted>/g' \
        -e 's/("(Authtoken|Token|Cookie)"[[:space:]]*:[[:space:]]*")[^"]+/\1<redacted>/g'
}

write_debug_snapshot() {
    reason="$1"
    [ -n "$DEBIAN_SSH_DEBUG_FILE" ] || return 0
    mkdir -p "${DEBIAN_SSH_DEBUG_FILE%/*}" 2>/dev/null || return 0
    tmp="${DEBIAN_SSH_DEBUG_FILE}.tmp.$$"
    {
        printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
        printf 'reason=%s\n' "$reason"
        printf 'wrapper_restart_count=%s\n' "${DEBIAN_SSH_WRAPPER_RESTART_COUNT:-}"
        printf 'reexec_count=%s\n' "${DEBIAN_SSH_REEXEC_COUNT:-}"
        printf 'entrypoint_unready_seconds=%s\n' "${entrypoint_unready_seconds:-}"
        printf 'ngrok_api_failures=%s\n' "${ngrok_api_failures:-}"
        printf 'health_pid=%s ssh_pid=%s ngrok_pid=%s self_watchdog_pid=%s\n' \
            "${HEALTH_PID:-}" "${SSHD_PID:-}" "${NGROK_PID:-}" "${SELF_WATCHDOG_PID:-}"
        printf '\n[ngrok-api-status]\n'
        cat "$DEBIAN_SSH_NGROK_API_STATUS_FILE" 2>/dev/null || true
        printf '\n[processes]\n'
        ps -eo pid,ppid,stat,args 2>/dev/null | grep -E 'debian-ssh|ngrok|dropbear|busybox httpd' | grep -v grep || true
        if [ -n "${NGROK_PID:-}" ]; then
            printf '\n[ngrok-proc-status]\n'
            cat "/proc/$NGROK_PID/status" 2>/dev/null || true
            printf 'wchan='
            cat "/proc/$NGROK_PID/wchan" 2>/dev/null || true
            printf '\n'
        fi
        printf '\n[ngrok-json]\n'
        cat "$DEBIAN_SSH_HOME/health/ngrok.json" 2>/dev/null || true
        printf '\n[ngrok-log]\n'
        tail -n "$DEBIAN_SSH_NGROK_LOG_LINES" "$DEBIAN_SSH_NGROK_LOG_FILE" 2>/dev/null || true
    } | redact_debug_stream >"$tmp" 2>/dev/null || {
        rm -f "$tmp" 2>/dev/null || true
        return 0
    }
    mv "$tmp" "$DEBIAN_SSH_DEBUG_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

write_startup_error() {
    message="$1"
    mkdir -p "$DEBIAN_SSH_HOME/health" 2>/dev/null || true
    printf '%s\n' "$message" >"$DEBIAN_SSH_HOME/health/startup-error.txt.tmp" 2>/dev/null || return 0
    mv "$DEBIAN_SSH_HOME/health/startup-error.txt.tmp" "$DEBIAN_SSH_HOME/health/startup-error.txt" 2>/dev/null || true
}

mark_ready() {
    public_url="$1"
    endpoint="${public_url#tcp://}"
    host="${endpoint%:*}"
    port="${endpoint##*:}"

    printf '%s\n' "$public_url" >"$DEBIAN_SSH_HOME/health/ngrok-url.txt.tmp"
    printf 'ssh -p %s %s@%s\n' "$port" "$DEBIAN_SSH_USER" "$host" >"$DEBIAN_SSH_HOME/health/ssh.txt.tmp"
    printf 'ok\n' >"$DEBIAN_SSH_HOME/health/healthz.tmp"
    mv "$DEBIAN_SSH_HOME/health/ngrok-url.txt.tmp" "$DEBIAN_SSH_HOME/health/ngrok-url.txt"
    mv "$DEBIAN_SSH_HOME/health/ssh.txt.tmp" "$DEBIAN_SSH_HOME/health/ssh.txt"
    mv "$DEBIAN_SSH_HOME/health/healthz.tmp" "$DEBIAN_SSH_HOME/health/healthz"
    touch "$DEBIAN_SSH_HOME/health/.ready-seen" 2>/dev/null || true
    touch "$DEBIAN_SSH_READY_MARKER" 2>/dev/null || true
    rm -f "$DEBIAN_SSH_HOME/health/startup-error.txt"
}

process_running() {
    pid="${1:-}"
    [ -n "$pid" ] || return 1
    stat="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    [ -n "$stat" ] || return 1
    case "$stat" in
        *Z*)
            return 1
            ;;
    esac
    return 0
}

sshd_pids() {
    ps -eo pid=,args= 2>/dev/null | awk '
        $2 == "/usr/sbin/dropbear" || $2 == "dropbear" { print $1 }
    '
}

kill_sshd_pid() {
    signal="$1"
    pid="$2"
    kill "-$signal" "$pid" 2>/dev/null || true
}

stop_process() {
    pid="${1:-}"
    [ -n "$pid" ] || return 0
    if ! process_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi

    kill "$pid" 2>/dev/null || true
    elapsed=0
    while process_running "$pid"; do
        if [ "$elapsed" -ge "$DEBIAN_STOP_TIMEOUT_SECONDS" ]; then
            echo "process ${pid} did not stop after ${DEBIAN_STOP_TIMEOUT_SECONDS}s; killing" >&2
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    elapsed=0
    while process_running "$pid"; do
        if [ "$elapsed" -ge 2 ]; then
            echo "process ${pid} did not stop after SIGKILL" >&2
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$pid" 2>/dev/null || true
}

stop_sshd() {
    pids="$(sshd_pids || true)"
    [ -n "$pids" ] || return 0

    for pid in $pids; do
        kill_sshd_pid TERM "$pid"
    done

    elapsed=0
    while :; do
        remaining=""
        for pid in $pids; do
            if process_running "$pid"; then
                remaining="${remaining} ${pid}"
            fi
        done
        [ -n "$remaining" ] || break

        if [ "$elapsed" -ge "$DEBIAN_STOP_TIMEOUT_SECONDS" ]; then
            echo "sshd processes did not stop after ${DEBIAN_STOP_TIMEOUT_SECONDS}s; killing" >&2
            for pid in $remaining; do
                kill_sshd_pid KILL "$pid"
            done
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    elapsed=0
    while :; do
        remaining=""
        for pid in $pids; do
            if process_running "$pid"; then
                remaining="${remaining} ${pid}"
            fi
        done
        [ -n "$remaining" ] || break

        if [ "$elapsed" -ge 2 ]; then
            echo "sshd processes still running after SIGKILL:${remaining}; skipping wait" >&2
            write_debug_snapshot "sshd still running after SIGKILL"
            break
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    for pid in $pids; do
        if process_running "$pid"; then
            continue
        fi
        wait "$pid" 2>/dev/null || true
    done
}

ssh_ready() {
    port_hex="$(printf '%04X' "$DEBIAN_SSH_PORT" 2>/dev/null)" || return 1
    awk -v port=":${port_hex}" '
        $2 ~ port "$" && $4 == "0A" { found=1 }
        END { exit found ? 0 : 1 }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

ssh_session_ready() {
    [ -r "$DEBIAN_SSH_READY_KEY" ] || return 1
    timeout "$DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS" ssh -F /dev/null \
        -i "$DEBIAN_SSH_READY_KEY" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o ConnectionAttempts=1 \
        -o GlobalKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -o LogLevel=ERROR \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$DEBIAN_SSH_PORT" \
        "${DEBIAN_SSH_USER}@127.0.0.1" \
        true </dev/null >/dev/null 2>&1
}

ngrok_public_url() {
    tmp="$DEBIAN_SSH_HOME/health/ngrok.json.tmp"
    curl_exit=0
    curl -fsS \
        --connect-timeout "$DEBIAN_NGROK_API_TIMEOUT_SECONDS" \
        --max-time "$DEBIAN_NGROK_API_TIMEOUT_SECONDS" \
        "http://127.0.0.1:${DEBIAN_NGROK_WEB_PORT}/api/tunnels" >"$tmp" || curl_exit="$?"
    if [ "$curl_exit" -ne 0 ]; then
        printf 'status=curl_failed exit=%s timestamp=%s\n' \
            "$curl_exit" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
            >"$DEBIAN_SSH_NGROK_API_STATUS_FILE" 2>/dev/null || true
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$DEBIAN_SSH_HOME/health/ngrok.json"
    public_url="$(jq -r '.tunnels[]?.public_url // empty' "$DEBIAN_SSH_HOME/health/ngrok.json" | awk '/^tcp:\/\// { print; exit }')"
    if [ -n "$public_url" ]; then
        printf 'status=ok public_url=%s timestamp=%s\n' \
            "$public_url" "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
            >"$DEBIAN_SSH_NGROK_API_STATUS_FILE" 2>/dev/null || true
        printf '%s\n' "$public_url"
        return 0
    fi
    printf 'status=no_tcp_tunnel timestamp=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" \
        >"$DEBIAN_SSH_NGROK_API_STATUS_FILE" 2>/dev/null || true
    return 1
}

restart_sshd() {
    echo "SSH daemon is not answering; restarting" >&2
    stop_sshd || true
    start_sshd
}

restart_health() {
    echo "health server is not running; restarting" >&2
    stop_process "${HEALTH_PID:-}" || true
    start_health
}

health_endpoint_ready() {
    [ -f "$DEBIAN_SSH_HOME/health/healthz" ] || return 1
    [ -f "$DEBIAN_SSH_HOME/health/ssh.txt" ] || return 1
    curl -fsS \
        --connect-timeout 2 \
        --max-time 2 \
        "http://127.0.0.1:${DEBIAN_HEALTH_PORT}/healthz" >/dev/null 2>&1
}

start_self_watchdog() {
    case "$DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS must be an integer" >&2
            return 1
            ;;
    esac
    case "$DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS must be an integer" >&2
            return 1
            ;;
    esac
    [ "$DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS" -gt 0 ] || return 0
    [ "$DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS" -gt 0 ] || return 0

    parent_pid="$$"
    (
        seen_ready=0
        unready_seconds=0
        while :; do
            if [ -f "$DEBIAN_SSH_READY_MARKER" ] \
                || [ -f "$DEBIAN_SSH_HOME/health/.ready-seen" ] \
                || [ -f "$DEBIAN_SSH_HOME/health/healthz" ]; then
                seen_ready=1
            fi

            if [ "$seen_ready" = "1" ]; then
                if health_endpoint_ready; then
                    unready_seconds=0
                else
                    unready_seconds=$((unready_seconds + DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS))
                    if [ "$unready_seconds" -ge "$DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS" ]; then
                        echo "health endpoint stayed unready for ${unready_seconds}s; terminating entrypoint" >&2
                        kill -TERM "$parent_pid" 2>/dev/null || true
                        exit 0
                    fi
                fi
            fi

            sleep "$DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS"
        done
    ) &
    SELF_WATCHDOG_PID="$!"
}

validate_ssh_login_watchdog_config() {
    case "$DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS must be an integer" >&2
            return 1
            ;;
    esac
    case "$DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS" in
        ''|*[!0-9]*)
            echo "DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS must be an integer" >&2
            return 1
            ;;
    esac
    if [ "$DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS" -gt 0 ] \
        && [ "$DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS" -le 0 ]; then
        echo "DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS must be greater than zero when login checks are enabled" >&2
        return 1
    fi
}

restart_ngrok() {
    echo "ngrok is not running; restarting" >&2
    stop_process "${NGROK_PID:-}" || true
    start_ngrok
}

reexec_entrypoint() {
    reason="${1:-entrypoint}"
    echo "${reason} stayed unready for ${entrypoint_unready_seconds}s; re-execing entrypoint" >&2
    trap - INT TERM EXIT
    stop_process "${NGROK_PID:-}" || true
    stop_sshd || true
    stop_process "${HEALTH_PID:-}" || true
    DEBIAN_SSH_REEXEC_COUNT=$((DEBIAN_SSH_REEXEC_COUNT + 1))
    export DEBIAN_SSH_REEXEC_COUNT
    exec "$0"
    echo "failed to re-exec entrypoint" >&2
    exit 1
}

record_entrypoint_unready() {
    reason="$1"
    entrypoint_unready_seconds=$((entrypoint_unready_seconds + DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS))
    if [ "$DEBIAN_NGROK_UNREADY_EXIT_SECONDS" -gt 0 ] \
        && [ "$entrypoint_unready_seconds" -ge "$DEBIAN_NGROK_UNREADY_EXIT_SECONDS" ]; then
        case "$DEBIAN_NGROK_UNREADY_ACTION" in
            exit)
                echo "${reason} stayed unready for ${entrypoint_unready_seconds}s; exiting for container restart" >&2
                exit 1
                ;;
            reexec)
                reexec_entrypoint "$reason"
                ;;
            *)
                echo "invalid DEBIAN_NGROK_UNREADY_ACTION: ${DEBIAN_NGROK_UNREADY_ACTION}" >&2
                exit 1
                ;;
        esac
    fi
}

sleep_supervise_interval() {
    remaining="$DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS"
    while [ "$remaining" -gt 0 ]; do
        sleep 1
        remaining=$((remaining - 1))
    done
}

supervise_services() {
    ngrok_api_failures=0
    entrypoint_unready_seconds=0
    DEBIAN_SSH_REEXEC_COUNT="${DEBIAN_SSH_REEXEC_COUNT:-0}"
    last_ssh_login_check_epoch="$(date +%s)"

    while :; do
        if ! process_running "${HEALTH_PID:-}"; then
            mark_unready "health server not running"
            record_entrypoint_unready "health server"
            restart_health
            sleep_supervise_interval
            continue
        fi

        if ! process_running "${SSHD_PID:-}" || ! ssh_ready; then
            mark_unready "SSH daemon not ready"
            ngrok_api_failures=0
            record_entrypoint_unready "SSH daemon"
            restart_sshd
            sleep_supervise_interval
            continue
        fi

        if ! process_running "${NGROK_PID:-}"; then
            mark_unready "ngrok process not running"
            ngrok_api_failures=0
            record_entrypoint_unready "ngrok"
            restart_ngrok
            sleep_supervise_interval
            continue
        fi

        public_url="$(ngrok_public_url || true)"
        if [ -n "$public_url" ]; then
            now="$(date +%s)"
            if [ ! -f "$DEBIAN_SSH_READY_MARKER" ] && [ ! -f "$DEBIAN_SSH_HOME/health/.ready-seen" ]; then
                last_ssh_login_check_epoch="$now"
            elif [ "$DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS" -gt 0 ] \
                && [ $((now - last_ssh_login_check_epoch)) -ge "$DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS" ]; then
                if ssh_session_ready; then
                    last_ssh_login_check_epoch="$now"
                else
                    mark_unready "ssh session not ready"
                    ngrok_api_failures=0
                    record_entrypoint_unready "ssh session"
                    restart_sshd
                    sleep_supervise_interval
                    continue
                fi
            fi
            ngrok_api_failures=0
            entrypoint_unready_seconds=0
            mark_ready "$public_url"
        else
            ngrok_api_failures=$((ngrok_api_failures + 1))
            mark_unready "ngrok API did not publish tcp tunnel"
            record_entrypoint_unready "ngrok"
            if [ "$ngrok_api_failures" -ge "$DEBIAN_NGROK_API_FAILURE_RESTARTS" ]; then
                echo "ngrok API is not answering; restarting" >&2
                restart_ngrok
                ngrok_api_failures=0
            fi
        fi

        sleep_supervise_interval
    done
}

cleanup() {
    [ -z "${SELF_WATCHDOG_PID:-}" ] || kill "$SELF_WATCHDOG_PID" 2>/dev/null || true
    [ -z "${HEALTH_PID:-}" ] || kill "$HEALTH_PID" 2>/dev/null || true
    stop_sshd || true
    [ -z "${NGROK_PID:-}" ] || kill "$NGROK_PID" 2>/dev/null || true
}

fail_stay_alive() {
    message="$1"
    echo "$message" >&2
    write_startup_error "$message"
    mark_unready "$message"
    while :; do
        if ! process_running "${HEALTH_PID:-}"; then
            start_health || true
        fi
        sleep_supervise_interval
    done
}

terminate() {
    status="$1"
    trap - INT TERM EXIT
    cleanup
    exit "$status"
}

trap 'terminate 130' INT
trap 'terminate 143' TERM
trap cleanup EXIT

if [ "${DEBIAN_SSH_NGROK_ENTRYPOINT_TEST:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

prepare_home || fail_stay_alive "prepare_home failed"
start_health || fail_stay_alive "health server failed to start"
load_persisted_config || fail_stay_alive "persisted config load failed"
wait_for_config || fail_stay_alive "CAP config wait failed"
load_cap_config || fail_stay_alive "CAP config load failed"
load_persisted_config || fail_stay_alive "persisted config load failed"
require_nonempty_env NGROK_AUTHTOKEN || fail_stay_alive "NGROK_AUTHTOKEN is required"
require_nonempty_env DEBIAN_SSH_AUTHORIZED_KEYS || fail_stay_alive "DEBIAN_SSH_AUTHORIZED_KEYS is required"
write_authorized_keys || fail_stay_alive "SSH authorized key validation failed"
prepare_ssh_ready_key || fail_stay_alive "SSH readiness key failed"
persist_required_config || true
validate_ssh_login_watchdog_config || fail_stay_alive "ssh login watchdog config invalid"
start_sshd || fail_stay_alive "SSH daemon failed to start"
start_ngrok || fail_stay_alive "ngrok failed to start"
start_self_watchdog || fail_stay_alive "self watchdog failed to start"
supervise_services
