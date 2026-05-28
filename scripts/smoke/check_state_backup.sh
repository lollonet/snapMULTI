#!/usr/bin/env bash
# scripts/smoke/check_state_backup.sh — snapserver + myMPD state
# backup freshness on /boot/firmware/snapmulti-backup/
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# Why this exists: under overlayroot=tmpfs the only userland-writable
# persistent path is /boot/firmware/ (FAT32). snapmulti-backup.timer
# writes server.json + myMPD state subdir there every 5 min after boot
# + daily; restore-snapmulti-state copies them back on every boot via
# ExecStartPre on snapmulti-server.service.
#
# This module surfaces:
#   - whether the backup directory exists and is fresh
#   - which artefacts are backed up (server.json, mympd/state)
#   - explicitly flags STALE backups (> 70 min — gives 60 min OnCalendar
#     daily fire room plus margin) since a stale backup will restore
#     stale state on the next reboot
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_BACKUP_DIR="${SNAPMULTI_BACKUP_DIR:-/boot/firmware/snapmulti-backup}"

check_state_backup() {
    section "State backup"

    if [[ ! -d "$_BACKUP_DIR" ]]; then
        info "State backup not yet present at $_BACKUP_DIR (snapmulti-backup.timer fires 5 min after boot + daily; expected on second timer tick)"
        return 0
    fi

    local _now _reported=false
    _now=$(date +%s)

    # 1. snapserver server.json — the small atomic file with group state.
    if [[ -f "$_BACKUP_DIR/data/server.json" ]]; then
        local _sz _mt _age_min
        _sz=$(stat -c %s "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _mt=$(stat -c %Y "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if (( _age_min > 70 )); then
            warn "snapserver state backup STALE: server.json ${_age_min} min old, ${_sz} B — restore will load stale state on next reboot. Check snapmulti-backup.timer."
        else
            pass_check "snapserver state backup fresh: server.json (${_sz} B, ${_age_min} min old)"
        fi
        _reported=true
    fi

    # 2. myMPD state subdir — smart playlists, scripts, theme.
    if [[ -d "$_BACKUP_DIR/mympd/state" ]]; then
        local _files _mt _age_min
        _files=$(find "$_BACKUP_DIR/mympd/state" -type f 2>/dev/null | wc -l)
        _mt=$(stat -c %Y "$_BACKUP_DIR/mympd/state" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if (( _age_min > 70 )); then
            warn "myMPD state backup STALE: ${_files} files, dir ${_age_min} min old — restore will load stale state on next reboot"
        else
            pass_check "myMPD state backup fresh: ${_files} files (dir ${_age_min} min old)"
        fi
        _reported=true
    fi

    # 3. MPD database backup (mpd.db) — the existing cross-reflash backup
    # we extended for v0.7.9.1 state persistence. Not strictly required
    # for restore-on-reboot (MPD rebuilds the db on start), but useful to
    # surface — its absence means snapmulti-backup.timer hasn't fired
    # successfully even once.
    if [[ -f "$_BACKUP_DIR/mpd/data/mpd.db" ]]; then
        local _sz_mb _mt _age_h
        _sz_mb=$(( $(stat -c %s "$_BACKUP_DIR/mpd/data/mpd.db" 2>/dev/null || echo 0) / 1024 / 1024 ))
        _mt=$(stat -c %Y "$_BACKUP_DIR/mpd/data/mpd.db" 2>/dev/null || echo 0)
        _age_h=$(( (_now - _mt) / 3600 ))
        pass_check "MPD database backup present: mpd.db (${_sz_mb} MB, ${_age_h} h old)"
        _reported=true
    fi

    if [[ "$_reported" != "true" ]]; then
        info "Backup directory $_BACKUP_DIR exists but is empty (snapmulti-backup.timer never produced output? check journalctl -u snapmulti-backup.service)"
    fi
}
