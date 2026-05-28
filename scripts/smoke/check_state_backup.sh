#!/usr/bin/env bash
# scripts/smoke/check_state_backup.sh — snapserver + myMPD state
# backup freshness on /boot/firmware/snapmulti-backup/
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# Why this exists: under overlayroot=tmpfs the only userland-writable
# persistent path is /boot/firmware/ (FAT32). snapmulti-state-backup.path
# writes server.json + myMPD state subdir there when they change;
# restore-snapmulti-state copies them back on every boot via ExecStartPre
# on snapmulti-server.service.
#
# This module surfaces:
#   - whether the backup directory exists and is fresh
#   - which artefacts are backed up (server.json, mympd/state)
#   - explicitly flags backups that lag behind the live source, since
#     that would restore stale state on the next reboot
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_BACKUP_DIR="${SNAPMULTI_BACKUP_DIR:-/boot/firmware/snapmulti-backup}"

check_state_backup() {
    section "State backup"

    if [[ ! -d "$_BACKUP_DIR" ]]; then
        info "State backup not yet present at $_BACKUP_DIR (snapmulti-state-backup.path creates it after the first state change)"
        return 0
    fi

    local _now _reported=false
    _now=$(date +%s)

    # 1. snapserver server.json — the small atomic file with group state.
    if [[ -f "$_BACKUP_DIR/data/server.json" ]]; then
        local _sz _mt _age_min _src_mt=0
        _sz=$(stat -c %s "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _mt=$(stat -c %Y "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if [[ -f /opt/snapmulti/data/server.json ]]; then
            _src_mt=$(stat -c %Y /opt/snapmulti/data/server.json 2>/dev/null || echo 0)
        fi
        if (( _src_mt > _mt + 60 )); then
            warn "snapserver state backup behind live server.json — restore would load stale state on next reboot. Check snapmulti-state-backup.path."
        else
            pass_check "snapserver state backup fresh: server.json (${_sz} B, ${_age_min} min old)"
        fi
        _reported=true
    fi

    # 2. myMPD state subdir — smart playlists, scripts, theme.
    if [[ -d "$_BACKUP_DIR/mympd/state" ]]; then
        local _files _mt _age_min _src_mt=0
        _files=$(find "$_BACKUP_DIR/mympd/state" -type f 2>/dev/null | wc -l)
        _mt=$(stat -c %Y "$_BACKUP_DIR/mympd/state" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if [[ -d /opt/snapmulti/mympd/workdir/state ]]; then
            _src_mt=$(stat -c %Y /opt/snapmulti/mympd/workdir/state 2>/dev/null || echo 0)
        fi
        if (( _src_mt > _mt + 60 )); then
            warn "myMPD state backup behind live state directory — restore would load stale state on next reboot"
        else
            pass_check "myMPD state backup fresh: ${_files} files (dir ${_age_min} min old)"
        fi
        _reported=true
    fi

    # 3. MPD database backup (mpd.db) — the existing cross-reflash backup
    # we extended for v0.7.9.1 state persistence. Not strictly required
    # for restore-on-reboot (MPD rebuilds the db on start), but useful to
    # surface — its absence means snapmulti-backup.timer hasn't produced
    # an MPD db snapshot yet.
    if [[ -f "$_BACKUP_DIR/mpd/data/mpd.db" ]]; then
        local _sz_mb _mt _age_h
        _sz_mb=$(( $(stat -c %s "$_BACKUP_DIR/mpd/data/mpd.db" 2>/dev/null || echo 0) / 1024 / 1024 ))
        _mt=$(stat -c %Y "$_BACKUP_DIR/mpd/data/mpd.db" 2>/dev/null || echo 0)
        _age_h=$(( (_now - _mt) / 3600 ))
        pass_check "MPD database backup present: mpd.db (${_sz_mb} MB, ${_age_h} h old)"
        _reported=true
    fi

    if [[ "$_reported" != "true" ]]; then
        info "Backup directory $_BACKUP_DIR exists but is empty (no state change or MPD backup completed yet)"
    fi
}
