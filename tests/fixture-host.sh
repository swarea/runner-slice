# Shared fixture host for the drills that run the real scripts: command
# doubles, a fixture root the library is pointed at, and the assertions.
# Sourced; expects ROOT and T to be set.
#
# shellcheck shell=bash

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Command doubles, shared by every fixture host
# ---------------------------------------------------------------------------
BIN="$T/bin"
mkdir -p "$BIN"

cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
# State: $FAKE/enabled and $FAKE/active list units; mutations are logged.
set -u
listed() { grep -Fqx -- "$2" "$FAKE/$1" 2>/dev/null; }
drop()   { grep -Fxv -- "$2" "$FAKE/$1" > "$FAKE/$1.new" 2>/dev/null; mv "$FAKE/$1.new" "$FAKE/$1"; }
start() {
    listed active "$1" || echo "$1" >> "$FAKE/active"
    mkdir -p "$FAKE_CG/ci.slice/$1" "$FAKE_PROC/4000"
    printf '%s\0' /runner/bin/Runner.Listener run > "$FAKE_PROC/4000/cmdline"
    printf 'Name:\tRunner.Listener\nUid:\t0\t0\t0\t0\n' > "$FAKE_PROC/4000/status"
    echo 4000 > "$FAKE_CG/ci.slice/$1/cgroup.procs"
}
stop() { drop active "$1"; rm -rf "${FAKE_CG:?}/ci.slice/$1"; }
cmd=$1; shift
case "$cmd" in
    show)       # UNIT -p PROPERTY --value
        if [ "$3" = ControlGroup ]; then
            if listed active "$1"; then echo "/ci.slice/$1"; else echo; fi
        elif [ -e "$FAKE/props/$1/$3" ]; then
            cat "$FAKE/props/$1/$3"
        else
            echo
        fi ;;
    is-enabled) if listed enabled "$1"; then echo enabled; else echo disabled; fi ;;
    is-active)  [ "$1" = --quiet ] && shift; listed active "$1"; exit ;;
    daemon-reload) echo daemon-reload >> "$FAKE/systemctl.log" ;;
    enable)     # --now UNIT
        u=${*: -1}; echo "enable $u" >> "$FAKE/systemctl.log"
        listed enabled "$u" || echo "$u" >> "$FAKE/enabled"; start "$u" ;;
    disable)
        u=${*: -1}; echo "disable $u" >> "$FAKE/systemctl.log"
        drop enabled "$u"; stop "$u" ;;
    restart)    echo "restart $1" >> "$FAKE/systemctl.log" ;;
    *) echo "unexpected systemctl $cmd $*" >&2; exit 97 ;;
esac
exit 0
EOF

cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
out=
while [ "$#" -gt 0 ]; do
    case "$1" in -o) out=$2; shift 2 ;; https://*) echo "$1" >> "$FAKE/curl.log"; shift ;; *) shift ;; esac
done
cp "$FAKE_ARCHIVE" "$out"
EOF

cat > "$BIN/dpkg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -s ] && grep -Fqx -- "$2" "$FAKE/packages" 2>/dev/null
EOF

cat > "$BIN/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$FAKE/apt.log"
echo "${*: -1}" >> "$FAKE/packages"
EOF

cat > "$BIN/chown" <<'EOF'
#!/usr/bin/env bash
echo "chown $*" >> "$FAKE/chown.log"
EOF

# Accounts exist when the fixture recorded them; groups come from a file.
cat > "$BIN/getent" <<'EOF'
#!/usr/bin/env bash
[ -e "$FAKE/user-$2" ] || exit 2
echo "$2:x:999:999::/home/$2:/bin/bash"
EOF

cat > "$BIN/id" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -nG ]; then
    cat "$FAKE/groups-$2" 2>/dev/null || echo "$2"
    exit 0
fi
exec /usr/bin/id "$@"
EOF

# Processes are read from the fixture's /proc, never from pgrep. This pgrep
# fails the way a broken one does -- nothing printed, exit 3 -- so a script
# that still trusted it would read "no process" and go ahead.
cat > "$BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF

cat > "$BIN/runuser" <<'EOF'
#!/usr/bin/env bash
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do shift; done
shift
exec "$@"
EOF
# tar is the real one. Right after it extracts, the mode of the directory it
# extracted into is recorded: the window before RunnerSlice's own chmod.
cat > "$BIN/tar" <<'EOF'
#!/usr/bin/env bash
/usr/bin/tar "$@" || exit
dir=
while [ "$#" -gt 0 ]; do [ "$1" = -C ] && dir=$2; shift; done
[ -n "$dir" ] && [ -n "${FAKE-}" ] && stat -c %a "$dir" >> "$FAKE/tar-dir-mode"
exit 0
EOF
chmod +x "$BIN"/*

# A release archive with the runner's shape and none of its content.
PAYLOAD="$T/payload"
mkdir -p "$PAYLOAD/bin"
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/config.sh"
# The runner binary only leaves a trace: nothing RunnerSlice runs as root may
# execute it. Its version is data, in the dependency manifest beside it.
# shellcheck disable=SC2016 # the fake runner expands this when it runs
printf '#!/bin/sh\necho executed >> "$FAKE/listener-executed"\necho 2.338.0\n' > "$PAYLOAD/bin/Runner.Listener"
printf '{"runtimeTarget": {"name": ".NETCoreApp,Version=v8.0/linux-x64"}, "libraries": {"Runner.Listener/2.338.0": {"type": "project"}, "Runner.Common/1.0.0": {"type": "project"}}}\n' \
    > "$PAYLOAD/bin/Runner.Listener.deps.json"
printf '#!/bin/sh\nexit 0\n' > "$PAYLOAD/bin/runsvc.sh"
chmod +x "$PAYLOAD/config.sh" "$PAYLOAD/bin/"*
# The official archive's "." entry is 0775; so is this one's.
chmod 0775 "$PAYLOAD"
ARCHIVE="$T/actions-runner-linux-x64-2.338.0.tar.gz"
tar -czf "$ARCHIVE" -C "$PAYLOAD" .

# ---------------------------------------------------------------------------
# Fixture host
# ---------------------------------------------------------------------------
# new_host NAME   builds $T/NAME and points H at it
new_host() {
    H="$T/$1"
    mkdir -p "$H/root" "$H/cg" "$H/proc/1" "$H/fake"
    printf 'Name:\tsystemd\nUid:\t0\t0\t0\t0\n' > "$H/proc/1/status"
    cp -a "$ROOT/fabric" "$H/fabric"
    cp -a "$ROOT/examples/basic/." "$H/config/"
    : > "$H/fake/enabled"; : > "$H/fake/active"; : > "$H/fake/systemctl.log"
    : > "$H/fake/curl.log"; : > "$H/fake/apt.log"; : > "$H/fake/chown.log"

    sed -i \
        -e "s/^runner-sha256 .*/runner-sha256    $(sha256sum "$ARCHIVE" | cut -d' ' -f1)/" \
        -e "s/^runner-bytes .*/runner-bytes     $(stat -c %s "$ARCHIVE")/" \
        "$H/config/runner-release.conf"
    echo 'apt-dependency   libfixture1' >> "$H/config/runner-release.conf"

    local lib="$H/fabric/host-lib.sh" var
    for var in HOST_ROOT CGROUP_ROOT PROC_ROOT; do
        [ "$(grep -c "^$var=" "$lib")" -eq 1 ] || { echo "fixture: $var is not assigned once" >&2; exit 1; }
    done
    sed -i \
        -e "s#^HOST_ROOT=.*#HOST_ROOT=\"$H/root\"#" \
        -e "s#^CGROUP_ROOT=.*#CGROUP_ROOT=\"$H/cg\"#" \
        -e "s#^PROC_ROOT=.*#PROC_ROOT=\"$H/proc\"#" \
        "$lib"
    cat >> "$lib" <<EOF

# --- fixture host: accounts and ownership are recorded, not made ---
host_preflight() { step "preflight"; ok "fixture host"; }
host_ensure_user() {
    # A person's account of that name: the real function refuses it (its
    # cases are in the host drill); what matters here is what apply does next.
    if [ -e "$H/fake/human-\$1" ]; then
        fail "account \$1 exists and is not a RunnerSlice system account; refusing to adopt it"
        return 1
    fi
    if [ -e "$H/fake/user-\$1" ]; then ok "fixture user \$1"; return 0; fi
    change "fixture user \$1"
    [ "\$CHECK_ONLY" -eq 0 ] && : > "$H/fake/user-\$1"
    return 0
}
host_remove_user() {
    if [ -e "$H/fake/user-\$1" ]; then
        change "remove fixture user \$1"
        [ "\$CHECK_ONLY" -eq 0 ] || return 0
        if [ -e "$H/fake/userdel-fails" ]; then
            fail "userdel could not remove \$1 (exit 8); the account is still there"
            return 1
        fi
        rm -f "$H/fake/user-\$1"
    else
        ok "fixture user \$1 is absent"
    fi
    return 0
}
host_ensure_dir() {
    if [ -d "\$1" ]; then ok "fixture dir \$1"; return 1; fi
    change "fixture dir \$1"
    if [ "\$CHECK_ONLY" -eq 0 ]; then
        install -d -m "\$4" "\$1"
        echo "\$2:\$3 \${4#0}" > "\$1.owner"
    fi
    return 0
}
# Ownership as recorded beside a path, since the drill cannot chown.
host_owner_mode() {
    if [ -e "\$1.owner" ]; then cat "\$1.owner"; else stat -c '%U:%G %a' "\$1"; fi
}
EOF
}

apply() { # ARGS...   sets OUT and RC
    RC=0
    OUT=$(env PATH="$BIN:$PATH" FAKE="$H/fake" FAKE_CG="$H/cg" FAKE_PROC="$H/proc" \
              FAKE_ARCHIVE="$ARCHIVE" \
              bash "$H/fabric/fabric-apply.sh" --config "$H/config" "$@" 2>&1) || RC=$?
}

# Everything a pass could change: the fixture root, the fake systemd and
# package state, and the logs of every mutating command.
snapshot() {
    (cd "$H" && find root fake cg -printf '%y %p %s\n' | sort
     cat fake/enabled fake/active fake/systemctl.log fake/curl.log fake/apt.log)
}

register() { # ID   what config.sh would leave behind
    local d="$H/root/var/lib/ci-$1/runner" f profile="$H/config/profiles/$1.conf"
    printf '\xef\xbb\xbf{"agentId": 7, "agentName": "%s", "poolId": 1, "poolName": "Default", "serverUrl": "https://pipelines.example.invalid/", "gitHubUrl": "https://github.com/%s", "workFolder": "%s"}' \
        "$(awk '$1 == "runner-name" { print $2 }' "$profile")" \
        "$(awk '$1 == "runner-repo" { print $2 }' "$profile")" \
        "$(awk '$1 == "work-dir" { print $2 }' "$profile")" > "$d/.runner"
    : > "$d/.credentials"
    for f in .runner .credentials; do
        echo "runner-$1:runner-$1 600" > "$d/$f.owner"
    done
}
busy() { # SERVICE
    mkdir -p "$H/proc/4100"
    printf '%s\0' /runner/bin/Runner.Worker spawnclient > "$H/proc/4100/cmdline"
    echo 4100 >> "$H/cg/ci.slice/$1/cgroup.procs"
}
idle() { # SERVICE
    echo 4000 > "$H/cg/ci.slice/$1/cgroup.procs"
}
only() { # ID...   reduce the fixture inventory to these profiles
    local f keep
    for f in "$H/config/profiles/"*.conf; do
        keep=0
        for id in "$@"; do [ "$(basename "$f" .conf)" = "$id" ] && keep=1; done
        [ "$keep" -eq 1 ] || rm -f "$f"
    done
    # A pool's lines must go with its last member, or validation refuses.
    if [ ! -e "$H/config/profiles/web-2.conf" ] && [ -e "$H/config/profiles/web.conf" ]; then
        sed -i '/^runner-pool/d' "$H/config/profiles/web.conf"
    fi
}

expect_rc()  { if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 (rc=$RC, want $2)"; printf '%s\n' "$OUT" | tail -15 >&2; fi; }
expect_out() { if grep -Fq -- "$2" <<<"$OUT"; then pass "$1"; else fail "$1 (no '$2')"; printf '%s\n' "$OUT" | tail -15 >&2; fi; }
expect_no()  { if grep -Fq -- "$2" <<<"$OUT"; then fail "$1 (found '$2')"; else pass "$1"; fi; }
expect_lines() { # DESCRIPTION FILE WANT
    local got; got=$(grep -c . "$2" 2>/dev/null) || got=0
    if [ "$got" -eq "$3" ]; then pass "$1"; else fail "$1 ($2 has $got lines, want $3)"; cat "$2" >&2; fi
}
expect_same() { # DESCRIPTION BEFORE
    if [ "$2" = "$(snapshot)" ]; then pass "$1"; else fail "$1"; diff <(printf '%s\n' "$2") <(snapshot) | head -20 >&2; fi
}

# shellcheck disable=SC2034 # used by the drills that source this file
UNITS=root/etc/systemd/system

holds()   { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }
refutes() { local d=$1; shift; if "$@"; then fail "$d"; else pass "$d"; fi; }

# is_rendered FILE (slice | PROFILE-ID)   FILE is what the library renders now
is_rendered() {
    local want
    if [ "$2" = slice ]; then
        want=$(bash -c '. "$1/fabric/fabric-lib.sh"; fabric_render_slice "$2"' _ "$ROOT" "$H/config")
    else
        want=$(bash -c '. "$1/fabric/fabric-lib.sh"; fabric_render_service "$2" "$2/profiles/$3.conf"' \
                   _ "$ROOT" "$H/config" "$2")
    fi
    [ -f "$1" ] && [ "$(cat "$1")" = "$want" ]
}
