#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCKERFILE="$ROOT_DIR/Dockerfile"

fail() {
    echo "error: $*" >&2
    exit 1
}

grep -Eq '^FROM debian:bookworm-slim@sha256:[0-9a-f]{64}$' "$DOCKERFILE" \
    || fail "Dockerfile base image must be debian:bookworm-slim pinned by sha256 digest"

grep -Eq '^ARG NGROK_SHA256=[0-9a-f]{64}$' "$DOCKERFILE" \
    || fail "Dockerfile must pin NGROK_SHA256 to a 64-character lowercase sha256 digest"

download_line="$(grep -n 'curl -fsSL "${NGROK_URL}" -o /tmp/ngrok.tgz' "$DOCKERFILE" | cut -d: -f1 || true)"
verify_line="$(grep -n 'sha256sum -c -' "$DOCKERFILE" | cut -d: -f1 || true)"
extract_line="$(grep -n 'tar -xzf /tmp/ngrok.tgz' "$DOCKERFILE" | cut -d: -f1 || true)"

[ -n "$download_line" ] && [ -n "$verify_line" ] && [ -n "$extract_line" ] \
    || fail "Dockerfile must download, checksum-verify, and then extract the ngrok tarball"

[ "$download_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$extract_line" ] \
    || fail "Dockerfile must verify NGROK_SHA256 before extracting ngrok"

grep -Fq 'https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-linux-amd64.tgz' "$DOCKERFILE" \
    || fail "Dockerfile must use the expected ngrok v3 Linux amd64 archive URL"

grep -Fq 'echo "${NGROK_SHA256}  /tmp/ngrok.tgz" | sha256sum -c -' "$DOCKERFILE" \
    || fail "Dockerfile must verify the ngrok archive checksum"

echo "Standalone template build-file tests passed"
