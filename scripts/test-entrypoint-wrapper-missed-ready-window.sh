#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:wrapper-missed-ready-window-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-wrapper-missed-ready-$$"
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

if [ "${DEBIAN_SSH_WRAPPER_RESTART_COUNT:-0}" -gt 0 ]; then
    cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:6666"}]}
JSON
elif [ ! -f /tmp/ngrok-initial-started ]; then
    touch /tmp/ngrok-initial-started
    cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
    (
        sleep 1
        cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
JSON
    ) &
else
    cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[]}
JSON
fi

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
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=0 \
    -e DEBIAN_SSH_RESTART_WRAPPER=1 \
    -e DEBIAN_SSH_RESTART_WRAPPER_CHECK_SECONDS=2 \
    -e DEBIAN_SSH_RESTART_WRAPPER_UNREADY_SECONDS=4 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 40); do
    if docker exec "$container_name" grep -qxF 'ssh -p 6666 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        exit 0
    fi
    sleep 1
done

docker logs "$container_name" >&2 || true
docker exec "$container_name" cat /home/user/health/ssh.txt >&2 2>/dev/null || true
echo "expected wrapper to recover after missing the initial ready window" >&2
exit 1
