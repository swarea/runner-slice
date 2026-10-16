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
expect_rc 'a fresh apply is not converged while registration is left to a person' 1
expect_out 'the registration command is printed' 'actions/runners/registration-token'
expect_out 'registration names the runner and its labels' '--name lab-app-01 --labels lab,app'
expect_out 'the token travels in the environment' 'sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u runner-app'
expect_no 'the token is never on a command line' '--token'
expect_no 'a first registration never replaces a runner of the same name' '--unattended --replace'
# config.sh checks its libraries with ./bin paths before it changes to its own
# directory; run from elsewhere, that check silently checks nothing.
expect_out 'registration runs config.sh in the runner directory' 'env -C /var/lib/ci-app/runner HOME=/home/runner-app ./config.sh'
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
expect_rc 'a unit waiting for a job leaves the apply unconverged' 1
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

# A registered runner whose release went missing is not unpacked into: its
# directory is the jobs', and root would be extracting where they can reach.
new_host lostrelease
only app
apply --profile app
register app
apply --profile app
rm -f "$H/root/var/lib/ci-app/runner/config.sh"
curl_before=$(grep -c . "$H/fake/curl.log")
apply --profile app
expect_rc 'a registered runner with a missing release is not converged' 1
expect_out 'it is reported, not re-unpacked' 'is registered but its release is incomplete'
expect_lines 'nothing was downloaded' "$H/fake/curl.log" "$curl_before"
refutes 'the runner binary was never executed by apply' [ -e "$H/fake/listener-executed" ]

# A runtime root RunnerSlice did not create is someone else's directory.
new_host foreignroot
only app
mkdir -p "$H/root/var/lib/ci-app"
: > "$H/root/var/lib/ci-app/their-data"
before=$(snapshot)
apply --profile app
expect_rc 'an existing runtime root without the marker stops the profile' 1
expect_out 'it is named' '/var/lib/ci-app exists and was not created by RunnerSlice'
expect_same 'nothing was created, chowned or downloaded' "$before"

# ---------------------------------------------------------------------------
echo
echo '== one runner: an interrupted unpack is completed, not trusted =='
# ---------------------------------------------------------------------------
new_host interrupted
only app
apply --profile app
rm -f "$H/root/var/lib/ci-app/.runner-slice-seeded" "$H/root/var/lib/ci-app/runner/bin/runsvc.sh"
apply --profile app --check
expect_out 'the plan names the unfinished unpack' 'complete an interrupted unpack'
apply --profile app
expect_out 'the unpack is completed' 'archive digest verified'
expect_rc 'and the run waits only for registration' 1
expect_out 'registration is the outstanding step' 'register the runner, as a person'
expect_lines 'the archive was fetched again' "$H/fake/curl.log" 2
holds 'the missing file is restored' [ -x "$H/root/var/lib/ci-app/runner/bin/runsvc.sh" ]
holds 'the seed marker records the release' grep -q '^2.338.0 ' "$H/root/var/lib/ci-app/.runner-slice-seeded"

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
expect_out 'it says what differs' "repository is 'https://github.com/example-org/elsewhere'"
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
busy ci-web-2-runner.service
before=$(snapshot)
apply --retire web-2
expect_rc 'a busy member is not retired' 1
expect_out 'the drain command is printed' "actions/runners/\$RID/labels"
expect_same 'a refused retirement changes nothing' "$before"
idle ci-web-2-runner.service

apply --retire web-2
expect_rc 'an idle member stops at deregistration' 10
expect_out 'the deregistration command is printed' 'actions/runners/remove-token'
expect_out 'deregistration runs config.sh in the runner directory' 'env -C /var/lib/ci-web-2/runner HOME=/home/runner-web-2 ./config.sh remove'
# config.sh remove accepts --token, --pat and --local only (actions/runner
# v2.338.0); --unattended is a configure flag and is reported as unrecognised.
expect_no 'deregistration passes no flag remove does not accept' 'config.sh remove --unattended'
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

# A runner outside any pool retires the same way.
apply --retire app --check
expect_rc 'a planned retirement reports pending work' 1
apply --retire app
expect_rc 'a single runner stops at deregistration' 10
rm -f "$H/root/var/lib/ci-app/runner/.runner" "$H/root/var/lib/ci-app/runner/.credentials"
apply --retire app
expect_rc 'and is then removed' 0
refutes 'its unit is removed' [ -e "$H/$UNITS/ci-app-runner.service" ]
refutes 'its runtime root is removed' [ -e "$H/root/var/lib/ci-app" ]
refutes 'its account is removed' [ -e "$H/fake/user-runner-app" ]
only docs web
apply --all
expect_rc 'the remaining inventory converges' 0
refutes "the remaining units no longer mask the retired root" grep -q 'InaccessiblePaths=/var/lib/ci-app$' "$H/$UNITS/ci-docs-runner.service"

# Every runner retired: what is left is exactly the slice unit, which goes
# when RunnerSlice itself is removed, and the inventory. No runner unit,
# runtime root, account, enabled service or running process remains.
for id in docs web; do
    apply --retire "$id"
    expect_rc "$id stops at deregistration" 10
    rm -f "$H/root/var/lib/ci-$id/runner/.runner" "$H/root/var/lib/ci-$id/runner/.credentials"
    if [ "$id" = docs ]; then
        # A job's leftover process blocks the removal; nothing is removed.
        echo 4242 > "$H/fake/procs-runner-docs"
        apply --retire docs
        expect_rc 'a leftover process of the runner blocks its removal' 1
        expect_out 'and is named' 'processes of runner-docs are still running (4242)'
        holds 'its runtime root is still there' [ -d "$H/root/var/lib/ci-docs" ]
        holds 'and so is its unit' [ -e "$H/$UNITS/ci-docs-runner.service" ]
        rm -f "$H/fake/procs-runner-docs"
        # A unit someone else put in place of RunnerSlice's is not removed.
        cp "$H/$UNITS/ci-docs-runner.service" "$T/docs.saved"
        printf '[Unit]\nDescription=replaced by hand\n' > "$H/$UNITS/ci-docs-runner.service"
        apply --retire docs
        expect_rc 'retirement refuses a unit RunnerSlice did not write' 1
        holds 'and leaves that unit in place' grep -q 'replaced by hand' "$H/$UNITS/ci-docs-runner.service"
        holds 'and removes nothing else either' [ -d "$H/root/var/lib/ci-docs" ]
        holds 'not even the account' [ -e "$H/fake/user-runner-docs" ]
        cp "$T/docs.saved" "$H/$UNITS/ci-docs-runner.service"
    fi
    apply --retire "$id"
    expect_rc "$id is removed" 0
done
# *.owner files are the fixture's record of ownership, not host files.
leftover=$(cd "$H/root" && find . -mindepth 1 \( -type f -o -type l \) ! -name '*.owner' | LC_ALL=C sort | paste -sd' ' -)
if [ "$leftover" = "./etc/systemd/system/ci.slice" ]; then
    pass 'after the last runner only the slice unit remains on the host'
else
    fail "files remain after the last runner: $leftover"
fi
holds 'and it is the one RunnerSlice wrote' is_rendered "$H/$UNITS/ci.slice" slice
expect_lines 'no runtime root remains' <(find "$H/root/var/lib" -mindepth 1 -maxdepth 1 -type d) 0
refutes 'no runner account remains' compgen -G "$H/fake/user-*"
expect_lines 'no service is enabled' "$H/fake/enabled" 0
expect_lines 'no service is active' "$H/fake/active" 0

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
