#!/usr/bin/env bash
#
# Operational status: is each runner online on GitHub, and running here?
#
#     fabric-status.sh --config DIR --all
#     fabric-status.sh --config DIR --profile ID
#
# Separate from fabric-check.sh on purpose:
#
#   check    declared state and boundaries, read from this host
#   status   transient state: the local service, and GitHub's view of it
#
# A busy runner is normal and does not fail. An offline runner, a service that
# is not running, an ambiguous GitHub identity, an API failure or unreadable
# local state fails closed. Needs an authenticated `gh` and no privilege; it
# refuses to run as root.
set -euo pipefail

FABRIC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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
CONFIG=$(cd "$CONFIG" && pwd -P)

host_preflight "$CONFIG" --user gh python3 mktemp

fabric_validate_fleet "$CONFIG" || { echo "inventory validation failed" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

status_failed=0
profile_count=0

status_profile() {
    local profile=$1
    local id repo name service json err remote
    local runner_id remote_status busy remote_os
    local load enabled active sub pid

    id=$(fabric_value "$profile" profile-id)
    repo=$(fabric_value "$profile" runner-repo)
    name=$(fabric_value "$profile" runner-name)
    service=$(fabric_value "$profile" runner-service)
    profile_count=$((profile_count + 1))

    json="$TMP/$id.json"
    err="$TMP/$id.err"

    printf '\n== %s\n' "$id"

    if ! gh api -H 'Accept: application/vnd.github+json' \
        "/repos/$repo/actions/runners?per_page=100" >"$json" 2>"$err"; then
        printf '  github   ERROR query failed for %s\n' "$repo"
        sed 's/^/           /' "$err" >&2
        status_failed=1
        return
    fi

    # Exactly one runner of this name, with a status and busy flag GitHub
    # actually stated. A second page would hide a duplicate, so more runners
    # than one page holds is refused rather than half-read.
    if ! remote=$(python3 -I - "$json" "$name" <<'PY'
import json
import sys

path, expected = sys.argv[1:3]
with open(path, encoding="utf-8") as f:
    data = json.load(f)

runners = data.get("runners")
if not isinstance(runners, list):
    raise SystemExit("response has no runners list")
total = data.get("total_count")
if not isinstance(total, int) or total > len(runners):
    raise SystemExit(f"response holds {len(runners)} of {total!r} runners")

matches = [r for r in runners if r.get("name") == expected]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one runner named {expected!r}, got {len(matches)}")

r = matches[0]
if r.get("status") not in {"online", "offline"}:
    raise SystemExit(f"unexpected runner status {r.get('status')!r}")
if not isinstance(r.get("busy"), bool):
    raise SystemExit(f"unexpected busy value {r.get('busy')!r}")

print(f"{r.get('id')}\t{r['status']}\t{str(r['busy']).lower()}\t{r.get('os')}")
PY
    ); then
        printf '  github   ERROR runner identity or status is not trustworthy\n'
        status_failed=1
        return
    fi

    IFS=$'\t' read -r runner_id remote_status busy remote_os <<<"$remote"

    load=$(systemctl show "$service" -p LoadState --value 2>/dev/null || true)
    enabled=$(systemctl show "$service" -p UnitFileState --value 2>/dev/null || true)
    active=$(systemctl show "$service" -p ActiveState --value 2>/dev/null || true)
    sub=$(systemctl show "$service" -p SubState --value 2>/dev/null || true)
    pid=$(systemctl show "$service" -p MainPID --value 2>/dev/null || true)

    printf '  repo     %s\n' "$repo"
    printf '  runner   %s id=%s os=%s\n' "$name" "$runner_id" "$remote_os"
    printf '  github   status=%s busy=%s\n' "$remote_status" "$busy"
    printf '  service  %s\n' "$service"
    printf '  local    load=%s enabled=%s active=%s sub=%s pid=%s\n' \
        "${load:-unknown}" "${enabled:-unknown}" "${active:-unknown}" \
        "${sub:-unknown}" "${pid:-unknown}"

    if [ "$remote_status" != online ]; then
        printf '  STATUS   remote runner is not online\n'
        status_failed=1
    fi

    if [ "$load" != loaded ] || [ "$enabled" != enabled ] ||
       [ "$active" != active ] || [ "$sub" != running ] ||
       ! [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
        printf '  STATUS   local runner service is not fully running\n'
        status_failed=1
    fi
}

case "$MODE" in
    all)
        while IFS= read -r profile; do
            [ -n "$profile" ] && status_profile "$profile"
        done < <(fabric_profiles "$CONFIG")
        ;;
    profile)
        PROFILE="$CONFIG/profiles/$PROFILE_ID.conf"
        [ -r "$PROFILE" ] || { echo "unknown profile: $PROFILE_ID" >&2; exit 1; }
        status_profile "$PROFILE"
        ;;
esac

[ "$profile_count" -gt 0 ] || { echo 'no runner profiles selected' >&2; exit 1; }

step "operational result"
if [ "$status_failed" -eq 0 ]; then
    note "all $profile_count selected runners are operational"
    exit 0
fi
note "one or more selected runners have an operational problem"
exit 1
