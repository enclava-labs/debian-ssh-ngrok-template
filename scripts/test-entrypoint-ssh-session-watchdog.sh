#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ssh-session-watchdog-test}"
container_name="debian-ssh-ngrok-ssh-session-watchdog-$$"
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

cat >"$stub_dir/ssh-keyscan" <<'STUB'
#!/bin/sh
printf '[127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeProbeKey\n'
STUB

cat >"$stub_dir/ssh" <<'STUB'
#!/bin/sh
touch /tmp/ssh-session-watchdog-called
exit 255
STUB

chmod 0755 "$stub_dir/ngrok" "$stub_dir/ssh-keyscan" "$stub_dir/ssh"

docker build -t "$IMAGE_TAG" .

docker run -d --name "$container_name" \
    -v "$stub_dir/ngrok:/usr/local/bin/ngrok:ro" \
    -v "$stub_dir/ssh-keyscan:/usr/local/bin/ssh-keyscan:ro" \
    -v "$stub_dir/ssh:/usr/local/bin/ssh:ro" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=4 \
    -e DEBIAN_SSH_SELF_WATCHDOG_UNREADY_SECONDS=0 \
    -e DEBIAN_SSH_LOGIN_CHECK_INTERVAL_SECONDS=3 \
    -e DEBIAN_SSH_LOGIN_CHECK_TIMEOUT_SECONDS=3 \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 20); do
    if docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
    docker logs "$container_name" >&2 || true
    echo "expected initial ready endpoint before SSH session watchdog test" >&2
    exit 1
fi

if ! timeout 20 docker wait "$container_name" >/tmp/debian-ssh-ngrok-ssh-session-watchdog-status; then
    docker logs "$container_name" >&2 || true
    echo "expected failed SSH session watchdog to withdraw health and exit" >&2
    exit 1
fi

status="$(cat /tmp/debian-ssh-ngrok-ssh-session-watchdog-status)"
rm -f /tmp/debian-ssh-ngrok-ssh-session-watchdog-status
if [ "$status" -eq 0 ]; then
    docker logs "$container_name" >&2 || true
    echo "expected sustained SSH session watchdog failure to exit non-zero" >&2
    exit 1
fi
