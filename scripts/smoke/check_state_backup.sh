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
#   - which artefacts are backed up (server.json, mympd/workdir)
#   - explicitly flags backups that lag behind the live source, since
#     that would restore stale state on the next reboot
#
# Reference messaging guidelines in scripts/smoke/MESSAGING.md.

# shellcheck disable=SC2154

_BACKUP_DIR="${SNAPMULTI_BACKUP_DIR:-/boot/firmware/snapmulti-backup}"

check_state_backup() {
    section "State backup"

    # State backup is server-only: it persists snapserver `server.json`
    # (group state) + myMPD workdir + mpd.db across reflashes. A pure
    # client (`MODE=client`, including the Pi Zero 2 W client-native
    # path) has none of those artefacts — `snapmulti-state-backup.{path,
    # timer}` are never installed (see scripts/smoke/check_timers.sh —
    # the units are gated `server`) and `/boot/firmware/snapmulti-backup/`
    # is never written. Surfacing "not yet present" on a client confused
    # the operator into expecting a backup that will never appear.
    if [[ "${MODE:-auto}" != "server" && "${MODE:-auto}" != "both" ]]; then
        info "State backup is server-only (this host runs MODE=${MODE:-auto}) — nothing to back up here"
        return 0
    fi

    if [[ ! -d "$_BACKUP_DIR" ]]; then
        info "State backup not yet present at $_BACKUP_DIR (snapmulti-state-backup.path creates it after the first state change)"
        return 0
    fi

    local _now _reported=false
    _now=$(date +%s)

    # 1. snapserver server.json — the small atomic file with group state.
    # Freshness can't use plain mtime because snapserver rewrites this
    # file every ~3 s to refresh client lastSeen heartbeats. Compare the
    # canonical projection (sorted keys, lastSeen stripped) — if equal,
    # the backup IS up-to-date with the user-meaningful state. Falls
    # back to a generous mtime tolerance when jq is unavailable.
    if [[ -f "$_BACKUP_DIR/data/server.json" ]]; then
        local _sz _mt _age_min
        _sz=$(stat -c %s "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _mt=$(stat -c %Y "$_BACKUP_DIR/data/server.json" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if [[ -f /opt/snapmulti/data/server.json ]] && command -v jq >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
            # Guard each $() with `|| _var=""` so a `jq` parse error on
            # truncated/corrupt server.json doesn't propagate through
            # `set -euo pipefail` and abort the whole smoke run. Hash
            # failure → empty string → falls through to the mtime
            # fallback below, where corruption surfaces as a stale-
            # backup WARN instead of a silent /status outage.
            local _canon_src="" _canon_dst=""
            _canon_src=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' /opt/snapmulti/data/server.json 2>/dev/null | sha256sum | cut -d' ' -f1) || _canon_src=""
            _canon_dst=$(jq -S 'walk(if type == "object" then del(.lastSeen) else . end)' "$_BACKUP_DIR/data/server.json" 2>/dev/null | sha256sum | cut -d' ' -f1) || _canon_dst=""
            if [[ -n "$_canon_src" && -n "$_canon_dst" && "$_canon_src" == "$_canon_dst" ]]; then
                pass_check "snapserver state backup up-to-date: server.json (${_sz} B, ${_age_min} min old, canonical-equal)"
            elif [[ -z "$_canon_src" || -z "$_canon_dst" ]]; then
                # At least one file failed to parse — surface as warn
                # so the operator notices, instead of silently passing
                # via mtime fallback when the content itself is bad.
                warn "snapserver state backup canonical hash failed (live or backup server.json may be corrupt) — see /opt/snapmulti/data/server.json and $_BACKUP_DIR/data/server.json"
            else
                warn "snapserver state backup behind live server.json (canonical diff present) — next snapmulti-state-backup.timer tick will reconcile (5 min max)"
            fi
        else
            local _src_mt=0
            [[ -f /opt/snapmulti/data/server.json ]] && _src_mt=$(stat -c %Y /opt/snapmulti/data/server.json 2>/dev/null || echo 0)
            if (( _src_mt > _mt + 600 )); then
                warn "snapserver state backup mtime behind live server.json by >10 min — restore would load stale state on next reboot"
            else
                pass_check "snapserver state backup fresh: server.json (${_sz} B, ${_age_min} min old, mtime fallback)"
            fi
        fi
        _reported=true
    fi

    # 2. myMPD WHOLE workdir — state + config + smartpls + scripts + pics.
    # Narrowing to state/ alone silently loses user-customised smart
    # playlists / scripts / theme on reboot.
    if [[ -d "$_BACKUP_DIR/mympd/workdir" ]]; then
        local _files _mt _age_min _src_mt=0
        _files=$(find "$_BACKUP_DIR/mympd/workdir" -type f 2>/dev/null | wc -l)
        _mt=$(stat -c %Y "$_BACKUP_DIR/mympd/workdir" 2>/dev/null || echo 0)
        _age_min=$(( (_now - _mt) / 60 ))
        if [[ -d /opt/snapmulti/mympd/workdir ]]; then
            _src_mt=$(stat -c %Y /opt/snapmulti/mympd/workdir 2>/dev/null || echo 0)
        fi
        if (( _src_mt > _mt + 60 )); then
            warn "myMPD workdir backup behind live workdir — restore would load stale state on next reboot"
        else
            pass_check "myMPD workdir backup fresh: ${_files} files (dir ${_age_min} min old)"
        fi
        _reported=true
    fi

    # 3. MPD database backup (mpd.db) — cross-reflash continuity
    # artefact. Not strictly required for restore-on-reboot (MPD
    # rebuilds the db on start), but useful to surface — its absence
    # means snapmulti-backup.timer hasn't produced an MPD db snapshot
    # yet.
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
