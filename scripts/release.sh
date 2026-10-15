#!/usr/bin/env bash
#
# Build the release archive for the committed tree and its checksum.
#
#     scripts/release.sh --out DIR [--snapshot]
#
# The archive is `git archive` of HEAD: exactly the committed files, under
# runnerslice-<version>/, with the commit's own timestamp, compressed without
# a name or time. The same commit always gives the same bytes, so anyone can
# rebuild it and compare the checksum.
#
# A release needs a clean tree and a VERSION without "-dev". --snapshot
# accepts a -dev version, for testing the build itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT=
SNAPSHOT=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) [ -n "${2-}" ] || { echo "usage: release.sh --out DIR [--snapshot]" >&2; exit 2; }
               OUT=$2; shift 2 ;;
        --snapshot) SNAPSHOT=1; shift ;;
        *) echo "usage: release.sh --out DIR [--snapshot]" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "usage: release.sh --out DIR [--snapshot]" >&2; exit 2; }

cd "$ROOT"
git rev-parse --verify -q HEAD >/dev/null || { echo "release.sh: not a git checkout" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ]; then
    echo "release.sh: the working tree has uncommitted changes; a release is built from a commit" >&2
    exit 1
fi

version=$(git show HEAD:VERSION)
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || {
    echo "release.sh: VERSION '$version' is not a version" >&2
    exit 1
}
if [[ "$version" == *-dev* ]] && [ "$SNAPSHOT" -eq 0 ]; then
    echo "release.sh: VERSION $version is a development version; use --snapshot to build it anyway" >&2
    exit 1
fi

name="runnerslice-$version"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
git archive --format=tar --prefix="$name/" HEAD | gzip -n -9 > "$OUT/$name.tar.gz"
(cd "$OUT" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

printf 'built  %s\n' "$OUT/$name.tar.gz"
printf 'commit %s\n' "$(git rev-parse HEAD)"
printf 'tree   %s\n' "$(git rev-parse 'HEAD^{tree}')"
cat "$OUT/$name.tar.gz.sha256"
