#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:ssh-ready-without-sys-chroot-test}"
container_name="debian-ssh-ngrok-ssh-ready-no-sys-chroot-$$"
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
    --cap-drop=SYS_CHROOT \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -v "$stub_dir/ngrok:/usr/local/bin/ngrok:ro" \
    -e NGROK_AUTHTOKEN=test-token \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=0 \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    docker exec "$container_name" cat /home/user/health/debug.txt >&2 2>/dev/null || true
    echo "expected SSH readiness to pass without CAP_SYS_CHROOT" >&2
    exit 1
fi

listener_owner="$(docker exec "$container_name" /bin/sh -eu -c "ps -eo user=,args= | awk '/sshd: .*\\[listener\\]/ { print \$1; exit }'")"
if [ "$listener_owner" != "user" ]; then
    docker exec "$container_name" ps -eo user,args >&2 || true
    echo "expected sshd listener to run without sudo under the CAP rootful-sudo profile" >&2
    exit 1
fi

if ! docker exec "$container_name" ssh -F /dev/null \
    -i /home/user/.ssh/ssh_ready_ed25519_key \
    -o BatchMode=yes \
    -o ConnectTimeout=3 \
    -o ConnectionAttempts=1 \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p 2222 \
    user@127.0.0.1 \
    'test "$(whoami)" = user' >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    echo "expected public-key SSH login to work without CAP_SYS_CHROOT" >&2
    exit 1
fi
