#!/usr/bin/env bash
# scripts/smoke/check_containers.sh — Docker container health + config drift
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   - Memory limits silently not applied. docker-compose.yml declares
#     deploy.resources.limits.memory under .env vars (MPD_MEM_LIMIT etc.)
#     but Docker Compose v5 does NOT consider that field part of the
#     recreate-hash. If deploy.sh later writes/rewrites .env and runs
#     `docker compose up -d` without --force-recreate, the running
#     container keeps its original (often unlimited) limit forever.
#     CPU limits DO get applied through HostConfig.NanoCpus, which makes
#     the drift invisible — `docker stats` shows the host's total RAM
#     as the "limit" column, and nothing complains until first OOM.
#     This check inspects HostConfig.Memory directly and fails when 0
#     on a container that the compose file declares a limit for.
#   - Containers in active restart failure. RestartCount is lifetime
#     history, so a healthy running container with RestartCount > 0 is
#     a past event, not a current smoke failure. Surface that history
#     as info, but fail when the current state is still bad.
#   - Containers reporting unhealthy. Compose `healthcheck:` runs the
#     declared probe; State.Health.Status goes through `starting` →
#     `healthy` or `unhealthy`. We treat `unhealthy` as fail, anything
#     past startup that's still `starting` for too long as warn (the
#     start_period grace counts as starting, so we only warn if the
#     container has been up for more than 5 minutes and is still
#     starting — that's a stalled healthcheck).
#
# Why not just trust docker compose ps healthy column: this check runs
# under sudo from device-smoke.sh and reads the canonical Docker engine
# state. `compose ps` formatting changes between versions; raw inspect
# is stable.

# shellcheck disable=SC2154

# Containers the smoke considers "ours" — i.e. expected to have a
# memory limit declared in docker-compose.yml. Anything else (system
# containers, user-added side projects) is ignored.
_SNAPMULTI_CONTAINERS=(
    "snapserver"
    "mpd"
    "mympd"
    "metadata"
    "shairport-sync"
    "librespot"
    "tidal-connect"
    "snapclient"
    "audio-visualizer"
    "fb-display"
)

_is_snapmulti_container() {
    local name=$1
    local known
    for known in "${_SNAPMULTI_CONTAINERS[@]}"; do
        [[ "$name" == "$known" ]] && return 0
    done
    return 1
}

# is_pi_zero_2w lives in scripts/common/device-detect.sh — the SINGLE
# authority for hardware detection. Source it here if device-smoke.sh
# hasn't already, so this module is callable standalone (ad-hoc operator
# runs) without surprises. We require the sibling common/ dir: a
# partial-deployment scenario (smoke dir copied without common/) is a
# bug worth surfacing loudly rather than papering over with an inline
# fallback — the previous fallback had no cache and risked diverging
# from device-detect.sh semantics over time.
if ! command -v is_pi_zero_2w &>/dev/null; then
    _CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_CC_DIR/../common/device-detect.sh" ]]; then
        # shellcheck source=../common/device-detect.sh
        source "$_CC_DIR/../common/device-detect.sh"
    else
        echo "ERROR: $_CC_DIR/../common/device-detect.sh not found." >&2
        echo "  check_containers.sh requires scripts/common/device-detect.sh." >&2
        echo "  Hint: re-deploy the smoke module bundle (scripts/smoke/ +" >&2
        echo "  scripts/common/) together — they ship as a unit." >&2
        unset _CC_DIR
        return 1 2>/dev/null || exit 1
    fi
    unset _CC_DIR
fi

check_containers() {
    section "Containers"

    # Pi Zero 2W (or any future native client install) runs snapclient
    # natively (no Docker — see client/common/scripts/setup-zero2w.sh).
    # device-smoke.sh exports INSTALL_TYPE_NATIVE_CLIENT=true when it
    # detects /opt/snapclient/install.conf with INSTALL_TYPE=client-native.
    # The model-based heuristic stays as a fallback for setups where the
    # env var is missing (e.g. invoking this module standalone).
    if { [[ "${INSTALL_TYPE_NATIVE_CLIENT:-false}" == "true" ]] || is_pi_zero_2w; } \
       && [[ "${MODE:-}" == "client" || "${MODE:-}" == "" ]]; then
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl is-active --quiet snapclient.service; then
                pass_check "snapclient.service active (Pi Zero 2W native install)"
            else
                fail_check "snapclient.service not active on Pi Zero 2W native install"
            fi
        else
            warn "systemctl not available — cannot verify native snapclient on Pi Zero 2W"
        fi
        return  # skip the rest of the Docker-oriented checks
    fi

    if ! command -v docker >/dev/null 2>&1; then
        info "docker not installed — container checks skipped"
        return
    fi

    # Use sudo -n: device-smoke is typically invoked as root, but if
    # called from a regular shell during dev, fall back gracefully.
    # Array pattern avoids SC2086 when expanding into command position.
    local -a docker_cmd=(docker)
    if [[ $EUID -ne 0 ]]; then
        if sudo -n true 2>/dev/null; then
            docker_cmd=(sudo -n docker)
        else
            warn "Not root and sudo unavailable — container checks skipped"
            return
        fi
    fi

    # List of running containers, one per line.
    local running
    running=$("${docker_cmd[@]}" ps --format '{{.Names}}' 2>/dev/null || true)
    if [[ -z "$running" ]]; then
        info "No running containers — smoke is probably on a fresh device pre-install"
        return
    fi

    # Track containers without enforced memory limit so we can fail once
    # with a useful aggregate message instead of one fail per container.
    local -a no_limit=()
    local -a active_restart_failures=()
    local -a restart_history=()
    local checked=0

    local name
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        _is_snapmulti_container "$name" || continue
        checked=$((checked + 1))

        # 1. Restart detection. RestartCount is a lifetime counter; do
        # not classify a recovered, healthy container as an active
        # crash-loop just because it restarted once during boot/install.
        local rc state health
        rc=$("${docker_cmd[@]}" inspect "$name" --format '{{.RestartCount}}' 2>/dev/null || echo "?")
        state=$("${docker_cmd[@]}" inspect "$name" --format '{{.State.Status}}' 2>/dev/null || echo "?")
        health=$("${docker_cmd[@]}" inspect "$name" --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || echo "")
        if [[ "$rc" =~ ^[0-9]+$ ]] && (( rc > 0 )); then
            # `paused` and `created` intentionally NOT classified as
            # failure. paused = explicit operator action (`docker pause`);
            # smoke should not override that. created + RC>0 is
            # unreachable in normal docker semantics.
            if [[ "$state" == "restarting" || "$state" == "dead" || "$state" == "exited" || "$health" == "unhealthy" ]]; then
                active_restart_failures+=("$name(RC=$rc,status=$state,health=${health:-none})")
            else
                restart_history+=("$name(RC=$rc)")
            fi
        fi

        # 2. Memory limit drift. HostConfig.Memory == 0 means "unlimited"
        # which is wrong for any snapMULTI container — every one of them
        # has a limit in docker-compose.yml. If we see 0, deploy.sh
        # didn't --force-recreate after writing .env.
        local mem
        mem=$("${docker_cmd[@]}" inspect "$name" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "?")
        if [[ "$mem" == "0" ]]; then
            no_limit+=("$name")
        fi

        # 3. Healthcheck (only for containers that declare one). Output
        # is empty string if no healthcheck. After start_period grace
        # the status stabilises at `healthy` or `unhealthy`.
        local started_at uptime_s
        if [[ -n "$health" ]]; then
            case "$health" in
                healthy)
                    pass_check "$name: healthcheck reporting healthy"
                    ;;
                unhealthy)
                    fail_check "$name: healthcheck reporting unhealthy — service is failing its probe"
                    ;;
                starting)
                    # If container has been up more than 5 min and still
                    # starting, the healthcheck is stuck — warn but don't
                    # fail (could be a slow first MPD scan).
                    started_at=$("${docker_cmd[@]}" inspect "$name" --format '{{.State.StartedAt}}' 2>/dev/null || echo "")
                    uptime_s=0
                    if [[ -n "$started_at" ]]; then
                        uptime_s=$(( $(date +%s) - $(date -d "$started_at" +%s 2>/dev/null || echo 0) ))
                    fi
                    if (( uptime_s > 300 )); then
                        warn "$name: healthcheck still 'starting' after $((uptime_s/60)) min — probe may be stuck"
                    else
                        info "$name: healthcheck 'starting' (uptime ${uptime_s}s — within start_period)"
                    fi
                    ;;
                *)
                    warn "$name: healthcheck status '$health' (unexpected)"
                    ;;
            esac
        fi
    done <<<"$running"

    if (( checked == 0 )); then
        info "No snapMULTI containers among the ${#_SNAPMULTI_CONTAINERS[@]} expected names — fresh device?"
        return
    fi

    # Aggregate restart report. Historical restarts are OK when the
    # container has recovered; active bad state remains a failure.
    if (( ${#active_restart_failures[@]} > 0 )); then
        local joined
        printf -v joined "%s, " "${active_restart_failures[@]}"; joined="${joined%, }"
        fail_check "Container(s) with active restart failure: $joined"
    else
        pass_check "No active container restart failures among $checked snapMULTI container(s)"
        if (( ${#restart_history[@]} > 0 )); then
            local joined
            printf -v joined "%s, " "${restart_history[@]}"; joined="${joined%, }"
            info "Past container restart(s) observed, current state not failing: $joined"
        fi
    fi

    # Aggregate memory-limit drift report.
    if (( ${#no_limit[@]} > 0 )); then
        local joined
        printf -v joined "%s, " "${no_limit[@]}"; joined="${joined%, }"
        fail_check "Container(s) with HostConfig.Memory=0 (limit drift — deploy.sh must --force-recreate): $joined"
    else
        pass_check "All $checked snapMULTI container(s) have memory limit applied"
    fi

    # 4. Metadata plugin liveness — the snapserver container forks
    # one meta_*.py per audio source (meta_mpd, meta_go-librespot,
    # meta_tidal, meta_shairport-sync). They feed cover-art + track
    # info to the snapserver via stdin. When one crashes — typically
    # a Python traceback that systemd doesn't restart — the cover
    # art and "now playing" string for that source vanish silently;
    # the audio keeps playing. Container healthcheck doesn't catch
    # this because snapserver itself is fine.
    #
    # The check is server-only (client containers don't run metadata
    # plugins) and depends on snapserver being one of the running
    # containers we already enumerated.
    if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
        if echo "$running" | grep -qw snapserver; then
            # BusyBox pgrep (Alpine base) lacks `-c`, so count via wc.
            # Match `meta_` prefix — covers meta_mpd.py, meta_tidal.py,
            # meta_shairport.py, meta_go-librespot.py (and any future
            # plugins keeping the convention).
            local plugin_count
            # pgrep exits 1 when 0 processes match. Under the parent's
            # `set -euo pipefail` the plain assignment would abort the
            # smoke here — which is exactly the scenario this check is
            # meant to catch. `|| echo 0` collapses both "match nothing"
            # and "docker exec failed" into a counted zero.
            plugin_count=$("${docker_cmd[@]}" exec snapserver pgrep -f 'meta_' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
            plugin_count=${plugin_count:-0}
            if (( plugin_count == 0 )); then
                fail_check "No meta_*.py plugins running in snapserver — cover art + 'now playing' will be empty for all sources"
            elif (( plugin_count == 1 )); then
                warn "Only 1 meta_*.py plugin running in snapserver — most snapMULTI installs run 4 (mpd, librespot, tidal, shairport)"
            else
                pass_check "$plugin_count meta_*.py plugin(s) running in snapserver"
            fi
        fi
    fi
}
