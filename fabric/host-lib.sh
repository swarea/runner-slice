#!/usr/bin/env bash
#
# Host primitives for fabric-apply.sh, fabric-check.sh and fabric-status.sh.
# Sourced, not executed.
#
# Two exit contracts live here, because conflating them produces the wrong
# answer in each direction:
#
#   apply   converges the host toward the declared configuration. It reports
#           what it changed, and under --check it reports what it would change
#           without changing it.
#   check   reads and compares only. It fails closed: a question it cannot
#           answer counts as a failure, never as a pass, because a conformance
#           check that reports healthy when its own probe broke is worse than
#           no check.

# ---------------------------------------------------------------------------
# Where the host is
# ---------------------------------------------------------------------------
# Every filesystem path the scripts touch on the host is prefixed with
# HOST_ROOT, and the cgroup and process trees are read from these roots. They
# are assigned here, unconditionally, and never taken from the environment: a
# root script whose target directory an environment variable could move is a
# root script anyone who can set its environment controls. The drills point
# them at a fixture by editing a temporary copy of this file.
HOST_ROOT=""
CGROUP_ROOT=/sys/fs/cgroup
PROC_ROOT=/proc
# shellcheck disable=SC2034 # read by the scripts that source this file
UNIT_DIR="$HOST_ROOT/etc/systemd/system"
# The only account trusted to own what root runs or reads.
TRUSTED_OWNER=root

# The oldest systemd whose behaviour the units rely on: ProtectHome=tmpfs with
# BindPaths, and a slice's IPAddressDeny merged into every unit inside it.
FABRIC_MIN_SYSTEMD=249

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
# config_changed   declared configuration differs from the host
# operator_todo    a step these scripts must not perform is outstanding
# check_failed     a conformance statement is false, or could not be read
CHECK_ONLY=0
config_changed=0
operator_todo=0
check_failed=0

note()   { printf '  %s\n' "$*"; }
step()   { printf '\n== %s\n' "$*"; }
change() { config_changed=1; printf '  CHANGE  %s\n' "$*"; }
todo()   { operator_todo=1;  printf '  TODO    %s\n' "$*"; }
fail()   { check_failed=1;   printf '  FAIL    %s\n' "$*"; }
ok()     { printf '  ok      %s\n' "$*"; }
warn()   { printf '  WARN    %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# host_release_arch PLATFORM   the uname -m a runner release platform runs on
host_release_arch() {
    case "$1" in
        linux-x64)   echo x86_64 ;;
        linux-arm64) echo aarch64 ;;
        *)           return 1 ;;
    esac
}

# host_unsafe_paths DIR...
#
# Prints every file under each DIR, and every directory above it, that an
# account other than root could change, and every symlink: a link points at
# a file whose owner was never checked. Root must not run, or act on, what an
# unprivileged account could have rewritten -- and a directory above is enough
# to swap the whole tree. Prints nothing when all is safe.
host_unsafe_paths() {
    local dir p
    for dir in "$@"; do
        find "$dir" \( -type l -o ! -user "$TRUSTED_OWNER" -o -perm -0020 -o -perm -0002 \) \
            -printf '%p ' 2>/dev/null || printf '%s(unreadable) ' "$dir"
        p=$(readlink -f -- "$dir")
        while [ "$p" != / ] && [ -n "$p" ]; do
            p=$(dirname "$p")
            # The sticky bit on a world-writable directory such as /tmp still
            # lets others rename entries they own, so it is not an exception.
            if [ "$(stat -c '%u' "$p")" != 0 ] ||
               [ -n "$(find "$p" -maxdepth 0 \( -perm -0020 -o -perm -0002 \))" ]; then
                printf '%s ' "$p"
            fi
        done
    done
}

# host_preflight CONFIG_DIR [--root|--user] [extra-command ...]
#
# Refuses a host the declaration does not describe, before anything is
# touched: the wrong distribution, an architecture the release seed was not
# built for, a systemd too old for the units, a cgroup v1 host, a hostname
# other than the one the policy names, or missing commands.
#
# --root also requires effective uid 0 and refuses a configuration directory
# that anyone but root could have written: root would otherwise apply what an
# unprivileged account put there. --user refuses root, for the GitHub status
# query, which needs no privilege and should not hold any.
host_preflight() {
    local config=$1 privilege=${2-}
    shift 2 || shift $#
    local failed=0 os_id="" host arch want_arch platform systemd_version expected_host

    step "preflight"

    case "$privilege" in
        --root)
            if [ "$(id -u)" -eq 0 ]; then
                ok "running as root"
            else
                warn "must run as root"
                failed=1
            fi
            ;;
        --user)
            if [ "$(id -u)" -eq 0 ]; then
                warn "running as root; this step needs no privilege"
                failed=1
            else
                ok "running as unprivileged user $(id -un)"
            fi
            ;;
    esac

    if [ -r "$HOST_ROOT/etc/os-release" ]; then
        # shellcheck disable=SC1091
        os_id=$(. "$HOST_ROOT/etc/os-release" && printf '%s' "${ID-}")
    fi
    if [ "$os_id" = ubuntu ]; then
        ok "distribution is ubuntu"
    else
        warn "distribution is '${os_id:-unknown}'; only ubuntu is supported"
        failed=1
    fi

    arch=$(uname -m)
    platform=$(fabric_value "$config/runner-release.conf" runner-platform)
    if want_arch=$(host_release_arch "$platform") && [ "$arch" = "$want_arch" ]; then
        ok "architecture $arch matches the release seed ($platform)"
    else
        warn "architecture is '$arch'; the release seed is '${platform:-unset}'"
        failed=1
    fi

    systemd_version=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')
    systemd_version=${systemd_version%%[!0-9]*}
    if [ -n "$systemd_version" ] && [ "$systemd_version" -ge "$FABRIC_MIN_SYSTEMD" ]; then
        ok "systemd $systemd_version"
    else
        warn "systemd '${systemd_version:-unknown}' is older than $FABRIC_MIN_SYSTEMD or unreadable"
        failed=1
    fi

    if [ -f "$CGROUP_ROOT/cgroup.controllers" ]; then
        ok "cgroup v2 unified hierarchy"
        # The slice's limits need these controllers. Without one, systemd
        # accepts the setting and enforces nothing.
        local controller missing_ctl=""
        for controller in cpu memory pids; do
            grep -qw -- "$controller" "$CGROUP_ROOT/cgroup.controllers" ||
                missing_ctl="$missing_ctl $controller"
        done
        if [ -n "$missing_ctl" ]; then
            warn "cgroup controllers not available:$missing_ctl"
            failed=1
        else
            ok "cpu, memory and pids controllers available"
        fi
    else
        warn "no cgroup v2 unified hierarchy at $CGROUP_ROOT"
        failed=1
    fi

    # A ceiling above what the host has limits nothing; it is a declaration
    # written for another machine.
    local mem_kib mem_max cpus quota
    mem_kib=$(awk '$1 == "MemTotal:" { print $2 }' "$PROC_ROOT/meminfo" 2>/dev/null)
    mem_max=$(fabric_value "$config/fabric.conf" slice-memory-max)
    if [[ "$mem_kib" =~ ^[0-9]+$ ]] && [[ "$mem_max" =~ ^[1-9][0-9]*[KMGT]?$ ]]; then
        if [ "$(fabric_size_bytes "$mem_max")" -le $((mem_kib * 1024)) ]; then
            ok "slice-memory-max $mem_max fits in $((mem_kib / 1024)) MiB of memory"
        else
            warn "slice-memory-max $mem_max is more than this host's $((mem_kib / 1024)) MiB"
            failed=1
        fi
    else
        warn "cannot compare slice-memory-max with this host's memory"
        failed=1
    fi
    cpus=$(nproc 2>/dev/null)
    quota=$(fabric_value "$config/fabric.conf" slice-cpu-quota)
    quota=${quota%\%}
    if [[ "$cpus" =~ ^[0-9]+$ ]] && [[ "$quota" =~ ^[0-9]+$ ]]; then
        if [ "$quota" -le $((cpus * 100)) ]; then
            ok "slice-cpu-quota ${quota}% fits in $cpus CPUs"
        else
            warn "slice-cpu-quota ${quota}% is more than this host's $cpus CPUs ($((cpus * 100))%)"
            failed=1
        fi
    else
        warn "cannot compare slice-cpu-quota with this host's CPUs"
        failed=1
    fi

    # Runners installed by GitHub's own svc.sh run outside the slice. They
    # are not RunnerSlice's to change, but the operator should know.
    local foreign
    foreign=$(find "$UNIT_DIR" -maxdepth 1 -name 'actions.runner.*.service' -printf '%f ' 2>/dev/null)
    [ -z "$foreign" ] || note "runners outside RunnerSlice, not limited by its slice: $foreign"

    expected_host=$(fabric_value "$config/fabric.conf" host-name)
    host=$(uname -n)
    if [ -z "$expected_host" ]; then
        note "no host-name declared; not checking the hostname"
    elif [ "$host" = "$expected_host" ]; then
        ok "hostname is $expected_host"
    else
        warn "hostname is '$host'; the configuration is for '$expected_host'"
        failed=1
    fi

    if [ "$privilege" = --root ]; then
        local unsafe
        # The whole tool tree, not only fabric/: the command in bin/ and
        # VERSION are read or run as root too.
        unsafe=$(host_unsafe_paths "$config" "$(dirname "$FABRIC_DIR")")
        if [ -n "$unsafe" ]; then
            warn "not owned by root, or writable by others: $unsafe"
            failed=1
        else
            ok "configuration and tool are writable only by root"
        fi
    fi

    local required missing=""
    for required in awk basename cmp dirname find grep id install nproc sed sort stat systemctl "$@"; do
        command -v "$required" >/dev/null 2>&1 || missing="$missing $required"
    done
    if [ -n "$missing" ]; then
        warn "missing required commands:$missing"
        failed=1
    else
        ok "required commands present"
    fi

    if [ "$failed" -eq 1 ]; then
        echo >&2
        echo "refusing to continue: this host does not match the declaration." >&2
        echo "Nothing was modified." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Files and units
# ---------------------------------------------------------------------------

# host_install_file SRC DST [MODE]
#
# Copy SRC to DST only when the bytes differ, so a second run is a no-op and
# the file's timestamp keeps meaning something. Returns 0 when it changed.
host_install_file() {
    local src=$1 dst=$2 mode=${3:-0644}
    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        ok "$dst is current"
        return 1
    fi
    change "install $dst"
    if [ "$CHECK_ONLY" -eq 0 ]; then
        install -D -m "$mode" "$src" "$dst"
    fi
    return 0
}

# host_remove_file PATH REASON   returns 0 when it removed (or would remove)
host_remove_file() {
    local path=$1 reason=$2
    [ -e "$path" ] || { ok "no $path"; return 1; }
    change "remove $path ($reason)"
    [ "$CHECK_ONLY" -eq 0 ] && rm -f "$path"
    return 0
}

# ---------------------------------------------------------------------------
# Accounts and directories
# ---------------------------------------------------------------------------

# host_uid_min   the first uid of an ordinary login account on this host
host_uid_min() {
    local min
    min=$(awk '$1 == "UID_MIN" { print $2 }' "$HOST_ROOT/etc/login.defs" 2>/dev/null)
    [[ "$min" =~ ^[0-9]+$ ]] || min=1000
    echo "$min"
}

# host_account_is_ours NAME
#
# Whether an existing account has the shape RunnerSlice creates: a system
# account whose home is /home/NAME. An ordinary login account of the same name
# belongs to a person, and is never adopted, chowned to or removed.
host_account_is_ours() {
    local name=$1 entry uid home
    entry=$(getent passwd "$name") || return 1
    uid=$(cut -d: -f3 <<<"$entry")
    home=$(cut -d: -f6 <<<"$entry")
    [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -lt "$(host_uid_min)" ] && [ "$uid" -ne 0 ] &&
        [ "$home" = "/home/$name" ]
}

# host_ensure_user NAME
#
# A system account with its own primary group, a real home, and no
# supplementary group at all. The last part is the boundary, not a detail:
# a runner account in the docker group is root on the host by another route.
# So membership is asserted to be empty rather than merely "not sudo".
#
# uid and gid are deliberately not pinned. They are allocation, not
# configuration; every path here is owned by name. Returns 1, having changed
# nothing, when an account of that name exists and is not one RunnerSlice
# would have created.
host_ensure_user() {
    local name=$1 groups
    if getent passwd "$name" >/dev/null && ! host_account_is_ours "$name"; then
        fail "account $name exists and is not a RunnerSlice system account; refusing to adopt it"
        return 1
    fi
    if ! getent passwd "$name" >/dev/null; then
        # A group or home of this name without the account predates it, and
        # belongs to someone else, or to an earlier install that was removed
        # by hand. Neither is adopted: useradd would make it the runner's.
        if getent group "$name" >/dev/null; then
            fail "group $name exists without an account of that name; refusing to adopt it"
            note "  if it is a leftover of an earlier install, remove it by hand: groupdel $name"
            return 1
        fi
        if [ -e "$HOST_ROOT/home/$name" ]; then
            fail "/home/$name exists without an account of that name; refusing to adopt it"
            return 1
        fi
        change "create user $name with its own group (home /home/$name, no supplementary groups)"
        [ "$CHECK_ONLY" -eq 0 ] && useradd --system --user-group \
            --home-dir "/home/$name" --create-home --shell /bin/bash "$name"
    else
        ok "user $name exists"
    fi
    if getent passwd "$name" >/dev/null; then
        # awk rather than `grep -vx`: under pipefail grep returns 1 when it
        # matches nothing, which is the correct state here, and under -e that
        # would end the run on a host that is already right.
        groups=$(id -nG "$name" 2>/dev/null | tr ' ' '\n' |
                 awk -v self="$name" 'NF && $0 != self { printf "%s ", $0 }')
        if [ -n "${groups// /}" ]; then
            fail "$name holds supplementary groups: $groups"
            todo "remove $name from those groups; this tool will not do it"
        else
            ok "$name holds no supplementary group"
        fi
    fi
    return 0
}

# host_remove_user NAME   the account, its home and its private group only
host_remove_user() {
    local name=$1
    if getent passwd "$name" >/dev/null; then
        if ! host_account_is_ours "$name"; then
            fail "account $name is not a RunnerSlice system account; not removing it"
            return 0
        fi
        change "remove user $name, its home and its own group"
        if [ "$CHECK_ONLY" -eq 0 ] && ! userdel --remove "$name"; then
            fail "userdel could not remove $name; nothing else was changed for it"
            return 0
        fi
    else
        ok "user $name is absent"
    fi
    # userdel removes the account's own group with it. A group of that name
    # left behind is not the account's, so it is reported, never deleted.
    if [ "$CHECK_ONLY" -eq 0 ] && getent group "$name" >/dev/null; then
        note "group $name still exists; it was not created with this account, so it is left"
    fi
    return 0
}

# host_owner_mode PATH   "user:group mode", as stat reports them
host_owner_mode() {
    stat -c '%U:%G %a' "$1"
}

# host_mode_eq WANT GOT
#
# Compare two octal modes by value: stat prints 750 where a declaration reads
# 0750. Leading zeros are stripped from both sides rather than padded onto
# one, because `[ 750 -eq 0750 ]` is false: the shell reads 0750 as octal.
host_mode_eq() {
    local a=${1#"${1%%[!0]*}"} b=${2#"${2%%[!0]*}"}
    [ "${a:-0}" = "${b:-0}" ]
}

# host_ensure_dir PATH OWNER GROUP MODE
#
# Creates when absent and corrects owner or mode when they drift. Existing
# content is never touched.
host_ensure_dir() {
    local path=$1 owner=$2 group=$3 mode=$4 cur_own cur_mode
    if [ ! -d "$path" ]; then
        change "create $path ($owner:$group $mode)"
        [ "$CHECK_ONLY" -eq 0 ] && install -d -o "$owner" -g "$group" -m "$mode" "$path"
        return 0
    fi
    read -r cur_own cur_mode <<<"$(host_owner_mode "$path")"
    if [ "$cur_own" = "$owner:$group" ] && host_mode_eq "$mode" "$cur_mode"; then
        ok "$path is $cur_own $cur_mode"
        return 1
    fi
    change "$path is $cur_own $cur_mode, expected $owner:$group $mode"
    if [ "$CHECK_ONLY" -eq 0 ]; then
        chown "$owner:$group" "$path"
        chmod "$mode" "$path"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Runner state
# ---------------------------------------------------------------------------

# host_job_state SERVICE
#
# 0 when a Runner.Worker (a job) is running in the service, 1 when the service
# is known idle, 2 when it cannot be determined safely. Callers treat 2 as
# busy: restarting a runner whose state is unknown is how a job dies mid-step.
#
# The cgroup path comes from systemd, not from the slice name, because a dash
# in a slice name is hierarchy and the path is systemd's to decide.
host_job_state() {
    local service=$1 cg procs pid
    cg=$(systemctl show "$service" -p ControlGroup --value 2>/dev/null) || return 2

    if [ -z "$cg" ]; then
        # No cgroup: the service is not running, so it cannot own a job --
        # unless systemd says it is active, in which case something is wrong.
        if systemctl is-active --quiet "$service" >/dev/null 2>&1; then
            return 2
        fi
        return 1
    fi

    procs="$CGROUP_ROOT$cg/cgroup.procs"
    [ -r "$procs" ] || return 2

    while read -r pid; do
        [ -n "$pid" ] || continue
        # A process may exit between reading cgroup.procs and /proc. One that
        # still exists but cannot be read is unknown, not idle.
        [ -e "$PROC_ROOT/$pid" ] || continue
        [ -r "$PROC_ROOT/$pid/cmdline" ] || return 2
        # A herestring, not a pipeline: under pipefail a producer killed by
        # grep -q exiting early would read as "no worker".
        if grep -q 'Runner\.Worker' <<<"$(tr '\0' ' ' < "$PROC_ROOT/$pid/cmdline")"; then
            return 0
        fi
    done < "$procs"

    return 1
}

# Python run by root on files the runner account can write. It opens without
# following a symlink, refuses anything but a small regular file, and never
# executes what it reads.
HOST_SAFE_JSON_PY='
import json, os, stat, sys

def safe_load(path, limit=4 << 20):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except OSError as e:
        raise ValueError(f"cannot open ({e.strerror})")
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not a regular file")
        if st.st_size > limit:
            raise ValueError("larger than expected")
        data = b""
        while len(data) <= limit:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            data += chunk
        if len(data) > limit:
            raise ValueError("larger than expected")
    finally:
        os.close(fd)
    try:
        return json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("not JSON")
'

# host_runner_version RUNNER_DIR
#
# The runner release installed in RUNNER_DIR, read from the runner's own
# dependency manifest -- data, never executed. Running the runner's binary to
# ask its version would run code the runner account can rewrite, outside the
# service's sandbox and attached to the operator's terminal. Prints the
# version and returns 0, or returns 2 when it cannot be read safely.
host_runner_version() {
    python3 -I -c "$HOST_SAFE_JSON_PY"'
import re
try:
    data = safe_load(sys.argv[1])
    libs = data.get("libraries", {}) if isinstance(data, dict) else {}
    found = [k.split("/", 1)[1] for k in libs if isinstance(k, str) and k.startswith("Runner.Listener/")]
except ValueError:
    sys.exit(2)
if len(found) != 1 or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", found[0]):
    sys.exit(2)
print(found[0])
' "$1/bin/Runner.Listener.deps.json"
}

# host_registration_state RUNNER_DIR REPO NAME WORK_DIR
#
# Whether the runner in RUNNER_DIR is registered as the profile says: to that
# repository, under that name, with that work folder. Reads only .runner,
# which the runner writes at registration and which holds no credential;
# .credentials is never opened. Prints "ok" and returns 0, prints what differs
# and returns 1, or prints why it could not tell and returns 2. What it
# prints from the file is escaped, so it cannot drive the terminal.
host_registration_state() {
    python3 -I -c "$HOST_SAFE_JSON_PY"'
path, repo, name, work = sys.argv[1:5]
try:
    data = safe_load(path, 1 << 20)
except ValueError as e:
    print(f".runner {e}")
    sys.exit(2)
if not isinstance(data, dict):
    print(".runner is not a JSON object")
    sys.exit(2)
problems = []
url = str(data.get("gitHubUrl", "")).rstrip("/")
if url.lower() != f"https://github.com/{repo}".lower():
    problems.append(f"repository is {url!r}")
agent = data.get("agentName")
folder = data.get("workFolder")
if agent != name:
    problems.append(f"name is {agent!r}")
if folder != work:
    problems.append(f"work folder is {folder!r}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("ok")
' "$1/.runner" "$2" "$3" "$4"
}

# ---------------------------------------------------------------------------
# Comparing the host with the declaration
# ---------------------------------------------------------------------------

# host_expect_property UNIT PROPERTY EXPECTED
#
# systemctl show reports the effective value, after every drop-in. Comparing
# against the unit file alone would miss exactly the drift worth finding.
host_expect_property() {
    local unit=$1 prop=$2 expected=$3 actual
    actual=$(systemctl show "$unit" -p "$prop" --value 2>/dev/null) || {
        fail "$unit: cannot read $prop"; return 1; }
    if [ "$actual" = "$expected" ]; then
        ok "$unit $prop=$actual"
    else
        fail "$unit $prop is '$actual', expected '$expected'"
    fi
}

# host_mask_for MOUNTINFO PATH
#
# Prints the mount point of the inaccessible mount that stops PATH being
# opened, and exits 0. Exits 1 when nothing covers it, 2 when MOUNTINFO cannot
# be read. A pure function of its inputs, so the drills exercise it on
# fixtures.
#
# Two things make a literal comparison of mount points wrong:
#
#   aliases     /var/run is a symlink to /run. systemd resolves both
#               declarations to one canonical path and creates one mask, so a
#               name-for-name search finds nothing for the alias.
#   ancestors   masking a directory makes everything beneath it unreachable,
#               whether or not the path has a mask of its own.
host_mask_for() {
    local mi=$1 path=$2 canon
    [ -r "$mi" ] || return 2
    canon=$(readlink -f -- "$HOST_ROOT$path" 2>/dev/null) || canon=""
    canon=${canon#"$HOST_ROOT"}
    # Only the literal path when canonicalisation fails: guessing wider would
    # be the direction that turns a missing mask into a pass.
    # systemd masks a path by bind-mounting one of its inaccessible nodes over
    # it, so the mount's root (field 4) is that node. A mount point that only
    # happens to contain the word is not a mask.
    awk -v a="$path" -v b="${canon:-$path}" '
        index($4, "/systemd/inaccessible/") != 1 { next }
        {
            mp = $5
            if (mp == a || mp == b) { print mp; found = 1; exit }
            if (index(a, mp "/") == 1 || index(b, mp "/") == 1) { print mp; found = 1; exit }
        }
        END { exit !found }
    ' "$mi"
}

# host_home_namespace_state MOUNTINFO OWN_HOME
#
# Proves, from a service's mountinfo, the shape that ProtectHome=tmpfs with
# BindPaths=OWN_HOME produces:
#
#   * /home itself is a tmpfs overmount;
#   * OWN_HOME is mounted directly below that overmount;
#   * OWN_HOME is a bind of the real path, not another tmpfs;
#   * no other /home branch has been bound back in.
#
# Mounts nested beneath OWN_HOME are allowed: a job owns that tree.
#
# Prints "ok" and exits 0, or one stable diagnostic token and exits 1.
# Unreadable mountinfo prints "mountinfo-unreadable" and exits 2.
host_home_namespace_state() {
    local mi=$1 own_home=$2

    if [ ! -r "$mi" ]; then
        printf '%s\n' 'mountinfo-unreadable'
        return 2
    fi

    awk -v own="$own_home" '
        {
            mp = $5
            fs = ""
            for (i = 6; i <= NF; i++) {
                if ($i == "-") { fs = $(i + 1); break }
            }
            if (mp == "/home") { home_seen = 1; home_id = $1; home_fs = fs }
            if (mp == own) { own_seen = 1; own_parent = $2; own_root = $4; own_fs = fs }
            if (index(mp, "/home/") == 1 && mp != own &&
                index(mp, own "/") != 1 && extra == "") {
                extra = mp
            }
        }
        END {
            if (!home_seen)                 { print "home-missing"; exit 1 }
            if (home_fs != "tmpfs")         { print "home-not-tmpfs:" home_fs; exit 1 }
            if (!own_seen)                  { print "own-home-missing"; exit 1 }
            if (own_parent != home_id)      { print "own-home-parent-mismatch"; exit 1 }
            if (own_root != own)            { print "own-home-root-mismatch:" own_root; exit 1 }
            if (own_fs == "" || own_fs == "tmpfs") { print "own-home-not-real:" own_fs; exit 1 }
            if (extra != "")                { print "unexpected-home-mount:" extra; exit 1 }
            print "ok"
            exit 0
        }
    ' "$mi"
}

# host_service_mountinfo UNIT   path of the running service's mountinfo
host_service_mountinfo() {
    local pid
    pid=$(systemctl show "$1" -p MainPID --value 2>/dev/null)
    if [ -z "$pid" ] || [ "$pid" = 0 ]; then
        return 1
    fi
    printf '%s\n' "$PROC_ROOT/$pid/mountinfo"
}

# host_expect_home_namespace UNIT OWN_HOME
host_expect_home_namespace() {
    local unit=$1 own_home=$2 mi state rc
    mi=$(host_service_mountinfo "$unit") || {
        fail "$unit is not running; its home namespace cannot be inspected"
        return 1
    }
    if state=$(host_home_namespace_state "$mi" "$own_home"); then
        ok "$unit exposes only its own home under an empty /home"
        return 0
    else
        rc=$?
    fi
    if [ "$rc" -eq 2 ]; then
        fail "cannot read $mi while checking home isolation"
    else
        fail "$unit home namespace is not default-deny: $state"
    fi
    return 1
}

# host_expect_masked UNIT PATH...
#
# Proves each mask in the service's live mount namespace. A unit that lists a
# path systemd failed to mask reads identically to one that masked it.
host_expect_masked() {
    local unit=$1; shift
    local mi p canon cover rc
    mi=$(host_service_mountinfo "$unit") || {
        fail "$unit is not running; its mount namespace cannot be inspected"
        return 1
    }
    if [ ! -r "$mi" ]; then
        fail "cannot read $mi"
        return 1
    fi
    for p in "$@"; do
        # Absent is not unsafe: there is nothing to open. This mirrors the
        # leading '-' on a mask, which tells systemd to skip a missing path.
        if [ ! -e "$HOST_ROOT$p" ]; then
            ok "absent, nothing to reach: $p"
            continue
        fi
        canon=$(readlink -f -- "$HOST_ROOT$p" 2>/dev/null) || canon=""
        canon=${canon#"$HOST_ROOT"}
        if cover=$(host_mask_for "$mi" "$p"); then
            rc=0
        else
            rc=$?
        fi
        case $rc in
            0)
                if [ "$cover" = "$p" ]; then
                    ok "masked in namespace: $p"
                else
                    ok "masked in namespace: $p (by $cover)"
                fi
                ;;
            2) fail "cannot read $mi while checking $p" ;;
            *) fail "NOT masked in namespace: $p${canon:+ (canonically $canon)}" ;;
        esac
    done
}

# host_expect_no_access USER PATH...
#
# The other half of the boundary. Masks cover a service; file permissions
# cover the account wherever it runs, including a login shell.
host_expect_no_access() {
    local user=$1; shift
    local p verdict
    for p in "$@"; do
        if [ ! -e "$HOST_ROOT$p" ]; then
            ok "absent: $p"
            continue
        fi
        verdict=$(host_access_as "$user" -r "$HOST_ROOT$p")
        case "$verdict" in
            DENIED) ok "$user cannot read $p" ;;
            ALLOWED) fail "$user can read $p ($(host_owner_mode "$HOST_ROOT$p"))" ;;
            *) fail "cannot test whether $user can read $p (${verdict:-no answer})" ;;
        esac
    done
}

# host_access_as USER TEST PATH   ALLOWED or DENIED, as USER sees PATH
#
# Prints exactly ALLOWED or DENIED. Anything else, including runuser failing
# to start the test at all, prints nothing usable, and the caller fails.
host_access_as() {
    # shellcheck disable=SC2016 # expanded by the inner sh, from its arguments
    runuser -u "$1" -- sh -c 'if test "$1" "$2"; then echo ALLOWED; else echo DENIED; fi' \
        sh "$2" "$3" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Exit contracts
# ---------------------------------------------------------------------------

# host_report_apply
#
# --check fails when configuration drifted or an operator action is
# outstanding. A normal run reports what it did, and exits 0 only when
# nothing is left to do.
host_report_apply() {
    step "result"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        if [ "$config_changed" -eq 1 ] || [ "$operator_todo" -eq 1 ] || [ "$check_failed" -eq 1 ]; then
            [ "$config_changed" -eq 1 ] && note "configuration changes are pending"
            [ "$operator_todo" -eq 1 ] && note "operator actions are outstanding"
            [ "$check_failed" -eq 1 ]  && note "conformance failures above"
            exit 1
        fi
        note "host matches the declared configuration"
        exit 0
    fi
    if [ "$config_changed" -eq 1 ]; then
        note "applied"
    else
        note "no change: host already matches the declared configuration"
    fi
    # Exit 0 means converged. A step left to a person, such as registration or
    # a unit waiting for a job, is not converged, and a script or a person
    # reading only the exit code must be able to tell.
    [ "$check_failed" -eq 1 ] && note "conformance failures above"
    [ "$operator_todo" -eq 1 ] && note "operator actions above are still outstanding"
    [ "$check_failed" -eq 0 ] && [ "$operator_todo" -eq 0 ] || exit 1
    exit 0
}

# host_report_check   read-only; anything short of a clean pass exits 1
host_report_check() {
    step "result"
    if [ "$check_failed" -eq 1 ] || [ "$config_changed" -eq 1 ]; then
        [ "$config_changed" -eq 1 ] && note "the host differs from the declared configuration"
        note "check failed"
        exit 1
    fi
    if [ "$operator_todo" -eq 1 ]; then
        note "operator actions are outstanding"
        exit 1
    fi
    note "host matches the declared configuration"
    exit 0
}
