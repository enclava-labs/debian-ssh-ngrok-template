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

assert_normalizes() {
    input="$1"
    expected="$2"
    actual="$(normalize_ngrok_tcp_url "$input")"
    if [ "$actual" != "$expected" ]; then
        echo "expected $input to normalize to $expected, got $actual" >&2
        exit 1
    fi
}

assert_rejects() {
    input="$1"
    label="$2"
    if normalize_ngrok_tcp_url "$input" >"$work_dir/$label.out" 2>"$work_dir/$label.err"; then
        cat "$work_dir/$label.out" >&2
        echo "expected $input to be rejected" >&2
        exit 1
    fi
    grep -Eq "reserved ngrok TCP address|port must be between 1 and 65535" "$work_dir/$label.err"
}

assert_normalizes " tcp://6.TCP.EU.NGROK.IO.:00009 " "6.tcp.eu.ngrok.io:9"
assert_normalizes "1.tcp.ngrok.io:22222" "1.tcp.ngrok.io:22222"

assert_rejects "example.com:22" "non-ngrok-host"
assert_rejects "-6.tcp.eu.ngrok.io:17958" "bad-label-start"
assert_rejects "6-.tcp.eu.ngrok.io:17958" "bad-label-end"
assert_rejects "6.foo.eu.ngrok.io:17958" "bad-ngrok-shape"
assert_rejects "6.tcp.eu.ngrok.io:000123" "overlong-port"
assert_rejects "$(printf '%064d' 0 | tr '0' 'a').tcp.eu.ngrok.io:17958" "overlong-label"

DEBIAN_SSH_PERSISTED_CONFIG_DIR="$work_dir/persisted-config"
export DEBIAN_SSH_PERSISTED_CONFIG_DIR
NGROK_AUTHTOKEN="test-token"
NGROK_TCP_URL=" tcp://6.TCP.EU.NGROK.IO.:00009 "
DEBIAN_SSH_AUTHORIZED_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGateTestOnlyGateTestOnlyGateTestOnlyGateTest test@example"
export NGROK_AUTHTOKEN NGROK_TCP_URL DEBIAN_SSH_AUTHORIZED_KEYS
normalize_ngrok_tcp_url_config
persist_runtime_config

test "$(cat "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/NGROK_TCP_URL")" = "6.tcp.eu.ngrok.io:9"
test "$(cat "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/NGROK_AUTHTOKEN")" = "test-token"
grep -q "test@example" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/DEBIAN_SSH_AUTHORIZED_KEYS"
test "$(stat -c "%a" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR")" = "700"
test "$(stat -c "%a" "$DEBIAN_SSH_PERSISTED_CONFIG_DIR/NGROK_TCP_URL")" = "600"

unset NGROK_AUTHTOKEN NGROK_TCP_URL DEBIAN_SSH_AUTHORIZED_KEYS
NGROK_TCP_URL=""
DEBIAN_SSH_AUTHORIZED_KEYS=""
export NGROK_TCP_URL DEBIAN_SSH_AUTHORIZED_KEYS
load_persisted_config
test "$NGROK_AUTHTOKEN" = "test-token"
test "$NGROK_TCP_URL" = "6.tcp.eu.ngrok.io:9"
case "$DEBIAN_SSH_AUTHORIZED_KEYS" in
    *"test@example")
        ;;
    *)
        echo "expected persisted authorized keys to reload" >&2
        exit 1
        ;;
esac

echo "Standalone entrypoint ngrok URL tests passed"
