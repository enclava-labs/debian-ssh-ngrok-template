#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/image.yml"

fail() {
    echo "error: $*" >&2
    exit 1
}

assert_contains() {
    needle="$1"
    grep -Fq -- "$needle" "$WORKFLOW" || fail "workflow is missing: $needle"
}

assert_not_contains() {
    needle="$1"
    if grep -Fq -- "$needle" "$WORKFLOW"; then
        fail "workflow must not contain: $needle"
    fi
}

assert_order() {
    first="$1"
    second="$2"
    first_line="$(grep -nF -- "$first" "$WORKFLOW" | head -n1 | cut -d: -f1 || true)"
    second_line="$(grep -nF -- "$second" "$WORKFLOW" | head -n1 | cut -d: -f1 || true)"
    [ -n "$first_line" ] && [ -n "$second_line" ] \
        || fail "workflow must contain both ordered lines: $first before $second"
    [ "$first_line" -lt "$second_line" ] \
        || fail "workflow must keep $first before $second"
}

unpinned_uses="$(
    grep -nE '^[[:space:]]+- uses: ' "$WORKFLOW" \
        | grep -Ev '@[0-9a-f]{40}([[:space:]]+#|[[:space:]]*$)' \
        || true
)"
if [ -n "$unpinned_uses" ]; then
    echo "$unpinned_uses" >&2
    fail "workflow actions must be pinned to 40-character commit SHAs"
fi

assert_contains "name: Validate Debian SSH ngrok Template Image"
assert_contains "workflow_dispatch:"
assert_contains "branches: [\"main\"]"
assert_contains "scripts/**"
assert_contains "permissions:"
assert_contains "contents: read"
assert_contains "sh -n entrypoint.sh"
assert_contains "sh -n scripts/test-entrypoint-keys.sh"
assert_contains "sh -n scripts/test-entrypoint-ngrok-url.sh"
assert_contains "sh -n scripts/test-build-files.sh"
assert_contains "sh -n scripts/test-workflow.sh"
assert_contains "run: scripts/test-workflow.sh"
assert_contains "run: scripts/test-build-files.sh"
assert_contains "run: scripts/test-entrypoint-keys.sh"
assert_contains "run: scripts/test-entrypoint-ngrok-url.sh"
assert_contains "run: scripts/test-image-layout.sh"
assert_contains "run: scripts/test-entrypoint-config-dir.sh"
assert_contains "run: scripts/test-entrypoint-ngrok-api-timeout.sh"
assert_contains "run: scripts/test-entrypoint-supervision.sh"

assert_order "- name: Shell syntax" "- name: Workflow contract tests"
assert_order "- name: Workflow contract tests" "- name: Build file tests"
assert_order "- name: Build file tests" "- name: SSH key validation tests"
assert_order "- name: SSH key validation tests" "- name: ngrok URL validation tests"
assert_order "- name: ngrok URL validation tests" "- name: Image layout test"
assert_order "- name: Image layout test" "- name: Config directory test"
assert_order "- name: Config directory test" "- name: ngrok API timeout test"
assert_order "- name: ngrok API timeout test" "- name: Supervision test"

assert_not_contains "id-token: write"
assert_not_contains "packages: write"
assert_not_contains "docker/login-action"
assert_not_contains "docker/metadata-action"
assert_not_contains "docker/build-push-action"
assert_not_contains "sigstore/cosign-installer"
assert_not_contains "cosign sign"
assert_not_contains "actions/upload-artifact"
assert_not_contains "push: true"
assert_not_contains "ghcr.io/enclava-labs/debian-ssh-ngrok-template"

echo "Standalone template workflow tests passed"
