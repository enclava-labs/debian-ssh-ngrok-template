#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:config-dir-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_name="debian-ssh-ngrok-config-dir-$$"
chmod 0755 "$stub_dir"
ssh-keygen -q -t ed25519 -N '' -C test@example -f "$stub_dir/id_ed25519"
public_key="$(cat "$stub_dir/id_ed25519.pub")"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
    rm -f "$output_file"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
echo "fake ngrok invoked" >&2
sleep 30
STUB
chmod 0755 "$stub_dir/ngrok"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e TEST_PUBLIC_KEY="$public_key" \
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/app-data/.enclava/config /state/.enclava/config
        printf "%s\n" test-token > /state/.enclava/config/NGROK_AUTHTOKEN
        printf "%s\n" 6.tcp.eu.ngrok.io:5555 > /state/.enclava/config/NGROK_TCP_URL
        printf "%s\n" "$TEST_PUBLIC_KEY" > /state/.enclava/config/DEBIAN_SSH_AUTHORIZED_KEYS
        touch /state/.enclava/config/.ready
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

for _ in $(seq 1 15); do
    docker logs "$container_name" >"$output_file" 2>&1 || true
    if grep -q "fake ngrok invoked" "$output_file"; then
        if ! docker exec "$container_name" grep -q "test@example" /home/user/.ssh/authorized_keys; then
            docker exec "$container_name" cat /home/user/.ssh/authorized_keys >&2 || true
            echo "expected configured SSH public key to be installed" >&2
            exit 1
        fi
        if docker exec "$container_name" grep -q "lio@beast" /home/user/.ssh/authorized_keys; then
            docker exec "$container_name" cat /home/user/.ssh/authorized_keys >&2 || true
            echo "expected no baked-in support SSH public key" >&2
            exit 1
        fi
        persisted_endpoint="$(docker exec "$container_name" cat /state/app-data/debian-ssh-ngrok/config/NGROK_TCP_URL)"
        if [ "$persisted_endpoint" != "6.tcp.eu.ngrok.io:5555" ]; then
            docker exec "$container_name" find /state/app-data/debian-ssh-ngrok/config -maxdepth 1 -type f -print -exec cat {} \; >&2 || true
            echo "expected canonical NGROK_TCP_URL to be persisted" >&2
            exit 1
        fi
        persisted_token="$(docker exec "$container_name" cat /state/app-data/debian-ssh-ngrok/config/NGROK_AUTHTOKEN)"
        if [ "$persisted_token" != "test-token" ]; then
            echo "expected NGROK_AUTHTOKEN to be persisted on encrypted runtime state" >&2
            exit 1
        fi
        if ! docker exec "$container_name" grep -q "test@example" /state/app-data/debian-ssh-ngrok/config/DEBIAN_SSH_AUTHORIZED_KEYS; then
            echo "expected DEBIAN_SSH_AUTHORIZED_KEYS to be persisted on encrypted runtime state" >&2
            exit 1
        fi
        persisted_dir_mode="$(docker exec "$container_name" stat -c %a /state/app-data/debian-ssh-ngrok/config)"
        if [ "$persisted_dir_mode" != "700" ]; then
            echo "expected persisted config directory mode 700" >&2
            exit 1
        fi
        persisted_file_mode="$(docker exec "$container_name" stat -c %a /state/app-data/debian-ssh-ngrok/config/NGROK_TCP_URL)"
        if [ "$persisted_file_mode" != "600" ]; then
            echo "expected persisted config files to be mode 600" >&2
            exit 1
        fi
        exit 0
    fi
    sleep 1
done

cat "$output_file" >&2
echo "expected entrypoint to load the ready config dir and invoke ngrok" >&2
exit 1
