#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ssh-session-readiness-test}"
container_name="debian-ssh-ngrok-session-readiness-$$"
stub_dir="$(mktemp -d)"

cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
root="/tmp/ngrok-root"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB

cat >"$stub_dir/ssh-keyscan" <<'STUB'
#!/bin/sh
printf '127.0.0.1 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeProbeKey\n'
STUB

cat >"$stub_dir/ssh" <<'STUB'
#!/bin/sh
touch /tmp/ssh-was-called
exit 255
STUB

chmod 0755 "$stub_dir/ngrok" "$stub_dir/ssh-keyscan" "$stub_dir/ssh"

docker build -t "$IMAGE_TAG" .

docker run -d --name "$container_name" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=4 \
    -v "$stub_dir/ngrok:/usr/local/bin/ngrok:ro" \
    -v "$stub_dir/ssh-keyscan:/usr/local/bin/ssh-keyscan:ro" \
    -v "$stub_dir/ssh:/usr/local/bin/ssh:ro" \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 15); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    echo "expected SSH readiness to use ssh-keyscan instead of a full SSH session" >&2
    exit 1
fi

if docker exec "$container_name" test -e /tmp/ssh-was-called; then
    docker logs "$container_name" >&2 || true
    echo "expected SSH readiness not to invoke the ssh client" >&2
    exit 1
fi
