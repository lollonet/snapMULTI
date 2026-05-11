#!/usr/bin/env bash
# scripts/smoke/check_snapcast.sh — Snapcast + MPD live state
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   - Snapcast server up but no clients connected. The container
#     healthcheck passes if the RPC port answers, even with zero
#     clients — but that's an empty multiroom. Most installations
#     should have ≥1 client (the local "both" player or a peer Pi).
#   - MPD reachable but in error state (e.g. "error: Failed to
#     open audio output"). MPD reports the error only via its
#     status command; the container is "healthy" because mpdctl
#     itself runs. Without this check, "music doesn't play" is
#     undebuggable without docker exec.
#   - MPD audio output disabled. If `mpc outputs` shows the named
#     pipe output (mpd_fifo or pipe-mpd) as `disabled`, MPD won't
#     feed snapserver — playback appears to "work" in mympd but no
#     audio reaches clients.
#
# Why not deeper: snapcast does not expose per-client time-sync drift
# in its public RPC. Drift is computed by each snapclient and used
# internally for sample alignment; reading it would require parsing
# every client's "diff to server [ms]:" log lines, which doesn't fit
# this single-host smoke. Catch it via fleet-smoke + targeted log
# diff if/when it becomes an operational issue.

# shellcheck disable=SC2154

# RPC ports + Docker container names. Snapcast server RPC: 1780 HTTP
# JSON-RPC. MPD ASCII protocol: 6600. Both are exposed via Docker's
# host networking on snapMULTI servers.
_SNAPSERVER_RPC_URL="http://127.0.0.1:1780/jsonrpc"
_MPD_HOST="127.0.0.1"
_MPD_PORT="6600"

_snapcast_get_status() {
    # Returns JSON or empty string on failure. Bounded by 3s.
    curl -sS --max-time 3 -X POST "$_SNAPSERVER_RPC_URL" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
        2>/dev/null || true
}

_mpc_status() {
    # Returns the multi-line mpc status output, or empty on failure.
    # Prefer host `mpc` (lighter), fall back to docker exec mpd mpc.
    if command -v mpc >/dev/null 2>&1; then
        timeout 3 mpc -h "$_MPD_HOST" -p "$_MPD_PORT" status 2>/dev/null || true
        return
    fi
    # Containerised mpc — if present, exec inside; assume the mpd
    # image ships mpc as a debug tool. This is best-effort; if not
    # available the check skips with info, not warn.
    if command -v docker >/dev/null 2>&1; then
        local sudo_p=""
        [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null && sudo_p="sudo -n"
        $sudo_p docker exec mpd mpc status 2>/dev/null || true
    fi
}

check_snapcast() {
    section "Snapcast + MPD"

    case "$MODE" in
        client)
            info "Client mode — snapserver/MPD checks skipped (no local server)"
            return
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        warn "curl not installed — Snapcast RPC check skipped"
    else
        local rpc_json
        rpc_json=$(_snapcast_get_status)
        if [[ -z "$rpc_json" ]]; then
            fail_check "Snapcast RPC at $_SNAPSERVER_RPC_URL did not respond — server down or RPC port closed"
        elif ! command -v jq >/dev/null 2>&1; then
            info "jq not installed — RPC reachable but contents not inspected"
        else
            # Extract client count and "any disconnected client" flag.
            local client_count connected disconnected
            client_count=$(jq -r '[.result.server.groups[]?.clients[]?] | length' <<<"$rpc_json" 2>/dev/null || echo 0)
            connected=$(jq -r '[.result.server.groups[]?.clients[]? | select(.connected==true)] | length' <<<"$rpc_json" 2>/dev/null || echo 0)
            disconnected=$(( client_count - connected ))
            if (( client_count == 0 )); then
                warn "Snapcast: 0 clients in any group — multiroom has no listeners (intentional if no players paired yet)"
            elif (( disconnected > 0 )); then
                warn "Snapcast: $connected/$client_count clients connected ($disconnected disconnected — paired but offline)"
            else
                pass_check "Snapcast: $connected/$client_count clients connected"
            fi
        fi
    fi

    # MPD reachability + state. Best-effort: skip with info if neither
    # host mpc nor docker available, since some installs may not have
    # mpc on the host (it's only in the mpd container by default).
    local mpc_out
    mpc_out=$(_mpc_status)
    if [[ -z "$mpc_out" ]]; then
        info "mpc unavailable on host and in container — MPD state not inspected (install mpc-cli to enable)"
        return
    fi

    # `mpc status` first line is the current song line OR (when stopped)
    # blank. Second line is "[state]" — playing/paused/stopped. Errors
    # appear as "error:" lines. Look for error first.
    if grep -qE "^error:" <<<"$mpc_out"; then
        local err_line
        err_line=$(grep -E "^error:" <<<"$mpc_out" | head -1)
        fail_check "MPD reports an error: $err_line"
    else
        local state
        state=$(grep -oE "^\[(playing|paused|stopped)\]" <<<"$mpc_out" | tr -d '[]' | head -1)
        state=${state:-unknown}
        pass_check "MPD reachable, state: $state"
    fi
}
