#!/usr/bin/env bash
# scripts/smoke/check_persistence.sh — overlayroot state persistence
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   Under overlayroot the upper tmpfs layer is wiped on every reboot.
#   snapserver group state and myMPD user settings are written at
#   runtime to /opt/snapmulti/data and /opt/snapmulti/mympd/workdir,
#   so without active bind-mounts to a persistent location they reset
#   on every boot.
#
#   snapmulti-data-persistence.service installs those bind-mounts
#   early at boot, sourcing /media/root-rw/snapmulti-persist/* (a
#   sibling of the overlay upperdir, on the writable backing fs).
#
#   This module surfaces:
#     - whether the unit is enabled + active (state should persist)
#     - whether the bind-mounts are in place
#     - whether the persistent location actually holds the expected
#       content (server.json present for snapserver)
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_PERSIST_ROOT=/media/root-rw/snapmulti-persist
_STAGED_PATHS=(
    "/opt/snapmulti/data"
    "/opt/snapmulti/mympd/workdir"
)
_PERSIST_UNIT=snapmulti-data-persistence.service

check_persistence() {
    section "State persistence"

    # No-op on non-overlayroot hosts — staged paths are already
    # persistent on the regular filesystem.
    if [[ ! -d /media/root-rw ]]; then
        info "State persistence check skipped (not on overlayroot — staged paths are already persistent)"
        return 0
    fi

    # Unit installed?
    if ! systemctl list-unit-files "$_PERSIST_UNIT" --no-legend 2>/dev/null \
            | grep -q "$_PERSIST_UNIT"; then
        warn "Persistence unit absent ($_PERSIST_UNIT) — snapserver groups + myMPD settings will NOT survive reboot"
        return 0
    fi

    # Unit active?
    if ! systemctl is-active --quiet "$_PERSIST_UNIT" 2>/dev/null; then
        local _state
        _state=$(systemctl is-active "$_PERSIST_UNIT" 2>/dev/null || echo unknown)
        fail_check "Persistence unit not active ($_PERSIST_UNIT state=$_state) — state from this boot will be lost"
        return 0
    fi

    # Per-path bind-mount + persistent location check.
    local _path _rel _persist _mount_ok=true _missing=()
    for _path in "${_STAGED_PATHS[@]}"; do
        _rel="${_path#/opt/snapmulti/}"
        _persist="$_PERSIST_ROOT/$_rel"
        if mountpoint -q "$_path" 2>/dev/null; then
            pass_check "Persistent bind active: $_path -> $_persist"
        else
            _mount_ok=false
            _missing+=("$_path")
        fi
    done
    if [[ "$_mount_ok" != "true" ]]; then
        # Unit is active (the setup script exits 0 even when mount --bind
        # fails — it logs and continues). A missing bind under an active
        # unit is a real persistence failure: state from this boot will
        # reset on reboot. fail_check (not warn) is the right gate so
        # ADR-005 smoke-as-release-gate catches it.
        fail_check "Persistence unit active but bind-mounts missing: ${_missing[*]} — state will reset on reboot"
    fi

    # Sanity: server.json present in the persistent location?
    if [[ -f "$_PERSIST_ROOT/data/server.json" ]]; then
        local _size
        _size=$(stat -c %s "$_PERSIST_ROOT/data/server.json" 2>/dev/null || echo 0)
        info "snapserver state on persistent fs: server.json ($_size bytes)"
    fi
}
