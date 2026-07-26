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

check_env() {
    section ".env Integrity"

    # Both install shapes carry a Docker `.env` with per-service limit keys:
    # the server at $SERVER_DIR/.env (/opt/snapmulti) and the Docker client at
    # $CLIENT_DIR/.env (/opt/snapclient, with SNAPCLIENT_/VISUALIZER_/FBDISPLAY_
    # limits). A `both` install has BOTH. Validate every one that exists — an
    # earlier version only looked at /opt/snapmulti/.env, so a pure client (no
    # server .env) reported "no .env" and never validated its client config.
    # Native Pi Zero clients use /etc/default/snapclient (no container limits),
    # so no .env there is the expected, correct state.
    local -a candidates=()
    [[ -n "${SERVER_DIR:-}" && -f "${SERVER_DIR}/.env" ]] && candidates+=("${SERVER_DIR}/.env")
    [[ -n "${CLIENT_DIR:-}" && -f "${CLIENT_DIR}/.env" ]] && candidates+=("${CLIENT_DIR}/.env")
    if (( ${#candidates[@]} == 0 )); then
        # Fall back to the well-known install paths when the dirs weren't
        # resolved (e.g. a bare re-run outside device-smoke's detection).
        local wk
        for wk in /opt/snapmulti/.env /opt/snapclient/.env; do
            [[ -f "$wk" ]] && candidates+=("$wk")
        done
    fi

    if (( ${#candidates[@]} == 0 )); then
        info "No .env found (server /opt/snapmulti/.env or client /opt/snapclient/.env) — native client (uses /etc/default/snapclient) or a fresh checkout?"
        return
    fi

    local env_file
    for env_file in "${candidates[@]}"; do
        _check_env_validate "$env_file"
    done
}

_check_env_validate() {
    local env_file="$1"
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
        printf -v joined "%s, " "${empty_keys[@]}"; joined="${joined%, }"
        fail_check ".env has empty limit key(s) (Compose treats as unset → no limit applied): $joined"
    fi

    if (( ${#bad_mem[@]} > 0 )); then
        local joined
        printf -v joined "%s, " "${bad_mem[@]}"; joined="${joined%, }"
        fail_check ".env has malformed memory limit(s) (expected NNN[K|M|G]): $joined"
    fi

    if (( ${#bad_cpu[@]} > 0 )); then
        local joined
        printf -v joined "%s, " "${bad_cpu[@]}"; joined="${joined%, }"
        fail_check ".env has malformed CPU limit(s) (expected positive float, no comma): $joined"
    fi

    if (( ${#empty_keys[@]} + ${#bad_mem[@]} + ${#bad_cpu[@]} == 0 )); then
        pass_check ".env limit keys (MEM_LIMIT / CPU_LIMIT / MEM_RESERVE) all well-formed"
    fi
}
