#!/usr/bin/env bash
#
# Converge this host's runners toward a declared inventory.
#
#     fabric-apply.sh --config DIR --all [--check]           the whole fleet
#     fabric-apply.sh --config DIR --profile ID [--check]    one runner
#     fabric-apply.sh --config DIR --retire ID [--check]     take a runner out
#
# --check reports what would change and changes nothing. Run as root.
#
# What this owns: each profile's Unix account and runtime directories, the
# release seed, the slice and the generated service units. What it does not
# own is registration. Registering a runner needs a token that lives for an
# hour; it is never fetched here, never written to disk and never stored in
# the inventory. The exact command is printed for a person to run instead.
#
# Idempotent. A second run downloads nothing, rewrites nothing and restarts
# nothing. It never restarts a runner while a job is in flight, or while it
# cannot tell whether one is: it reports that as an outstanding action.
#
# Exit codes: 0 converged, with nothing left to do (under --check: nothing
# would change); 1 failure, refusal, a step left to a person such as
# registration, or a pending change; 2 usage; 10 waiting for registration (for
# fleet children) or for deregistration (for --retire).
set -euo pipefail

# Temporary files of a root run go where root decides, not where an inherited
# TMPDIR points: a directory another account can write would let it swap a
# rendered unit before it is installed.
unset TMPDIR

FABRIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=fabric-lib.sh
. "$FABRIC_DIR/fabric-lib.sh"
# shellcheck source=host-lib.sh
. "$FABRIC_DIR/host-lib.sh"

usage() {
    echo "usage: $(basename "$0") --config DIR (--all | --profile ID | --retire ID) [--check]" >&2
    exit 2
}

CONFIG=
MODE=
PROFILE_ID=
FLEET_CHILD=0

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
        --profile|--retire)
            [ -z "$MODE" ] || usage
            [ -n "${2-}" ] || usage
            MODE=${1#--}
            PROFILE_ID=$2
            [[ "$PROFILE_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
                echo "invalid profile id: $PROFILE_ID" >&2
                exit 2
            }
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --fleet-child)
            # Internal: set by --all for each child. It only adds guards.
            FLEET_CHILD=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done

[ -n "$CONFIG" ] || usage
[ -n "$MODE" ] || usage
[ -d "$CONFIG" ] || { echo "no such configuration directory: $CONFIG" >&2; exit 2; }
CONFIG=$(cd "$CONFIG" && pwd -P)

POLICY="$CONFIG/fabric.conf"

host_preflight "$CONFIG" --root curl tar sha256sum getent runuser python3

fabric_validate_fleet "$CONFIG" || {
    echo "inventory validation failed" >&2
    exit 1
}

SLICE=$(fabric_value "$POLICY" slice)
NAME_PREFIX=$(fabric_value "$POLICY" name-prefix)

# Runner units installed on this host that no profile renders. A runner that
# leaves the inventory before it is retired is still installed, may still be
# registered and may still be running a job, and nothing would look at it
# again. So the fleet refuses to apply while one exists.
fabric_orphan_units() {
    local unit known
    known=$(
        while IFS= read -r profile; do
            fabric_value "$profile" runner-service
        done < <(fabric_profiles "$CONFIG")
    )
    for unit in "$UNIT_DIR/$NAME_PREFIX-runner.service" \
                "$UNIT_DIR/$NAME_PREFIX"-*-runner.service; do
        fabric_unit_is_ours "$unit" || continue
        grep -Fxq -- "$(basename "$unit")" <<<"$known" || basename "$unit"
    done
}

# The runtime root carries a root-owned marker naming its profile, written
# when RunnerSlice creates the root. A directory of that name without it
# belongs to something else -- /var/lib/docker, say, under name-prefix docker
# -- and is neither adopted nor removed.
install_root_is_ours() {
    [ -f "$FS_INSTALL_ROOT/.runner-slice-root" ] && [ ! -L "$FS_INSTALL_ROOT/.runner-slice-root" ] &&
        [ "$(cat "$FS_INSTALL_ROOT/.runner-slice-root")" = "$PROFILE_ID" ]
}

# refuse_if_busy SERVICE WHAT   exits when a job is, or may be, in flight
refuse_if_busy() {
    local rc=0
    host_job_state "$1" || rc=$?
    case "$rc" in
        0) echo "$2 refused: $1 has a job in flight" >&2; exit 1 ;;
        2) echo "$2 refused: cannot tell whether $1 is running a job" >&2; exit 1 ;;
    esac
}

if [ "$MODE" = all ]; then
    orphans=$(fabric_orphan_units | paste -sd' ' -)
    if [ -n "$orphans" ]; then
        echo "fleet refused: installed runner unit(s) not in this inventory: $orphans" >&2
        echo "retire each with --retire from the inventory that still names it, then apply this one" >&2
        exit 1
    fi

    mapfile -t PROFILES < <(fabric_profiles "$CONFIG")
    [ "${#PROFILES[@]}" -gt 0 ] || { echo 'no runner profiles in the inventory' >&2; exit 1; }

    child_args=(--config "$CONFIG")
    [ "$CHECK_ONLY" -eq 1 ] && child_args+=(--check)

    if [ "$CHECK_ONLY" -eq 0 ]; then
        # Fail closed before the first child can change anything. A registered
        # runner whose job state cannot be read is not assumed idle.
        for profile in "${PROFILES[@]}"; do
            [ -f "$HOST_ROOT$(fabric_value "$profile" runner-dir)/.runner" ] || continue
            refuse_if_busy "$(fabric_value "$profile" runner-service)" "fleet apply"
        done
        child_args+=(--fleet-child)
    fi

    failed=0
    needs_registration=()

    # Sequential. A child that stops at the registration boundary does not
    # block later profiles; any harder failure stops the fleet where it is.
    for profile in "${PROFILES[@]}"; do
        id=$(fabric_value "$profile" profile-id)
        printf '\n============================================================\n'
        printf 'RUNNER PROFILE: %s\n' "$id"
        printf '============================================================\n'

        rc=0
        bash "$FABRIC_DIR/fabric-apply.sh" "${child_args[@]}" --profile "$id" || rc=$?
        [ "$rc" -eq 0 ] && continue

        if [ "$CHECK_ONLY" -eq 1 ]; then
            printf '\nPROFILE RESULT: %s differs (rc=%s)\n' "$id" "$rc"
            failed=1
        elif [ "$rc" -eq 10 ]; then
            printf '\nPROFILE RESULT: %s requires registration\n' "$id"
            needs_registration+=("$id")
        else
            printf '\nPROFILE RESULT: %s failed with rc=%s\n' "$id" "$rc"
            step "fleet result"
            note "fleet apply stopped at $id"
            exit "$rc"
        fi
    done

    step "fleet result"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        if [ "$failed" -eq 0 ]; then
            note "all ${#PROFILES[@]} runner profiles match the declaration"
            exit 0
        fi
        note "one or more runner profiles require convergence"
        exit 1
    fi
    if [ "${#needs_registration[@]}" -gt 0 ]; then
        note "registration is required for: ${needs_registration[*]}"
        note "register those runners, then run --all again"
        exit 1
    fi
    note "all ${#PROFILES[@]} runner profiles converged"
    exit 0
fi

PROFILE="$CONFIG/profiles/$PROFILE_ID.conf"
[ -r "$PROFILE" ] || { echo "unknown profile: $PROFILE_ID" >&2; exit 1; }

RELEASE="$CONFIG/runner-release.conf"
RUNNER_VERSION=$(fabric_value "$RELEASE" runner-version)
RUNNER_ARCHIVE=$(fabric_value "$RELEASE" runner-archive)
RUNNER_SHA=$(fabric_value "$RELEASE" runner-sha256)
RUNNER_URL=$(fabric_value "$RELEASE" runner-url)
mapfile -t APT_DEPS < <(fabric_values "$RELEASE" apt-dependency)

RUNNER_REPO=$(fabric_value "$PROFILE" runner-repo)
RUNNER_NAME=$(fabric_value "$PROFILE" runner-name)
RUNNER_USER=$(fabric_value "$PROFILE" runner-user)
RUNNER_HOME=$(fabric_value "$PROFILE" runner-home)
SERVICE=$(fabric_value "$PROFILE" runner-service)
INSTALL_ROOT=$(fabric_value "$PROFILE" install-root)
RUNNER_DIR=$(fabric_value "$PROFILE" runner-dir)
WORK_DIR=$(fabric_value "$PROFILE" work-dir)
LABELS=$(fabric_values "$PROFILE" runner-label | paste -sd, -)

# Where those paths are on this host. Identical to the declared paths except
# in the drills, which run against a fixture root.
FS_INSTALL_ROOT="$HOST_ROOT$INSTALL_ROOT"
FS_RUNNER_DIR="$HOST_ROOT$RUNNER_DIR"
FS_WORK_DIR="$HOST_ROOT$WORK_DIR"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RENDERED_SERVICE="$WORK/$SERVICE"
RENDERED_SLICE="$WORK/$SLICE"
fabric_render_service "$CONFIG" "$PROFILE" > "$RENDERED_SERVICE"
fabric_render_slice "$CONFIG" > "$RENDERED_SLICE"

slice_changed=0
units_changed=0
registration_required=0

# ---------------------------------------------------------------------------
# Retiring a runner
# ---------------------------------------------------------------------------
# Run while the inventory still names the member, so every tool still sees
# it. Each step happens only once the one before it is true, and a re-run
# resumes:
#
#   1. no job in flight            refused otherwise; drain it on GitHub first
#   2. stopped and disabled        so it takes no new job
#   3. deregistered                by a person, with a token; this stops here
#                                  until the registration files are gone
#   4. unit, runtime root, account removed
#
# Any runner can be retired, a pool member or not. Afterwards its profile is
# deleted from the inventory and the remaining runners applied, which drops
# the mask for its runtime root from their units.
if [ "$MODE" = retire ]; then
    step "retire $PROFILE_ID: no job in flight"
    job_rc=0
    host_job_state "$SERVICE" || job_rc=$?
    case "$job_rc" in
        0)
            fail "$PROFILE_ID has a job in flight; nothing was changed"
            note "  drain it first: with its custom labels removed, GitHub sends it nothing new"
            note "  RID=\$(gh api /repos/$RUNNER_REPO/actions/runners --jq '.runners[] | select(.name==\"$RUNNER_NAME\") | .id')"
            note "  gh api -X DELETE /repos/$RUNNER_REPO/actions/runners/\$RID/labels"
            note "  then wait for the job to finish, and run --retire $PROFILE_ID again"
            host_report_apply
            ;;
        2)
            fail "cannot tell whether $PROFILE_ID is running a job; nothing was changed"
            host_report_apply
            ;;
    esac
    ok "$PROFILE_ID has no job in flight"

    step "retire $PROFILE_ID: stop taking jobs"
    if [ "$(systemctl is-enabled "$SERVICE" 2>/dev/null)" = enabled ] ||
       systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
        change "stop and disable $SERVICE"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            # A job can be assigned between the check above and here.
            job_rc=0
            host_job_state "$SERVICE" || job_rc=$?
            if [ "$job_rc" -ne 1 ]; then
                fail "$PROFILE_ID took a job just now, or its state is unknown; not stopping it"
                host_report_apply
            fi
            systemctl disable --now "$SERVICE"
        fi
    else
        ok "$SERVICE is stopped and disabled"
    fi

    step "retire $PROFILE_ID: deregistration"
    if [ -f "$FS_RUNNER_DIR/.runner" ] || [ -f "$FS_RUNNER_DIR/.credentials" ]; then
        todo "deregister $RUNNER_NAME from $RUNNER_REPO, as a person; the files here are its credentials:"
        note ""
        note "  export ACTIONS_RUNNER_INPUT_TOKEN=\"\$(gh api -X POST /repos/$RUNNER_REPO/actions/runners/remove-token --jq .token)\""
        note "  sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u $RUNNER_USER -H \\"
        note "      env HOME=$RUNNER_HOME $RUNNER_DIR/config.sh remove --unattended"
        note "  unset ACTIONS_RUNNER_INPUT_TOKEN"
        note ""
        note "  if GitHub cannot be reached from here, delete the runner on GitHub instead and then"
        note "  sudo rm -f $RUNNER_DIR/.runner $RUNNER_DIR/.credentials $RUNNER_DIR/.credentials_rsaparams"
        note ""
        note "then run --retire $PROFILE_ID again; nothing further is removed until then"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            step "result"
            note "deregistration is still required"
            exit 10
        fi
    else
        ok "$PROFILE_ID holds no registration"
    fi

    step "retire $PROFILE_ID: remove what the inventory installed"
    if [ -f "$FS_RUNNER_DIR/.runner" ] || [ -f "$FS_RUNNER_DIR/.credentials" ]; then
        note "left in place until deregistration is done"
    else
        # Everything is checked before anything is removed: a retirement that
        # stops half-way must not have taken some things and left others.
        removable=1
        if [ -e "$UNIT_DIR/$SERVICE" ] && ! fabric_unit_is_ours "$UNIT_DIR/$SERVICE"; then
            fail "refusing to remove $UNIT_DIR/$SERVICE: it was not written by RunnerSlice"
            removable=0
        fi
        # Validation already proved the root is /var/lib/<prefix>[-<id>] and
        # unique in the fleet; the marker proves RunnerSlice created it.
        root_ok=1
        case "$INSTALL_ROOT" in /var/lib/"$NAME_PREFIX"|/var/lib/"$NAME_PREFIX"-?*) ;; *) root_ok=0 ;; esac
        while IFS= read -r peer; do
            [ "$peer" = "$PROFILE" ] && continue
            [ "$(fabric_value "$peer" install-root)" = "$INSTALL_ROOT" ] && root_ok=0
        done < <(fabric_profiles "$CONFIG")
        if [ -e "$FS_INSTALL_ROOT" ] && ! install_root_is_ours; then
            root_ok=0
        fi
        if [ "$root_ok" -ne 1 ]; then
            fail "refusing to remove $INSTALL_ROOT: it is not a runtime root RunnerSlice created for this runner"
            removable=0
        fi
        if getent passwd "$RUNNER_USER" >/dev/null && ! host_account_is_ours "$RUNNER_USER"; then
            fail "account $RUNNER_USER is not a RunnerSlice system account; not removing it"
            removable=0
        fi
        # A job's leftover process (KillMode=process lets one outlive the
        # service) would keep files open and make the account removal fail.
        if leftover=$(pgrep -u "$RUNNER_USER" 2>/dev/null | paste -sd' ' -) && [ -n "$leftover" ]; then
            fail "processes of $RUNNER_USER are still running ($leftover)"
            note "  stop them, then run --retire $PROFILE_ID again"
            removable=0
        fi
        if [ "$removable" -ne 1 ]; then
            note "nothing was removed"
            host_report_apply
        fi

        if host_remove_file "$UNIT_DIR/$SERVICE" "retired runner" && [ "$CHECK_ONLY" -eq 0 ]; then
            systemctl daemon-reload
        fi
        if [ -e "$FS_INSTALL_ROOT" ]; then
            change "remove $INSTALL_ROOT"
            [ "$CHECK_ONLY" -eq 0 ] && rm -rf --one-file-system -- "$FS_INSTALL_ROOT"
        else
            ok "$INSTALL_ROOT is absent"
        fi
        host_remove_user "$RUNNER_USER"
        note "retired. Now delete profiles/$PROFILE_ID.conf and run --all with the other"
        note "runners idle: their units drop the mask for $INSTALL_ROOT."
    fi

    host_report_apply
fi

registration_preexisting_todo=0
late_job_todo=0

# A fleet child checks again once it has resolved its own profile, so a job
# that started after the fleet-wide check still wins.
if [ "$FLEET_CHILD" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ] &&
   [ -f "$FS_RUNNER_DIR/.runner" ]; then
    refuse_if_busy "$SERVICE" "fleet child"
fi

# ---------------------------------------------------------------------------
step "ownership"
# ---------------------------------------------------------------------------
# A unit of the same name that RunnerSlice did not write is someone else's
# service. Nothing for this profile is created next to it.
for unit in "$SLICE" "$SERVICE"; do
    if [ -e "$UNIT_DIR/$unit" ] && ! fabric_unit_is_ours "$UNIT_DIR/$unit"; then
        fail "$UNIT_DIR/$unit exists and was not written by RunnerSlice; rename the profile or remove it by hand"
    else
        ok "$unit is RunnerSlice's or absent"
    fi
done
# Likewise a runtime root RunnerSlice did not create.
if [ -e "$FS_INSTALL_ROOT" ] && ! install_root_is_ours; then
    fail "$INSTALL_ROOT exists and was not created by RunnerSlice for $PROFILE_ID; refusing to adopt it"
else
    ok "$INSTALL_ROOT is RunnerSlice's or absent"
fi
[ "$check_failed" -eq 0 ] || host_report_apply

# ---------------------------------------------------------------------------
step "account"
# ---------------------------------------------------------------------------
host_ensure_user "$RUNNER_USER" || host_report_apply

# ---------------------------------------------------------------------------
step "directories"
# ---------------------------------------------------------------------------
# root owns the runtime root so the runner account cannot replace the tree
# its service starts from; the account owns only what the runner writes.
if host_ensure_dir "$FS_INSTALL_ROOT" root "$RUNNER_USER" 0750 &&
   [ "$CHECK_ONLY" -eq 0 ] && [ ! -e "$FS_INSTALL_ROOT/.runner-slice-root" ]; then
    printf '%s\n' "$PROFILE_ID" > "$FS_INSTALL_ROOT/.runner-slice-root"
fi
host_ensure_dir "$FS_RUNNER_DIR"   "$RUNNER_USER" "$RUNNER_USER" 0750 || true
host_ensure_dir "$FS_WORK_DIR"     "$RUNNER_USER" "$RUNNER_USER" 0750 || true

# ---------------------------------------------------------------------------
step "runner dependencies"
# ---------------------------------------------------------------------------
# Only the packages the release file names; no upgrade, no dist-upgrade.
if [ "${#APT_DEPS[@]}" -eq 0 ]; then
    ok "the release declares no package dependencies"
fi
for dep in "${APT_DEPS[@]}"; do
    if dpkg -s "$dep" >/dev/null 2>&1; then
        ok "$dep installed"
    else
        change "install $dep"
        if [ "$CHECK_ONLY" -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$dep"
        fi
    fi
done

# ---------------------------------------------------------------------------
step "runner release $RUNNER_VERSION"
# ---------------------------------------------------------------------------
# The archive is trusted by digest, not by URL. A re-tagged release, a proxy
# or a truncated download all fail the same way here.
#
# The release file is a seed and a floor, not a version this holds the host
# at. A registered runner updates itself, and GitHub eventually refuses
# releases that are too old, so freezing the version would trade a benign
# drift report for an outage.
# The seed marker is written, root-owned, only after a complete unpack. An
# unpack interrupted part-way leaves no marker and is redone rather than
# mistaken for a runner.
#
# A registered runner is never unpacked into again. Its directory holds what
# its jobs wrote; root extracting and chowning there would act inside a tree
# a job controls, through any link a job left. A first unpack goes into a
# directory root has just created, empty and closed to the runner account.
SEED_MARKER="$FS_INSTALL_ROOT/.runner-slice-seeded"
registered=0
{ [ -f "$FS_RUNNER_DIR/.runner" ] || [ -f "$FS_RUNNER_DIR/.credentials" ]; } && registered=1

if [ "$registered" -eq 1 ] && [ ! -f "$FS_RUNNER_DIR/config.sh" ]; then
    todo "$PROFILE_ID is registered but its release is incomplete; it is not unpacked over"
    note "  re-seed it by hand with no job in flight, or retire it and apply again"
elif [ "$registered" -eq 1 ] || [ -f "$SEED_MARKER" ]; then
    installed=""
    installed=$(host_runner_version "$FS_RUNNER_DIR") || installed=""
    if [ -z "$installed" ]; then
        ok "runner release unpacked in $RUNNER_DIR (its version could not be read)"
    elif [ "$(printf '%s\n%s\n' "$RUNNER_VERSION" "$installed" | sort -V | head -1)" = "$RUNNER_VERSION" ]; then
        ok "runner $installed installed, at or above the seed $RUNNER_VERSION"
    else
        # Below the seed means self-update is not working. Re-seeding a
        # registered runner is a person's decision, not something to do
        # underneath a job that may be running.
        todo "runner is $installed, below the seed $RUNNER_VERSION"
        note "  self-update appears not to be working; re-seed deliberately, with no job in flight:"
        note "    sudo systemctl stop $SERVICE"
        note "    sudo -u $RUNNER_USER tar -xzf <verified $RUNNER_ARCHIVE> -C $RUNNER_DIR"
        note "    sudo systemctl start $SERVICE"
        note "  .runner and .credentials survive an unpack, so this does not re-register"
    fi
else
    if [ -e "$FS_RUNNER_DIR/config.sh" ]; then
        change "complete an interrupted unpack of $RUNNER_ARCHIVE into $RUNNER_DIR"
    else
        change "download and unpack $RUNNER_ARCHIVE into $RUNNER_DIR"
    fi
    if [ "$CHECK_ONLY" -eq 0 ]; then
        mkdir -m 0700 "$WORK/release"
        curl -fsSL --retry 5 --retry-delay 5 -o "$WORK/release/$RUNNER_ARCHIVE" "$RUNNER_URL"
        echo "$RUNNER_SHA  $WORK/release/$RUNNER_ARCHIVE" | sha256sum -c - >/dev/null \
            || { echo "runner archive digest mismatch; refusing to unpack" >&2; exit 1; }
        note "archive digest verified"
        # Unregistered, so nothing here is the runner's yet: start from an
        # empty directory only root can enter, then hand it over.
        rm -rf --one-file-system -- "$FS_RUNNER_DIR"
        mkdir -m 0700 "$FS_RUNNER_DIR"
        tar -xzf "$WORK/release/$RUNNER_ARCHIVE" -C "$FS_RUNNER_DIR" --no-same-owner
        chown -R "$RUNNER_USER:$RUNNER_USER" "$FS_RUNNER_DIR"
        chmod 0750 "$FS_RUNNER_DIR"
        printf '%s %s\n' "$RUNNER_VERSION" "$RUNNER_SHA" > "$SEED_MARKER"
        rm -rf "$WORK/release"
    fi
fi

# ---------------------------------------------------------------------------
step "registration"
# ---------------------------------------------------------------------------
# .runner and .credentials are the runner's identity with GitHub, created on
# this host by the runner itself. This tool creates neither. It reads .runner,
# which names the repository, runner and work folder, to refuse to start a
# runner registered as something the profile does not say. .credentials is
# never opened.
registration_preexisting_todo=$operator_todo
registration_wrong=0

if [ -f "$FS_RUNNER_DIR/.runner" ]; then
    reg_rc=0
    reg_state=$(host_registration_state "$FS_RUNNER_DIR" "$RUNNER_REPO" "$RUNNER_NAME" "$WORK_DIR") || reg_rc=$?
    case "$reg_rc" in
        0) ok "registered as $RUNNER_NAME for $RUNNER_REPO" ;;
        1) registration_wrong=1
           fail "the registration does not match the profile: $reg_state"
           note "  deregister it and register again with the command this prints for an unregistered runner" ;;
        *) registration_wrong=1
           fail "cannot read the registration: $reg_state" ;;
    esac
else
    registration_required=1
    todo "register the runner, as a person, with a token that expires in an hour:"
    note ""
    note "  export ACTIONS_RUNNER_INPUT_TOKEN=\"\$(gh api -X POST /repos/$RUNNER_REPO/actions/runners/registration-token --jq .token)\""
    note "  sudo --preserve-env=ACTIONS_RUNNER_INPUT_TOKEN -u $RUNNER_USER -H \\"
    note "      env HOME=$RUNNER_HOME $RUNNER_DIR/config.sh \\"
    note "      --url https://github.com/$RUNNER_REPO \\"
    note "      --name $RUNNER_NAME --labels $LABELS \\"
    note "      --work $WORK_DIR --unattended --replace"
    note "  unset ACTIONS_RUNNER_INPUT_TOKEN"
    note "  sudo chmod 600 $RUNNER_DIR/.runner $RUNNER_DIR/.credentials $RUNNER_DIR/.credentials_rsaparams"
    note ""
    note "  the token travels in the environment, which only root and the runner account"
    note "  can read, never on a command line that sudo logs and ps shows"
    note ""
    note "then run this again to install and start the service"
fi

# A job can start after the entry guard. Check again immediately before
# replacing a unit, so a running job never has its contract replaced under it.
if [ "$FLEET_CHILD" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ] &&
   [ -f "$FS_RUNNER_DIR/.runner" ]; then
    refuse_if_busy "$SERVICE" "fleet child, before installing units,"
fi

# ---------------------------------------------------------------------------
step "systemd units"
# ---------------------------------------------------------------------------
# A changed slice takes effect on reload, for every runner in it, without a
# restart. Only a runner whose own unit changed is restarted.
host_install_file "$RENDERED_SLICE" "$UNIT_DIR/$SLICE" 0644 && slice_changed=1

# A changed unit is not installed under a job. Installing it and deferring
# only the restart would lose the restart: the next run would find the unit
# current. Left uninstalled, the difference itself is the pending work, and
# the next run with the runner idle installs and restarts.
defer_service=0
if [ -f "$FS_RUNNER_DIR/.runner" ] &&
   ! cmp -s "$RENDERED_SERVICE" "$UNIT_DIR/$SERVICE" 2>/dev/null; then
    job_rc=0
    host_job_state "$SERVICE" || job_rc=$?
    case "$job_rc" in
        0)
            defer_service=1
            late_job_todo=1
            todo "$SERVICE has a new unit, but a job is running; it waits until the job ends"
            note "  run this again once the job finishes"
            ;;
        2)
            defer_service=1
            fail "cannot tell whether $SERVICE is running a job; its new unit waits"
            ;;
    esac
fi
if [ "$defer_service" -eq 0 ]; then
    host_install_file "$RENDERED_SERVICE" "$UNIT_DIR/$SERVICE" 0644 && units_changed=1
fi

if [ "$slice_changed$units_changed" != 00 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    systemctl daemon-reload
    note "systemd reloaded"
fi

# ---------------------------------------------------------------------------
step "service"
# ---------------------------------------------------------------------------
if [ ! -f "$FS_RUNNER_DIR/.runner" ]; then
    note "not registered: unit installed, service left alone"
elif [ "$registration_wrong" -eq 1 ]; then
    note "registration does not match: service left as it is"
elif [ "$(systemctl is-enabled "$SERVICE" 2>/dev/null)" != enabled ]; then
    change "enable and start $SERVICE"
    [ "$CHECK_ONLY" -eq 0 ] && systemctl enable --now "$SERVICE"
elif [ "$defer_service" -eq 1 ]; then
    note "$SERVICE keeps running its current unit"
elif [ "$units_changed" -eq 1 ]; then
    # Checked again: a job can start between the install and here. If one
    # did, the unit is already installed, so a later run will not see a
    # difference; the operator has to restart it.
    job_rc=0
    [ "$CHECK_ONLY" -eq 1 ] || host_job_state "$SERVICE" || job_rc=$?
    case "$job_rc" in
        0)
            late_job_todo=1
            todo "a job started on $SERVICE while its unit was replaced; restart it once the job finishes:"
            note "  systemctl restart $SERVICE"
            ;;
        2)
            fail "cannot tell whether $SERVICE is running a job; restart it by hand once idle"
            ;;
        *)
            change "restart $SERVICE to apply the new unit"
            [ "$CHECK_ONLY" -eq 0 ] && systemctl restart "$SERVICE"
            ;;
    esac
else
    ok "$SERVICE is enabled and its unit is current"
fi

if [ "$FLEET_CHILD" -eq 1 ] && [ "$CHECK_ONLY" -eq 0 ]; then
    if [ "$registration_required" -eq 1 ] &&
       [ "$registration_preexisting_todo" -eq 0 ] &&
       [ "$late_job_todo" -eq 0 ] &&
       [ "$check_failed" -eq 0 ]; then
        step "result"
        [ "$config_changed" -eq 1 ] && note "applied"
        note "runner registration is still required"
        exit 10
    fi
    if [ "$operator_todo" -eq 1 ]; then
        step "result"
        [ "$config_changed" -eq 1 ] && note "applied"
        note "operator actions above are still outstanding"
        [ "$check_failed" -eq 1 ] && note "conformance failures above"
        exit 1
    fi
fi

host_report_apply
