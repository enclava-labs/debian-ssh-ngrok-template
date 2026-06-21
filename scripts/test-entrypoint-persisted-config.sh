#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:persisted-config-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
state_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_one="debian-ssh-ngrok-persist-config-one-$$"
container_two="debian-ssh-ngrok-persist-config-two-$$"
cleanup() {
    docker rm -f "$container_one" "$container_two" >/dev/null 2>&1 || true
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

docker run -d --name "$container_one" \
    -v "$state_dir:/state" \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/app-data/.enclava/config
        printf "%s\n" test-token > /state/app-data/.enclava/config/NGROK_AUTHTOKEN
        touch /state/app-data/.enclava/config/.ready
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_one" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_one" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker logs "$container_one" >"$output_file" 2>&1 || true
    cat "$output_file" >&2
    echo "expected first start to use delivered CAP config" >&2
    exit 1
fi

docker rm -f "$container_one" >/dev/null
docker run --rm \
    --user 0:0 \
    -v "$state_dir:/state" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c 'rm -rf /state/app-data/.enclava' >/dev/null

docker run -d --name "$container_two" \
    -v "$state_dir:/state" \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_two" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

docker logs "$container_two" >"$output_file" 2>&1 || true
cat "$output_file" >&2
docker exec "$container_two" curl -fsS http://127.0.0.1:8080/startup-error.txt >&2 2>/dev/null || true
echo "expected recovered start to load NGROK_AUTHTOKEN from encrypted state" >&2
exit 1
