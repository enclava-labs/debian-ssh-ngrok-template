#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
WORKFLOW="${ROOT_DIR}/.github/workflows/image.yml"

awk '
  /^[[:space:]]*uses:[[:space:]]*/ {
    uses = $0
    sub(/^[[:space:]]*uses:[[:space:]]*/, "", uses)
    sub(/[[:space:]]+#.*/, "", uses)
    if (uses !~ /@[0-9a-f]{40}$/) {
      printf "workflow action is not pinned to a 40-character commit SHA: %s\n", uses >"/dev/stderr"
      failed = 1
    }
  }
  END {
    exit failed ? 1 : 0
  }
' "$WORKFLOW"

echo "Workflow actions are pinned to commit SHAs"
