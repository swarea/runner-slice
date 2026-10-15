#!/usr/bin/env bash
#
# Exercise the host primitives in fabric/host-lib.sh against synthetic
# fixtures: mount tables, cgroup and process trees, and a fake systemctl.
# Unprivileged; it reads no real service and changes nothing outside its own
# temporary directory.
#
# Several of these primitives answer questions that are easy to get wrong in
# a way that looks right -- whether a path can be opened rather than whether
# its spelling appears in a table, whether a runner is idle rather than merely
# not known to be busy -- so the cases include the ones that must NOT pass.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../fabric/fabric-lib.sh
. "$ROOT/fabric/fabric-lib.sh"
# shellcheck source=../fabric/host-lib.sh
. "$ROOT/fabric/host-lib.sh"

PASS=0
FAIL=0
result() { # DESCRIPTION EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3" >&2
    fi
}

# mktemp can return a path under a symlink, which would make every
# canonicalisation assertion below true for the wrong reason.
T=$(mktemp -d) || { echo "cannot create a temporary directory" >&2; exit 1; }
T=$(readlink -f "$T")
trap 'rm -rf "$T"' EXIT

echo '== the host location is not taken from the environment =='

# A root script whose target an environment variable could move belongs to
# whoever sets its environment. Sourcing the library must reset every root.
# shellcheck disable=SC2016 # expanded by the inner shell, after sourcing
got=$(env HOST_ROOT=/elsewhere CGROUP_ROOT=/elsewhere PROC_ROOT=/elsewhere \
          UNIT_DIR=/elsewhere TRUSTED_OWNER=nobody CHECK_ONLY=0 bash -c '
    . "$1/fabric/host-lib.sh"
    printf "%s|%s|%s|%s|%s" "$HOST_ROOT" "$CGROUP_ROOT" "$PROC_ROOT" "$UNIT_DIR" "$TRUSTED_OWNER"
' _ "$ROOT")
result "environment cannot move the host roots or the trusted owner" \
    "|/sys/fs/cgroup|/proc|/etc/systemd/system|root" "$got"

echo
echo '== mask resolution =='

# A mountinfo line in the shape the kernel emits. Field 5 is the mount point;
# a mask is recognised by systemd's inaccessible source.
mi_mask()  { printf '%s %s 0:27 /systemd/inaccessible/%s %s ro,nosuid,nodev,noexec,relatime shared:1 master:5 - tmpfs tmpfs rw,size=1k,mode=755\n' "$1" "$(( $1 - 1 ))" "$3" "$2"; }
mi_plain() { printf '%s %s 0:99 / %s rw,relatime shared:2 - tmpfs tmpfs rw,size=1k\n' "$1" "$(( $1 - 1 ))" "$2"; }

mkdir -p "$T/dir"
: > "$T/real"
: > "$T/dir/child"
: > "$T/unmasked"
: > "$T/plain"
ln -s "$T/real" "$T/alias"

FIX="$T/mountinfo"
{
    mi_mask  100 "$T/real" reg
    mi_mask  200 "$T/dir"  dir
    mi_plain 300 "$T/plain"
} > "$FIX"

mask() { local c rc=0; c=$(host_mask_for "$@") || rc=$?; printf '%s:%s' "$rc" "$c"; }

result "the literal masked path is covered"            "0:$T/real" "$(mask "$FIX" "$T/real")"
# The /var/run -> /run case: the caller's spelling never appears in
# mountinfo, and the object is masked all the same.
result "a symlink alias resolves to the masked path"   "0:$T/real" "$(mask "$FIX" "$T/alias")"
result "an unmasked path is not covered"               "1:"        "$(mask "$FIX" "$T/unmasked")"
result "a child of a masked directory is covered"      "0:$T/dir"  "$(mask "$FIX" "$T/dir/child")"
# Treating any mount as protection would be the fail-open mistake.
result "an ordinary mount is not mistaken for a mask"  "1:"        "$(mask "$FIX" "$T/plain")"
result "unreadable mountinfo fails closed"             "2:"        "$(mask "$T/does-not-exist" "$T/real")"
result "an absent path is not reported as covered"     "1:"        "$(mask "$FIX" "$T/never-existed")"

echo
echo '== default-deny home namespace =='

mi_home()       { printf '%s %s 0:79 / /home rw,nosuid,relatime shared:10 - tmpfs tmpfs rw,inode64\n' "$1" "$2"; }
mi_bind_home()  { printf '%s %s 8:1 %s %s rw,nosuid,relatime shared:11 - ext4 /dev/sda1 rw,errors=remount-ro\n' "$1" "$2" "$3" "$4"; }
mi_tmpfs_path() { printf '%s %s 0:80 / %s rw,nosuid,relatime shared:12 - tmpfs tmpfs rw,inode64\n' "$1" "$2" "$3"; }

home() { local s rc=0; s=$(host_home_namespace_state "$@") || rc=$?; printf '%s:%s' "$rc" "$s"; }

{
    mi_home      500 1
    mi_bind_home 501 500 /home/runner-app /home/runner-app
    # Mounts inside the runner's own home are not another exposed home.
    echo '502 501 0:90 / /home/runner-app/work/cache rw,relatime shared:13 - tmpfs tmpfs rw,inode64'
} > "$T/home-ok"
result "tmpfs /home plus the runner's real home is accepted" "0:ok" \
    "$(home "$T/home-ok" /home/runner-app)"

{
    echo '510 1 8:1 /home /home rw,relatime shared:20 - ext4 /dev/sda1 rw'
    mi_bind_home 511 510 /home/runner-app /home/runner-app
} > "$T/home-plain"
result "the host's ordinary /home is rejected" "1:home-not-tmpfs:ext4" \
    "$(home "$T/home-plain" /home/runner-app)"

mi_home 520 1 > "$T/home-no-own"
result "tmpfs without the runner's home is rejected" "1:own-home-missing" \
    "$(home "$T/home-no-own" /home/runner-app)"

{ mi_home 530 1; mi_tmpfs_path 531 530 /home/runner-app; } > "$T/home-fake"
result "a tmpfs posing as the runner's home is rejected" "1:own-home-root-mismatch:/" \
    "$(home "$T/home-fake" /home/runner-app)"

{
    mi_home 540 1
    echo '541 540 8:1 /home/someone-else /home/runner-app rw,relatime shared:30 - ext4 /dev/sda1 rw'
} > "$T/home-wrong-root"
result "a bind from another real home is rejected" "1:own-home-root-mismatch:/home/someone-else" \
    "$(home "$T/home-wrong-root" /home/runner-app)"

{ mi_home 550 1; mi_bind_home 551 42 /home/runner-app /home/runner-app; } > "$T/home-wrong-parent"
result "the runner's home must sit below the protected /home" "1:own-home-parent-mismatch" \
    "$(home "$T/home-wrong-parent" /home/runner-app)"

{
    mi_home      560 1
    mi_bind_home 561 560 /home/runner-app /home/runner-app
    mi_bind_home 562 560 /home/runner-web /home/runner-web
} > "$T/home-peer"
result "a peer's home bound back in is rejected" "1:unexpected-home-mount:/home/runner-web" \
    "$(home "$T/home-peer" /home/runner-app)"

result "unreadable home mountinfo fails closed" "2:mountinfo-unreadable" \
    "$(home "$T/no-such-mountinfo" /home/runner-app)"

echo
echo '== job state =='

# A fake systemctl that answers from files, and fixture cgroup and process
# trees. Only host_job_state is under test; the roots are set in this shell.
mkdir -p "$T/bin" "$T/cg" "$T/proc" "$T/sd"
cat > "$T/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# show UNIT -p ControlGroup --value | is-active --quiet UNIT
case "$1" in
    show)
        [ -e "$FAKE_SD/fail-show" ] && exit 1
        cat "$FAKE_SD/$2.cg" 2>/dev/null
        exit 0
        ;;
    is-active)
        [ -e "$FAKE_SD/${3:-$2}.active" ]
        exit
        ;;
esac
exit 97
EOF
chmod +x "$T/bin/systemctl"
export FAKE_SD="$T/sd"
PATH="$T/bin:$PATH"
CGROUP_ROOT="$T/cg"
PROC_ROOT="$T/proc"

SVC=ci-app-runner.service
running() { # PID COMMAND...
    local pid=$1; shift
    mkdir -p "$T/proc/$pid"
    printf '%s\0' "$@" > "$T/proc/$pid/cmdline"
}
reset_job() {
    rm -rf "$T/cg" "$T/proc" "$T/sd"
    mkdir -p "$T/cg/ci.slice/$SVC" "$T/proc" "$T/sd"
    echo "/ci.slice/$SVC" > "$T/sd/$SVC.cg"
    : > "$T/sd/$SVC.active"
    running 101 /var/lib/ci-app/runner/bin/Runner.Listener run --startuptype service
    echo 101 > "$T/cg/ci.slice/$SVC/cgroup.procs"
}
state() { local rc=0; host_job_state "$SVC" || rc=$?; echo "$rc"; }

reset_job
result "a listener alone is idle" 1 "$(state)"

reset_job
running 102 /var/lib/ci-app/runner/bin/Runner.Worker spawnclient 1 2
echo 102 >> "$T/cg/ci.slice/$SVC/cgroup.procs"
result "a worker in the service cgroup is a job in flight" 0 "$(state)"

reset_job
# The cgroup path is systemd's answer, not one built from the slice name.
mkdir -p "$T/cg/outer.slice/outer-ci.slice/$SVC"
echo "/outer.slice/outer-ci.slice/$SVC" > "$T/sd/$SVC.cg"
running 103 /x/bin/Runner.Worker
echo 103 > "$T/cg/outer.slice/outer-ci.slice/$SVC/cgroup.procs"
result "a nested slice is followed through systemd's ControlGroup" 0 "$(state)"

reset_job
echo 104 >> "$T/cg/ci.slice/$SVC/cgroup.procs"
result "a process that exited before it was read is skipped" 1 "$(state)"

reset_job
mkdir -p "$T/proc/105"
echo 105 >> "$T/cg/ci.slice/$SVC/cgroup.procs"
result "a process that exists but cannot be read is unknown" 2 "$(state)"

reset_job
rm -f "$T/cg/ci.slice/$SVC/cgroup.procs"
result "an unreadable cgroup is unknown" 2 "$(state)"

reset_job
: > "$T/sd/$SVC.cg"
rm -f "$T/sd/$SVC.active"
result "no cgroup and inactive is idle" 1 "$(state)"

reset_job
: > "$T/sd/$SVC.cg"
result "no cgroup while systemd says active is unknown" 2 "$(state)"

reset_job
: > "$T/sd/fail-show"
result "systemctl failing is unknown" 2 "$(state)"

echo
echo '== slices and sizes =='

result "a top-level slice has no ancestors" "" "$(fabric_slice_ancestors ci.slice | paste -sd' ' -)"
result "a dashed slice lists every ancestor, outermost first" "a.slice a-b.slice" \
    "$(fabric_slice_ancestors a-b-c.slice | paste -sd' ' -)"
result "sizes are base 1024" "1610612736 2147483648 4096 512" \
    "$(printf '%s ' "$(fabric_size_bytes 1536M)" "$(fabric_size_bytes 2G)" \
        "$(fabric_size_bytes 4K)" "$(fabric_size_bytes 512)" | sed 's/ $//')"

echo
echo '== root must only run what root controls =='

# The drill is unprivileged, so it can only show the refusal side: files it
# owns are not root's, and a group-writable file is unsafe whoever owns it.
mkdir -p "$T/cfg/profiles"
: > "$T/cfg/fabric.conf"
unsafe=$(host_unsafe_paths "$T/cfg")
case "$unsafe" in
    *"$T/cfg/fabric.conf"*) result "a configuration file root does not own is refused" yes yes ;;
    *) result "a configuration file root does not own is refused" yes "no ($unsafe)" ;;
esac
case "$unsafe" in
    *"$(dirname "$T") "*) result "a directory above the configuration is checked too" yes yes ;;
    *) result "a directory above the configuration is checked too" yes "no ($unsafe)" ;;
esac

# With the drill's own account as the trusted owner, each other reason a
# path is unsafe can be seen on its own.
mkdir -p "$T/cfg2/profiles"
: > "$T/cfg2/fabric.conf"
: > "$T/cfg2/profiles/plain.conf"
: > "$T/cfg2/profiles/shared.conf"
chmod g+w "$T/cfg2/profiles/shared.conf"
ln -s "$T/cfg2/profiles/plain.conf" "$T/cfg2/profiles/linked.conf"
unsafe=$(TRUSTED_OWNER=$(id -un); host_unsafe_paths "$T/cfg2")
listed() { case " $unsafe " in *" $1 "*) echo yes ;; *) echo no ;; esac; }
result "a plain file of the trusted owner is safe"  no  "$(listed "$T/cfg2/profiles/plain.conf")"
result "a symlink is unsafe whoever owns it"         yes "$(listed "$T/cfg2/profiles/linked.conf")"
result "a group-writable file is unsafe"            yes "$(listed "$T/cfg2/profiles/shared.conf")"

echo
echo '== preflight against a declared host =='

# The real preflight, with the machine's answers faked: uname, id and
# systemctl --version come from files, os-release and cgroup from the fixture.
PF="$T/pf"
mkdir -p "$PF/bin" "$PF/root/etc/systemd/system" "$PF/cg" "$PF/proc"
cp -a "$ROOT/examples/basic" "$PF/config"
cat > "$PF/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in -m) cat "$PF_STATE/arch" ;; -n) cat "$PF_STATE/host" ;; esac
EOF
cat > "$PF/bin/id" <<'EOF'
#!/usr/bin/env bash
case "$1" in -u) cat "$PF_STATE/uid" ;; -un) echo tester ;; *) exec /usr/bin/id "$@" ;; esac
EOF
cat > "$PF/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] && echo "systemd $(cat "$PF_STATE/systemd") (255.4-1ubuntu8)"
EOF
cat > "$PF/bin/nproc" <<'EOF'
#!/usr/bin/env bash
cat "$PF_STATE/cpus"
EOF
chmod +x "$PF/bin/"*
export PF_STATE="$PF/state"
mkdir -p "$PF_STATE"

pf_reset() {
    echo x86_64 > "$PF_STATE/arch"
    echo build-01 > "$PF_STATE/host"
    echo 1000 > "$PF_STATE/uid"
    echo 255 > "$PF_STATE/systemd"
    echo 2 > "$PF_STATE/cpus"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$PF/root/etc/os-release"
    echo 'cpuset cpu io memory hugetlb pids rdma misc' > "$PF/cg/cgroup.controllers"
    printf 'MemTotal:        4015636 kB\nMemFree:          123456 kB\n' > "$PF/proc/meminfo"
    rm -f "$PF/root/etc/systemd/system/"*
    sed -i '/^host-name/d' "$PF/config/fabric.conf"
}
pf() { # PRIVILEGE [COMMAND...]   prints rc:first warning
    local out rc=0
    out=$(PATH="$PF/bin:$PATH" bash -c '
              . "$1/fabric/fabric-lib.sh"; . "$1/fabric/host-lib.sh"
              HOST_ROOT=$2; CGROUP_ROOT=$3; PROC_ROOT=$4; FABRIC_DIR=$5
              UNIT_DIR="$HOST_ROOT/etc/systemd/system"; shift 5
              host_preflight "$@"
          ' _ "$ROOT" "$PF/root" "$PF/cg" "$PF/proc" "$ROOT/fabric" "$PF/config" "$@" 2>&1) || rc=$?
    printf '%s\n' "$out" > "$T/pf.out"
    printf '%s:%s' "$rc" "$(grep -m1 -o 'WARN.*' <<<"$out" | sed 's/^WARN *//')"
}

pf_reset
result "a host that matches the declaration passes" "0:" "$(pf --user)"

printf 'ID=debian\n' > "$PF/root/etc/os-release"
result "another distribution is refused" "1:distribution is 'debian'; only ubuntu is supported" "$(pf --user)"
pf_reset

echo aarch64 > "$PF_STATE/arch"
result "an architecture the seed was not built for is refused" \
    "1:architecture is 'aarch64'; the release seed is 'linux-x64'" "$(pf --user)"
pf_reset

echo 245 > "$PF_STATE/systemd"
result "a systemd older than the units need is refused" \
    "1:systemd '245' is older than 249 or unreadable" "$(pf --user)"
pf_reset

rm -f "$PF/cg/cgroup.controllers"
result "a host without cgroup v2 is refused" \
    "1:no cgroup v2 unified hierarchy at $PF/cg" "$(pf --user)"
pf_reset

echo 'host-name        build-02' >> "$PF/config/fabric.conf"
result "a configuration for another host is refused" \
    "1:hostname is 'build-01'; the configuration is for 'build-02'" "$(pf --user)"
sed -i 's/^host-name .*/host-name        build-01/' "$PF/config/fabric.conf"
result "the declared host passes" "0:" "$(pf --user)"
pf_reset

result "a converge as an ordinary user is refused" "1:must run as root" "$(pf --root)"
echo 0 > "$PF_STATE/uid"
result "the status query as root is refused" "1:running as root; this step needs no privilege" "$(pf --user)"
# The fake says root, but the files are the drill's: root would be acting on
# a configuration an ordinary account can rewrite.
result "root refuses a configuration it does not own" "1:not owned by root, or writable by others" \
    "$(pf --root | cut -d: -f1-2)"
pf_reset

result "a missing command is refused" "1:missing required commands: no-such-tool" \
    "$(pf --user no-such-tool)"

echo 'cpuset cpu io pids' > "$PF/cg/cgroup.controllers"
result "a host without the memory controller is refused" \
    "1:cgroup controllers not available: memory" "$(pf --user)"
pf_reset

printf 'MemTotal:        1015636 kB\n' > "$PF/proc/meminfo"
result "a memory ceiling above the host's memory is refused" \
    "1:slice-memory-max 2G is more than this host's 991 MiB" "$(pf --user)"
: > "$PF/proc/meminfo"
result "unreadable host memory fails closed" \
    "1:cannot compare slice-memory-max with this host's memory" "$(pf --user)"
pf_reset

sed -i 's/^slice-cpu-quota .*/slice-cpu-quota     300%/' "$PF/config/fabric.conf"
result "a CPU quota above the host's CPUs is refused" \
    "1:slice-cpu-quota 300% is more than this host's 2 CPUs (200%)" "$(pf --user)"
sed -i 's/^slice-cpu-quota .*/slice-cpu-quota     100%/' "$PF/config/fabric.conf"
pf_reset

: > "$PF/root/etc/systemd/system/actions.runner.example-org-old.lab-old-01.service"
result "a runner installed outside RunnerSlice is not refused" "0:" "$(pf --user)"
result "it is reported as outside the slice" yes \
    "$(grep -q 'not limited by its slice: actions.runner.example-org-old.lab-old-01.service' "$T/pf.out" && echo yes || echo no)"
pf_reset

echo
echo '== accounts RunnerSlice did not create =='

# getent answers from a file; the commands that would change accounts only
# log. The real host_ensure_user and host_remove_user decide.
ACC="$T/acct"
mkdir -p "$ACC/root/etc"
echo 'UID_MIN                  1000' > "$ACC/root/etc/login.defs"
cat > "$T/bin/getent" <<'EOF'
#!/usr/bin/env bash
grep "^$2:" "$FAKE_ACCOUNTS.$1" 2>/dev/null
EOF
for c in groupadd useradd userdel groupdel; do
    # shellcheck disable=SC2016 # the fake expands these when it runs
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FAKE_ACCOUNTS.log"\n' "$c" > "$T/bin/$c"
done
chmod +x "$T/bin/"*
export FAKE_ACCOUNTS="$ACC/db"

account() { # NAME UID HOME
    echo "$1:x:$2:$2::$3:/bin/bash" > "$FAKE_ACCOUNTS.passwd"
    echo "$1:x:$2:" > "$FAKE_ACCOUNTS.group"
    : > "$FAKE_ACCOUNTS.log"
}
acct() { # FUNCTION NAME   prints rc:first FAIL line
    local out rc=0
    out=$(HOST_ROOT="$ACC/root"; CHECK_ONLY=0; "$1" "$2" 2>&1) || rc=$?
    printf '%s:%s' "$rc" "$(grep -m1 -o 'FAIL .*' <<<"$out" | sed 's/^FAIL *//')"
}
ours() { HOST_ROOT="$ACC/root"; host_account_is_ours "$1" && echo yes || echo no; }

account runner-app 998 /home/runner-app
result "a system account with its own home is RunnerSlice's" yes "$(ours runner-app)"
result "it is kept as it is" "0:" "$(acct host_ensure_user runner-app)"

account runner-app 1001 /home/runner-app
result "an ordinary login account is not RunnerSlice's" no "$(ours runner-app)"
result "it is not adopted" \
    "1:account runner-app exists and is not a RunnerSlice system account; refusing to adopt it" \
    "$(acct host_ensure_user runner-app)"
result "and nothing was created for it" 0 "$(grep -c . "$FAKE_ACCOUNTS.log")"
result "it is not removed either" \
    "0:account runner-app is not a RunnerSlice system account; not removing it" \
    "$(acct host_remove_user runner-app)"
result "and nothing was deleted" 0 "$(grep -c . "$FAKE_ACCOUNTS.log")"

account runner-app 998 /srv/runner-app
result "a system account living elsewhere is not RunnerSlice's" no "$(ours runner-app)"
account runner-app 0 /home/runner-app
result "root by another name is not RunnerSlice's" no "$(ours runner-app)"

account runner-app 998 /home/runner-app
acct host_remove_user runner-app >/dev/null
result "RunnerSlice's own account is removed with its home and group" \
    "userdel --remove runner-app|groupdel runner-app" "$(paste -sd'|' "$FAKE_ACCOUNTS.log")"

: > "$FAKE_ACCOUNTS.passwd"; : > "$FAKE_ACCOUNTS.group"; : > "$FAKE_ACCOUNTS.log"
acct host_ensure_user runner-new >/dev/null
result "a missing account is created as a system account" \
    "groupadd --system runner-new|useradd --system --gid runner-new --home-dir /home/runner-new --create-home --shell /bin/bash runner-new" \
    "$(paste -sd'|' "$FAKE_ACCOUNTS.log")"
rm -f "$T/bin/getent" "$T/bin/groupadd" "$T/bin/useradd" "$T/bin/userdel" "$T/bin/groupdel"

echo
echo '== mode comparison =='

m() { host_mode_eq "$1" "$2" && echo same || echo differs; }
result "0750 equals 750"       same    "$(m 0750 750)"
result "0750 differs from 755" differs "$(m 0750 755)"
result "0000 equals 0"         same    "$(m 0000 0)"

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
