#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ngrok-api-timeout-test}"
TEST_IMAGE_TAG="${IMAGE_TAG}-stubbed"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-api-timeout-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    docker rmi "$TEST_IMAGE_TAG" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu
exec busybox nc -ll -p 4040 -e /usr/local/bin/ngrok-handler
STUB
chmod 0755 "$stub_dir/ngrok"

cat >"$stub_dir/ngrok-handler" <<'STUB'
#!/bin/sh
set -eu
count_file="/tmp/ngrok-handler-count"
count=0
if [ -f "$count_file" ]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"

if [ "$count" -eq 1 ]; then
    body='{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}'
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#body}" "$body"
    exit 0
fi

sleep 120
STUB
chmod 0755 "$stub_dir/ngrok-handler"

cat >"$stub_dir/Dockerfile" <<'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER 0:0
COPY ngrok /usr/local/bin/ngrok
COPY ngrok-handler /usr/local/bin/ngrok-handler
RUN chmod 0755 /usr/local/bin/ngrok /usr/local/bin/ngrok-handler
USER 10001:10001
EOF
docker build --build-arg "BASE_IMAGE=$IMAGE_TAG" -t "$TEST_IMAGE_TAG" "$stub_dir"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    --entrypoint /bin/sh \
    "$TEST_IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/.enclava/config
        printf "%s\n" test-token > /state/.enclava/config/NGROK_AUTHTOKEN
        touch /state/.enclava/config/.ready
        DEBIAN_NGROK_API_TIMEOUT_SECONDS=2 DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" test -e /home/user/health/healthz; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" test -e /home/user/health/healthz; then
    docker logs "$container_name" >&2 || true
    echo "expected entrypoint to publish initial healthz before ngrok API timeout test" >&2
    exit 1
fi

initial_mtime="$(docker exec "$container_name" stat -c %Y /home/user/health/healthz)"
sleep 8

if docker exec "$container_name" test -e /home/user/health/healthz; then
    current_mtime="$(docker exec "$container_name" stat -c %Y /home/user/health/healthz)"
    if [ "$current_mtime" = "$initial_mtime" ]; then
        docker logs "$container_name" >&2 || true
        echo "expected hung ngrok API probe not to leave stale healthz published" >&2
        exit 1
    fi
fi

exit 0
