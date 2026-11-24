#!/bin/sh
set -eu

# D2 (template issue #3): a hostile NGROK_AUTHTOKEN (characters outside the
# ngrok base64url credential charset) must fail closed: the container stays
# alive and unready, the charset message is written, no ngrok.yml is
# created, and the token value never appears in any message or log. A valid
# base64url dummy token then starts the tunnel stub as before.

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ngrok-token-charset-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$stub_dir"
}

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu

printf '%s\n' "$@" >"$HOME/ngrok-argv.txt"

root="$(mktemp -d)"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON

exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"
chmod 0755 "$stub_dir"

container_name="debian-ssh-ngrok-token-charset-$$"
docker_cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
}
# Single EXIT trap runs both cleanups (the D3 idiom).
trap 'cleanup; docker_cleanup' EXIT

dummy_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINncqj+z395SDlU4JsYI38lpxfztRl6dQe9zANxPM/9W dummy-ngrok-template-test"

run_case() {
    hostile_token="$1"
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    docker run -d --name "$container_name" \
        --tmpfs /state:uid=10001,gid=10001,mode=0770 \
        --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
        -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
        -e NGROK_AUTHTOKEN="$hostile_token" \
        -e DEBIAN_SSH_AUTHORIZED_KEYS="$dummy_key" \
        -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
        -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
        -e DEBIAN_NGROK_API_FAILURE_RESTARTS=1 \
        -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=0 \
        -v "$stub_dir:/test-bin:ro" \
        "$IMAGE_TAG" >/dev/null

    for _ in $(seq 1 20); do
        if docker exec "$container_name" test -f /home/user/health/startup-error.txt; then
            break
        fi
        sleep 1
    done

    if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
        echo "case '$2': expected container to stay alive on a hostile token" >&2
        docker logs "$container_name" >&2 || true
        return 1
    fi
    if ! docker exec "$container_name" grep -qx 'NGROK_AUTHTOKEN has an unexpected character set' /home/user/health/startup-error.txt; then
        echo "case '$2': expected the charset startup error" >&2
        docker exec "$container_name" cat /home/user/health/startup-error.txt >&2 || true
        return 1
    fi
    if docker exec "$container_name" test -e /home/user/.config/ngrok/ngrok.yml; then
        echo "case '$2': no ngrok.yml may be written for a hostile token" >&2
        return 1
    fi
    if docker exec "$container_name" test -e /home/user/health/healthz; then
        echo "case '$2': hostile token must not publish healthz" >&2
        return 1
    fi
    # The token value must never be echoed back in any message or log.
    if docker exec "$container_name" sh -c "grep -rF '$hostile_token' /home/user/health 2>/dev/null"; then
        echo "case '$2': the hostile token value leaked into health output" >&2
        return 1
    fi
    if docker logs "$container_name" 2>&1 | grep -F "$hostile_token"; then
        echo "case '$2': the hostile token value leaked into logs" >&2
        return 1
    fi
}

# One hostile character each: a space, a double quote, a colon.
run_case 'abc def0123456789abcdef' space
run_case 'abc"def0123456789abcdef' dquote
run_case 'abc:def0123456789abcdef' colon

# A valid base64url dummy token starts the tunnel stub as before.
docker rm -f "$container_name" >/dev/null 2>&1 || true
valid_token="dummy-token-never-real_9f8e-7d6c"
docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_AUTHTOKEN="$valid_token" \
    -e DEBIAN_SSH_AUTHORIZED_KEYS="$dummy_key" \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_API_FAILURE_RESTARTS=1 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=0 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt; then
    docker logs "$container_name" >&2 || true
    echo "expected the valid base64url token to start the tunnel stub" >&2
    exit 1
fi

exit 0
