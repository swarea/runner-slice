#!/usr/bin/env bash
# Print the systemd unit one profile renders to. The whole fleet is validated
# first, because a unit's masks are derived from every other profile.
#
#     fabric-render-service.sh CONFIG_DIR PROFILE_ID
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fabric-lib.sh
. "$LIB_DIR/fabric-lib.sh"

[ "$#" -eq 2 ] || {
    echo "usage: $(basename "$0") CONFIG_DIR PROFILE_ID" >&2
    exit 2
}
CONFIG_DIR=$1
PROFILE_ID=$2

[[ "$PROFILE_ID" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "invalid profile id: $PROFILE_ID" >&2
    exit 2
}

PROFILE="$CONFIG_DIR/profiles/$PROFILE_ID.conf"

[ -f "$PROFILE" ] || {
    echo "unknown profile: $PROFILE_ID" >&2
    exit 1
}

fabric_validate_fleet "$CONFIG_DIR"
fabric_render_service "$CONFIG_DIR" "$PROFILE"
