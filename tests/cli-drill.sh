#!/usr/bin/env bash
#
# The runnerslice entry point translates each command into exactly one fabric
# script call. The translation is checked against a copy whose fabric scripts
# only record how they were called; the offline commands also run for real
# against the example inventory. SYNTHETICALLY TESTED.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
result() { # DESCRIPTION EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL  %s: expected [%s], got [%s]\n' "$1" "$2" "$3" >&2
    fi
}

T=$(mktemp -d) || exit 1
T=$(readlink -f "$T")
trap 'rm -rf "$T"' EXIT

echo '== the offline commands, for real =='

out=$("$ROOT/bin/runnerslice" --config "$ROOT/examples/basic" validate 2>&1); rc=$?
result 'validate accepts the example inventory' '0:RunnerSlice inventory: valid' "$rc:$(head -1 <<<"$out")"
"$ROOT/bin/runnerslice" --config "$ROOT/examples/basic" render web-2 > "$T/web-2.service"; rc=$?
result 'render prints the unit the library renders' "0:yes" \
    "$rc:$(bash -c '. "$1/fabric/fabric-lib.sh"; fabric_render_service "$2" "$2/profiles/web-2.conf"' \
              _ "$ROOT" "$ROOT/examples/basic" | cmp -s - "$T/web-2.service" && echo yes || echo no)"
result 'version reads the VERSION file' "runnerslice $(cat "$ROOT/VERSION")" "$("$ROOT/bin/runnerslice" version)"

echo
echo '== every command reaches one script, with these arguments =='

# A copy whose fabric scripts only print how they were called.
mkdir -p "$T/rs/bin" "$T/rs/fabric"
cp "$ROOT/bin/runnerslice" "$T/rs/bin/"
cp "$ROOT/VERSION" "$T/rs/"
for s in fabric-validate.sh fabric-render-service.sh fabric-apply.sh fabric-check.sh fabric-status.sh; do
    printf '#!/usr/bin/env bash\necho "%s $*"\n' "$s" > "$T/rs/fabric/$s"
done
# Called through a symlink, as an install in /usr/local/bin would be.
ln -s "$T/rs/bin/runnerslice" "$T/runnerslice"

rs() { "$T/runnerslice" "$@" 2>/dev/null; }
result 'validate'            'fabric-validate.sh /etc/runnerslice'                          "$(rs validate)"
result 'render'              'fabric-render-service.sh /etc/runnerslice app'                "$(rs render app)"
result 'plan, whole fleet'   'fabric-apply.sh --config /etc/runnerslice --all --check'      "$(rs plan)"
result 'plan, one profile'   'fabric-apply.sh --config /etc/runnerslice --profile app --check' "$(rs plan app)"
result 'apply, whole fleet'  'fabric-apply.sh --config /etc/runnerslice --all'              "$(rs apply)"
result 'apply, one profile'  'fabric-apply.sh --config /etc/runnerslice --profile app'      "$(rs apply app)"
result 'retire'              'fabric-apply.sh --config /etc/runnerslice --retire web-2'     "$(rs retire web-2)"
result 'retire, planned'     'fabric-apply.sh --config /etc/runnerslice --retire web-2 --check' "$(rs retire web-2 --check)"
result 'check'               'fabric-check.sh --config /etc/runnerslice --all'              "$(rs check)"
result 'status, one profile' 'fabric-status.sh --config /etc/runnerslice --profile app'     "$(rs status app)"
result 'a named configuration' 'fabric-check.sh --config /srv/x --profile app'              "$(rs --config /srv/x check app)"
result 'the configuration is not read from the environment' \
    'fabric-check.sh --config /etc/runnerslice --all' "$(RUNNERSLICE_CONFIG=/elsewhere CONFIG=/elsewhere rs check)"

echo
echo '== usage errors =='

code() { "$T/runnerslice" "$@" >/dev/null 2>&1; echo $?; }
result 'no command'                      2 "$(code)"
result 'an unknown command'              2 "$(code deploy)"
result 'render without a profile'        2 "$(code render)"
result 'two profiles'                    2 "$(code apply app web)"
result 'retire with a stray argument'    2 "$(code retire web-2 --force)"
result '--config without a directory'    2 "$(code --config)"

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
