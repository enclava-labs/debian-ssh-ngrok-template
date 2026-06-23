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

NGROK_TCP_URL=" tcp://6.TCP.EU.NGROK.IO:17958 "
normalize_ngrok_tcp_url_config
test "${NGROK_TCP_URL}" = "6.tcp.eu.ngrok.io:17958"
ngrok_public_url_matches_reserved "tcp://6.tcp.eu.ngrok.io:17958"
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

export ENCLAVA_REQUIRED_CONFIG_KEYS="NGROK_AUTHTOKEN,DEBIAN_SSH_AUTHORIZED_KEYS"
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
