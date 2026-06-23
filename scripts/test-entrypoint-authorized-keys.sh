#!/bin/sh
set -eu

test_tmp="$(mktemp -d)"
test_cleanup() {
    rm -rf "$test_tmp"
}
trap test_cleanup EXIT INT TERM

ssh-keygen -q -t ed25519 -N '' -C 'debian-ssh-ngrok-test' -f "$test_tmp/id_ed25519"
public_key="$(cat "$test_tmp/id_ed25519.pub")"

export DEBIAN_SSH_NGROK_ENTRYPOINT_TEST=1
export DEBIAN_SSH_HOME="$test_tmp/home"
export DEBIAN_SSH_READY_KEY="$DEBIAN_SSH_HOME/.ssh/ssh_ready_ed25519_key"
export DEBIAN_SSH_HOST_KEY="$DEBIAN_SSH_HOME/.ssh/dropbear_ed25519_host_key"
export DEBIAN_SSH_DEBUG_FILE="$DEBIAN_SSH_HOME/health/debug.txt"
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_BYTES=32768
export DEBIAN_SSH_AUTHORIZED_KEYS_MAX_ITEMS=10
export DEBIAN_SSH_AUTHORIZED_KEY_ALGORITHMS="ssh-ed25519 ecdsa-sha2-nistp256 rsa-sha2-512 rsa-sha2-256"

# shellcheck source=../entrypoint.sh
. "$PWD/entrypoint.sh"
trap test_cleanup EXIT INT TERM

mkdir -p "$DEBIAN_SSH_HOME/.ssh" "$DEBIAN_SSH_HOME/health"
chmod 700 "$DEBIAN_SSH_HOME" "$DEBIAN_SSH_HOME/.ssh"

DEBIAN_SSH_AUTHORIZED_KEYS=""
if write_authorized_keys 2>"$test_tmp/missing.err"; then
    echo "expected empty authorized keys to fail" >&2
    exit 1
fi
grep -q "at least one valid public key" "$test_tmp/missing.err"

DEBIAN_SSH_AUTHORIZED_KEYS="-----BEGIN OPENSSH PRIVATE KEY-----"
if write_authorized_keys 2>"$test_tmp/private.err"; then
    echo "expected private key material to fail" >&2
    exit 1
fi
grep -q "public keys, not private keys" "$test_tmp/private.err"

DEBIAN_SSH_AUTHORIZED_KEYS="ssh-dss AAAAB3NzaC1kc3MAAACBbad"
if write_authorized_keys 2>"$test_tmp/algorithm.err"; then
    echo "expected unsupported SSH key algorithm to fail" >&2
    exit 1
fi
grep -q "unsupported SSH public key algorithm" "$test_tmp/algorithm.err"

DEBIAN_SSH_AUTHORIZED_KEYS="$(printf '# comment\n%s\n%s\n' "$public_key" "$public_key")"
write_authorized_keys
prepare_ssh_ready_key

if [ "$(grep -cF "$public_key" "$DEBIAN_SSH_HOME/.ssh/authorized_keys")" -ne 1 ]; then
    cat "$DEBIAN_SSH_HOME/.ssh/authorized_keys" >&2
    echo "expected duplicate public keys to be deduplicated" >&2
    exit 1
fi

if grep -q "lio@beast" "$DEBIAN_SSH_HOME/.ssh/authorized_keys"; then
    cat "$DEBIAN_SSH_HOME/.ssh/authorized_keys" >&2
    echo "expected baked-in operator key to be absent" >&2
    exit 1
fi

if [ "$(stat -c "%a" "$DEBIAN_SSH_HOME/.ssh/authorized_keys")" != "600" ]; then
    stat -c "%a %n" "$DEBIAN_SSH_HOME/.ssh/authorized_keys" >&2
    echo "expected authorized_keys mode 600" >&2
    exit 1
fi

if ! grep -q "debian-ssh-ngrok-readiness" "$DEBIAN_SSH_HOME/.ssh/authorized_keys"; then
    cat "$DEBIAN_SSH_HOME/.ssh/authorized_keys" >&2
    echo "expected internal readiness key to remain installed" >&2
    exit 1
fi
