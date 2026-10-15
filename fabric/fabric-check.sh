#!/usr/bin/env bash
#
# Read-only conformance check: does this host run what the inventory declares?
#
#     fabric-check.sh --config DIR --all
#     fabric-check.sh --config DIR --profile ID
#
# Run as root: reading the runtime directories and a service's mount namespace
# needs it. Nothing here writes.
#
# It fails closed. A question it cannot answer counts as a failure, because a
# boundary check that reports healthy when its own probe broke is the failure
# worth preventing.
#
# It checks the host, not GitHub. Whether a runner is online or busy right now
# is fabric-status.sh's question.
set -uo pipefail

FABRIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fabric-lib.sh
. "$FABRIC_DIR/fabric-lib.sh"
# shellcheck source=host-lib.sh
. "$FABRIC_DIR/host-lib.sh"

usage() {
    echo "usage: $(basename "$0") --config DIR (--all | --profile ID)" >&2
    exit 2
}

CONFIG=
MODE=
PROFILE_ID=

while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ -n "${2-}" ] || usage
            CONFIG=$2
            shift 2
            ;;
        --all)
            [ -z "$MODE" ] || usage
            MODE=all
            shift
            ;;
        --profile)
            [ -z "$MODE" ] || usage
            [ -n "${2-}" ] || usage
            MODE=profile
            PROFILE_ID=$2
            [[ "$PROFILE_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
                echo "invalid profile id: $PROFILE_ID" >&2
                exit 2
            }
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

[ -n "$CONFIG" ] || usage
[ -n "$MODE" ] || usage
[ -d "$CONFIG" ] || { echo "no such configuration directory: $CONFIG" >&2; exit 2; }
CONFIG=$(cd "$CONFIG" && pwd)
POLICY="$CONFIG/fabric.conf"

if [ "$MODE" = all ]; then
    fabric_validate_fleet "$CONFIG" || { echo "inventory validation failed" >&2; exit 1; }

    all_failed=0
    profile_count=0
    while IFS= read -r profile; do
        [ -n "$profile" ] || continue
        id=$(fabric_value "$profile" profile-id)
        profile_count=$((profile_count + 1))
        printf '\n============================================================\n'
        printf 'RUNNER PROFILE: %s\n' "$id"
        printf '============================================================\n'
        rc=0
        bash "$FABRIC_DIR/fabric-check.sh" --config "$CONFIG" --profile "$id" || rc=$?
        if [ "$rc" -ne 0 ]; then
            all_failed=1
            printf '\nPROFILE RESULT: %s failed with rc=%s\n' "$id" "$rc"
        fi
    done < <(fabric_profiles "$CONFIG")

    [ "$profile_count" -gt 0 ] || { echo 'no runner profiles in the inventory' >&2; exit 1; }

    step "fleet result"
    if [ "$all_failed" -eq 0 ]; then
        note "all $profile_count runner profiles match the declaration"
        exit 0
    fi
    note "one or more runner profiles failed conformance"
    exit 1
fi

host_preflight "$CONFIG" --root runuser dpkg python3

fabric_validate_fleet "$CONFIG" || { echo "inventory validation failed" >&2; exit 1; }

PROFILE="$CONFIG/profiles/$PROFILE_ID.conf"
[ -r "$PROFILE" ] || { echo "unknown profile: $PROFILE_ID" >&2; exit 1; }

RELEASE="$CONFIG/runner-release.conf"
RUNNER_VERSION=$(fabric_value "$RELEASE" runner-version)
mapfile -t APT_DEPS < <(fabric_values "$RELEASE" apt-dependency)

SLICE=$(fabric_value "$POLICY" slice)
RUNNER_REPO=$(fabric_value "$PROFILE" runner-repo)
RUNNER_NAME=$(fabric_value "$PROFILE" runner-name)
RUNNER_USER=$(fabric_value "$PROFILE" runner-user)
RUNNER_HOME=$(fabric_value "$PROFILE" runner-home)
SERVICE=$(fabric_value "$PROFILE" runner-service)
INSTALL_ROOT=$(fabric_value "$PROFILE" install-root)
RUNNER_DIR=$(fabric_value "$PROFILE" runner-dir)
WORK_DIR=$(fabric_value "$PROFILE" work-dir)
SANDBOX=$(fabric_value "$PROFILE" sandbox-class)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RENDERED_SERVICE="$WORK/$SERVICE"
RENDERED_SLICE="$WORK/$SLICE"
fabric_render_service "$CONFIG" "$PROFILE" > "$RENDERED_SERVICE"
fabric_render_slice "$CONFIG" > "$RENDERED_SLICE"

# Everything the service must not be able to open. Derived from the
# inventory rather than read out of the installed unit: a check that takes its
# expectations from the thing it checks cannot notice that thing being wrong.
MASKED_PATHS=()
while IFS= read -r path; do
    [ -n "$path" ] && MASKED_PATHS+=("${path#-}")
done < <(fabric_expected_masks "$CONFIG" "$PROFILE")

mapfile -t PROTECTED_PATHS < <(fabric_values "$POLICY" protected-path)

# ---------------------------------------------------------------------------
step "installed units are the rendered units"
# ---------------------------------------------------------------------------
for pair in "$SLICE|$RENDERED_SLICE" "$SERVICE|$RENDERED_SERVICE"; do
    unit=${pair%%|*}
    rendered=${pair#*|}
    if [ ! -f "$UNIT_DIR/$unit" ]; then
        fail "$UNIT_DIR/$unit is missing"
    elif cmp -s "$rendered" "$UNIT_DIR/$unit"; then
        ok "$unit matches the rendering"
    else
        change "$unit differs from the rendering"
    fi
done

# A drop-in is a second answer to a question the unit already answers. The
# boundary in particular must not be assembled from two files.
shopt -s nullglob
dropins=("$UNIT_DIR/$SERVICE.d"/*.conf "$UNIT_DIR/$SLICE.d"/*.conf
         "$HOST_ROOT/run/systemd/system/$SERVICE.d"/*.conf
         "$HOST_ROOT/run/systemd/system/$SLICE.d"/*.conf)
shopt -u nullglob
if [ ${#dropins[@]} -eq 0 ]; then
    ok "no drop-ins override the units"
else
    for d in "${dropins[@]}"; do change "unexpected drop-in $d"; done
fi

# ---------------------------------------------------------------------------
step "effective slice limits"
# ---------------------------------------------------------------------------
# The bytes above prove the text is installed. This proves systemd enforces
# it, which differs whenever a missed reload or a runtime property intervenes.
host_expect_property "$SLICE" TasksMax  "$(fabric_value "$POLICY" slice-tasks-max)"
host_expect_property "$SLICE" MemoryMax "$(fabric_size_bytes "$(fabric_value "$POLICY" slice-memory-max)")"
mem_high=$(fabric_value "$POLICY" slice-memory-high)
host_expect_property "$SLICE" MemoryHigh "$(if [ -n "$mem_high" ]; then fabric_size_bytes "$mem_high"; else echo infinity; fi)"
weight=$(fabric_value "$POLICY" slice-cpu-weight)
[ -n "$weight" ] && host_expect_property "$SLICE" CPUWeight "$weight"

# CPUQuota is reported as a per-second duration whose rendering systemd
# chooses ("1.500000s", "1s"). Compared as a number.
quota_pct=$(fabric_value "$POLICY" slice-cpu-quota)
quota_pct=${quota_pct%\%}
quota_actual=$(systemctl show "$SLICE" -p CPUQuotaPerSecUSec --value 2>/dev/null)
quota_secs=$(awk -v v="$quota_actual" 'BEGIN {
    if (v ~ /^[0-9.]+s$/)  { sub(/s$/, "", v);  print v + 0; exit }
    if (v ~ /^[0-9.]+ms$/) { sub(/ms$/, "", v); print v / 1000; exit }
    if (v ~ /^[0-9.]+min$/) { sub(/min$/, "", v); print v * 60; exit }
    exit 1 }') || quota_secs=""
if [ -z "$quota_secs" ]; then
    fail "$SLICE: cannot read CPUQuotaPerSecUSec ('$quota_actual')"
elif awk -v a="$quota_secs" -v p="$quota_pct" 'BEGIN { exit !(a == p / 100) }'; then
    ok "$SLICE CPUQuota=${quota_pct}% ($quota_actual)"
else
    fail "$SLICE CPUQuota is $quota_actual, expected ${quota_pct}%"
fi

# The deny list systemd holds for the slice, which it merges into the filter
# of every unit inside it. This does not prove a kernel filter is attached to
# each running runner; that is a runtime observation for the operator.
# systemd may print a host address with or without /32, so both sides are
# compared without it.
deny_effective=$(systemctl show "$SLICE" -p IPAddressDeny --value 2>/dev/null) || deny_effective="?"
deny_effective=" $(printf '%s' "$deny_effective" | sed 's#/32\( \|$\)#\1#g; s#/128\( \|$\)#\1#g') "
while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    bare=${addr%/32}
    bare=${bare%/128}
    case "$deny_effective" in
        *" $bare "*) ok "$SLICE denies $addr" ;;
        *) fail "$SLICE does not deny $addr (effective:${deny_effective})" ;;
    esac
done < <(fabric_values "$POLICY" slice-ip-deny)

# An allow list is consulted before the deny list, so one on the runner or on
# any slice above it would quietly reopen what the deny closes.
while IFS= read -r unit; do
    host_expect_property "$unit" IPAddressAllow ""
done < <(fabric_slice_ancestors "$SLICE"; printf '%s\n' "$SLICE" "$SERVICE")

# ---------------------------------------------------------------------------
step "account boundary"
# ---------------------------------------------------------------------------
if ! getent passwd "$RUNNER_USER" >/dev/null; then
    fail "user $RUNNER_USER does not exist"
else
    extra=$(id -nG "$RUNNER_USER" | tr ' ' '\n' |
            awk -v self="$RUNNER_USER" 'NF && $0 != self { printf "%s ", $0 }')
    if [ -n "${extra// /}" ]; then
        fail "$RUNNER_USER holds supplementary groups: $extra"
    else
        ok "$RUNNER_USER holds no supplementary group"
    fi
fi

for sock in /run/docker.sock /var/run/docker.sock; do
    [ -e "$HOST_ROOT$sock" ] || continue
    if runuser -u "$RUNNER_USER" -- test -w "$HOST_ROOT$sock" 2>/dev/null; then
        fail "$RUNNER_USER can write $sock"
    else
        ok "$RUNNER_USER cannot use $sock"
    fi
done

# ---------------------------------------------------------------------------
step "filesystem contract"
# ---------------------------------------------------------------------------
expect_dir() {  # PATH OWNER GROUP MODE
    local path=$1 owner=$2 group=$3 mode=$4 cur_own cur_mode
    if [ ! -d "$HOST_ROOT$path" ]; then fail "$path is missing"; return; fi
    read -r cur_own cur_mode <<<"$(host_owner_mode "$HOST_ROOT$path")"
    if [ "$cur_own" = "$owner:$group" ] && host_mode_eq "$mode" "$cur_mode"; then
        ok "$path is $cur_own $cur_mode"
    else
        change "$path is $cur_own $cur_mode, expected $owner:$group $mode"
    fi
}
expect_dir "$INSTALL_ROOT" root           "$RUNNER_USER" 0750
expect_dir "$RUNNER_DIR"   "$RUNNER_USER" "$RUNNER_USER" 0750
expect_dir "$WORK_DIR"     "$RUNNER_USER" "$RUNNER_USER" 0750

# ---------------------------------------------------------------------------
step "runner release"
# ---------------------------------------------------------------------------
for dep in "${APT_DEPS[@]}"; do
    if dpkg -s "$dep" >/dev/null 2>&1; then ok "$dep installed"; else fail "$dep missing"; fi
done

listener="$HOST_ROOT$RUNNER_DIR/bin/Runner.Listener"
if [ ! -x "$listener" ]; then
    fail "$RUNNER_DIR/bin/Runner.Listener is missing"
else
    got=$(runuser -u "$RUNNER_USER" -- "$listener" --version 2>/dev/null | tr -d '\r' | head -1)
    if [ -z "$got" ]; then
        fail "cannot determine the installed runner version"
    elif [ "$(printf '%s\n%s\n' "$RUNNER_VERSION" "$got" | sort -V | head -1)" = "$RUNNER_VERSION" ]; then
        # Above the seed is the expected steady state: runners update
        # themselves. Below it means that is not happening.
        ok "runner version $got, at or above the seed $RUNNER_VERSION"
    else
        fail "runner version is $got, below the seed $RUNNER_VERSION; self-update is not working"
    fi
fi

# Presence, owner and mode only. These are the runner's credentials with
# GitHub; nothing here opens them.
for f in .runner .credentials; do
    if [ -f "$HOST_ROOT$RUNNER_DIR/$f" ]; then
        m=$(host_owner_mode "$HOST_ROOT$RUNNER_DIR/$f")
        case "$m" in
            "$RUNNER_USER:$RUNNER_USER 600") ok "$f present, $m" ;;
            *) fail "$f is $m, expected $RUNNER_USER:$RUNNER_USER 600" ;;
        esac
    else
        fail "$f is missing; the runner is not registered"
    fi
done

# Registered, but as what: the repository, name and work folder the runner
# recorded must be the profile's. .credentials is not opened.
if [ -f "$HOST_ROOT$RUNNER_DIR/.runner" ]; then
    reg_rc=0
    reg_state=$(host_registration_state "$HOST_ROOT$RUNNER_DIR" "$RUNNER_REPO" "$RUNNER_NAME" "$WORK_DIR") || reg_rc=$?
    case "$reg_rc" in
        0) ok "registered as $RUNNER_NAME for $RUNNER_REPO, working in $WORK_DIR" ;;
        1) fail "the registration does not match the profile: $reg_state" ;;
        *) fail "cannot read the registration: $reg_state" ;;
    esac
fi

# ---------------------------------------------------------------------------
step "service"
# ---------------------------------------------------------------------------
host_expect_property "$SERVICE" UnitFileState      enabled
host_expect_property "$SERVICE" ActiveState        active
host_expect_property "$SERVICE" User               "$RUNNER_USER"
host_expect_property "$SERVICE" Slice              "$SLICE"
host_expect_property "$SERVICE" NoNewPrivileges    yes
host_expect_property "$SERVICE" PrivateTmp         yes
host_expect_property "$SERVICE" ProtectSystem      full
host_expect_property "$SERVICE" ProtectHome        tmpfs
host_expect_property "$SERVICE" SupplementaryGroups ""
# systemd prints the namespaces a unit may still create; an empty list is
# RestrictNamespaces=yes.
case "$SANDBOX" in
    baseline) host_expect_property "$SERVICE" RestrictNamespaces "" ;;
esac

# ---------------------------------------------------------------------------
step "boundary in the live mount namespace"
# ---------------------------------------------------------------------------
host_expect_masked "$SERVICE" "${MASKED_PATHS[@]}"
host_expect_home_namespace "$SERVICE" "$RUNNER_HOME"

# ---------------------------------------------------------------------------
step "boundary in file permissions"
# ---------------------------------------------------------------------------
if [ "${#PROTECTED_PATHS[@]}" -eq 0 ]; then
    note "no protected-path declared"
else
    host_expect_no_access "$RUNNER_USER" "${PROTECTED_PATHS[@]}"
fi

host_report_check
