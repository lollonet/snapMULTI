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
        if [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null; then
            sudo -n docker exec mpd mpc status 2>/dev/null || true
        else
            docker exec mpd mpc status 2>/dev/null || true
        fi
    fi
}

check_snapcast() {
    section "Snapcast + MPD"

    case "$MODE" in
        client)
            info "Snapserver / MPD checks: skipped (N/A on client-only install)"
            return
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        warn "Snapcast control API check skipped (missing dep: curl)"
    else
        local rpc_json
        rpc_json=$(_snapcast_get_status)
        if [[ -z "$rpc_json" ]]; then
            fail_check "Snapcast control API ($_SNAPSERVER_RPC_URL): no response — server down or port closed"
        elif ! command -v jq >/dev/null 2>&1; then
            info "Snapcast control API: reachable, but client roster not parsed (missing dep: jq)"
        else
            # Extract client count and disconnected client list. Snapserver
            # keeps paired clients in its state even when they are offline;
            # that is useful context, not a smoke warning.
            local client_count connected disconnected disconnected_clients
            client_count=$(jq -r '[.result.server.groups[]?.clients[]?] | length' <<<"$rpc_json" 2>/dev/null || echo 0)
            connected=$(jq -r '[.result.server.groups[]?.clients[]? | select(.connected==true)] | length' <<<"$rpc_json" 2>/dev/null || echo 0)
            disconnected=$(( client_count - connected ))
            disconnected_clients=$(
                jq -r '
                    [.result.server.groups[]?.clients[]?
                     | select(.connected != true)
                     | (.host.name // .host.ip // .id // "unknown") as $name
                     | (.host.ip // "") as $ip
                     | if $ip != "" and $ip != $name then "\($name)(\($ip))" else $name end]
                    | join(", ")
                ' <<<"$rpc_json" 2>/dev/null || true
            )
            if (( client_count == 0 )); then
                warn "Snapcast clients: none paired yet — multiroom has no listeners (normal on a fresh install)"
            elif (( disconnected > 0 )); then
                pass_check "Snapcast clients: $connected of $client_count connected"
                info "Snapcast clients offline: ${disconnected_clients:-unknown} (paired but not reachable now)"
            else
                pass_check "Snapcast clients: $connected of $client_count connected"
            fi

            # Active stream + now-playing surface. Each group has a
            # stream_id assignment — the stream that group's clients
            # actually hear. Show the first group that has at least
            # one connected client plus that stream's metadata if any.
            local now_playing
            now_playing=$(
                jq -r '
                    .result.server.groups[]
                    | select((.clients[]?.connected // false) == true)
                    | "\(.name // "default")|\(.stream_id)"
                ' <<<"$rpc_json" 2>/dev/null | head -1
            )
            if [[ -n "$now_playing" ]]; then
                local grp_name="${now_playing%%|*}"
                local stream_id="${now_playing#*|}"
                local track
                track=$(jq -r --arg sid "$stream_id" '
                    (.result.server.streams[]? | select(.id == $sid)) as $s
                    | if $s.properties.metadata then
                        (($s.properties.metadata.artist[0]? // "Unknown artist") + " — "
                         + ($s.properties.metadata.title // "Unknown title"))
                      else
                        ("(no metadata, status=" + ($s.status // "?") + ")")
                      end
                ' <<<"$rpc_json" 2>/dev/null || true)
                info "Now playing: group \"$grp_name\" → stream \"$stream_id\" ($track)"
            fi
        fi
    fi

    # MPD reachability + state. Best-effort: skip with info if neither
    # host mpc nor docker available, since some installs may not have
    # mpc on the host (it's only in the mpd container by default).
    local mpc_out
    mpc_out=$(_mpc_status)
    if [[ -z "$mpc_out" ]]; then
        info "MPD state check skipped (missing dep: mpc-cli on both host and container)"
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
        # mpc status output shapes (most common first):
        #   1. Playlist loaded + playing/paused → 3 lines, second is "[state] #N/M time"
        #   2. Playlist loaded but stopped → 2 lines, second is "[stopped]"
        #   3. NO playlist loaded → 1 line "volume: ..." only — no [state] bracket
        # Case 3 was previously reported as "state: unknown" which reads
        # like a failure. It's actually the most common idle case on
        # fresh installs (snapserver up, mympd reachable, but no one
        # has queued anything yet). Make the message say so.
        local state
        state=$(grep -oE "^\[(playing|paused|stopped)\]" <<<"$mpc_out" | tr -d '[]' | head -1 || true)
        if [[ -n "$state" ]]; then
            pass_check "MPD reachable, state: $state"
        elif grep -q "^volume:" <<<"$mpc_out"; then
            pass_check "MPD reachable, idle (no playlist loaded)"
        else
            pass_check "MPD reachable, state: unrecognized (mpc returned no [state] or volume line)"
        fi
    fi

    # MPD scan progress — large NFS libraries take hours on first boot. Surface as INFO so users know the FAIL on `mpd: starting` healthcheck is expected during this window (not a real problem).
    if grep -qE "^Updating DB" <<<"$mpc_out"; then
        local job
        job=$(grep -oE 'Updating DB \(#[0-9]+\)' <<<"$mpc_out" | head -1)
        info "MPD library scan in progress ($job) — large libraries can take hours; a transient FAIL on mpd healthcheck during this window is expected"
    fi
}
