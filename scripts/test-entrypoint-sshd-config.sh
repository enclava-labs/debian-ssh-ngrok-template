#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:sshd-config-test}"
container_name="debian-ssh-ngrok-sshd-config-$$"
stub_dir="$(mktemp -d)"

cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT INT TERM

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
root="/tmp/ngrok-root"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"

docker build -t "$IMAGE_TAG" .

docker run -d --name "$container_name" \
    -v "$stub_dir/ngrok:/usr/local/bin/ngrok:ro" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" test -f /home/user/.ssh/sshd_config 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! docker exec "$container_name" grep -qxF 'LoginGraceTime 60' /home/user/.ssh/sshd_config; then
    docker exec "$container_name" cat /home/user/.ssh/sshd_config >&2 || true
    echo "expected sshd_config to bound unauthenticated SSH sessions" >&2
    exit 1
fi

if ! docker exec "$container_name" grep -qxF 'MaxStartups 50:30:200' /home/user/.ssh/sshd_config; then
    docker exec "$container_name" cat /home/user/.ssh/sshd_config >&2 || true
    echo "expected sshd_config to tolerate public tunnel connection bursts" >&2
    exit 1
fi
