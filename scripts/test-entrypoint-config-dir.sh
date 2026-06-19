#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:config-dir-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_name="debian-ssh-ngrok-config-dir-$$"
chmod 0755 "$stub_dir"
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
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/app-data/.enclava/config /state/.enclava/config
        printf "%s\n" test-token > /state/.enclava/config/NGROK_AUTHTOKEN
        touch /state/.enclava/config/.ready
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

for _ in $(seq 1 15); do
    docker logs "$container_name" >"$output_file" 2>&1 || true
    if grep -q "fake ngrok invoked" "$output_file"; then
        exit 0
    fi
    sleep 1
done

cat "$output_file" >&2
echo "expected entrypoint to load the ready config dir and invoke ngrok" >&2
exit 1
