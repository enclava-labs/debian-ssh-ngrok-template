#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

run_test() {
    test_script="$1"
    printf 'running %s\n' "${test_script#"$SCRIPT_DIR"/}"
    "$test_script"
}

run_test "$SCRIPT_DIR/test-image-layout.sh"

for test_script in "$SCRIPT_DIR"/test-entrypoint-*.sh; do
    [ -f "$test_script" ] || continue
    run_test "$test_script"
done
