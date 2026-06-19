#!/bin/sh
set -eu

IMAGE_TAG="${IMAGE_TAG:-debian-ssh-ngrok-template:missing-config-test}"
container_name="debian-ssh-ngrok-missing-config-$$"

cleanup() {
    docker rm -f "$container_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker build -t "$IMAGE_TAG" .

docker run -d \
    --name "$container_name" \
    -e DEBIAN_SSH_CONFIG_WAIT_SECONDS=1 \
    "$IMAGE_TAG" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container_name" test -f /home/user/health/startup-error.txt; then
        break
    fi
    sleep 1
done

if ! docker ps --format '{{.Names}}' | grep -qx "$container_name"; then
    echo "expected entrypoint to keep the container alive after missing config" >&2
    docker logs "$container_name" >&2 || true
    exit 1
fi

if ! docker exec "$container_name" grep -qx 'NGROK_AUTHTOKEN is required' /home/user/health/startup-error.txt; then
    echo "expected missing-token startup error to be exposed" >&2
    docker exec "$container_name" cat /home/user/health/startup-error.txt >&2 || true
    exit 1
fi

if docker exec "$container_name" test -e /home/user/health/healthz; then
    echo "expected missing config not to publish healthz" >&2
    exit 1
fi

if ! docker exec "$container_name" curl -fsS http://127.0.0.1:8080/startup-error.txt | grep -qx 'NGROK_AUTHTOKEN is required'; then
    echo "expected health server to expose startup-error.txt" >&2
    exit 1
fi
