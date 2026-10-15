#!/usr/bin/env bash
# The one verification entry point: static checks, then every drill.
# CI runs exactly this. Set SHELLCHECK to use a binary that is not on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELLCHECK=${SHELLCHECK:-shellcheck}

command -v "$SHELLCHECK" >/dev/null || {
    echo "run.sh: shellcheck not found (set SHELLCHECK)" >&2
    exit 2
}

mapfile -t scripts < <(cd "$ROOT" && git ls-files -co --exclude-standard '*.sh')
(cd "$ROOT" && "$SHELLCHECK" "${scripts[@]}")
echo "shellcheck: ${#scripts[@]} scripts clean"

failed=0
for drill in "$ROOT"/tests/*-drill.sh; do
    echo
    echo "### ${drill#"$ROOT"/}"
    bash "$drill" || failed=1
done

[ "$failed" -eq 0 ]
