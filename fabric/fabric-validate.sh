#!/usr/bin/env bash
# Validate a RunnerSlice inventory: policy, release seed and every profile,
# as one fleet. Offline: no root, no GitHub, no live host state.
#
#     fabric-validate.sh CONFIG_DIR
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fabric-lib.sh
. "$LIB_DIR/fabric-lib.sh"

[ "$#" -eq 1 ] || {
    echo "usage: $(basename "$0") CONFIG_DIR" >&2
    exit 2
}
CONFIG_DIR=$1
[ -d "$CONFIG_DIR" ] || {
    echo "not a directory: $CONFIG_DIR" >&2
    exit 2
}

fabric_validate_fleet "$CONFIG_DIR"

echo 'RunnerSlice inventory: valid'

while IFS= read -r profile; do
    id=$(fabric_value "$profile" profile-id)
    repo=$(fabric_value "$profile" runner-repo)
    user=$(fabric_value "$profile" runner-user)
    service=$(fabric_value "$profile" runner-service)

    printf '  %-10s %-24s %-18s %s\n' \
        "$id" "$repo" "$user" "$service"
done < <(fabric_profiles "$CONFIG_DIR")
