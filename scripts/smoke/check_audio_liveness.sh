#!/usr/bin/env bash
# scripts/smoke/check_audio_liveness.sh — client audio liveness
#
# Sourced by device-smoke.sh. Relies on helpers from the main script
# (section / pass_check / fail_check / info / warn) and on $MODE +
# $INSTALL_TYPE_NATIVE_CLIENT + $CLIENT_DIR.
#
# The gap this closes: a snapclient container/service can be `Up (healthy)`
# and the snapserver roster can report it `connected: true` while NO audio
# reaches the speakers. container health only proves the binary is alive;
# roster connectivity only proves the control socket is up. Neither looks
# at whether PCM is actually flowing to ALSA. Two real failure modes hide
# behind a green smoke:
#
#   1. RECONNECT FLAP — snapclient keeps dropping and re-establishing the
#      server connection (e.g. `Time sync request failed: Connection timed
#      out` on a weak 2.4 GHz link). Audio blips in and out. Observed live
#      on a Pi Zero 2W latched onto a weak BSSID. Signal: reconnect lines
#      in the snapclient log over a short window. Works on every client
#      (Docker or native) because error/reconnect lines ARE logged at the
#      default level — only the per-chunk decode lines are not, so the
#      log-scan for "playing" that the issue floated is a dead end and we
#      do not use it.
#
#   2. DECODER SILENT — client is connected and stable, its group's stream
#      is `playing` on the server, but the local ALSA playback substream is
#      not RUNNING. The decoder is wedged / ALSA never (re)opened. Signal:
#      snapserver says this client's stream is playing AND no
#      `/proc/asound/card*/pcm*p/sub*/status` reads `RUNNING`. The
#      per-group stream lookup matters — another group playing must not
#      mask this group being silent.
#
# Both verdicts are boot-gated: within $_AL_BOOT_GRACE_S of boot the stream
# may legitimately not be flowing yet, so findings demote to INFO (same
# rationale as the NM-dispatcher boot-race handling elsewhere).
#
# Scope by install shape:
#   - flap check: all client-bearing installs (client, both, native).
#   - decoder check: needs the server RPC + this client's id. Available on
#     Docker client / both (`$CLIENT_DIR/.env` carries SNAPSERVER_HOST +
#     CLIENT_ID). Native client (Pi Zero, no .env) INFO-skips the decoder
#     leg — flap is the failure that actually bites those boards anyway.

# shellcheck disable=SC2154  # MODE / helpers come from device-smoke.sh

_AL_FLAP_WINDOW_S=60       # log window scanned for reconnect lines
_AL_FLAP_FAIL_THRESHOLD=3  # reconnects in the window => fail (1-2 = transient)
_AL_BOOT_GRACE_S=120       # below this uptime, demote findings to INFO
_AL_PCM_SETTLE_S=3         # gap between the two PCM samples before "silent"

# ---- I/O seams (overridden in unit tests) ----

_al_uptime_s() {
    local u
    u=$(cut -d. -f1 /proc/uptime 2>/dev/null) || u=""
    printf '%s' "${u:-0}"
}

_al_snapclient_logs() {
    # Recent snapclient log text over the flap window (Docker or native).
    # Returns non-zero when the log source is UNAVAILABLE (docker present
    # but inaccessible, journalctl denied) so the caller can skip with INFO
    # instead of reading zero reconnects off an error string and declaring
    # the link stable. The natural exit code of journalctl / docker logs
    # propagates — no `|| true` masking it. `2>&1` on the docker path is
    # deliberate: snapclient writes its log lines (incl. reconnects) to the
    # container's stderr, so they must be captured on success; on failure
    # the error text lands on stdout too but the caller discards it.
    if [[ "${INSTALL_TYPE_NATIVE_CLIENT:-false}" == "true" ]]; then
        journalctl -u snapclient.service --since "-${_AL_FLAP_WINDOW_S}s" \
            --no-pager 2>/dev/null
        return
    fi
    command -v docker >/dev/null 2>&1 || return 1
    if [[ $EUID -ne 0 ]] && sudo -n true 2>/dev/null; then
        sudo -n docker logs --since "${_AL_FLAP_WINDOW_S}s" snapclient 2>&1
    else
        docker logs --since "${_AL_FLAP_WINDOW_S}s" snapclient 2>&1
    fi
}

_al_pcm_running() {
    # rc 0 if any ALSA playback substream is RUNNING, 1 otherwise.
    local s state
    for s in /proc/asound/card*/pcm*p/sub*/status; do
        [[ -e "$s" ]] || continue
        state=$(head -1 "$s" 2>/dev/null) || continue
        if [[ "$state" == "state: RUNNING" ]]; then
            return 0
        fi
    done
    return 1
}

_al_server_status_json() {
    # snapserver Server.GetStatus JSON for the given host, or empty string.
    local host="$1"
    command -v curl >/dev/null 2>&1 || return
    # -s (not -sS): stderr is discarded below, so -S (show-error) would be a
    # no-op. An empty body is the caller's "skip" signal for an unreachable
    # server — connectivity itself is the Snapcast check's job.
    curl -s --max-time 3 -X POST "http://${host}:1780/jsonrpc" \
        -H 'Content-Type: application/json' \
        -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
        2>/dev/null || true
}

# ---- pure classifiers (unit-tested directly, no I/O) ----

# _al_classify_flap <reconnects> <uptime_s> -> boot|ok|transient|flap
_al_classify_flap() {
    local reconnects="$1" uptime_s="$2"
    if (( uptime_s < _AL_BOOT_GRACE_S )); then printf 'boot'; return; fi
    if (( reconnects >= _AL_FLAP_FAIL_THRESHOLD )); then printf 'flap'; return; fi
    if (( reconnects > 0 )); then printf 'transient'; return; fi
    printf 'ok'
}

# _al_classify_decoder <stream_state> <pcm_running 0|1> <connected 0|1> <uptime_s>
#   -> boot|disconnected|idle|playing_ok|silent|unknown
_al_classify_decoder() {
    local stream_state="$1" pcm_running="$2" connected="$3" uptime_s="$4"
    if (( uptime_s < _AL_BOOT_GRACE_S )); then printf 'boot'; return; fi
    if (( connected == 0 )); then printf 'disconnected'; return; fi
    case "$stream_state" in
        playing)
            if (( pcm_running == 1 )); then printf 'playing_ok'; else printf 'silent'; fi
            ;;
        idle) printf 'idle' ;;
        *) printf 'unknown' ;;
    esac
}

# Resolve this client's id + the server host from $CLIENT_DIR/.env.
# Echoes "<client_id>|<server_host>" or empty when unavailable (native
# client without .env). Kept out of the classifier so tests stay pure.
_al_client_identity() {
    local env_file="${CLIENT_DIR:-/opt/snapclient}/.env"
    [[ -f "$env_file" ]] || return
    local cid host
    cid=$(grep -E '^CLIENT_ID=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
    host=$(grep -E '^SNAPSERVER_HOST=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2-)
    [[ -z "$cid" ]] && cid="snapclient-$(hostname 2>/dev/null || echo unknown)"
    # both-mode: the local client talks to the server on this same host.
    [[ -z "$host" ]] && host="127.0.0.1"
    printf '%s|%s' "$cid" "$host"
}

# Extract "<connected 0|1> <stream_state>" for a client id from RPC JSON.
# stream_state is the status of the stream assigned to THAT client's group.
_al_client_stream_state() {
    local rpc_json="$1" client_id="$2"
    command -v jq >/dev/null 2>&1 || { printf ''; return; }
    # Zero groups matching the client id yields NO output (jq's `EXPR as $g`
    # with zero left inputs skips the body — it does not bind $g to null), so
    # a "missing" branch would be dead code. Collect matches into an array and
    # branch on its length instead; empty output is the caller's skip signal.
    jq -r --arg id "$client_id" '
        [.result.server.groups[]? | select(any(.clients[]?; .id == $id))] as $gs
        | if ($gs | length) == 0 then empty
          else
            $gs[0] as $g
            | (($g.clients[] | select(.id == $id) | .connected) // false) as $conn
            | (.result.server.streams[]? | select(.id == $g.stream_id) | .status) as $st
            | "\(if $conn then 1 else 0 end) \($st // "unknown")"
          end
    ' <<<"$rpc_json" 2>/dev/null || printf ''
}

check_audio_liveness() {
    section "Audio liveness"

    case "$MODE" in
        server)
            info "Audio liveness: skipped (no local snapclient on a server-only install)"
            return
            ;;
    esac

    local uptime_s
    uptime_s=$(_al_uptime_s)

    # ---- 1. reconnect flap ----
    # `if !` context so set -e doesn't abort on an unavailable log source,
    # and so we can tell "no reconnects" (healthy) from "logs unreadable"
    # (skip) — both would otherwise look like an empty string / zero count.
    local logs reconnects verdict
    if ! logs=$(_al_snapclient_logs); then
        info "snapclient reconnect check skipped (log source unavailable — docker not accessible or unit missing)"
        logs=""
        verdict="skip"
    else
        reconnects=$(grep -c 'Reconnecting' <<<"$logs" 2>/dev/null || true)
        [[ "$reconnects" =~ ^[0-9]+$ ]] || reconnects=0
        verdict=$(_al_classify_flap "$reconnects" "$uptime_s")
    fi
    case "$verdict" in
        skip) : ;;  # already reported above
        flap)
            fail_check "snapclient flapping: ${reconnects} reconnects in ${_AL_FLAP_WINDOW_S}s — audio drops in and out (check WiFi signal / BSSID roaming, see TROUBLESHOOTING)"
            ;;
        transient)
            info "snapclient reconnected ${reconnects}× in ${_AL_FLAP_WINDOW_S}s — transient, not yet flapping"
            ;;
        boot)
            info "snapclient reconnect check deferred (uptime < ${_AL_BOOT_GRACE_S}s — stream still settling)"
            ;;
        ok)
            pass_check "snapclient link stable: no reconnects in ${_AL_FLAP_WINDOW_S}s"
            ;;
    esac

    # ---- 2. decoder silent while stream playing ----
    local identity client_id server_host
    identity=$(_al_client_identity)
    if [[ -z "$identity" ]]; then
        info "Decoder liveness: skipped (no client .env — native install; flap check above still applies)"
        return
    fi
    client_id="${identity%%|*}"
    server_host="${identity#*|}"

    local rpc_json state_pair connected stream_state
    rpc_json=$(_al_server_status_json "$server_host")
    if [[ -z "$rpc_json" ]]; then
        info "Decoder liveness: skipped (snapserver RPC at ${server_host}:1780 unreachable — connectivity is covered by the Snapcast check)"
        return
    fi
    state_pair=$(_al_client_stream_state "$rpc_json" "$client_id")
    if [[ -z "$state_pair" ]]; then
        info "Decoder liveness: skipped (client '$client_id' not in server roster, or jq missing)"
        return
    fi
    connected="${state_pair%% *}"
    stream_state="${state_pair##* }"

    # Only pay the settle delay when it could matter: stream playing but the
    # first PCM sample is closed. A single running sample is enough to pass.
    local pcm_running=0
    if _al_pcm_running; then
        pcm_running=1
    elif [[ "$stream_state" == "playing" && "$connected" == "1" ]]; then
        sleep "$_AL_PCM_SETTLE_S"
        if _al_pcm_running; then
            pcm_running=1
        fi
    fi

    verdict=$(_al_classify_decoder "$stream_state" "$pcm_running" "$connected" "$uptime_s")
    case "$verdict" in
        silent)
            fail_check "decoder silent: client connected and stream '$stream_state' but no ALSA substream is RUNNING — audio wedged (snapclient not writing PCM; restart the snapclient container/service)"
            ;;
        playing_ok)
            pass_check "decoder live: stream playing and ALSA substream RUNNING"
            ;;
        idle)
            pass_check "decoder idle: stream not playing (nothing to decode — expected)"
            ;;
        disconnected)
            info "Decoder liveness: client '$client_id' not connected to the server right now (covered by the Snapcast check)"
            ;;
        boot)
            info "Decoder liveness deferred (uptime < ${_AL_BOOT_GRACE_S}s — stream still settling)"
            ;;
        unknown)
            info "Decoder liveness: stream state for '$client_id' is unknown (server reported no status)"
            ;;
    esac
}
