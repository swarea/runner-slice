#!/usr/bin/env bash
#
# The release archive is reproducible and self-verifying: two builds of one
# commit are byte-identical, the archive holds exactly the commit's files
# minus CI configuration, and its own tests/run.sh passes when unpacked.
# Needs a git checkout; from an archive it reports SKIPPED.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*" >&2; }

if ! git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    echo 'SKIPPED  not a git checkout; the release build needs one'
    printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 0
fi

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT

# A clone of the current commit, so uncommitted work never decides the result.
git clone -q "$ROOT" "$T/src"
git -C "$T/src" checkout -q "$(git -C "$ROOT" rev-parse HEAD)"
version=$(cat "$T/src/VERSION")
name="runnerslice-$version"

echo '== refusals =='
echo 'local change' >> "$T/src/VERSION"
if bash "$T/src/scripts/release.sh" --out "$T/a" --snapshot >/dev/null 2>&1; then
    fail 'a dirty tree is refused'
else
    pass 'a dirty tree is refused'
fi
git -C "$T/src" checkout -q -- VERSION

if [[ "$version" == *-dev* ]]; then
    if bash "$T/src/scripts/release.sh" --out "$T/a" >/dev/null 2>&1; then
        fail 'a development version is not released without --snapshot'
    else
        pass 'a development version is not released without --snapshot'
    fi
fi

echo
echo '== reproducible =='
if bash "$T/src/scripts/release.sh" --out "$T/a" --snapshot >/dev/null &&
   bash "$T/src/scripts/release.sh" --out "$T/b" --snapshot >/dev/null &&
   [ -f "$T/a/$name.tar.gz" ]; then
    pass 'the archive builds'
else
    fail 'the archive does not build; nothing further can be checked'
    printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
    exit 1
fi
if cmp -s "$T/a/$name.tar.gz" "$T/b/$name.tar.gz"; then
    pass 'two builds of one commit are byte-identical'
else
    fail 'two builds of one commit differ'
fi
if (cd "$T/a" && sha256sum -c --quiet "$name.tar.gz.sha256"); then
    pass 'the checksum file verifies the archive'
else
    fail 'the checksum file does not verify the archive'
fi

echo
echo '== contents =='
tar -tzf "$T/a/$name.tar.gz" | sed "s#^$name/##" | grep -v '/$' | grep . | LC_ALL=C sort > "$T/archive.list"
git -C "$T/src" ls-files | grep -v -E '^\.github/|^\.gitattributes$' | LC_ALL=C sort > "$T/expected.list"
if diff "$T/expected.list" "$T/archive.list" >/dev/null; then
    pass 'the archive holds exactly the committed files, without CI configuration'
else
    fail 'the archive contents differ from the commit'
    diff "$T/expected.list" "$T/archive.list" | head >&2
fi
if [ "$(tar -tzf "$T/a/$name.tar.gz" | grep -vc "^$name/")" -eq 0 ]; then
    pass 'everything is under one top-level directory'
else
    fail 'the archive has entries outside its top-level directory'
fi

echo
echo '== the unpacked archive verifies itself =='
mkdir -p "$T/unpacked"
tar -xzf "$T/a/$name.tar.gz" -C "$T/unpacked"
if out=$(cd "$T/unpacked/$name" && bash tests/run.sh 2>&1); then
    pass 'tests/run.sh passes inside the unpacked archive'
else
    fail 'tests/run.sh fails inside the unpacked archive'
    printf '%s\n' "$out" | grep -E 'FAIL|result' | head >&2
fi
if "$T/unpacked/$name/bin/runnerslice" --config "$T/unpacked/$name/examples/basic" validate >/dev/null; then
    pass 'the unpacked command validates the example inventory'
else
    fail 'the unpacked command does not validate the example inventory'
fi

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
