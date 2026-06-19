#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:stop-timeout-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-stop-timeout-$$"
chmod 0755 "$stub_dir"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu

root="/tmp/ngrok-root"
started="/tmp/ngrok-started"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON

if [ ! -f "$started" ]; then
    touch "$started"
    (
        sleep 4
        cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
JSON
    ) &
fi

trap '' TERM
exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/.enclava/config
        printf "%s\n" test-token > /state/.enclava/config/NGROK_AUTHTOKEN
        touch /state/.enclava/config/.ready
        DEBIAN_NGROK_API_FAILURE_RESTARTS=1 DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 DEBIAN_STOP_TIMEOUT_SECONDS=2 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" test -e /home/user/health/healthz; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" test -e /home/user/health/healthz; then
    docker logs "$container_name" >&2 || true
    echo "expected initial healthz before stop timeout test" >&2
    exit 1
fi
initial_mtime="$(docker exec "$container_name" stat -c %Y /home/user/health/healthz)"

for _ in $(seq 1 20); do
    if ! docker exec "$container_name" test -e /home/user/health/healthz; then
        break
    fi
    sleep 1
done
if docker exec "$container_name" test -e /home/user/health/healthz; then
    docker logs "$container_name" >&2 || true
    echo "expected ngrok API failure to withdraw healthz before recovery" >&2
    exit 1
fi

for _ in $(seq 1 30); do
    if docker exec "$container_name" test -e /home/user/health/healthz; then
        current_mtime="$(docker exec "$container_name" stat -c %Y /home/user/health/healthz)"
        current="$(docker exec "$container_name" cat /home/user/health/ssh.txt 2>/dev/null || true)"
        if [ "$current_mtime" -gt "$initial_mtime" ] && [ "$current" = "ssh -p 5555 user@127.0.0.1" ]; then
            exit 0
        fi
    fi
    sleep 1
done

docker logs "$container_name" >&2 || true
echo "expected supervisor to recover after TERM-ignoring ngrok process" >&2
exit 1
