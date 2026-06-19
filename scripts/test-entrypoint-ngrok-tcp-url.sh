#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ngrok-tcp-url-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-tcp-url-$$"
args_file="/tmp/ngrok-args"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu
printf '%s\n' "$@" > /tmp/ngrok-args
root="$(mktemp -d)"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://reserved.tcp.example.com:22222"}]}
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
    -e NGROK_TCP_URL=tcp://reserved.tcp.example.com:22222 \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_name" test -s "$args_file"; then
        break
    fi
    sleep 1
done

if ! docker exec "$container_name" grep -qx -- '--url' "$args_file"; then
    docker logs "$container_name" >&2 || true
    docker exec "$container_name" cat "$args_file" >&2 || true
    echo "expected entrypoint to pass --url when NGROK_TCP_URL is configured" >&2
    exit 1
fi

if ! docker exec "$container_name" grep -qx -- 'tcp://reserved.tcp.example.com:22222' "$args_file"; then
    docker logs "$container_name" >&2 || true
    docker exec "$container_name" cat "$args_file" >&2 || true
    echo "expected entrypoint to pass the configured NGROK_TCP_URL value" >&2
    exit 1
fi
