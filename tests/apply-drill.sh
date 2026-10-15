#!/usr/bin/env bash
#
# Drive fabric-apply.sh through a runner's whole life on a fixture host:
# fresh install, the registration boundary, enable, idempotent re-apply, unit
# changes with idle, busy and unknown runners, a fleet, a pool member's
# retirement, and the refusals in between.
#
# The script under test runs unmodified from a temporary copy. Only the host
# is replaced: the library's roots point at a fixture directory, accounts and
# ownership are recorded instead of created, and systemctl, curl, dpkg,
# apt-get, chown and runuser are fakes that keep their state in files. Job
# detection is the real code reading a fixture cgroup and process tree.
#
# Every result here is SYNTHETICALLY TESTED. None of it is evidence about a
# real host, a real systemd or a real registration.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T=$(mktemp -d) || exit 1
T=$(readlink -f "$T")
trap 'rm -rf "$T"' EXIT

sources_hash() {
    (cd "$ROOT" && find fabric examples -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
}
SOURCES_BEFORE=$(sources_hash)

# shellcheck source=fixture-host.sh
. "$ROOT/tests/fixture-host.sh"

# ---------------------------------------------------------------------------
echo '== one runner: fresh host to the registration boundary =='
# ---------------------------------------------------------------------------
new_host single
only app

before=$(snapshot)
apply --profile app --check
expect_rc 'a plan on a fresh host reports pending work' 1
expect_out 'the plan names the download' 'CHANGE  download and unpack'
expect_same 'a plan changes nothing' "$before"

apply --profile app
expect_rc 'a fresh apply succeeds with the registration left to a person' 0
expect_out 'the registration command is printed' 'actions/runners/registration-token'
expect_out 'registration names the runner and its labels' '--name lab-app-01 --labels lab,app'
expect_no 'no token is requested by the tool itself' 'TOKEN=ghs'
holds 'the verified release is unpacked' [ -x "$H/root/var/lib/ci-app/runner/config.sh" ]
expect_lines 'the archive was downloaded once' "$H/fake/curl.log" 1
expect_lines 'the declared package was installed' "$H/fake/apt.log" 1
holds 'the slice unit is the rendering' is_rendered "$H/$UNITS/ci.slice" slice
holds 'the service unit is the rendering' is_rendered "$H/$UNITS/ci-app-runner.service" app
expect_lines 'an unregistered runner is not enabled' "$H/fake/enabled" 0

apply --profile app --check
expect_rc 'a plan still fails while registration is outstanding' 1
expect_out 'the outstanding registration is reported' 'operator actions are outstanding'

# ---------------------------------------------------------------------------
echo
echo '== one runner: registered, enabled, then idempotent =='
# ---------------------------------------------------------------------------
register app
apply --profile app
expect_rc 'the registered runner converges' 0
expect_out 'it is enabled and started' 'CHANGE  enable and start ci-app-runner.service'
expect_lines 'nothing was downloaded again' "$H/fake/curl.log" 1

before=$(snapshot)
apply --profile app
expect_rc 'a third apply succeeds' 0
expect_out 'it reports no change' 'no change: host already matches'
expect_same 'a third apply changes nothing at all' "$before"

apply --profile app --check
expect_rc 'a plan on a converged host passes' 0

# ---------------------------------------------------------------------------
echo
echo '== one runner: a unit change meets idle, busy and unknown runners =='
# ---------------------------------------------------------------------------
# A slice change is a reload, not a restart.
sed -i 's/^slice-tasks-max .*/slice-tasks-max     2048/' "$H/config/fabric.conf"
apply --profile app
expect_rc 'a slice change applies' 0
expect_out 'it reloads systemd' 'systemd reloaded'
refutes 'a slice change restarts no runner' grep -q '^restart' "$H/fake/systemctl.log"

# A service change needs a restart, which waits for the job.
echo 'common-mask      -/srv/other-app' >> "$H/config/fabric.conf"
busy ci-app-runner.service
apply --profile app
expect_rc 'a busy runner does not fail the apply' 0
expect_out 'the deferred unit is an operator action' 'has a new unit, but a job is running; it waits until the job ends'
refutes 'a busy runner is not restarted' grep -q '^restart' "$H/fake/systemctl.log"
refutes 'the new unit waits for the job' is_rendered "$H/$UNITS/ci-app-runner.service" app

idle ci-app-runner.service
apply --profile app
expect_rc 'an idle runner takes the new unit' 0
expect_lines 'an idle runner is restarted once' <(grep '^restart' "$H/fake/systemctl.log") 1

echo 'common-mask      -/srv/third-app' >> "$H/config/fabric.conf"
mkdir -p "$H/proc/4200"
echo 4200 >> "$H/cg/ci.slice/ci-app-runner.service/cgroup.procs"
apply --profile app
expect_rc 'a runner whose job state cannot be read fails the apply' 1
expect_out 'it says why' 'cannot tell whether ci-app-runner.service is running a job'
expect_lines 'and is not restarted' <(grep '^restart' "$H/fake/systemctl.log") 1
expect_out 'its new unit is not installed' 'its new unit waits'
refutes 'the installed unit is still the old one' is_rendered "$H/$UNITS/ci-app-runner.service" app
rm -rf "$H/proc/4200"
idle ci-app-runner.service

# ---------------------------------------------------------------------------
echo
echo '== one runner: a tampered download is refused =='
# ---------------------------------------------------------------------------
new_host tampered
only app
sed -i "s/^runner-sha256 .*/runner-sha256    $(printf '0%.0s' {1..64})/" "$H/config/runner-release.conf"
apply --profile app
expect_rc 'a digest mismatch fails' 1
expect_out 'and says so' 'digest mismatch; refusing to unpack'
refutes 'nothing was unpacked' [ -e "$H/root/var/lib/ci-app/runner/config.sh" ]

# ---------------------------------------------------------------------------
echo
echo '== one runner: an interrupted unpack is completed, not trusted =='
# ---------------------------------------------------------------------------
new_host interrupted
only app
apply --profile app
rm -f "$H/root/var/lib/ci-app/.runnerslice-seeded" "$H/root/var/lib/ci-app/runner/bin/runsvc.sh"
apply --profile app --check
expect_out 'the plan names the unfinished unpack' 'complete an interrupted unpack'
apply --profile app
expect_rc 'the unpack is completed' 0
expect_lines 'the archive was fetched again' "$H/fake/curl.log" 2
holds 'the missing file is restored' [ -x "$H/root/var/lib/ci-app/runner/bin/runsvc.sh" ]
holds 'the seed marker records the release' grep -q '^2.338.0 ' "$H/root/var/lib/ci-app/.runnerslice-seeded"

# ---------------------------------------------------------------------------
echo
echo '== one runner: what RunnerSlice did not write is not taken over =='
# ---------------------------------------------------------------------------
new_host foreign
only app
mkdir -p "$H/$UNITS"
printf '[Unit]\nDescription=somebody else\n' > "$H/$UNITS/ci-app-runner.service"
before=$(snapshot)
apply --profile app
expect_rc 'a foreign unit of the same name stops the profile' 1
expect_out 'it is named' 'ci-app-runner.service exists and was not written by RunnerSlice'
expect_same 'nothing was created beside it' "$before"
rm -f "$H/$UNITS/ci-app-runner.service"

printf '[Slice]\nCPUQuota=10%%\n' > "$H/$UNITS/ci.slice"
apply --profile app
expect_rc 'a foreign slice of the same name stops the profile' 1
holds 'the foreign slice is untouched' grep -q '^CPUQuota=10%$' "$H/$UNITS/ci.slice"
rm -f "$H/$UNITS/ci.slice"

apply --profile app
register app
apply --profile app
expect_rc 'the profile converges once the names are free' 0

# A registration that names another repository, runner or work folder is a
# runner the profile does not describe; it is not started.
new_host misregistered
only app
apply --profile app
register app
sed -i 's#"gitHubUrl": "[^"]*"#"gitHubUrl": "https://github.com/example-org/elsewhere"#' \
    "$H/root/var/lib/ci-app/runner/.runner"
apply --profile app
expect_rc 'a registration for another repository fails' 1
expect_out 'it says what differs' 'repository is https://github.com/example-org/elsewhere'
expect_lines 'the runner is not started' "$H/fake/enabled" 0
printf 'not json' > "$H/root/var/lib/ci-app/runner/.runner"
apply --profile app
expect_out 'an unreadable registration fails closed' 'cannot read the registration'
expect_lines 'and is not started either' "$H/fake/enabled" 0
register app
apply --profile app
expect_rc 'the corrected registration starts' 0
expect_lines 'the runner is started' "$H/fake/enabled" 1

# The plan says what the run would do with a busy runner: wait.
echo 'common-mask      -/srv/plan-app' >> "$H/config/fabric.conf"
busy ci-app-runner.service
before=$(snapshot)
apply --profile app --check
expect_rc 'a plan with a busy runner reports outstanding work' 1
expect_out 'it says the unit waits for the job' 'it waits until the job ends'
expect_no 'it does not promise a restart' 'CHANGE  restart'
expect_same 'the plan changes nothing' "$before"
idle ci-app-runner.service

# ---------------------------------------------------------------------------
echo
echo '== fleet: four runners, one pool =='
# ---------------------------------------------------------------------------
new_host fleet

before=$(snapshot)
apply --all --check
expect_rc 'a fleet plan on a fresh host reports pending work' 1
expect_same 'a fleet plan changes nothing' "$before"

apply --all
expect_rc 'a fresh fleet stops at the registration boundary' 1
expect_out 'every runner waits for registration' 'registration is required for: app docs web-2 web'
expect_lines 'each runner downloaded its seed once' "$H/fake/curl.log" 4

for id in app docs web web-2; do register "$id"; done
apply --all
expect_rc 'the registered fleet converges' 0
expect_lines 'all four runners are enabled' "$H/fake/enabled" 4

before=$(snapshot)
apply --all
expect_rc 'a second fleet apply succeeds' 0
expect_same 'a second fleet apply changes nothing' "$before"

# A policy change rewrites the slice and every service. With one runner busy
# the fleet refuses before the first child changes anything.
sed -i 's/^slice-memory-max .*/slice-memory-max    3G/' "$H/config/fabric.conf"
busy ci-web-2-runner.service
before=$(snapshot)
apply --all
expect_rc 'a busy runner stops the fleet' 1
expect_out 'the refusal names it' 'fleet apply refused: ci-web-2-runner.service has a job in flight'
expect_same 'the refused fleet changed nothing' "$before"

idle ci-web-2-runner.service
apply --all
expect_rc 'the idle fleet takes the slice change' 0
expect_lines 'a slice change restarts no runner' <(grep '^restart' "$H/fake/systemctl.log") 0

echo 'common-mask      -/srv/other-app' >> "$H/config/fabric.conf"
apply --all
expect_rc 'the idle fleet takes a service change' 0
expect_lines 'each runner is restarted once' <(grep '^restart' "$H/fake/systemctl.log") 4

# An installed runner unit that no profile renders may still hold a
# registration and a job; the fleet will not converge around it.
cp "$H/$UNITS/ci-docs-runner.service" "$H/$UNITS/ci-old-runner.service"
before=$(snapshot)
apply --all
expect_rc 'an orphaned runner unit stops the fleet' 1
expect_out 'the refusal names it' 'not in this inventory: ci-old-runner.service'
expect_same 'the refused fleet changed nothing' "$before"
rm -f "$H/$UNITS/ci-old-runner.service"

# A unit outside the declared prefix, or one RunnerSlice did not write,
# is not this tool's to judge.
: > "$H/$UNITS/cinder-runner.service"
apply --all
expect_rc 'a unit outside the name-prefix is left alone' 0
rm -f "$H/$UNITS/cinder-runner.service"
printf '[Unit]\nDescription=hand-made\n' > "$H/$UNITS/ci-handmade-runner.service"
apply --all
expect_rc 'an unmarked unit inside the prefix is not an orphan' 0
holds 'and is left alone' grep -q 'hand-made' "$H/$UNITS/ci-handmade-runner.service"
rm -f "$H/$UNITS/ci-handmade-runner.service"

# ---------------------------------------------------------------------------
echo
echo '== retiring a pool member =='
# ---------------------------------------------------------------------------
apply --retire app
expect_rc 'a runner outside a pool cannot be retired' 2
apply --retire web
expect_rc "a pool's first runner cannot be retired" 2

busy ci-web-2-runner.service
before=$(snapshot)
apply --retire web-2
expect_rc 'a busy member is not retired' 1
expect_out 'the drain command is printed' "actions/runners/\$RID/labels/web"
expect_same 'a refused retirement changes nothing' "$before"
idle ci-web-2-runner.service

apply --retire web-2
expect_rc 'an idle member stops at deregistration' 10
expect_out 'the deregistration command is printed' 'actions/runners/remove-token'
holds 'it is stopped and disabled first' grep -q '^disable ci-web-2-runner.service' "$H/fake/systemctl.log"
holds 'its registration is left for the person' [ -e "$H/root/var/lib/ci-web-2/runner/.runner" ]

rm -f "$H/root/var/lib/ci-web-2/runner/.runner" "$H/root/var/lib/ci-web-2/runner/.credentials"
apply --retire web-2
expect_rc 'a deregistered member is removed' 0
refutes 'its unit is removed' [ -e "$H/$UNITS/ci-web-2-runner.service" ]
refutes 'its runtime root is removed' [ -e "$H/root/var/lib/ci-web-2" ]
refutes 'its account is removed' [ -e "$H/fake/user-runner-web-2" ]
holds 'its pool peer is untouched' [ -e "$H/root/var/lib/ci-web/runner/.runner" ]

before=$(snapshot)
apply --retire web-2
expect_rc 'retiring again is a no-op' 0
expect_same 'and changes nothing' "$before"

only app docs web
apply --all
expect_rc 'the inventory without the member converges' 0
expect_lines 'three runners remain enabled' "$H/fake/enabled" 3

# ---------------------------------------------------------------------------
echo
echo '== source integrity =='
# ---------------------------------------------------------------------------
if diff -q "$ROOT/fabric/fabric-apply.sh" "$H/fabric/fabric-apply.sh" >/dev/null; then
    pass 'the drill ran the apply script unmodified'
else
    fail 'the drill ran a modified apply script'
fi
if [ "$SOURCES_BEFORE" = "$(sources_hash)" ]; then
    pass 'the drill left the sources untouched'
else
    fail 'the drill changed the sources'
fi

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
