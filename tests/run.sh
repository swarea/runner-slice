#!/usr/bin/env bash
# The one verification entry point: static checks, then every drill.
# CI runs exactly this. Set SHELLCHECK to use a binary that is not on PATH.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The drills prove refusals of an ordinary account; as root every file is
# readable and those cases would pass or fail for the wrong reason.
[ "$(id -u)" -ne 0 ] || { echo "run.sh: run the drills as an ordinary user" >&2; exit 2; }
SHELLCHECK=${SHELLCHECK:-shellcheck}

command -v "$SHELLCHECK" >/dev/null || {
    echo "run.sh: shellcheck not found (set SHELLCHECK)" >&2
    exit 2
}

# find rather than git, so a release archive verifies the same way.
mapfile -t scripts < <(cd "$ROOT" && find . -name '*.sh' -not -path './.git/*' | LC_ALL=C sort)
(cd "$ROOT" && "$SHELLCHECK" "${scripts[@]}")
echo "shellcheck: ${#scripts[@]} scripts clean"

failed=0
for drill in "$ROOT"/tests/*-drill.sh; do
    echo
    echo "### ${drill#"$ROOT"/}"
    bash "$drill" || failed=1
done

[ "$failed" -eq 0 ]
