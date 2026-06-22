#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:debug-snapshot-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-debug-snapshot-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu

root="$(mktemp -d)"
mkdir -p "$root/api"
printf 'ngrok stub args: %s\n' "$*" >/tmp/debian-ssh-ngrok-agent.log

if [ ! -f /tmp/ngrok-debug-snapshot-started ]; then
    touch /tmp/ngrok-debug-snapshot-started
    cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
    (
        sleep 3
        cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
JSON
    ) &
else
    cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
JSON
fi

busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"
chmod 0755 "$stub_dir"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_AUTHTOKEN=test-token-secret \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_API_FAILURE_RESTARTS=99 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=60 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
    docker logs "$container_name" >&2 || true
    echo "expected initial ngrok endpoint before debug snapshot test" >&2
    exit 1
fi

for _ in $(seq 1 30); do
    if docker exec "$container_name" /bin/sh -c \
        "grep -qxF 'reason=ngrok API did not publish tcp tunnel' /home/user/health/debug.txt && grep -q '^status=no_tcp_tunnel ' /home/user/health/debug.txt" 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" /bin/sh -c \
    "grep -qxF 'reason=ngrok API did not publish tcp tunnel' /home/user/health/debug.txt && grep -q '^status=no_tcp_tunnel ' /home/user/health/debug.txt" 2>/dev/null; then
    docker logs "$container_name" >&2 || true
    docker exec "$container_name" cat /home/user/health/debug.txt >&2 2>/dev/null || true
    echo "expected debug snapshot to record ngrok API unready reason" >&2
    exit 1
fi

if docker exec "$container_name" grep -q 'test-token-secret' /home/user/health/debug.txt; then
    docker exec "$container_name" cat /home/user/health/debug.txt >&2 || true
    echo "expected debug snapshot to redact ngrok authtoken" >&2
    exit 1
fi

if ! docker exec "$container_name" grep -q -- '--authtoken <redacted>' /home/user/health/debug.txt; then
    docker exec "$container_name" cat /home/user/health/debug.txt >&2 || true
    echo "expected debug snapshot to show redacted ngrok authtoken" >&2
    exit 1
fi

if ! docker exec "$container_name" grep -q '^\[ngrok-log\]$' /home/user/health/debug.txt; then
    docker exec "$container_name" cat /home/user/health/debug.txt >&2 || true
    echo "expected debug snapshot to include ngrok log tail" >&2
    exit 1
fi
