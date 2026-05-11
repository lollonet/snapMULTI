#!/usr/bin/env bash
# scripts/smoke/check_env.sh — .env integrity
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   - A *_MEM_LIMIT or *_CPU_LIMIT key that is present but empty
#     (e.g. `MPD_MEM_LIMIT=`). Compose treats this as "unset" and
#     applies no limit — the value silently becomes 0 / unlimited
#     after the next force-recreate, same bug class as the missing
#     --force-recreate (PR #351) but for a different reason: bad
#     data instead of stale runtime state.
#   - A *_MEM_LIMIT with a malformed value (e.g. `384` without unit,
#     `MEM_LIMIT=abc`). Compose silently falls back to "no limit"
#     when it can't parse the value — there's no warning, just a
#     container with HostConfig.Memory=0.
#   - A *_CPU_LIMIT that is not a valid float (e.g. `0,5` with a
#     comma instead of `0.5`). Compose accepts the value into the
#     rendered config but Docker may reject it at create time, and
#     in the worst case applies a fallback that's wrong by 10×.
#
# Why not catch this at deploy.sh time: deploy.sh writes .env from
# hardware-profile templates that ARE well-formed, but a human
# editing the file after the install (to tune for a specific room,
# add a new HAT, etc.) can introduce these errors. Smoke runs on
# every release-gate, so it catches drift introduced post-install.

# shellcheck disable=SC2154

# Where to look for .env. /opt/snapmulti is server-side; client mode
# doesn't have a .env (snapclient.conf instead).
_ENV_CANDIDATES=(
    /opt/snapmulti/.env
)

check_env() {
    section ".env Integrity"

    local env_file=""
    local candidate
    for candidate in "${_ENV_CANDIDATES[@]}"; do
        if [[ -f "$candidate" ]]; then
            env_file="$candidate"
            break
        fi
    done

    if [[ -z "$env_file" ]]; then
        info "No .env found in any of: ${_ENV_CANDIDATES[*]} (client-only device?)"
        return
    fi

    pass_check ".env present at $env_file"

    # Stream the file, split on '=', validate per-key. Skip comments
    # (#) and blank lines. Ignore values that contain '$' (likely a
    # reference we can't resolve here without sourcing — Compose does
    # the env-substitution at render time).
    local -a bad_mem=() bad_cpu=() empty_keys=()
    local line key value
    while IFS= read -r line; do
        # Strip CRLF.
        line=${line%$'\r'}
        # Skip empty lines and comments.
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Must contain at least one '='.
        [[ "$line" != *=* ]] && continue
        key=${line%%=*}
        value=${line#*=}
        # Strip surrounding quotes from value (rare in .env but allowed).
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}

        # Empty value is suspicious for our known limit keys.
        if [[ -z "$value" ]]; then
            if [[ "$key" == *_MEM_LIMIT || "$key" == *_CPU_LIMIT || "$key" == *_MEM_RESERVE ]]; then
                empty_keys+=("$key")
            fi
            continue
        fi

        # Skip values containing variable references — can't validate
        # those without rendering them through compose.
        [[ "$value" == *'$'* ]] && continue

        case "$key" in
            *_MEM_LIMIT|*_MEM_RESERVE)
                # Must match an integer followed by K/M/G (case-insensitive).
                # Compose also accepts plain bytes, but the snapMULTI
                # templates always write a unit suffix — flag bare ints
                # as suspicious.
                if [[ ! "$value" =~ ^[0-9]+[KMGkmg]$ ]]; then
                    bad_mem+=("$key=$value")
                fi
                ;;
            *_CPU_LIMIT)
                # Must match a positive float — 1, 1.0, 0.5, 2.5, etc.
                # No commas (locale-dependent decimal separators bite).
                if [[ ! "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    bad_cpu+=("$key=$value")
                fi
                ;;
        esac
    done <"$env_file"

    if (( ${#empty_keys[@]} > 0 )); then
        local joined
        joined=$(IFS=', '; echo "${empty_keys[*]}")
        fail_check ".env has empty limit key(s) (Compose treats as unset → no limit applied): $joined"
    fi

    if (( ${#bad_mem[@]} > 0 )); then
        local joined
        joined=$(IFS=', '; echo "${bad_mem[*]}")
        fail_check ".env has malformed memory limit(s) (expected NNN[K|M|G]): $joined"
    fi

    if (( ${#bad_cpu[@]} > 0 )); then
        local joined
        joined=$(IFS=', '; echo "${bad_cpu[*]}")
        fail_check ".env has malformed CPU limit(s) (expected positive float, no comma): $joined"
    fi

    if (( ${#empty_keys[@]} + ${#bad_mem[@]} + ${#bad_cpu[@]} == 0 )); then
        pass_check ".env limit keys (MEM_LIMIT / CPU_LIMIT / MEM_RESERVE) all well-formed"
    fi
}
