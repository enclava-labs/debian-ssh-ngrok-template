#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTRYPOINT="$ROOT_DIR/entrypoint.sh"

work_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

DEBIAN_SSH_NGROK_ENTRYPOINT_TEST=1
export DEBIAN_SSH_NGROK_ENTRYPOINT_TEST
# shellcheck source=../entrypoint.sh
. "$ENTRYPOINT"

DEBIAN_SSH_HOME="$work_dir/home"
export DEBIAN_SSH_HOME
mkdir -p "$DEBIAN_SSH_HOME/.ssh"
chmod 700 "$DEBIAN_SSH_HOME" "$DEBIAN_SSH_HOME/.ssh"

ssh-keygen -q -t ed25519 -N '' -C standalone-keys@example -f "$work_dir/id_ed25519"
public_key="$(cat "$work_dir/id_ed25519.pub")"

assert_rejects_keys() {
    label="$1"
    expected="$2"
    DEBIAN_SSH_AUTHORIZED_KEYS="$3"
    export DEBIAN_SSH_AUTHORIZED_KEYS
    if write_authorized_keys "$DEBIAN_SSH_HOME/.ssh/authorized_keys" 2>"$work_dir/$label.err"; then
        cat "$DEBIAN_SSH_HOME/.ssh/authorized_keys" >&2
        echo "expected $label SSH keys to be rejected" >&2
        exit 1
    fi
    grep -q "$expected" "$work_dir/$label.err"
}

assert_rejects_keys "missing" "at least one valid public key" ""
assert_rejects_keys "private" "public keys, not private keys" "-----BEGIN OPENSSH PRIVATE KEY-----"
assert_rejects_keys "algorithm" "unsupported SSH public key algorithm" "ssh-dss AAAAB3NzaC1kc3MAAACBbad"
assert_rejects_keys "base64" "malformed base64" "ssh-ed25519 not_base64! test@example"
assert_rejects_keys "unparseable" "could not be parsed by ssh-keygen" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGateTestOnlyGateTestOnlyGateTestOnlyGateTest test@example"

DEBIAN_SSH_AUTHORIZED_KEYS="$(printf '# comment\n%s\n%s\n' "$public_key" "$public_key")"
export DEBIAN_SSH_AUTHORIZED_KEYS
write_authorized_keys "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
grep -qxF "$public_key" "$DEBIAN_SSH_HOME/.ssh/authorized_keys"
test "$(grep -cF "$public_key" "$DEBIAN_SSH_HOME/.ssh/authorized_keys")" = "1"
test "$(stat -c "%a" "$DEBIAN_SSH_HOME/.ssh/authorized_keys")" = "600"

echo "Standalone entrypoint SSH key tests passed"
