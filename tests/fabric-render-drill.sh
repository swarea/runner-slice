#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_DIR="$ROOT/examples/basic"

# shellcheck source=../fabric/fabric-lib.sh
. "$ROOT/fabric/fabric-lib.sh"

PASS=0
FAIL=0

pass() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$*"
}

fail() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$*" >&2
}

has_line() {
    local file=$1 line=$2
    grep -Fqx -- "$line" "$file"
}

render_profile() {
    local ci_dir=$1 id=$2 out=$3
    fabric_render_service \
        "$ci_dir" \
        "$ci_dir/profiles/$id.conf" \
        > "$out"
}

fixture() {
    local dst
    dst=$(mktemp -d)

    mkdir -p "$dst/ci"
    cp "$CI_DIR/runner-release.conf" "$dst/ci/"
    cp "$CI_DIR/fabric.conf" "$dst/ci/"
    cp -a "$CI_DIR/profiles" "$dst/ci/"

    cat > "$dst/ci/profiles/synthetic.conf" <<'PROFILE'
profile-id       synthetic
runner-repo      example-org/synthetic
runner-name      lab-synthetic-01
runner-user      runner-synthetic
runner-home      /home/runner-synthetic
runner-service   ci-synthetic-runner.service

runner-label     lab
runner-label     synthetic

install-root     /var/lib/ci-synthetic
runner-dir       /var/lib/ci-synthetic/runner
work-dir         /var/lib/ci-synthetic/work

resource-class   shared
sandbox-class    baseline
PROFILE

    printf '%s\n' "$dst"
}

fabric_validate_fleet "$CI_DIR"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo '== deterministic tracked-fleet rendering =='

for profile in "$CI_DIR/profiles/"*.conf; do
    id=$(fabric_value "$profile" profile-id)
    render_profile "$CI_DIR" "$id" "$TMP/$id.1.service"
    render_profile "$CI_DIR" "$id" "$TMP/$id.2.service"

    if cmp -s "$TMP/$id.1.service" "$TMP/$id.2.service"; then
        pass "$id renders byte-identically twice"
    else
        fail "$id rendering is nondeterministic"
    fi

    profile="$CI_DIR/profiles/$id.conf"
    user=$(fabric_value "$profile" runner-user)
    home=$(fabric_value "$profile" runner-home)
    install=$(fabric_value "$profile" install-root)
    runner=$(fabric_value "$profile" runner-dir)

    if has_line "$TMP/$id.1.service" "User=$user" &&
       has_line "$TMP/$id.1.service" "Group=$user" &&
       has_line "$TMP/$id.1.service" "WorkingDirectory=$runner" &&
       has_line "$TMP/$id.1.service" "ExecStart=$runner/bin/runsvc.sh" &&
       has_line "$TMP/$id.1.service" "ReadWritePaths=$install" &&
       has_line "$TMP/$id.1.service" "ReadWritePaths=$home"; then
        pass "$id preserves its identity and writable roots"
    else
        fail "$id lost an identity or writable-root contract"
    fi

    for common in \
        -/srv/example-app \
        -/run/docker.sock \
        -/var/run/docker.sock
    do
        if ! has_line "$TMP/$id.1.service" "InaccessiblePaths=$common"; then
            fail "$id omitted common boundary $common"
        fi
    done

    if has_line "$TMP/$id.1.service" 'NoNewPrivileges=yes' &&
       has_line "$TMP/$id.1.service" 'PrivateTmp=yes' &&
       has_line "$TMP/$id.1.service" 'ProtectSystem=full' &&
       has_line "$TMP/$id.1.service" 'ProtectHome=tmpfs' &&
       has_line "$TMP/$id.1.service" "BindPaths=$home" &&
       has_line "$TMP/$id.1.service" 'ProtectKernelTunables=yes' &&
       has_line "$TMP/$id.1.service" 'ProtectKernelModules=yes' &&
       has_line "$TMP/$id.1.service" 'ProtectControlGroups=yes' &&
       has_line "$TMP/$id.1.service" 'ProtectClock=yes' &&
       has_line "$TMP/$id.1.service" 'RestrictSUIDSGID=yes' &&
       has_line "$TMP/$id.1.service" 'RestrictRealtime=yes' &&
       has_line "$TMP/$id.1.service" 'LockPersonality=yes' &&
       has_line "$TMP/$id.1.service" 'UMask=0027'; then
        pass "$id carries the mandatory service hardening"
    else
        fail "$id omitted mandatory service hardening"
    fi
done

# The example opts exactly one profile into user namespaces; every other
# profile must render the baseline restriction (decision 0002).
for profile in "$CI_DIR/profiles/"*.conf; do
    id=$(fabric_value "$profile" profile-id)
    sandbox=$(fabric_value "$profile" sandbox-class)

    case "$sandbox" in
        userns) want='RestrictNamespaces=no' ;;
        *)      want='RestrictNamespaces=yes' ;;
    esac

    if has_line "$TMP/$id.1.service" "$want" &&
       [ "$(grep -c '^RestrictNamespaces=' "$TMP/$id.1.service")" -eq 1 ]; then
        pass "$id renders exactly $want for sandbox-class $sandbox"
    else
        fail "$id does not render exactly $want for sandbox-class $sandbox"
    fi
done

echo
echo '== current tracked peer isolation =='

for profile in "$CI_DIR/profiles/"*.conf; do
    id=$(fabric_value "$profile" profile-id)

    while IFS= read -r peer; do
        peer_id=$(fabric_value "$peer" profile-id)
        [ "$peer_id" = "$id" ] && continue

        peer_root=$(fabric_value "$peer" install-root)
        peer_home=$(fabric_value "$peer" runner-home)

        if has_line "$TMP/$id.1.service" "InaccessiblePaths=$peer_root" &&
           ! has_line "$TMP/$id.1.service" "InaccessiblePaths=$peer_home"; then
            pass "$id derives runtime isolation for peer $peer_id without pairwise home masks"
        else
            fail "$id peer-isolation contract is wrong for $peer_id"
        fi
    done < <(fabric_profiles "$CI_DIR")
done

echo
echo '== slice rendering =='

if diff <(fabric_render_slice "$CI_DIR") - <<'SLICE'
# Managed by RunnerSlice. Changes here are replaced on the next apply.
[Unit]
Description=GitHub Actions runners managed by RunnerSlice

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
TasksAccounting=yes
CPUQuota=100%
MemoryHigh=1536M
MemoryMax=2G
TasksMax=1024
SLICE
then
    pass 'the example slice renders exactly its declared limits'
else
    fail 'the example slice rendering changed'
fi

F=$(fixture)
sed -i -e '/^slice-memory-high/d' "$F/ci/fabric.conf"
printf 'slice-cpu-weight    40\nslice-ip-deny       169.254.169.254/32\nslice-ip-deny       fd00:ec2::254\n' \
    >> "$F/ci/fabric.conf"
fabric_render_slice "$F/ci" > "$F/slice"
if ! grep -q '^MemoryHigh=' "$F/slice" &&
   has_line "$F/slice" 'CPUWeight=40' &&
   has_line "$F/slice" 'IPAddressDeny=169.254.169.254/32' &&
   has_line "$F/slice" 'IPAddressDeny=fd00:ec2::254'; then
    pass 'optional limits render only when declared, and every deny entry renders'
else
    fail 'optional slice limits render wrongly'
    cat "$F/slice" >&2
fi
rm -rf "$F"

echo
echo '== synthetic additional runner =='

F=$(fixture)

if fabric_validate_fleet "$F/ci"; then
    pass 'tracked fleet plus synthetic profile validates before rendering'
else
    fail 'tracked fleet plus synthetic profile does not validate'
fi

for profile in "$F/ci/profiles/"*.conf; do
    id=$(fabric_value "$profile" profile-id)
    render_profile "$F/ci" "$id" "$TMP/$id.synthetic.service"
done

for profile in "$F/ci/profiles/"*.conf; do
    id=$(fabric_value "$profile" profile-id)
    [ "$id" = synthetic ] && continue

    if has_line "$TMP/$id.synthetic.service" \
           'InaccessiblePaths=/var/lib/ci-synthetic' &&
       ! has_line "$TMP/$id.synthetic.service" \
           'InaccessiblePaths=/home/runner-synthetic' &&
       has_line "$TMP/$id.synthetic.service" 'ProtectHome=tmpfs'; then
        pass "$id derives the new runtime peer while home isolation stays default-deny"
    else
        fail "$id rendering did not preserve default-deny home isolation"
    fi
done

for peer_profile in "$F/ci/profiles/"*.conf; do
    peer=$(fabric_value "$peer_profile" profile-id)
    [ "$peer" = synthetic ] && continue
    peer_root=$(fabric_value "$peer_profile" install-root)
    peer_home=$(fabric_value "$peer_profile" runner-home)

    if has_line "$TMP/synthetic.synthetic.service" \
           "InaccessiblePaths=$peer_root" &&
       ! has_line "$TMP/synthetic.synthetic.service" \
           "InaccessiblePaths=$peer_home" &&
       has_line "$TMP/synthetic.synthetic.service" 'ProtectHome=tmpfs' &&
       has_line "$TMP/synthetic.synthetic.service" \
           'BindPaths=/home/runner-synthetic'; then
        pass "synthetic rendering isolates $peer runtime and exposes only its own home"
    else
        fail "synthetic rendering does not enforce the default-deny home model"
    fi
done

echo
echo '== planted renderer defect =='

cp "$TMP/app.1.service" "$TMP/app.broken.service"
grep -Fxv \
    'InaccessiblePaths=/var/lib/ci-web' \
    "$TMP/app.broken.service" \
    > "$TMP/app.broken.new"
mv "$TMP/app.broken.new" "$TMP/app.broken.service"

if fabric_validate_mask_file \
      "$CI_DIR" \
      "$CI_DIR/profiles/app.conf" \
      <(sed -n 's/^InaccessiblePaths=//p' "$TMP/app.broken.service") \
      >/dev/null 2>&1
then
    fail 'renderer boundary defect escaped validation'
else
    pass 'renderer boundary defect is detected'
fi

rm -rf "$F"

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
