#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:self-watchdog-health-exit-test}"
BUILD_CONTEXT="${BUILD_CONTEXT:-.}"

docker build -t "$IMAGE_TAG" "$BUILD_CONTEXT"

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-self-watchdog-$$"
wait_file="/tmp/debian-ssh-ngrok-self-watchdog-wait-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
    rm -f "$wait_file"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu

root="$(mktemp -d)"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"
chmod 0755 "$stub_dir"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=999 \
    -e DEBIAN_SSH_READY_MARKER=/proc/debian-ssh-ngrok-ready-seen \
    -e DEBIAN_SSH_SELF_WATCHDOG_CHECK_SECONDS=1 \
    -e DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS=4 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
    docker logs "$container_name" >&2 || true
    echo "expected initial ready endpoint before self-watchdog test" >&2
    exit 1
fi

health_pid="$(docker exec "$container_name" /bin/sh -eu -c "ps -eo pid,args | awk '/busybox httpd/ && /0.0.0.0:8080/ && !/awk/ { print \$1; exit }'")"
docker exec "$container_name" kill "$health_pid"

if ! timeout 20 docker wait "$container_name" >"$wait_file"; then
    docker logs "$container_name" >&2 || true
    echo "expected entrypoint to exit after post-ready health endpoint disappeared" >&2
    exit 1
fi

status="$(cat "$wait_file")"
case "$status" in
    0)
        docker logs "$container_name" >&2 || true
        echo "expected self-watchdog exit to be non-zero" >&2
        exit 1
        ;;
esac
