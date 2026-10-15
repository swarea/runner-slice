#!/usr/bin/env bash
#
# Drive fabric-check.sh against a fixture host that fabric-apply.sh
# converged: first a conformant one, then one broken in a single way at a
# time. Each break must fail the check and name what broke; each repair must
# pass again. A check that cannot fail proves nothing, so most cases here are
# the failing ones.
#
# systemd's effective properties and each service's mount table are
# fixtures. These results are SYNTHETICALLY TESTED: they show the check reads
# and judges correctly, not that a real systemd reports these values.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

T=$(mktemp -d) || exit 1
T=$(readlink -f "$T")
trap 'rm -rf "$T"' EXIT

# shellcheck source=fixture-host.sh
. "$ROOT/tests/fixture-host.sh"

check() { # ARGS...   sets OUT and RC
    RC=0
    OUT=$(env PATH="$BIN:$PATH" FAKE="$H/fake" FAKE_CG="$H/cg" FAKE_PROC="$H/proc" \
              bash "$H/fabric/fabric-check.sh" --config "$H/config" "$@" 2>&1) || RC=$?
}

prop() { # UNIT PROPERTY VALUE
    mkdir -p "$H/fake/props/$1"
    printf '%s\n' "$3" > "$H/fake/props/$1/$2"
}

# A service's mount table as systemd builds it from the rendered unit: an
# empty /home with the runner's own home bound back, and a mask over every
# path the inventory says the runner must not see.
mountinfo() { # ID PID [PATH-NOT-MASKED]
    local id=$1 pid=$2 skip=${3-} n=600 path
    mkdir -p "$H/proc/$pid"
    {
        echo "500 1 0:79 / /home rw,nosuid,relatime shared:10 - tmpfs tmpfs rw,inode64"
        echo "501 500 8:1 /home/runner-$id /home/runner-$id rw,relatime shared:11 - ext4 /dev/sda1 rw"
        while IFS= read -r path; do
            path=${path#-}
            [ "$path" = "$skip" ] && continue
            n=$((n + 1))
            echo "$n 1 0:27 /systemd/inaccessible/dir $path ro,nosuid,nodev,noexec,relatime shared:1 - tmpfs tmpfs rw"
        done < <(bash -c '. "$1/fabric/fabric-lib.sh"; fabric_expected_masks "$2" "$2/profiles/$3.conf"' \
                     _ "$ROOT" "$H/config" "$id")
    } > "$H/proc/$pid/mountinfo"
}

conform() { # ID PID
    local id=$1 pid=$2 svc="ci-$1-runner.service"
    prop ci.slice TasksMax 1024
    prop ci.slice MemoryMax 2147483648
    prop ci.slice MemoryHigh 1610612736
    prop ci.slice CPUQuotaPerSecUSec 1s
    prop "$svc" UnitFileState enabled
    prop "$svc" ActiveState active
    prop "$svc" User "runner-$id"
    prop "$svc" Slice ci.slice
    prop "$svc" NoNewPrivileges yes
    prop "$svc" PrivateTmp yes
    prop "$svc" ProtectSystem full
    prop "$svc" ProtectHome tmpfs
    prop "$svc" MainPID "$pid"
    # As systemd 255 prints it: yes for baseline, no for userns.
    if [ "$id" = docs ]; then prop "$svc" RestrictNamespaces no; else prop "$svc" RestrictNamespaces yes; fi
    mountinfo "$id" "$pid"
}

expect_pass() { # DESCRIPTION
    if [ "$RC" -eq 0 ]; then pass "$1"; else fail "$1 (rc=$RC)"; grep -E 'FAIL|CHANGE' <<<"$OUT" >&2; fi
}
expect_fail() { # DESCRIPTION NEEDLE
    if [ "$RC" -ne 0 ] && grep -Fq -- "$2" <<<"$OUT"; then
        pass "$1"
    else
        fail "$1 (rc=$RC, no '$2')"
        grep -E 'FAIL|CHANGE' <<<"$OUT" >&2
    fi
}

# ---------------------------------------------------------------------------
echo '== a converged host =='
# ---------------------------------------------------------------------------
new_host checked
only app docs
mkdir -p "$H/root/srv/example-app"
install -m 0000 /dev/null "$H/root/srv/example-app/.env"
echo 'protected-path   /srv/example-app/.env' >> "$H/config/fabric.conf"

apply --all
register app
register docs
apply --all
[ "$RC" -eq 0 ] || { echo "fixture: the host did not converge" >&2; printf '%s\n' "$OUT" >&2; exit 1; }
conform app 5001
conform docs 5002

check --profile app
expect_pass 'a converged host passes'
expect_out 'the slice is compared with its rendering' 'ci.slice matches the rendering'
expect_out 'the declared mask is proven in the namespace' 'masked in namespace: /srv/example-app'
expect_out 'a peer runtime root is proven masked' 'masked in namespace: /var/lib/ci-docs'
expect_out 'the home namespace is proven' 'exposes only its own home'
expect_out 'the protected path is proven unreadable' 'runner-app cannot read /srv/example-app/.env'
expect_out 'the baseline sandbox is checked' 'RestrictNamespaces=yes'

check --all
expect_pass 'the converged fleet passes'

# ---------------------------------------------------------------------------
echo
echo '== installed units =='
# ---------------------------------------------------------------------------
UNIT="$H/$UNITS/ci-app-runner.service"
cp "$UNIT" "$T/unit.saved"
echo 'IPAddressAllow=any' >> "$UNIT"
check --profile app
expect_fail 'an edited unit fails' 'ci-app-runner.service differs from the rendering'
mv "$T/unit.saved" "$UNIT"

mkdir -p "$UNIT.d"
printf '[Service]\nInaccessiblePaths=\n' > "$UNIT.d/override.conf"
check --profile app
expect_fail 'a drop-in fails' 'unexpected drop-in'
rm -rf "$UNIT.d"

mkdir -p "$H/root/run/systemd/system/ci.slice.d"
printf '[Slice]\nMemoryMax=infinity\n' > "$H/root/run/systemd/system/ci.slice.d/50-MemoryMax.conf"
check --profile app
expect_fail 'a runtime drop-in on the slice fails' 'unexpected drop-in'
rm -rf "$H/root/run"

mv "$UNIT" "$T/unit.saved"
check --profile app
expect_fail 'a missing unit fails' 'ci-app-runner.service is missing'
mv "$T/unit.saved" "$UNIT"

check --profile app
expect_pass 'the repaired units pass'

# ---------------------------------------------------------------------------
echo
echo '== effective limits =='
# ---------------------------------------------------------------------------
prop ci.slice MemoryMax infinity
check --profile app
expect_fail 'an unenforced memory ceiling fails' "ci.slice MemoryMax is 'infinity'"
prop ci.slice MemoryMax 2147483648

prop ci.slice CPUQuotaPerSecUSec 1000ms
check --profile app
expect_pass 'the same quota in another spelling passes'
prop ci.slice CPUQuotaPerSecUSec 1.500000s
check --profile app
expect_fail 'a different quota fails' 'ci.slice CPUQuota is 1.500000s, expected 100%'
prop ci.slice CPUQuotaPerSecUSec ''
check --profile app
expect_fail 'an unreadable quota fails closed' 'cannot read CPUQuotaPerSecUSec'
prop ci.slice CPUQuotaPerSecUSec 1s

prop ci-app-runner.service IPAddressAllow 169.254.169.254/32
check --profile app
expect_fail 'an allow list on the runner fails' "IPAddressAllow is '169.254.169.254/32'"
rm -f "$H/fake/props/ci-app-runner.service/IPAddressAllow"

echo 'slice-ip-deny     169.254.169.254/32' >> "$H/config/fabric.conf"
apply --all
prop ci.slice IPAddressDeny ''
check --profile app
expect_fail 'a declared deny systemd does not hold fails' 'ci.slice does not deny 169.254.169.254/32'
prop ci.slice IPAddressDeny 169.254.169.254
check --profile app
expect_pass 'a held deny passes whether or not systemd prints the prefix'

# ---------------------------------------------------------------------------
echo
echo '== account and filesystem =='
# ---------------------------------------------------------------------------
echo 'runner-app docker' > "$H/fake/groups-runner-app"
check --profile app
expect_fail 'a supplementary group fails' 'runner-app holds supplementary groups: docker'
rm -f "$H/fake/groups-runner-app"

rm -f "$H/fake/user-runner-app"
check --profile app
expect_fail 'a missing account fails' 'user runner-app does not exist'
: > "$H/fake/user-runner-app"

echo 'runner-app:runner-app 750' > "$H/root/var/lib/ci-app.owner"
check --profile app
expect_fail 'a runtime root the runner owns fails' '/var/lib/ci-app is runner-app:runner-app 750, expected root:runner-app 0750'
echo 'root:runner-app 750' > "$H/root/var/lib/ci-app.owner"

RUNNER_FILE="$H/root/var/lib/ci-app/runner/.runner"
cp "$RUNNER_FILE" "$T/runner.saved"
sed -i 's#"agentName": "[^"]*"#"agentName": "lab-other-01"#' "$RUNNER_FILE"
check --profile app
expect_fail 'a runner registered under another name fails' "the registration does not match the profile: name is 'lab-other-01'"
sed -i 's#"workFolder": "[^"]*"#"workFolder": "/tmp/work"#' "$RUNNER_FILE"
check --profile app
expect_fail 'every difference is named' "work folder is '/tmp/work'"
printf '{"agentName": ' > "$RUNNER_FILE"
check --profile app
expect_fail 'an unparseable registration fails closed' 'cannot read the registration'
cp "$T/runner.saved" "$RUNNER_FILE"
check --profile app
expect_pass 'the restored registration passes'
expect_out 'it is reported' 'registered as lab-app-01 for example-org/app, working in /var/lib/ci-app/work'

echo 'runner-app:runner-app 644' > "$H/root/var/lib/ci-app/runner/.credentials.owner"
check --profile app
expect_fail 'readable credentials fail' '.credentials is runner-app:runner-app 644'
echo 'runner-app:runner-app 600' > "$H/root/var/lib/ci-app/runner/.credentials.owner"

chmod 0644 "$H/root/srv/example-app/.env"
check --profile app
expect_fail 'a readable protected path fails' 'runner-app can read /srv/example-app/.env'
chmod 0000 "$H/root/srv/example-app/.env"

# ---------------------------------------------------------------------------
echo
echo '== runner release =='
# ---------------------------------------------------------------------------
DEPS="$H/root/var/lib/ci-app/runner/bin/Runner.Listener.deps.json"
cp "$DEPS" "$T/deps.saved"
version() { printf '{"libraries": {"Runner.Listener/%s": {}}}\n' "$1" > "$DEPS"; }
version 2.340.0
check --profile app
expect_pass 'a runner that updated itself passes'
version 2.300.0
check --profile app
expect_fail 'a runner below the seed fails' 'below the seed 2.338.0'
printf 'not json' > "$DEPS"
check --profile app
expect_fail 'an unreadable version fails closed' 'cannot determine the installed runner version'
# A link to a perfectly good manifest elsewhere is still not followed.
printf '{"libraries": {"Runner.Listener/2.338.0": {}}}\n' > "$T/elsewhere.json"
rm -f "$DEPS"; ln -s "$T/elsewhere.json" "$DEPS"
check --profile app
expect_fail 'a manifest that is a symlink is not followed' 'cannot determine the installed runner version'
rm -f "$DEPS"; cp "$T/deps.saved" "$DEPS"
refutes 'the runner binary was never executed by check' [ -e "$H/fake/listener-executed" ]

# ---------------------------------------------------------------------------
echo
echo '== service and namespace =='
# ---------------------------------------------------------------------------
prop ci-app-runner.service RestrictNamespaces no
check --profile app
expect_fail 'a baseline runner allowed namespaces fails' "RestrictNamespaces is 'no', expected 'yes'"
prop ci-app-runner.service RestrictNamespaces 'net user'
check --profile app
expect_fail 'a baseline runner allowed some namespaces fails' "RestrictNamespaces is 'net user', expected 'yes'"
prop ci-app-runner.service RestrictNamespaces yes

check --profile docs
expect_pass 'a userns runner may create namespaces'
prop ci-docs-runner.service RestrictNamespaces yes
check --profile docs
expect_fail 'a userns runner that cannot is drift too' "RestrictNamespaces is 'yes', expected 'no'"
prop ci-docs-runner.service RestrictNamespaces no

mountinfo app 5001 /srv/example-app
check --profile app
expect_fail 'a declared mask missing from the namespace fails' 'NOT masked in namespace: /srv/example-app'
mountinfo app 5001 /var/lib/ci-docs
check --profile app
expect_fail 'a peer root missing from the namespace fails' 'NOT masked in namespace: /var/lib/ci-docs'
mountinfo app 5001
echo '502 500 8:1 /home/runner-docs /home/runner-docs rw,relatime shared:12 - ext4 /dev/sda1 rw' \
    >> "$H/proc/5001/mountinfo"
check --profile app
expect_fail "a peer's home bound in fails" 'unexpected-home-mount:/home/runner-docs'
mountinfo app 5001

prop ci-app-runner.service MainPID 0
check --profile app
expect_fail 'a stopped runner cannot be proven and fails' 'mount namespace cannot be inspected'
prop ci-app-runner.service MainPID 5001

check --profile app
expect_pass 'the repaired host passes'

prop ci-docs-runner.service ActiveState failed
check --all
expect_fail 'one failing runner fails the fleet' 'PROFILE RESULT: docs failed'
prop ci-docs-runner.service ActiveState active

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
