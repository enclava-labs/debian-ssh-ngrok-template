#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:persisted-config-bypass-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
state_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_name="debian-ssh-ngrok-persist-config-bypass-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    docker run --rm \
        --user 0:0 \
        -v "$state_dir:/state" \
        --entrypoint /bin/sh \
        "$IMAGE_TAG" \
        -eu -c 'rm -rf /state/* /state/.[!.]* /state/..?*' >/dev/null 2>&1 || true
    rm -rf "$stub_dir" "$state_dir"
    rm -f "$output_file"
}
trap cleanup EXIT

chmod 0755 "$stub_dir"
chmod 0777 "$state_dir"

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

docker run --rm \
    --user 0:0 \
    -v "$state_dir:/state" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/app-data/debian-ssh-ngrok/config
        printf "%s\n" test-token > /state/app-data/debian-ssh-ngrok/config/NGROK_AUTHTOKEN
        chown -R 10001:10001 /state/app-data
        chmod 700 /state/app-data/debian-ssh-ngrok/config
        chmod 600 /state/app-data/debian-ssh-ngrok/config/NGROK_AUTHTOKEN
    ' >/dev/null

docker run -d --name "$container_name" \
    -v "$state_dir:/state" \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=30 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 10); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

docker logs "$container_name" >"$output_file" 2>&1 || true
cat "$output_file" >&2
echo "expected persisted config to bypass CAP config wait" >&2
exit 1
