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

write_synthetic() {
    local dir=$1

    cat > "$dir/profiles/synthetic.conf" <<'PROFILE'
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
}

fixture() {
    local dst
    dst=$(mktemp -d)

    mkdir -p "$dst/ci"
    cp "$CI_DIR/runner-release.conf" "$dst/ci/"
    cp "$CI_DIR/fabric.conf" "$dst/ci/"
    cp -a "$CI_DIR/profiles" "$dst/ci/"

    write_synthetic "$dst/ci"

    printf '%s\n' "$dst"
}

expect_reject() {
    local description=$1 pattern=$2
    shift 2

    local output rc
    set +e
    output=$("$@" 2>&1)
    rc=$?
    set -e

    if [ "$rc" -ne 0 ] && grep -Fq -- "$pattern" <<<"$output"; then
        pass "$description"
    else
        fail "$description"
        printf '%s\n' "$output" >&2
    fi
}

echo '== baseline =='

if fabric_validate_fleet "$CI_DIR"; then
    pass 'tracked profile fleet validates'
else
    fail 'tracked profile fleet validates'
fi

BASE_SHA="$(
    {
        sha256sum "$CI_DIR"/profiles/*.conf
        sha256sum "$CI_DIR/runner-release.conf" "$CI_DIR/fabric.conf"
    } | sha256sum | awk '{print $1}'
)"

echo
echo '== synthetic additional profile =='

F=$(fixture)
trap 'rm -rf "$F"' EXIT

if fabric_validate_fleet "$F/ci"; then
    pass 'an additional profile is discovered without editing existing profiles'
else
    fail 'an additional profile is discovered without editing existing profiles'
fi

for existing_profile in "$F/ci/profiles/"*.conf; do
    existing=$(fabric_value "$existing_profile" profile-id)
    [ "$existing" = synthetic ] && continue
    masks="$F/$existing.masks"

    fabric_expected_masks \
        "$F/ci" \
        "$F/ci/profiles/$existing.conf" \
        > "$masks"

    if grep -Fxq '/var/lib/ci-synthetic' "$masks" &&
       ! grep -Fxq '/home/runner-synthetic' "$masks"; then
        pass "$existing derives the new synthetic runtime peer without a pairwise home mask"
    else
        fail "$existing synthetic peer derivation is incorrect"
    fi
done

SYNTH_MASKS="$F/synthetic.masks"

fabric_expected_masks \
    "$F/ci" \
    "$F/ci/profiles/synthetic.conf" \
    > "$SYNTH_MASKS"

for peer_profile in "$F/ci/profiles/"*.conf; do
    peer_id=$(fabric_value "$peer_profile" profile-id)
    [ "$peer_id" = synthetic ] && continue
    peer=$(fabric_value "$peer_profile" install-root)
    if grep -Fxq -- "$peer" "$SYNTH_MASKS"; then
        pass "synthetic runner automatically isolates peer $peer"
    else
        fail "synthetic runner automatically isolates peer $peer"
    fi
done

echo
echo '== planted validation defects =='

T=$(fixture)
sed -i \
    's/^runner-name[[:space:]].*/runner-name      lab-app-01/' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'duplicate runner identity is rejected' \
    "duplicate runner-name 'lab-app-01'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's#^install-root[[:space:]].*#install-root     /var/lib/ci-web#' \
    "$T/ci/profiles/synthetic.conf"
sed -i \
    's#^runner-dir[[:space:]].*#runner-dir       /var/lib/ci-web/runner#' \
    "$T/ci/profiles/synthetic.conf"
sed -i \
    's#^work-dir[[:space:]].*#work-dir         /var/lib/ci-web/work#' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'duplicate runtime root is rejected' \
    "duplicate install-root '/var/lib/ci-web'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's/^resource-class[[:space:]].*/resource-class   impossible/' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'unknown resource class is rejected' \
    "unsupported resource-class 'impossible'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's/^sandbox-class[[:space:]].*/sandbox-class    impossible/' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'unknown sandbox class is rejected' \
    "unsupported sandbox-class 'impossible'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
printf '\nrunner-version   99.99.99\n' \
    >> "$T/ci/profiles/synthetic.conf"

expect_reject \
    'profile-local release data is rejected' \
    'profile-local release key forbidden: runner-version' \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
awk '
    !($1 == "common-mask" && $2 == "-/run/docker.sock")
' "$T/ci/fabric.conf" > "$T/ci/fabric.conf.new"
mv "$T/ci/fabric.conf.new" "$T/ci/fabric.conf"

expect_reject \
    'missing mandatory common isolation rule is rejected' \
    'mandatory common-mask missing: -/run/docker.sock' \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

# The collision checks below are the ones a second tenant actually collides on:
# a repository, an account and a unit name are each easier to copy by accident
# than a runtime root, and each would give two tenants one identity.

T=$(fixture)
sed -i \
    's#^runner-repo[[:space:]].*#runner-repo      example-org/app#' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'duplicate repository is rejected' \
    "duplicate runner-repo 'example-org/app'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's#^runner-user[[:space:]].*#runner-user      runner-docs#' \
    "$T/ci/profiles/synthetic.conf"
sed -i \
    's#^runner-home[[:space:]].*#runner-home      /home/runner-docs#' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'duplicate runner account is rejected' \
    "duplicate runner-user 'runner-docs'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's#^runner-service[[:space:]].*#runner-service   ci-docs-runner.service#' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'duplicate systemd unit is rejected' \
    "duplicate runner-service 'ci-docs-runner.service'" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

# A label is the tenant routing contract: a job asks for `home` and reaches the
# home runner. A profile whose labels do not name it would register a runner no
# workflow can address.
#
# The label is REPLACED rather than deleted on purpose. Deleting it leaves one
# label, which the count rule rejects first, so the test would pass without the
# identity rule existing at all -- which is what a first attempt at this did.
T=$(fixture)
sed -i \
    's/^runner-label     synthetic$/runner-label     somethingelse/' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'a profile whose labels do not name it is rejected' \
    'runner-label synthetic is required' \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's/^runner-label     lab$/runner-label     lab-2/' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'a profile that does not claim the host class is rejected' \
    'runner-label lab is required' \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

T=$(fixture)
sed -i \
    's#^runner-home[[:space:]].*#runner-home      /home/somebody-else#' \
    "$T/ci/profiles/synthetic.conf"

expect_reject \
    'a home that is not the account home is rejected' \
    "runner-home '/home/somebody-else' must be /home/runner-synthetic" \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

# The profile inventory is reviewed in Git and must never be a place a
# credential can be introduced, even by a well-meant key name.
T=$(fixture)
printf '\nrunner-token     placeholder-not-a-credential\n' \
    >> "$T/ci/profiles/synthetic.conf"

expect_reject \
    'a secret-bearing profile key is rejected' \
    'secret-bearing profile key forbidden: runner-token' \
    fabric_validate_fleet "$T/ci"

rm -rf "$T"

echo
echo '== planted peer-isolation defect =='

T=$(fixture)

fabric_expected_masks \
    "$T/ci" \
    "$T/ci/profiles/app.conf" \
    > "$T/app.masks"

grep -Fxv '/var/lib/ci-synthetic' \
    "$T/app.masks" \
    > "$T/app.masks.broken"

expect_reject \
    'missing synthetic peer mask is rejected' \
    'derived isolation mask set differs for app' \
    fabric_validate_mask_file \
        "$T/ci" \
        "$T/ci/profiles/app.conf" \
        "$T/app.masks.broken"

rm -rf "$T"

echo
echo '== the configuration cache answers exactly what the files say =='

# fabric_values, fabric_value and fabric_key_count answer from a cache inside
# validation and rendering. The cache must be invisible: for every key of every
# file, and for the shapes the original awk normalises -- whitespace runs, tabs,
# an empty value, a repeated key, a comment, a key that is absent -- the answer
# with the cache on is byte-identical to the answer with it off.
E=$(mktemp -d)
mkdir -p "$E/profiles"
cp "$CI_DIR/fabric.conf" "$CI_DIR/runner-release.conf" "$E/"
cp "$CI_DIR"/profiles/*.conf "$E/profiles/"
printf 'profile-id odd\n# runner-label commented-out\nrunner-label   a    b\t c\nrunner-label\t\ttabbed\nrunner-pool\nrunner-label   last\n   \n' \
    > "$E/profiles/odd.conf"
answers() {
    local f k
    for f in "$E"/profiles/*.conf "$E/fabric.conf" "$E/runner-release.conf"; do
        for k in $(awk '!/^[[:space:]]*#/ && NF { print $1 }' "$f" | sort -u) absent-key; do
            printf '%s|%s|values=' "$f" "$k"; fabric_values "$f" "$k" | od -c | tr -s ' ' | tr '\n' ' '
            printf '|value='; fabric_value "$f" "$k" | od -c | tr -s ' ' | tr '\n' ' '
            printf '|count=%s\n' "$(fabric_key_count "$f" "$k")"
        done
    done
}
answers > "$E/uncached"
fabric_cache_begin "$E"
answers > "$E/cached"
fabric_cache_end
if [ -s "$E/uncached" ] && cmp -s "$E/uncached" "$E/cached"; then
    pass "cached and uncached answers are identical for $(wc -l < "$E/uncached") file/key pairs"
else
    fail 'the cache answers differently from the files'
    diff "$E/uncached" "$E/cached" | head -20 >&2
fi
if [ "$FABRIC_CACHE_DEPTH" -eq 0 ] && [ "${#FABRIC_KV[@]}" -eq 0 ]; then
    pass 'the cache is empty again once the call that loaded it returns'
else
    fail 'the cache outlived its call'
fi
# Not served stale: a file rewritten between two validations is read afresh.
rm -f "$E/profiles/odd.conf"
fabric_validate_fleet "$E" >/dev/null 2>&1 || fail 'the copied fleet does not validate before the rewrite'
sed -i 's/^runner-name[[:space:]].*/runner-name      lab-app-01/' "$E/profiles/docs.conf"
if fabric_validate_fleet "$E" >/dev/null 2>&1; then
    fail 'a file changed between two validations was answered from a stale cache'
else
    pass 'a file changed between two validations is read afresh'
fi
rm -rf "$E"

echo
echo '== several runners for one repository: the web pool =='

# The tracked fleet carries two web runners. Everything below is about what
# that may and may not mean: one repository, one pool, and otherwise nothing
# shared -- not a name, an account, a unit, a runtime root, or a label set.

# Every runner masks every other runner's runtime root, and never its own.
# This is the whole isolation matrix rather than the new runner's row: the
# point of adding a pool member is that the five existing runners also lose
# sight of it.
matrix_ok=1
while IFS= read -r a; do
    a_id=$(fabric_value "$a" profile-id)
    a_root=$(fabric_value "$a" install-root)
    masks=$(fabric_expected_masks "$CI_DIR" "$a")
    if grep -Fxq -- "$a_root" <<<"$masks"; then
        fail "$a_id masks its own runtime root $a_root"
        matrix_ok=0
    fi
    while IFS= read -r b; do
        b_id=$(fabric_value "$b" profile-id)
        [ "$b_id" = "$a_id" ] && continue
        b_root=$(fabric_value "$b" install-root)
        grep -Fxq -- "$b_root" <<<"$masks" || {
            fail "$a_id does not mask peer $b_id ($b_root)"
            matrix_ok=0
        }
    done < <(fabric_profiles "$CI_DIR")
done < <(fabric_profiles "$CI_DIR")
n=$(fabric_profiles "$CI_DIR" | wc -l)
[ "$matrix_ok" -eq 1 ] && pass "all $n runners mask every peer runtime root and none masks its own"

# Both pool members render a unit of their own: own account, own runtime
# root writable, own home bound back, the other member's root masked.
for id in web web-2; do
    prof="$CI_DIR/profiles/$id.conf"
    unit=$(fabric_render_service "$CI_DIR" "$prof")
    user=$(fabric_value "$prof" runner-user)
    root=$(fabric_value "$prof" install-root)
    other=web-2; [ "$id" = web-2 ] && other=web
    other_root=$(fabric_value "$CI_DIR/profiles/$other.conf" install-root)
    if grep -Fxq "User=$user" <<<"$unit" &&
       grep -Fxq "ReadWritePaths=$root" <<<"$unit" &&
       grep -Fxq "BindPaths=/home/$user" <<<"$unit" &&
       grep -Fxq "InaccessiblePaths=$other_root" <<<"$unit" &&
       ! grep -Fxq "InaccessiblePaths=$root" <<<"$unit" &&
       [ "$(grep -c '^ReadWritePaths=' <<<"$unit")" -eq 2 ]; then
        pass "$id renders its own identity and masks $other_root"
    else
        fail "$id does not render a separate identity from $other"
    fi
done

# What adding the second member does to every other unit: one added line, the
# mask for the new root, and nothing else. This is the exact change an operator
# rolls out to the five existing runners, so it is asserted rather than read.
P=$(fixture)
rm -f "$P/ci/profiles/synthetic.conf" "$P/ci/profiles/web-2.conf"
awk '$1 != "runner-pool"' "$CI_DIR/profiles/web.conf" > "$P/ci/profiles/web.conf"
if fabric_validate_fleet "$P/ci" >/dev/null 2>&1; then
    pass 'the fleet without the second member still validates (the rollback state)'
else
    fail 'the fleet without the second member does not validate'
fi
while IFS= read -r prof; do
    id=$(fabric_value "$prof" profile-id)
    [ "$id" = web-2 ] && continue
    before=$(fabric_render_service "$P/ci" "$P/ci/profiles/$id.conf")
    after=$(fabric_render_service "$CI_DIR" "$prof")
    delta=$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep '^[<>]' || true)
    if [ "$delta" = "> InaccessiblePaths=/var/lib/ci-web-2" ]; then
        pass "$id unit changes only by the mask for /var/lib/ci-web-2"
    else
        fail "$id unit changes by more than the new peer mask"
        printf '%s\n' "$delta" >&2
    fi
done < <(fabric_profiles "$CI_DIR")
rm -rf "$P"

# A pool of one is the state a rollback leaves, and must stay valid.
P=$(fixture)
rm -f "$P/ci/profiles/web-2.conf"
if fabric_validate_fleet "$P/ci" >/dev/null 2>&1; then
    pass 'a pool with one member validates'
else
    fail 'a pool with one member does not validate'
fi
rm -rf "$P"

pool_reject() { # <description> <expected error fragment> <sed program> [file]
    local description=$1 pattern=$2 prog=$3 file=${4:-web-2}
    T=$(fixture)
    sed -i -e "$prog" "$T/ci/profiles/$file.conf"
    expect_reject "$description" "$pattern" fabric_validate_fleet "$T/ci"
    rm -rf "$T"
}

# The old rule, for a repository nobody declared a pool for, is unchanged:
# dropping the declaration from either member makes it a plain duplicate.
pool_reject 'a second web profile without runner-pool is a duplicate repository' \
    "duplicate runner-repo 'example-org/web'" '/^runner-pool/d'
pool_reject 'the first web profile without runner-pool is a duplicate repository' \
    "duplicate runner-repo 'example-org/web'" '/^runner-pool/d' web

# Registration runs with --replace, so a pool member that reused the other
# member's runner name would take over its registration with GitHub.
pool_reject 'a pool member reusing the other member runner name is rejected' \
    "duplicate runner-name 'lab-web-01'" \
    's/^runner-name[[:space:]].*/runner-name      lab-web-01/'
pool_reject 'a pool member reusing the other member account is rejected' \
    "duplicate runner-user 'runner-web'" \
    's#^runner-user[[:space:]].*#runner-user      runner-web#; s#^runner-home[[:space:]].*#runner-home      /home/runner-web#'
pool_reject 'a pool member reusing the other member unit is rejected' \
    "duplicate runner-service 'ci-web-runner.service'" \
    's#^runner-service[[:space:]].*#runner-service   ci-web-runner.service#'
pool_reject 'a pool member reusing the other member runtime root is rejected' \
    "duplicate install-root '/var/lib/ci-web'" \
    's#/var/lib/ci-web-2#/var/lib/ci-web#'

# Routing: every member carries the pool label, and offers exactly the labels
# the others offer. Replacing rather than deleting, for the reason given above.
pool_reject 'a pool member without the pool label is rejected' \
    'runner-label web is required by runner-pool web' \
    's/^runner-label     web$/runner-label     elsewhere/'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
pool_reject 'a pool member offering an extra label is rejected' \
    "runner-pool 'web' members offer different labels" \
    '$a runner-label     fast'

# Membership: a pool belongs to one repository, its members are named for it,
# and one repository cannot be split across two pools.
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
pool_reject 'a profile name that is not a pool member name is rejected' \
    "profile-id 'web-2' is not a member name of runner-pool 'other'" \
    's/^runner-pool[[:space:]].*/runner-pool      other/; $a runner-label     other'
pool_reject 'one repository split across two pools is rejected' \
    "runner-repo 'example-org/web' has profiles in different pools" \
    's/^runner-pool[[:space:]].*/runner-pool      web-2/'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
pool_reject 'a repeated runner-pool is rejected' \
    'runner-pool may appear at most once' '$a runner-pool      web'

T=$(fixture)
sed -e 's/^profile-id[[:space:]].*/profile-id       web-3/' \
    -e 's#^runner-repo[[:space:]].*#runner-repo      example-org/synthetic#' \
    -e 's/^runner-name[[:space:]].*/runner-name      lab-web-03/' \
    -e 's/^runner-user[[:space:]].*/runner-user      runner-web-3/' \
    -e 's#^runner-home[[:space:]].*#runner-home      /home/runner-web-3#' \
    -e 's/^runner-service[[:space:]].*/runner-service   ci-web-3-runner.service/' \
    -e 's/^runner-label     web-2$/runner-label     web-3/' \
    -e 's#/var/lib/ci-web-2#/var/lib/ci-web-3#' \
    "$CI_DIR/profiles/web-2.conf" > "$T/ci/profiles/web-3.conf"
rm -f "$T/ci/profiles/synthetic.conf"
expect_reject 'a pool that spans two repositories is rejected' \
    "runner-pool 'web' spans repositories" fabric_validate_fleet "$T/ci"
rm -rf "$T"

echo
echo '== declared naming policy =='

# The example policy's names are only examples. Translating the whole fixture
# to other names must validate and render under those names, so a value that
# leaked back into the library as a constant shows up here as a failure.
renamed_fixture() {
    local t
    t=$(fixture)
    sed -i \
        -e 's/^slice[[:space:]].*/slice            build-pool.slice/' \
        -e 's/^name-prefix[[:space:]].*/name-prefix      gha/' \
        -e 's/^user-prefix[[:space:]].*/user-prefix      gh/' \
        -e 's/^host-label[[:space:]].*/host-label       rack7/' \
        "$t/ci/fabric.conf"
    sed -i \
        -e 's/^\(runner-user[[:space:]]*\)runner-/\1gh-/' \
        -e 's#^\(runner-home[[:space:]]*\)/home/runner-#\1/home/gh-#' \
        -e 's/^\(runner-service[[:space:]]*\)ci-/\1gha-/' \
        -e 's#/var/lib/ci-#/var/lib/gha-#g' \
        -e 's/^\(runner-label[[:space:]]*\)lab$/\1rack7/' \
        "$t/ci/profiles/"*.conf
    printf '%s\n' "$t"
}

T=$(renamed_fixture)
if fabric_validate_fleet "$T/ci" >/dev/null 2>&1; then
    pass 'a fleet under another naming policy validates'
else
    fail 'a fleet under another naming policy does not validate'
    fabric_validate_fleet "$T/ci" || true
fi

unit=$(fabric_render_service "$T/ci" "$T/ci/profiles/web-2.conf")
if grep -Fqx 'Slice=build-pool.slice' <<<"$unit" &&
   grep -Fqx 'User=gh-web-2' <<<"$unit" &&
   grep -Fqx 'WorkingDirectory=/var/lib/gha-web-2/runner' <<<"$unit" &&
   grep -Fqx 'InaccessiblePaths=/var/lib/gha-web' <<<"$unit" &&
   ! grep -Eq 'ci\.slice|/var/lib/ci-|runner-web' <<<"$unit"; then
    pass 'rendering follows the declared slice, prefixes and peers'
else
    fail 'rendering does not follow the declared naming policy'
    printf '%s\n' "$unit" >&2
fi

# A profile left on the old names after a policy change is refused rather
# than rendered into a unit the rest of the fleet does not account for.
sed -i 's/^\(runner-service[[:space:]]*\)gha-/\1ci-/' "$T/ci/profiles/app.conf"
expect_reject 'a service outside the declared name-prefix is rejected' \
    "invalid runner-service 'ci-app-runner.service'" \
    fabric_validate_fleet "$T/ci"
rm -rf "$T"

T=$(renamed_fixture)
sed -i 's/^\(runner-user[[:space:]]*\)gh-/\1runner-/' "$T/ci/profiles/app.conf"
expect_reject 'an account outside the declared user-prefix is rejected' \
    "invalid runner-user 'runner-app'" \
    fabric_validate_fleet "$T/ci"
rm -rf "$T"

T=$(renamed_fixture)
sed -i 's/^\(runner-label[[:space:]]*\)rack7$/\1lab/' "$T/ci/profiles/app.conf"
expect_reject 'a profile that misses the declared host-label is rejected' \
    'runner-label rack7 is required' \
    fabric_validate_fleet "$T/ci"
rm -rf "$T"

policy_reject() {
    local description=$1 pattern=$2 prog=$3 t
    t=$(fixture)
    sed -i -e "$prog" "$t/ci/fabric.conf"
    expect_reject "$description" "$pattern" fabric_validate_fleet "$t/ci"
    rm -rf "$t"
}

policy_reject 'a missing slice is rejected' \
    'slice must appear exactly once (got 0)' '/^slice[[:space:]]/d'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'a second slice is rejected' \
    'slice must appear exactly once (got 2)' '$a slice            other.slice'
policy_reject 'a slice that is not a slice unit is rejected' \
    'slice must be a systemd slice name' \
    's/^slice[[:space:]].*/slice            ci.service/'
policy_reject 'a name-prefix that is a pattern is rejected' \
    "invalid name-prefix 'ci.*'" \
    's/^name-prefix[[:space:]].*/name-prefix      ci.*/'
policy_reject 'a user-prefix with upper case is rejected' \
    "invalid user-prefix 'Runner'" \
    's/^user-prefix[[:space:]].*/user-prefix      Runner/'
policy_reject 'a missing host-label is rejected' \
    'host-label must appear exactly once (got 0)' \
    '/^host-label[[:space:]]/d'
policy_reject 'a host-label with a path separator is rejected' \
    "invalid host-label 'lab/1'" \
    's#^host-label[[:space:]].*#host-label       lab/1#'

echo
echo '== declared slice limits and host policy =='

# No limit has a default, so each one missing is its own refusal.
for key in slice-cpu-quota slice-memory-max slice-tasks-max; do
    policy_reject "a missing $key is rejected" \
        "$key must appear exactly once (got 0)" "/^${key}[[:space:]]/d"
done
policy_reject 'a quota that is not a percentage is rejected' \
    "slice-cpu-quota '1.5' must be a percentage" \
    's/^slice-cpu-quota[[:space:]].*/slice-cpu-quota     1.5/'
policy_reject 'a memory size systemd would not read is rejected' \
    "slice-memory-max '2GB' must be bytes or a K/M/G/T size" \
    's/^slice-memory-max[[:space:]].*/slice-memory-max    2GB/'
policy_reject 'a soft memory limit above the hard one is rejected' \
    'slice-memory-high 3G is above slice-memory-max 2G' \
    's/^slice-memory-high[[:space:]].*/slice-memory-high   3G/'
policy_reject 'a zero task limit is rejected' \
    "slice-tasks-max '0' must be a positive integer" \
    's/^slice-tasks-max[[:space:]].*/slice-tasks-max     0/'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'a CPU weight outside systemd range is rejected' \
    "slice-cpu-weight '20000' must be 1 to 10000" '$a slice-cpu-weight    20000'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'a deny entry that is not an address is rejected' \
    "slice-ip-deny 'metadata' is not an address or prefix" '$a slice-ip-deny       metadata'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'a relative protected path is rejected' \
    "protected-path 'srv/app/.env' must be an absolute path" '$a protected-path      srv/app/.env'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'an invalid host-name is rejected' \
    "invalid host-name 'build 01'" '$a host-name           build 01'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
policy_reject 'a repeated host-name is rejected' \
    'host-name may appear at most once' '$a host-name a
$a host-name b'

echo
echo '== values that reach commands, URLs and systemd =='

for bad in system.slice user.slice machine.slice system-runners.slice; do
    policy_reject "systemd's own slice $bad is rejected" \
        "slice '$bad' is one of systemd's own" "s/^slice[[:space:]].*/slice            $bad/"
done

profile_reject() { # DESCRIPTION PATTERN SED-PROGRAM
    local t
    t=$(fixture)
    sed -i -e "$3" "$t/ci/profiles/synthetic.conf"
    expect_reject "$1" "$2" fabric_validate_fleet "$t/ci"
    rm -rf "$t"
}

# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
profile_reject 'a label with a shell metacharacter is rejected' \
    "invalid runner-label 'x;id'" '$a runner-label     x;id'
# shellcheck disable=SC2016 # a sed script: \$a is sed's, not the shell's
profile_reject 'a label with a comma is rejected' \
    "invalid runner-label 'a,b'" '$a runner-label     a,b'
profile_reject 'a runner name that reads as an option is rejected' \
    "invalid runner-name '-lab-01'" 's/^runner-name[[:space:]].*/runner-name      -lab-01/'
profile_reject 'a runner name longer than GitHub allows is rejected' \
    "invalid runner-name" "s/^runner-name[[:space:]].*/runner-name      $(printf 'a%.0s' {1..65})/"
profile_reject 'a repository that walks up a path is rejected' \
    "malformed runner-repo 'example-org/..'" 's#^runner-repo[[:space:]].*#runner-repo      example-org/..#'
profile_reject 'an owner that starts with a dot is rejected' \
    "malformed runner-repo '../synthetic'" 's#^runner-repo[[:space:]].*#runner-repo      ../synthetic#'

T=$(fixture)
long=runner-$(printf 'x%.0s' {1..30})
sed -i -e "s/runner-synthetic/$long/g" -e "s/ci-synthetic/ci-$long/" "$T/ci/profiles/synthetic.conf"
expect_reject 'an account name useradd would refuse is rejected' \
    "is longer than the 32 characters useradd accepts" fabric_validate_fleet "$T/ci"
rm -rf "$T"

T=$(fixture)
ln -s "$T/ci/profiles/synthetic.conf" "$T/ci/profiles/linked.conf"
expect_reject 'a symlinked profile is rejected, not skipped' \
    'not a regular file' fabric_validate_fleet "$T/ci"
rm -rf "$T"

echo
echo '== source immutability =='

AFTER_SHA="$(
    {
        sha256sum "$CI_DIR"/profiles/*.conf
        sha256sum "$CI_DIR/runner-release.conf" "$CI_DIR/fabric.conf"
    } | sha256sum | awk '{print $1}'
)"

if [ "$BASE_SHA" = "$AFTER_SHA" ]; then
    pass 'the drill did not mutate tracked fabric inputs'
else
    fail 'the drill mutated tracked fabric inputs'
fi

echo
printf 'result: %d passed, %d failed\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
