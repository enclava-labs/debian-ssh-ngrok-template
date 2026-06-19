#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ngrok-unready-exit-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-unready-exit-$$"
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
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
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
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_API_FAILURE_RESTARTS=1 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=4 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

if ! timeout 20 docker wait "$container_name" >/tmp/debian-ssh-ngrok-unready-exit-status; then
    docker logs "$container_name" >&2 || true
    echo "expected sustained ngrok unready state to exit for container restart" >&2
    exit 1
fi

status="$(cat /tmp/debian-ssh-ngrok-unready-exit-status)"
rm -f /tmp/debian-ssh-ngrok-unready-exit-status
if [ "$status" -eq 0 ]; then
    docker logs "$container_name" >&2 || true
    echo "expected sustained ngrok unready exit to be non-zero" >&2
    exit 1
fi
