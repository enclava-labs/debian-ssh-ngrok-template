#!/bin/sh
set -eu

# Issue #1: the platform-owned ngrok authtoken must never appear on the ngrok
# process command line (readable via /proc/<pid>/cmdline by any same-uid
# process — this image runs one uid for the workload and SSH sessions alike).
# The token is delivered through the 0600 config file instead.

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ngrok-token-off-cmdline-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$stub_dir"
}
# POSIX sh keeps ONE trap per signal: the second registration below used
# to silently discard this one and leak the host-side stub dir.

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu

printf '%s\n' "$@" >"$HOME/ngrok-argv.txt"

root="$(mktemp -d)"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON

exec busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"
chmod 0755 "$stub_dir"

container_name="debian-ssh-ngrok-token-off-cmdline-$$"
docker rm -f "$container_name" >/dev/null 2>&1 || true
docker_cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
}
# Single EXIT trap runs both cleanups: host stub dir and container.
trap 'cleanup; docker_cleanup' EXIT

dummy_token="dummy-token-never-real-9f8e7d6c"
dummy_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINncqj+z395SDlU4JsYI38lpxfztRl6dQe9zANxPM/9W dummy-ngrok-template-test"
docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_AUTHTOKEN="$dummy_token" \
    -e DEBIAN_SSH_AUTHORIZED_KEYS="$dummy_key" \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    -e DEBIAN_SSH_SUPERVISE_INTERVAL_SECONDS=1 \
    -e DEBIAN_NGROK_API_FAILURE_RESTARTS=1 \
    -e DEBIAN_NGROK_UNREADY_EXIT_SECONDS=0 \
    -v "$stub_dir:/test-bin:ro" \
    "$IMAGE_TAG" >/dev/null

# Wait for the tunnel to come up: proves the flow still works end to end.
for _ in $(seq 1 20); do
    if docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" grep -qxF 'ssh -p 5555 user@127.0.0.1' /home/user/health/ssh.txt 2>/dev/null; then
    docker logs "$container_name" >&2 || true
    echo "expected ngrok tunnel to come up with the config-file authtoken" >&2
    exit 1
fi

# The stub ngrok must have been started WITHOUT --authtoken and WITHOUT the
# token value anywhere in its argv.
if docker exec "$container_name" sh -c "grep -e --authtoken -e '$dummy_token' /home/user/ngrok-argv.txt"; then
    docker exec "$container_name" cat /home/user/ngrok-argv.txt >&2 || true
    echo "ngrok argv leaked the authtoken" >&2
    exit 1
fi

# The live process table must not carry the token either.
if docker exec "$container_name" sh -c "ps -eo args | grep -e --authtoken -e '$dummy_token' | grep -v grep"; then
    echo "live process table carries the authtoken" >&2
    exit 1
fi

# The config file carries the token, but only readable by its owner.
docker exec "$container_name" grep -q "^authtoken: $dummy_token\$" /home/user/.config/ngrok/ngrok.yml || {
    docker exec "$container_name" cat /home/user/.config/ngrok/ngrok.yml >&2 || true
    echo "expected authtoken in the ngrok config file" >&2
    exit 1
}
mode="$(docker exec "$container_name" stat -c '%a' /home/user/.config/ngrok/ngrok.yml)"
if [ "$mode" != "600" ]; then
    echo "expected ngrok.yml mode 0600, found $mode" >&2
    exit 1
fi
dir_mode="$(docker exec "$container_name" stat -c '%a' /home/user/.config/ngrok)"
if [ "$dir_mode" != "700" ]; then
    echo "expected .config/ngrok dir mode 0700, found $dir_mode" >&2
    exit 1
fi

exit 0
