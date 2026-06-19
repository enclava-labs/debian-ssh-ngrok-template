#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:supervision-test}"

docker build -t "$IMAGE_TAG" .

stub_dir="$(mktemp -d)"
container_name="debian-ssh-ngrok-supervision-$$"
chmod 0755 "$stub_dir"
cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    rm -rf "$stub_dir"
}
trap cleanup EXIT

cat >"$stub_dir/ngrok" <<'STUB'
#!/bin/sh
set -eu
root="$(mktemp -d)"
mkdir -p "$root/api"
cat >"$root/api/tunnels" <<'JSON'
{"tunnels":[{"public_url":"tcp://127.0.0.1:5555"}]}
JSON
sleep "${NGROK_API_DELAY_SECONDS:-0}"
busybox httpd -f -p 127.0.0.1:4040 -h "$root"
STUB
chmod 0755 "$stub_dir/ngrok"

docker run -d --name "$container_name" \
    --tmpfs /state:uid=10001,gid=10001,mode=0770 \
    --tmpfs /tmp:uid=10001,gid=10001,mode=1777 \
    -e PATH="/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e NGROK_API_DELAY_SECONDS=8 \
    -v "$stub_dir:/test-bin:ro" \
    --entrypoint /bin/sh \
    "$IMAGE_TAG" \
    -eu -c '
        mkdir -p /state/app/home-user/health /state/.enclava/config
        printf "%s\n" stale-endpoint > /state/app/home-user/health/ssh.txt
        printf "%s\n" test-token > /state/.enclava/config/NGROK_AUTHTOKEN
        touch /state/.enclava/config/.ready
        DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 exec /usr/local/bin/debian-ssh-ngrok-entrypoint
    ' >/dev/null

sleep 2
if docker exec "$container_name" test -e /home/user/health/ssh.txt; then
    docker logs "$container_name" >&2 || true
    echo "expected stale ssh.txt to be removed before ngrok publishes a fresh endpoint" >&2
    exit 1
fi

for _ in $(seq 1 30); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    echo "expected health server to answer before restart test" >&2
    exit 1
fi

health_pid="$(docker exec "$container_name" /bin/sh -eu -c "ps -eo pid,args | awk '/busybox httpd/ && /0.0.0.0:8080/ && !/awk/ { print \$1; exit }'")"
docker exec "$container_name" kill "$health_pid"

for _ in $(seq 1 30); do
    if docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" curl -fsS http://127.0.0.1:8080/healthz >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    echo "expected entrypoint to restart health server after it exits" >&2
    exit 1
fi

for _ in $(seq 1 30); do
    if docker exec "$container_name" ssh-keyscan -T 2 -t ed25519 -p 2222 127.0.0.1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ! docker exec "$container_name" ssh-keyscan -T 2 -t ed25519 -p 2222 127.0.0.1 >/dev/null 2>&1; then
    docker logs "$container_name" >&2 || true
    echo "expected sshd to answer before restart test" >&2
    exit 1
fi

docker exec "$container_name" /bin/sh -eu -c 'kill "$(cat /home/user/.ssh/sshd.pid)"'

for _ in $(seq 1 30); do
    if docker exec "$container_name" ssh-keyscan -T 2 -t ed25519 -p 2222 127.0.0.1 >/dev/null 2>&1; then
        exit 0
    fi
    sleep 1
done

docker logs "$container_name" >&2 || true
echo "expected entrypoint to restart sshd after it exits" >&2
exit 1
