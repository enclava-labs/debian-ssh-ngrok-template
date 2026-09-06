#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="${ROOT_DIR}/entrypoint.sh"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: missing required command: $1" >&2
    exit 2
  }
}

need ssh-keygen
need grep

workdir="$(mktemp -d -t debian-ssh-template-config-test.XXXXXX)"
trap 'rm -rf "${workdir}"' EXIT

ssh-keygen -q -t ed25519 -N '' -C debian-ssh-ngrok-test -f "${workdir}/id_ed25519"
public_key="$(cat "${workdir}/id_ed25519.pub")"

export DEBIAN_SSH_NGROK_ENTRYPOINT_TEST=1
export DEBIAN_SSH_HOME="${workdir}/home"
export DEBIAN_SSH_READY_KEY="${DEBIAN_SSH_HOME}/.ssh/ssh_ready_ed25519_key"
export DEBIAN_SSH_HOST_KEY="${DEBIAN_SSH_HOME}/.ssh/dropbear_ed25519_host_key"
export DEBIAN_SSH_DEBUG_FILE="${DEBIAN_SSH_HOME}/health/debug.txt"
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES=32768
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS=10
export DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS="ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256"

# shellcheck source=../entrypoint.sh
. "${ENTRYPOINT}"

mkdir -p "${DEBIAN_SSH_HOME}/.ssh" "${DEBIAN_SSH_HOME}/health"
chmod 700 "${DEBIAN_SSH_HOME}" "${DEBIAN_SSH_HOME}/.ssh"
export DEBIAN_SSH_PERSISTED_CONFIG_DIR="${workdir}/persisted-config"

awk '/^start_ngrok\(\)/,/^}/ { print }' "${ENTRYPOINT}" >"${workdir}/start-ngrok.txt"
test "$(grep -c 'ngrok tcp "127.0.0.1:${DEBIAN_SSH_PORT}"' "${workdir}/start-ngrok.txt")" = "1"
grep -q -- '--url "$NGROK_TCP_URL"' "${workdir}/start-ngrok.txt"
if grep -q 'if \[ -n "\$NGROK_TCP_URL" \]' "${workdir}/start-ngrok.txt"; then
  echo "error: start_ngrok still contains a dynamic endpoint fallback branch" >&2
  exit 1
fi

export ENCLAVA_REQUIRED_CONFIG_KEYS="NGROK_AUTHTOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
export DEBIAN_SSH_REQUIRE_NGROK_TCP_URL=1
test "$(required_config_keys)" = "NGROK_TCP_URL NGROK_AUTHTOKEN DEBIAN_SSH_AUTHORIZED_KEYS"
test "$(persisted_config_keys)" = "NGROK_TCP_URL NGROK_AUTHTOKEN DEBIAN_SSH_AUTHORIZED_KEYS"

export ENCLAVA_REQUIRED_CONFIG_KEYS="NGROK_TCP_URL,NGROK_AUTHTOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
test "$(required_config_keys)" = "NGROK_TCP_URL NGROK_AUTHTOKEN DEBIAN_SSH_AUTHORIZED_KEYS"
test "$(persisted_config_keys)" = "NGROK_TCP_URL NGROK_AUTHTOKEN DEBIAN_SSH_AUTHORIZED_KEYS"

export DEBIAN_SSH_REQUIRE_NGROK_TCP_URL=0
export ENCLAVA_REQUIRED_CONFIG_KEYS="NGROK_AUTHTOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
if validate_ngrok_tcp_url_requirement_config 2>"${workdir}/ngrok-dynamic-disabled.err"; then
  echo "error: DEBIAN_SSH_REQUIRE_NGROK_TCP_URL=0 was accepted" >&2
  exit 1
fi
grep -q "DEBIAN_SSH_REQUIRE_NGROK_TCP_URL=0 is not supported" "${workdir}/ngrok-dynamic-disabled.err"
if required_config_keys >/dev/null 2>"${workdir}/ngrok-dynamic-required.err"; then
  echo "error: required_config_keys accepted disabled stable endpoint requirement" >&2
  exit 1
fi

export DEBIAN_SSH_REQUIRE_NGROK_TCP_URL=1
unset NGROK_TCP_URL
if require_ngrok_tcp_url_if_needed 2>"${workdir}/ngrok-required.err"; then
  echo "error: missing NGROK_TCP_URL was accepted while stable endpoint is required" >&2
  exit 1
fi
grep -q "NGROK_TCP_URL is required" "${workdir}/ngrok-required.err"

NGROK_TCP_URL=" tcp://6.TCP.EU.NGROK.IO.:17958 "
normalize_ngrok_tcp_url_config
test "${NGROK_TCP_URL}" = "6.tcp.eu.ngrok.io:17958"
ngrok_public_url_matches_reserved "tcp://6.tcp.eu.ngrok.io.:17958"

NGROK_TCP_URL="tcp://6.tcp.eu.ngrok.io:00009"
normalize_ngrok_tcp_url_config
test "${NGROK_TCP_URL}" = "6.tcp.eu.ngrok.io:9"
ngrok_public_url_matches_reserved "tcp://6.tcp.eu.ngrok.io:00009"
mark_ready "tcp://6.TCP.EU.NGROK.IO.:00009"
test "$(cat "${DEBIAN_SSH_HOME}/health/ngrok-url.txt")" = "tcp://6.tcp.eu.ngrok.io:9"
test "$(cat "${DEBIAN_SSH_HOME}/health/ssh.txt")" = "ssh -p 9 user@6.tcp.eu.ngrok.io"
if mark_ready "tcp://example.com:9" 2>"${workdir}/mark-ready-invalid.err"; then
  echo "error: invalid stable ngrok endpoint was rendered as ready" >&2
  exit 1
fi
test "$(cat "${DEBIAN_SSH_HOME}/health/ssh.txt")" = "ssh -p 9 user@6.tcp.eu.ngrok.io"

NGROK_TCP_URL="6.tcp.eu.ngrok.io:000123"
if normalize_ngrok_tcp_url_config 2>"${workdir}/ngrok-overlong-port.err"; then
  echo "error: ngrok TCP endpoint with overlong zero-padded port was accepted" >&2
  exit 1
fi
grep -q "reserved ngrok TCP address" "${workdir}/ngrok-overlong-port.err"

if ngrok_public_url_matches_reserved "tcp://7.tcp.eu.ngrok.io:17958" 2>"${workdir}/ngrok-mismatch.err"; then
  echo "error: mismatched ngrok TCP endpoint was accepted" >&2
  exit 1
fi
grep -q "does not match reserved NGROK_TCP_URL" "${workdir}/ngrok-mismatch.err"

NGROK_TCP_URL="example.com:22"
if normalize_ngrok_tcp_url_config 2>"${workdir}/ngrok-invalid.err"; then
  echo "error: invalid ngrok TCP endpoint was accepted" >&2
  exit 1
fi
grep -q "reserved ngrok TCP address" "${workdir}/ngrok-invalid.err"

NGROK_TCP_URL="-6.tcp.eu.ngrok.io:17958"
if normalize_ngrok_tcp_url_config 2>"${workdir}/ngrok-invalid-label-start.err"; then
  echo "error: ngrok TCP endpoint with invalid label start was accepted" >&2
  exit 1
fi
grep -q "reserved ngrok TCP address" "${workdir}/ngrok-invalid-label-start.err"

NGROK_TCP_URL="6-.tcp.eu.ngrok.io:17958"
if normalize_ngrok_tcp_url_config 2>"${workdir}/ngrok-invalid-label-end.err"; then
  echo "error: ngrok TCP endpoint with invalid label end was accepted" >&2
  exit 1
fi
grep -q "reserved ngrok TCP address" "${workdir}/ngrok-invalid-label-end.err"

export NGROK_AUTHTOKEN="test-token"
export NGROK_TCP_URL="6.tcp.eu.ngrok.io:17958"
persist_runtime_config
unset NGROK_TCP_URL
load_persisted_config
test "${NGROK_TCP_URL}" = "6.tcp.eu.ngrok.io:17958"

DEBIAN_SSH_AUTHORIZED_KEYS=""
if write_authorized_keys 2>"${workdir}/missing.err"; then
  echo "error: empty authorized keys were accepted" >&2
  exit 1
fi
grep -q "at least one valid public key" "${workdir}/missing.err"

DEBIAN_SSH_AUTHORIZED_KEYS="-----BEGIN OPENSSH PRIVATE KEY-----"
if write_authorized_keys 2>"${workdir}/private.err"; then
  echo "error: private key material was accepted" >&2
  exit 1
fi
grep -q "public keys, not private keys" "${workdir}/private.err"

DEBIAN_SSH_AUTHORIZED_KEYS="ssh-dss AAAAB3NzaC1kc3MAAACBbad"
if write_authorized_keys 2>"${workdir}/algorithm.err"; then
  echo "error: unsupported SSH key algorithm was accepted" >&2
  exit 1
fi
grep -q "unsupported SSH public key algorithm" "${workdir}/algorithm.err"

DEBIAN_SSH_AUTHORIZED_KEYS="$(printf '# comment\n%s\n%s\n' "${public_key}" "${public_key}")"
write_authorized_keys
prepare_ssh_ready_key

grep -qxF "${public_key}" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys"
test "$(grep -cF "${public_key}" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys")" = "1"
test "$(stat -c "%a" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys")" = "600"
grep -q "debian-ssh-ngrok-readiness" "${DEBIAN_SSH_HOME}/.ssh/authorized_keys"

if grep -q "lio@beast" "${ENTRYPOINT}"; then
  echo "error: committed support key is still present in entrypoint" >&2
  exit 1
fi

echo "Debian SSH template config validation tests passed"
