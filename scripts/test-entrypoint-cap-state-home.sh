#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:cap-state-home-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_name="debian-ssh-ngrok-cap-state-home-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
    rm -f "$output_file"
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
    --tmpfs /state:uid=0,gid=0,mode=0755 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

docker logs "$container_name" >"$output_file" 2>&1 || true
cat "$output_file" >&2
echo "expected entrypoint to run when /state is mounted root-owned" >&2
exit 1
