#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:sshd-root-listener-test}"
container_name="debian-ssh-ngrok-sshd-root-listener-$$"
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

listener_owner=""
for _ in $(seq 1 30); do
    listener_owner="$(docker exec "$container_name" /bin/sh -eu -c "ps -eo user=,args= | awk '/sshd: .*\\[listener\\]/ { print \$1; exit }'" 2>/dev/null || true)"
    [ -n "$listener_owner" ] && break
    sleep 1
done

if [ "$listener_owner" != "root" ]; then
    docker exec "$container_name" ps -eo user,args >&2 || true
    docker logs "$container_name" >&2 || true
    echo "expected sshd listener to run as root under the rootful-sudo profile" >&2
    exit 1
fi
