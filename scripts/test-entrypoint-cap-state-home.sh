#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:cap-state-home-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
state_dir="$(mktemp -d)"
output_file="$(mktemp)"
container_name="debian-ssh-ngrok-cap-state-home-$$"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    if [ -d "$state_dir" ]; then
        docker run --rm --user 0 --entrypoint /bin/sh -v "$state_dir:/state" "$IMAGE_TAG" -c 'chmod -R u+rwX,g+rwX,o+rwX /state' >/dev/null 2>&1 || true
    fi
    rm -rf "$stub_dir" "$state_dir"
    rm -f "$output_file"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
echo "fake ngrok invoked" >&2
sleep 30
STUB
chmod 0755 "$stub_dir/ngrok"
chmod 0755 "$stub_dir"

mkdir -p "$state_dir/.enclava/config" "$state_dir/app"
printf "%s\n" test-token >"$state_dir/.enclava/config/NGROK_AUTHTOKEN"
touch "$state_dir/.enclava/config/.ready"
chmod 0755 "$state_dir"

docker run --rm --user 0 --entrypoint /bin/sh -v "$state_dir:/state" "$IMAGE_TAG" -eu -c '
    chown -R 0:0 /state/.enclava
    chmod 0755 /state/.enclava /state/.enclava/config
    chown 10001:10001 /state/app
    chmod 0750 /state/app
'

docker run -d --name "$container_name" \
    -v "$state_dir:/state" \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c 'DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint' >/dev/null

for _ in $(seq 1 15); do
    docker logs "$container_name" >"$output_file" 2>&1 || true
    if grep -q "fake ngrok invoked" "$output_file"; then
        exit 0
    fi
    sleep 1
done

cat "$output_file" >&2
echo "expected entrypoint to use /state/app for home and invoke ngrok" >&2
exit 1
