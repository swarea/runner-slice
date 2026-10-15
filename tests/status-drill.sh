#!/usr/bin/env bash
#
# Drive fabric-status.sh with a fake `gh` that answers from fixture JSON and
# the fixture systemd. A busy runner is healthy; anything GitHub did not state
# plainly, or a local service that is not running, fails. SYNTHETICALLY
# TESTED: the JSON has the API's shape, not a recorded response.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T=$(mktemp -d) || exit 1
T=$(readlink -f "$T")
trap 'rm -rf "$T"' EXIT

# shellcheck source=fixture-host.sh
. "$ROOT/tests/fixture-host.sh"

cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# gh api -H ... /repos/OWNER/REPO/actions/runners?per_page=100
[ -e "$FAKE/gh-fails" ] && { echo "HTTP 502" >&2; exit 1; }
for a in "$@"; do
    case "$a" in
        /repos/*) repo=${a#/repos/}; repo=${repo%%/actions/*} ;;
    esac
done
cat "$FAKE/gh/${repo//\//_}.json"
GH
chmod +x "$BIN/gh"

status() { # ARGS...   sets OUT and RC
    RC=0
    OUT=$(env PATH="$BIN:$PATH" FAKE="$H/fake" \
              bash "$H/fabric/fabric-status.sh" --config "$H/config" "$@" 2>&1) || RC=$?
}

runners() { # REPO TOTAL ENTRY...   ENTRY is name:status:busy
    local repo=$1 total=$2 sep="" e name st busy id=10
    shift 2
    mkdir -p "$H/fake/gh"
    {
        printf '{"total_count": %s, "runners": [' "$total"
        for e in "$@"; do
            IFS=: read -r name st busy <<<"$e"
            id=$((id + 1))
            printf '%s{"id": %d, "name": "%s", "os": "Linux", "status": "%s", "busy": %s, "labels": []}' \
                "$sep" "$id" "$name" "$st" "$busy"
            sep=", "
        done
        printf ']}\n'
    } > "$H/fake/gh/${repo//\//_}.json"
}

running() { # SERVICE
    local p
    for p in LoadState:loaded UnitFileState:enabled ActiveState:active SubState:running MainPID:4000; do
        mkdir -p "$H/fake/props/$1"
        echo "${p#*:}" > "$H/fake/props/$1/${p%%:*}"
    done
}

new_host status
only app web web-2
running ci-app-runner.service
running ci-web-runner.service
running ci-web-2-runner.service
runners example-org/app 1 lab-app-01:online:false
runners example-org/web 2 lab-web-01:online:true lab-web-02:online:false

echo '== healthy =='
status --all
expect_rc 'online runners with running services pass, busy or not' 0
expect_out 'a busy runner is reported' 'status=online busy=true'

echo
echo '== failing closed =='
runners example-org/app 1 lab-app-01:offline:false
status --profile app
expect_rc 'an offline runner fails' 1
expect_out 'and says so' 'remote runner is not online'

runners example-org/app 2 lab-app-01:online:false lab-app-01:online:false
status --profile app
expect_rc 'two runners of one name fail' 1
expect_out 'as an untrustworthy identity' 'not trustworthy'

runners example-org/app 1 lab-other-01:online:false
status --profile app
expect_rc 'a runner GitHub does not list fails' 1

runners example-org/app 150 lab-app-01:online:false
status --profile app
expect_rc 'a partial listing fails rather than hide a duplicate' 1

runners example-org/app 1 lab-app-01:idle:false
status --profile app
expect_rc 'a status GitHub does not define fails' 1

runners example-org/app 1 lab-app-01:online:false
: > "$H/fake/gh-fails"
status --profile app
expect_rc 'an API failure fails' 1
expect_out 'and names the repository' 'query failed for example-org/app'
rm -f "$H/fake/gh-fails"

echo failed > "$H/fake/props/ci-app-runner.service/ActiveState"
status --profile app
expect_rc 'a local service that is not running fails' 1
expect_out 'and says so' 'local runner service is not fully running'
running ci-app-runner.service

rm -rf "$H/fake/props/ci-web-2-runner.service"
status --all
expect_rc 'unreadable local state fails' 1
expect_out 'and is shown as unknown' 'load=unknown'

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
