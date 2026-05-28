#!/usr/bin/env bash
# scripts/smoke/check_timers.sh — snapMULTI systemd timers
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
# Several snapMULTI features are scheduled via systemd timers:
#   - snapmulti-status.timer       : 5-min status snapshot (issue #177)
#   - snapmulti-diagnostics.timer  : 30-min diagnostic dump (rotation)
#   - snapmulti-backup.timer       : daily 4am MPD db backup
#   - snapmulti-state-backup.path  : event-driven snapserver/myMPD state backup
#   - snapmulti-state-backup.timer : safety net every 10 min (catches nested writes .path doesn't fire on)
#   - snapclient-discover.timer    : mDNS rediscovery for client failover
# A timer that is enabled-but-not-active means firstboot installed it
# but something later disabled it (e.g. a partial reflash). A timer
# that's missing entirely means the install did not complete — the
# feature is silently absent and the user only notices when they go
# looking for /status snapshots that never materialised.

# shellcheck disable=SC2154

_check_timer() {
    local timer="$1" desc="$2" mode_filter="$3"

    # mode_filter: "server", "client", "both", or empty (= always check)
    case "$mode_filter" in
        "")            ;;
        server)        [[ "$MODE" == "server" || "$MODE" == "both" ]] || return 0 ;;
        client)        [[ "$MODE" == "client" || "$MODE" == "both" ]] || return 0 ;;
        both)          [[ "$MODE" == "both" ]] || return 0 ;;
    esac

    # is-enabled is the source of truth for whether the install set
    # up the timer at all. is-active confirms it's currently armed.
    local enabled active
    enabled=$(systemctl is-enabled "$timer" 2>/dev/null || echo "missing")
    active=$(systemctl is-active "$timer" 2>/dev/null || echo "inactive")

    case "$enabled" in
        enabled|enabled-runtime|static)
            if [[ "$active" == "active" ]]; then
                pass_check "Timer $timer enabled and active — $desc"
            else
                fail_check "Timer $timer enabled but state is '$active' — $desc"
            fi
            ;;
        missing|not-found)
            fail_check "Timer $timer NOT installed — $desc (firstboot finalize incomplete?)"
            ;;
        disabled|masked)
            fail_check "Timer $timer is '$enabled' — $desc (was it disabled by accident?)"
            ;;
        *)
            warn "Timer $timer in unexpected state '$enabled' / '$active'"
            ;;
    esac
}

_check_path() {
    local path_unit="$1" desc="$2" mode_filter="$3"

    case "$mode_filter" in
        "")            ;;
        server)        [[ "$MODE" == "server" || "$MODE" == "both" ]] || return 0 ;;
        client)        [[ "$MODE" == "client" || "$MODE" == "both" ]] || return 0 ;;
        both)          [[ "$MODE" == "both" ]] || return 0 ;;
    esac

    local enabled active
    enabled=$(systemctl is-enabled "$path_unit" 2>/dev/null || echo "missing")
    active=$(systemctl is-active "$path_unit" 2>/dev/null || echo "inactive")

    case "$enabled" in
        enabled|enabled-runtime|static)
            if [[ "$active" == "active" ]]; then
                pass_check "Path unit $path_unit enabled and active — $desc"
            else
                fail_check "Path unit $path_unit enabled but state is '$active' — $desc"
            fi
            ;;
        missing|not-found)
            fail_check "Path unit $path_unit NOT installed — $desc (firstboot finalize incomplete?)"
            ;;
        disabled|masked)
            fail_check "Path unit $path_unit is '$enabled' — $desc (was it disabled by accident?)"
            ;;
        *)
            warn "Path unit $path_unit in unexpected state '$enabled' / '$active'"
            ;;
    esac
}

check_timers() {
    section "Timers"

    # Server-side scheduled features.
    _check_timer "snapmulti-status.timer"       "5-min status snapshot for /status web" server
    _check_timer "snapmulti-diagnostics.timer"  "30-min diagnostic snapshots for /var/lib/snapmulti-diagnostics" server
    _check_timer "snapmulti-backup.timer"       "daily MPD database backup to boot partition (cross-reflash continuity)" server
    _check_path  "snapmulti-state-backup.path"  "snapserver/myMPD state backup to boot partition on change (event-driven)" server
    _check_timer "snapmulti-state-backup.timer" "10-min safety-net backup for nested myMPD writes the .path unit doesn't fire on" server

    # Client-side scheduled features. snapclient-discover.timer drives
    # the multi-server failover mechanism (PR #285); without it, a
    # client that loses its server cannot rediscover.
    #
    # Native client (Pi Zero 2W) does not install this timer — snapclient
    # itself uses libavahi-client for mDNS discovery, so no host-side
    # rediscovery script is needed. Skip the check on that path.
    if [[ "${INSTALL_TYPE_NATIVE_CLIENT:-false}" == "true" ]]; then
        info "Timer snapclient-discover.timer skipped on native client (libavahi-client used instead)"
    else
        _check_timer "snapclient-discover.timer"    "mDNS server rediscovery (multi-server failover)" client
    fi
}
