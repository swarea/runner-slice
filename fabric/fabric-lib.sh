#!/usr/bin/env bash
#
# Offline primitives for runner-fabric: validation, mask derivation and unit
# rendering for a declared inventory of GitHub Actions runners.
#
# Nothing in this file requires root, GitHub access, registration credentials
# or live host state.

# ---------------------------------------------------------------------------
# Reading configuration, and why there is a cache
# ---------------------------------------------------------------------------
#
# Validating the fleet asks dozens of questions of each of a handful of small
# files, and each question used to be its own awk process. That is most of what
# a validation costs, and the bootstrap validates once per runner per pass.
#
# So the three entry points that ask many questions -- fleet validation,
# expected masks and service rendering -- read every file under the CI
# directory ONCE, eagerly and in the calling shell, and answer from memory
# until they return. Eagerly, because callers ask from inside $(...), and a
# subshell that filled a cache would throw it away. Scoped to the call, so
# nothing is answered from a cache across calls: a fixture rewritten between
# two validations is read afresh by the second. A file outside the loaded
# directory falls through to the original awk, so the answers are the same
# either way -- fabric-drill.sh asserts that for every key of every file.

declare -gA FABRIC_KV=()
declare -gA FABRIC_KC=()
declare -gA FABRIC_LOADED=()
FABRIC_CACHE_DEPTH=0

fabric_cache_begin() {
    local ci_dir=$1 file key value
    FABRIC_CACHE_DEPTH=$((FABRIC_CACHE_DEPTH + 1))
    [ "$FABRIC_CACHE_DEPTH" -eq 1 ] || return 0
    local -a files=()
    mapfile -t files < <(
        fabric_profiles "$ci_dir" 2>/dev/null
        for file in "$ci_dir/fabric.conf" "$ci_dir/runner-release.conf"; do
            [ -f "$file" ] && printf '%s\n' "$file"
        done
    )
    [ "${#files[@]}" -gt 0 ] || return 0
    for file in "${files[@]}"; do FABRIC_LOADED[$file]=1; done
    # One awk for every file. The value transformation is the original one
    # byte for byte: blanking $1 rebuilds the record with single spaces.
    while IFS=$'\t' read -r file key value; do
        if [ -n "${FABRIC_KC[$file$'\x1f'$key]+x}" ]; then
            FABRIC_KV[$file$'\x1f'$key]+=$'\n'"$value"
            FABRIC_KC[$file$'\x1f'$key]=$((FABRIC_KC[$file$'\x1f'$key] + 1))
        else
            FABRIC_KV[$file$'\x1f'$key]=$value
            FABRIC_KC[$file$'\x1f'$key]=1
        fi
    done < <(
        awk '
            /^[[:space:]]*#/ || NF == 0 { next }
            {
                k = $1
                $1 = ""
                sub(/^[[:space:]]+/, "")
                printf "%s\t%s\t%s\n", FILENAME, k, $0
            }
        ' "${files[@]}"
    )
}

fabric_cache_end() {
    FABRIC_CACHE_DEPTH=$((FABRIC_CACHE_DEPTH - 1))
    if [ "$FABRIC_CACHE_DEPTH" -le 0 ]; then
        FABRIC_CACHE_DEPTH=0
        FABRIC_KV=()
        FABRIC_KC=()
        FABRIC_LOADED=()
    fi
}

fabric_values() {
    local file=$1 key=$2
    if [ "$FABRIC_CACHE_DEPTH" -gt 0 ] && [ -n "${FABRIC_LOADED[$file]+x}" ]; then
        [ -n "${FABRIC_KC[$file$'\x1f'$key]+x}" ] &&
            printf '%s\n' "${FABRIC_KV[$file$'\x1f'$key]}"
        return 0
    fi
    awk -v k="$key" '
        /^[[:space:]]*#/ || NF == 0 { next }
        $1 == k {
            $1=""
            sub(/^[[:space:]]+/, "")
            print
        }
    ' "$file"
}

fabric_value() {
    local file=$1 key=$2
    if [ "$FABRIC_CACHE_DEPTH" -gt 0 ] && [ -n "${FABRIC_LOADED[$file]+x}" ]; then
        [ -n "${FABRIC_KC[$file$'\x1f'$key]+x}" ] &&
            printf '%s\n' "${FABRIC_KV[$file$'\x1f'$key]%%$'\n'*}"
        return 0
    fi
    fabric_values "$file" "$key" | head -1
}

fabric_key_count() {
    local file=$1 key=$2
    if [ "$FABRIC_CACHE_DEPTH" -gt 0 ] && [ -n "${FABRIC_LOADED[$file]+x}" ]; then
        printf '%s\n' "${FABRIC_KC[$file$'\x1f'$key]-0}"
        return 0
    fi
    awk -v k="$key" '
        /^[[:space:]]*#/ || NF == 0 { next }
        $1 == k { n++ }
        END { print n+0 }
    ' "$file"
}

fabric_profiles() {
    local ci_dir=$1
    find "$ci_dir/profiles" \
        -maxdepth 1 \
        -type f \
        -name '*.conf' \
        -print |
        LC_ALL=C sort
}

fabric_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

# fabric_size_bytes SIZE   a systemd size (bytes, or K/M/G/T, base 1024)
fabric_size_bytes() {
    local size=$1
    case "$size" in
        *K) echo $(( ${size%K} * 1024 )) ;;
        *M) echo $(( ${size%M} * 1024 * 1024 )) ;;
        *G) echo $(( ${size%G} * 1024 * 1024 * 1024 )) ;;
        *T) echo $(( ${size%T} * 1024 * 1024 * 1024 * 1024 )) ;;
        *)  echo "$size" ;;
    esac
}

# fabric_slice_ancestors SLICE   the slices above SLICE, outermost first
#
# A dash in a slice name is hierarchy: a-b.slice lives inside a.slice. An
# allow list on any of them is consulted before the slice's deny list, so the
# check has to look at every one.
fabric_slice_ancestors() {
    local name=${1%.slice} prefix="" part
    local -a parts=()
    IFS=- read -r -a parts <<<"$name"
    for part in "${parts[@]:0:${#parts[@]}-1}"; do
        prefix=${prefix:+$prefix-}$part
        printf '%s.slice\n' "$prefix"
    done
}

fabric_validate_release() {
    local ci_dir=$1
    local file="$ci_dir/runner-release.conf"
    local failed=0 key count value

    [ -r "$file" ] || {
        fabric_error "missing $file"
        return 1
    }

    local required=(
        runner-version
        runner-platform
        runner-archive
        runner-bytes
        runner-sha256
        runner-url
    )

    # apt-dependency may appear any number of times: which packages the
    # runner's .NET runtime needs depends on the distribution release.
    for key in "${required[@]}"; do
        count=$(fabric_key_count "$file" "$key")
        if [ "$count" -ne 1 ]; then
            fabric_error "$file: $key must appear exactly once (got $count)"
            failed=1
        fi
    done

    while read -r key _; do
        [ -n "${key:-}" ] || continue
        case "$key" in
            runner-version|runner-platform|runner-archive|runner-bytes|runner-sha256|runner-url|apt-dependency)
                ;;
            *)
                fabric_error "$file: unknown release key $key"
                failed=1
                ;;
        esac
    done < <(
        awk '
            /^[[:space:]]*#/ || NF == 0 { next }
            { print $1, $2 }
        ' "$file"
    )

    value=$(fabric_value "$file" runner-bytes)
    case "$value" in
        ''|*[!0-9]*)
            fabric_error "$file: runner-bytes is not numeric"
            failed=1
            ;;
    esac

    value=$(fabric_value "$file" runner-sha256)
    if ! [[ "$value" =~ ^[0-9a-f]{64}$ ]]; then
        fabric_error "$file: runner-sha256 is not a lowercase SHA-256"
        failed=1
    fi

    value=$(fabric_value "$file" runner-url)
    if ! [[ "$value" =~ ^https://github\.com/actions/runner/releases/download/ ]]; then
        fabric_error "$file: runner-url is outside the expected GitHub runner release path"
        failed=1
    fi

    # A seed is one platform's archive. Version, platform, archive name and
    # URL must describe the same file, or a seed for one architecture could be
    # installed on another.
    local version platform archive
    version=$(fabric_value "$file" runner-version)
    platform=$(fabric_value "$file" runner-platform)
    archive=$(fabric_value "$file" runner-archive)
    case "$platform" in
        linux-x64|linux-arm64) ;;
        *)
            fabric_error "$file: unsupported runner-platform '$platform'"
            failed=1
            ;;
    esac
    [ "$archive" = "actions-runner-$platform-$version.tar.gz" ] || {
        fabric_error "$file: runner-archive '$archive' does not match platform $platform and version $version"
        failed=1
    }
    [ "$value" = "https://github.com/actions/runner/releases/download/v$version/$archive" ] || {
        fabric_error "$file: runner-url does not name v$version/$archive"
        failed=1
    }

    return "$failed"
}

fabric_validate_policy() {
    local ci_dir=$1
    local file="$ci_dir/fabric.conf"
    local failed=0 key

    [ -r "$file" ] || {
        fabric_error "missing $file"
        return 1
    }

    while read -r key _; do
        [ -n "${key:-}" ] || continue
        case "$key" in
            resource-class|sandbox-class|common-mask|slice|name-prefix|user-prefix|host-label|protected-path|host-name)
                ;;
            slice-cpu-quota|slice-memory-max|slice-memory-high|slice-tasks-max|slice-cpu-weight|slice-ip-deny)
                ;;
            *)
                fabric_error "$file: unknown policy key $key"
                failed=1
                ;;
        esac
    done < <(
        awk '
            /^[[:space:]]*#/ || NF == 0 { next }
            { print $1, $2 }
        ' "$file"
    )

    # Naming is declared, not assumed: the slice every runner joins, the
    # prefix of each runner's unit and runtime root, the prefix of each
    # runner's account, and the label that selects this host.
    local single
    for single in slice name-prefix user-prefix host-label; do
        if [ "$(fabric_key_count "$file" "$single")" -ne 1 ]; then
            fabric_error "$file: $single must appear exactly once (got $(fabric_key_count "$file" "$single"))"
            failed=1
        fi
    done
    [[ "$(fabric_value "$file" slice)" =~ ^[a-z0-9][a-z0-9-]*\.slice$ ]] || {
        fabric_error "$file: slice must be a systemd slice name such as ci.slice"
        failed=1
    }
    [[ "$(fabric_value "$file" name-prefix)" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || {
        fabric_error "$file: invalid name-prefix '$(fabric_value "$file" name-prefix)'"
        failed=1
    }
    [[ "$(fabric_value "$file" user-prefix)" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || {
        fabric_error "$file: invalid user-prefix '$(fabric_value "$file" user-prefix)'"
        failed=1
    }
    [[ "$(fabric_value "$file" host-label)" =~ ^[A-Za-z0-9._-]+$ ]] || {
        fabric_error "$file: invalid host-label '$(fabric_value "$file" host-label)'"
        failed=1
    }

    # Optional: the hostname this configuration is for, so applying it on
    # the wrong machine is refused before anything changes.
    if [ "$(fabric_key_count "$file" host-name)" -gt 1 ]; then
        fabric_error "$file: host-name may appear at most once"
        failed=1
    elif [ "$(fabric_key_count "$file" host-name)" -eq 1 ] &&
         ! [[ "$(fabric_value "$file" host-name)" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        fabric_error "$file: invalid host-name '$(fabric_value "$file" host-name)'"
        failed=1
    fi

    # The slice's limits are the ceiling every runner shares. There are no
    # defaults: a number that suits one host starves or overcommits another,
    # so each host declares its own.
    for single in slice-cpu-quota slice-memory-max slice-tasks-max; do
        if [ "$(fabric_key_count "$file" "$single")" -ne 1 ]; then
            fabric_error "$file: $single must appear exactly once (got $(fabric_key_count "$file" "$single"))"
            failed=1
        fi
    done
    for single in slice-memory-high slice-cpu-weight; do
        if [ "$(fabric_key_count "$file" "$single")" -gt 1 ]; then
            fabric_error "$file: $single may appear at most once"
            failed=1
        fi
    done
    local quota mem_max mem_high tasks weight addr
    quota=$(fabric_value "$file" slice-cpu-quota)
    mem_max=$(fabric_value "$file" slice-memory-max)
    mem_high=$(fabric_value "$file" slice-memory-high)
    tasks=$(fabric_value "$file" slice-tasks-max)
    weight=$(fabric_value "$file" slice-cpu-weight)
    [[ "$quota" =~ ^[1-9][0-9]*%$ ]] || {
        fabric_error "$file: slice-cpu-quota '$quota' must be a percentage such as 150%"
        failed=1
    }
    [[ "$mem_max" =~ ^[1-9][0-9]*[KMGT]?$ ]] || {
        fabric_error "$file: slice-memory-max '$mem_max' must be bytes or a K/M/G/T size"
        failed=1
    }
    if [ -n "$mem_high" ]; then
        if ! [[ "$mem_high" =~ ^[1-9][0-9]*[KMGT]?$ ]]; then
            fabric_error "$file: slice-memory-high '$mem_high' must be bytes or a K/M/G/T size"
            failed=1
        elif [[ "$mem_max" =~ ^[1-9][0-9]*[KMGT]?$ ]] &&
             [ "$(fabric_size_bytes "$mem_high")" -gt "$(fabric_size_bytes "$mem_max")" ]; then
            fabric_error "$file: slice-memory-high $mem_high is above slice-memory-max $mem_max"
            failed=1
        fi
    fi
    [[ "$tasks" =~ ^[1-9][0-9]*$ ]] || {
        fabric_error "$file: slice-tasks-max '$tasks' must be a positive integer"
        failed=1
    }
    if [ -n "$weight" ] &&
       ! { [[ "$weight" =~ ^[1-9][0-9]*$ ]] && [ "$weight" -le 10000 ]; }; then
        fabric_error "$file: slice-cpu-weight '$weight' must be 1 to 10000"
        failed=1
    fi
    while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        [[ "$addr" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || {
            fabric_error "$file: slice-ip-deny '$addr' is not an address or prefix"
            failed=1
        }
    done < <(fabric_values "$file" slice-ip-deny)

    # A protected path is one the runner accounts must not be able to read
    # even outside their service, for example from a login shell. The check
    # proves it; nothing here changes permissions.
    local protected
    while IFS= read -r protected; do
        [ -n "$protected" ] || continue
        [[ "$protected" =~ ^/[^[:space:]]*$ ]] || {
            fabric_error "$file: protected-path '$protected' must be an absolute path"
            failed=1
        }
    done < <(fabric_values "$file" protected-path)

    # Only the Docker socket is mandatory everywhere: access to it is root on
    # the host. Which other paths a runner must not see is the operator's
    # declaration, as further common-mask lines.
    local mandatory_masks=(
        -/run/docker.sock
        -/var/run/docker.sock
    )

    local mask
    for mask in "${mandatory_masks[@]}"; do
        if ! grep -Fxq -- "$mask" <<<"$(fabric_values "$file" common-mask)"; then
            fabric_error "$file: mandatory common-mask missing: $mask"
            failed=1
        fi
    done

    [ "$(fabric_key_count "$file" resource-class)" -gt 0 ] || {
        fabric_error "$file: no resource-class is defined"
        failed=1
    }

    [ "$(fabric_key_count "$file" sandbox-class)" -gt 0 ] || {
        fabric_error "$file: no sandbox-class is defined"
        failed=1
    }

    return "$failed"
}

fabric_validate_profile() {
    local ci_dir=$1 file=$2
    local failed=0 key count
    local id repo name user home service install runner work resource sandbox

    local required=(
        profile-id
        runner-repo
        runner-name
        runner-user
        runner-home
        runner-service
        install-root
        runner-dir
        work-dir
        resource-class
        sandbox-class
    )

    for key in "${required[@]}"; do
        count=$(fabric_key_count "$file" "$key")
        if [ "$count" -ne 1 ]; then
            fabric_error "$file: $key must appear exactly once (got $count)"
            failed=1
        fi
    done

    if [ "$(fabric_key_count "$file" runner-pool)" -gt 1 ]; then
        fabric_error "$file: runner-pool may appear at most once"
        failed=1
    fi

    if [ "$(fabric_key_count "$file" runner-label)" -lt 2 ]; then
        fabric_error "$file: at least two explicit runner-label values are required"
        failed=1
    fi

    while read -r key _; do
        [ -n "${key:-}" ] || continue

        case "$key" in
            profile-id|runner-repo|runner-name|runner-user|runner-home|runner-service|runner-label|runner-pool|install-root|runner-dir|work-dir|resource-class|sandbox-class)
                ;;
            runner-version|runner-platform|runner-archive|runner-bytes|runner-sha256|runner-url|apt-dependency)
                fabric_error "$file: profile-local release key forbidden: $key"
                failed=1
                ;;
            *token*|*credential*|*secret*|*password*|*private-key*)
                fabric_error "$file: secret-bearing profile key forbidden: $key"
                failed=1
                ;;
            *)
                fabric_error "$file: unknown profile key $key"
                failed=1
                ;;
        esac
    done < <(
        awk '
            /^[[:space:]]*#/ || NF == 0 { next }
            { print $1, $2 }
        ' "$file"
    )

    # Do not attempt semantic checks with incomplete required fields.
    [ "$failed" -eq 0 ] || return 1

    id=$(fabric_value "$file" profile-id)
    repo=$(fabric_value "$file" runner-repo)
    name=$(fabric_value "$file" runner-name)
    user=$(fabric_value "$file" runner-user)
    home=$(fabric_value "$file" runner-home)
    service=$(fabric_value "$file" runner-service)
    install=$(fabric_value "$file" install-root)
    runner=$(fabric_value "$file" runner-dir)
    work=$(fabric_value "$file" work-dir)
    resource=$(fabric_value "$file" resource-class)
    sandbox=$(fabric_value "$file" sandbox-class)

    local basename
    basename=$(basename "$file" .conf)

    [ "$id" = "$basename" ] || {
        fabric_error "$file: profile-id '$id' does not match filename '$basename'"
        failed=1
    }

    [[ "$id" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
        fabric_error "$file: invalid profile-id '$id'"
        failed=1
    }

    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
        fabric_error "$file: malformed runner-repo '$repo'"
        failed=1
    }

    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || {
        fabric_error "$file: invalid runner-name '$name'"
        failed=1
    }

    local policy="$ci_dir/fabric.conf" user_prefix name_prefix host_label
    user_prefix=$(fabric_value "$policy" user-prefix)
    name_prefix=$(fabric_value "$policy" name-prefix)
    host_label=$(fabric_value "$policy" host-label)
    [[ "$user" =~ ^${user_prefix}(-[a-z0-9][a-z0-9-]*)?$ ]] || {
        fabric_error "$file: invalid runner-user '$user'"
        failed=1
    }

    [ "$home" = "/home/$user" ] || {
        fabric_error "$file: runner-home '$home' must be /home/$user"
        failed=1
    }

    [[ "$service" =~ ^${name_prefix}(-[a-z0-9-]+)?-runner\.service$ ]] || {
        fabric_error "$file: invalid runner-service '$service'"
        failed=1
    }

    [[ "$install" =~ ^/var/lib/${name_prefix}(-[a-z0-9-]+)?$ ]] || {
        fabric_error "$file: invalid install-root '$install'"
        failed=1
    }

    [ "$runner" = "$install/runner" ] || {
        fabric_error "$file: runner-dir must be $install/runner"
        failed=1
    }

    [ "$work" = "$install/work" ] || {
        fabric_error "$file: work-dir must be $install/work"
        failed=1
    }

    grep -Fxq -- "$resource" <<<"$(fabric_values "$ci_dir/fabric.conf" resource-class)" || {
            fabric_error "$file: unsupported resource-class '$resource'"
            failed=1
        }

    grep -Fxq -- "$sandbox" <<<"$(fabric_values "$ci_dir/fabric.conf" sandbox-class)" || {
            fabric_error "$file: unsupported sandbox-class '$sandbox'"
            failed=1
        }

    # Every membership test here reads its producer to completion through a
    # herestring. As a pipeline, `grep -q` exits on the first match and a
    # producer still writing is killed by SIGPIPE, which pipefail reports as a
    # failed match. The cached reader writes one line at a time, so that race
    # was real: about one validation in four hundred refused a valid profile.
    grep -Fxq -- "$host_label" <<<"$(fabric_values "$file" runner-label)" || {
        fabric_error "$file: runner-label $host_label is required"
        failed=1
    }

    grep -Fxq -- "$id" <<<"$(fabric_values "$file" runner-label)" || {
        fabric_error "$file: runner-label $id is required"
        failed=1
    }

    # A pool is the deliberate form of "more than one runner for one
    # repository". Its name is the label workflows select, and its members are
    # named after it, so a member can be told from an accidental copy by its
    # file name alone: the pool's first runner is the profile named for the
    # pool, and the others are <pool>-<n>.
    local pool
    pool=$(fabric_value "$file" runner-pool)
    if [ -n "$pool" ]; then
        [[ "$pool" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
            fabric_error "$file: invalid runner-pool '$pool'"
            failed=1
        }
        [ "$id" = "$pool" ] || [[ "$id" =~ ^${pool}-[2-9]$ ]] || {
            fabric_error "$file: profile-id '$id' is not a member name of runner-pool '$pool' (expected $pool or $pool-<2..9>)"
            failed=1
        }
        grep -Fxq -- "$pool" <<<"$(fabric_values "$file" runner-label)" || {
            fabric_error "$file: runner-label $pool is required by runner-pool $pool"
            failed=1
        }
    fi

    return "$failed"
}

# The label set a pool member offers to jobs, with its own member label taken
# out and the pool label put in. Every member of one pool must offer the same
# set, or a job could be routed to one member that another could not take.
fabric_pool_labels() {
    local file=$1 id pool
    id=$(fabric_value "$file" profile-id)
    pool=$(fabric_value "$file" runner-pool)
    {
        fabric_values "$file" runner-label | grep -Fxv -- "$id"
        printf '%s\n' "$pool"
    } | awk 'NF && !seen[$0]++' | sort | paste -sd, -
}

fabric_validate_fleet() {
    fabric_cache_begin "$1"
    local _fabric_rc=0
    _fabric_validate_fleet "$@" || _fabric_rc=$?
    fabric_cache_end
    return "$_fabric_rc"
}

_fabric_validate_fleet() {
    local ci_dir=$1
    local failed=0 file
    local -a profiles=()

    fabric_validate_release "$ci_dir" || failed=1
    fabric_validate_policy "$ci_dir" || failed=1

    mapfile -t profiles < <(fabric_profiles "$ci_dir")

    [ "${#profiles[@]}" -gt 0 ] || {
        fabric_error "$ci_dir: no runner profiles found"
        return 1
    }

    for file in "${profiles[@]}"; do
        fabric_validate_profile "$ci_dir" "$file" || failed=1
    done

    [ "$failed" -eq 0 ] || return 1

    local -A seen_repo=()
    local -A seen_pool_repo=()

    # Reached only through the nameref below.
    # shellcheck disable=SC2034
    local -A seen_id=() seen_name=() seen_user=() seen_home=() \
        seen_service=() seen_install=() seen_runner=() seen_work=()

    local id repo name user home service install runner work value prior

    for file in "${profiles[@]}"; do
        id=$(fabric_value "$file" profile-id)
        repo=$(fabric_value "$file" runner-repo)
        name=$(fabric_value "$file" runner-name)
        user=$(fabric_value "$file" runner-user)
        home=$(fabric_value "$file" runner-home)
        service=$(fabric_value "$file" runner-service)
        install=$(fabric_value "$file" install-root)
        runner=$(fabric_value "$file" runner-dir)
        work=$(fabric_value "$file" work-dir)

        local pair
        for pair in \
            "profile-id|$id|seen_id" \
            "runner-name|$name|seen_name" \
            "runner-user|$user|seen_user" \
            "runner-home|$home|seen_home" \
            "runner-service|$service|seen_service" \
            "install-root|$install|seen_install" \
            "runner-dir|$runner|seen_runner" \
            "work-dir|$work|seen_work"
        do
            local kind mapname
            kind=${pair%%|*}
            pair=${pair#*|}
            value=${pair%%|*}
            mapname=${pair##*|}

            declare -n map="$mapname"

            prior=${map[$value]-}
            if [ -n "$prior" ]; then
                fabric_error "duplicate $kind '$value': $prior and $file"
                failed=1
            else
                map["$value"]=$file
            fi
        done
    done

    # Repository sharing. Without a pool, one repository has exactly one
    # profile, as before: a second profile for it is an accidental copy and is
    # refused with the same error it always was. With a pool, every profile of
    # that repository must declare the same pool and offer the same labels, and
    # a pool belongs to one repository. Every other identity above stays unique
    # across the whole fleet, pool or not, because a runner name, account, unit
    # or runtime root shared inside a pool is exactly as much a shared identity
    # as one shared between tenants -- and a shared runner name is worse, since
    # registration runs with --replace and would take over the other runner.
    local pool prior_pool prior_labels labels
    for file in "${profiles[@]}"; do
        repo=$(fabric_value "$file" runner-repo)
        pool=$(fabric_value "$file" runner-pool)
        prior=${seen_repo[$repo]-}

        if [ -n "$pool" ]; then
            prior_pool=${seen_pool_repo[$pool]-}
            if [ -n "$prior_pool" ] && [ "$prior_pool" != "$repo" ]; then
                fabric_error "runner-pool '$pool' spans repositories: $prior_pool and $repo ($file)"
                failed=1
            fi
            seen_pool_repo[$pool]=$repo
        fi

        if [ -z "$prior" ]; then
            seen_repo[$repo]=$file
            continue
        fi

        prior_pool=$(fabric_value "$prior" runner-pool)
        if [ -z "$pool" ] || [ -z "$prior_pool" ]; then
            fabric_error "duplicate runner-repo '$repo': $prior and $file (declare one runner-pool on every profile to run several runners for one repository)"
            failed=1
            continue
        fi
        if [ "$pool" != "$prior_pool" ]; then
            fabric_error "runner-repo '$repo' has profiles in different pools: $prior_pool ($prior) and $pool ($file)"
            failed=1
            continue
        fi
        prior_labels=$(fabric_pool_labels "$prior")
        labels=$(fabric_pool_labels "$file")
        if [ "$labels" != "$prior_labels" ]; then
            fabric_error "runner-pool '$pool' members offer different labels: $prior_labels ($prior) and $labels ($file)"
            failed=1
        fi
    done

    return "$failed"
}

fabric_peer_masks() {
    local ci_dir=$1 profile=$2
    local own_id peer peer_id

    own_id=$(fabric_value "$profile" profile-id)

    while IFS= read -r peer; do
        peer_id=$(fabric_value "$peer" profile-id)
        [ "$peer_id" = "$own_id" ] && continue

        # Peer runtime roots remain explicit derived masks because all runner
        # state lives under /var/lib rather than under a systemd-protected
        # home tree. Peer homes are deliberately absent here: ProtectHome=tmpfs
        # hides the whole home namespace by default, and the service binds
        # back only its own real home.
        fabric_value "$peer" install-root
    done < <(fabric_profiles "$ci_dir") |
        awk 'NF && !seen[$0]++' |
        sort
}

fabric_expected_masks() {
    fabric_cache_begin "$1"
    local _fabric_rc=0
    _fabric_expected_masks "$@" || _fabric_rc=$?
    fabric_cache_end
    return "$_fabric_rc"
}

_fabric_expected_masks() {
    local ci_dir=$1 profile=$2

    {
        fabric_values "$ci_dir/fabric.conf" common-mask
        fabric_peer_masks "$ci_dir" "$profile"
    } |
        awk 'NF && !seen[$0]++' |
        sort
}

fabric_validate_mask_file() {
    local ci_dir=$1 profile=$2 actual=$3
    local expected normalized
    local rc=0

    expected=$(mktemp)
    normalized=$(mktemp)
    trap 'rm -f "$expected" "$normalized"' RETURN

    fabric_expected_masks "$ci_dir" "$profile" > "$expected"

    awk 'NF && !seen[$0]++' "$actual" |
        sort > "$normalized"

    if ! diff -u "$expected" "$normalized"; then
        fabric_error "derived isolation mask set differs for $(fabric_value "$profile" profile-id)"
        rc=1
    fi

    rm -f "$expected" "$normalized"
    trap - RETURN

    return "$rc"
}

# ---------------------------------------------------------------------------
# Complete systemd service rendering
# ---------------------------------------------------------------------------

# fabric_render_service CI_DIR PROFILE_FILE
#
# Print the complete service contract for one already-validated profile.
# Nothing is installed. Peer isolation is derived from the whole fleet rather
# than copied into profiles by hand.
#
# Baseline deliberately preserves the current namespace behavior. The
# `userns` class records Infra's explicit need for unrestricted namespaces.
# Tightening the baseline namespace policy or switching homes to a stronger
# default-deny primitive is a separate security change to prove independently
# from adopting the renderer.
fabric_render_service() {
    fabric_cache_begin "$1"
    local _fabric_rc=0
    _fabric_render_service "$@" || _fabric_rc=$?
    fabric_cache_end
    return "$_fabric_rc"
}

_fabric_render_service() {
    local ci_dir=$1 profile=$2
    local repo user home service install runner sandbox platform slice

    slice=$(fabric_value "$ci_dir/fabric.conf" slice)
    repo=$(fabric_value "$profile" runner-repo)
    user=$(fabric_value "$profile" runner-user)
    home=$(fabric_value "$profile" runner-home)
    service=$(fabric_value "$profile" runner-service)
    install=$(fabric_value "$profile" install-root)
    runner=$(fabric_value "$profile" runner-dir)
    sandbox=$(fabric_value "$profile" sandbox-class)
    platform=$(fabric_value "$ci_dir/runner-release.conf" runner-platform)

    cat <<UNIT
[Unit]
Description=GitHub Actions self-hosted runner ($repo, $platform)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$user
Group=$user
Slice=$slice

WorkingDirectory=$runner
Environment=HOME=$home
Environment=RUNNER_MANUALLY_TRAP_SIG=1
Environment=ACTIONS_RUNNER_PRINT_LOG_TO_STDOUT=1

ExecStart=$runner/bin/runsvc.sh

Restart=always
RestartSec=15
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=5min

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=tmpfs
BindPaths=$home

ReadWritePaths=$install
ReadWritePaths=$home

UNIT

    while IFS= read -r mask; do
        [ -n "$mask" ] || continue
        printf 'InaccessiblePaths=%s\n' "$mask"
    done < <(fabric_expected_masks "$ci_dir" "$profile")

    cat <<'UNIT'

ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectClock=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
UNIT

    case "$sandbox" in
        baseline)
            # No namespaces for jobs: rootless containers, unshare and bwrap
            # need the userns class, chosen per profile (decision 0002).
            echo 'RestrictNamespaces=yes'
            ;;
        userns)
            echo 'RestrictNamespaces=no'
            ;;
        *)
            fabric_error "$profile: cannot render unknown sandbox-class '$sandbox'"
            return 1
            ;;
    esac

    cat <<'UNIT'
LockPersonality=yes
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT

    # `service` is intentionally read even though the unit body does not need
    # to repeat its own file name. Keeping it here makes an incomplete caller
    # fail while rendering rather than producing plausible output.
    [ -n "$service" ]
}

# fabric_render_slice CI_DIR
#
# The slice every runner joins, rendered from the policy. Accounting is always
# on so the check can read what the runners use.
fabric_render_slice() {
    local file="$1/fabric.conf" value

    cat <<'UNIT'
[Unit]
Description=GitHub Actions runners managed by runner-fabric

[Slice]
CPUAccounting=yes
MemoryAccounting=yes
TasksAccounting=yes
UNIT
    printf 'CPUQuota=%s\n' "$(fabric_value "$file" slice-cpu-quota)"
    value=$(fabric_value "$file" slice-memory-high)
    [ -z "$value" ] || printf 'MemoryHigh=%s\n' "$value"
    printf 'MemoryMax=%s\n' "$(fabric_value "$file" slice-memory-max)"
    printf 'TasksMax=%s\n' "$(fabric_value "$file" slice-tasks-max)"
    value=$(fabric_value "$file" slice-cpu-weight)
    [ -z "$value" ] || printf 'CPUWeight=%s\n' "$value"
    while IFS= read -r value; do
        [ -n "$value" ] && printf 'IPAddressDeny=%s\n' "$value"
    done < <(fabric_values "$file" slice-ip-deny)
    return 0
}
