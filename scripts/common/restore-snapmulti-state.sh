#!/usr/bin/env bash
# restore-snapmulti-state — restore snapserver group state and myMPD
# user settings from the boot partition into /opt/snapmulti/ before
# the snapmulti-server.service compose-up starts the containers.
#
# Required because under overlayroot=tmpfs (the snapMULTI standard),
# /opt/ lives in volatile RAM — every reboot wipes server.json (snapcast
# groups, client positions) and mympd/workdir/state (smart playlists,
# theme). The companion snapmulti-state-backup.path writes these files
# to /boot/firmware/snapmulti-backup/ (FAT32, persistent) when they
# change; this script copies them back at the next boot before
# containers start.
#
# Wired as ExecStartPre on snapmulti-server.service. Must complete
# BEFORE compose up — otherwise snapserver creates a default empty
# server.json which would then be backed up over the good one on the
# next timer fire.
#
# Idempotent. No-op when no backup exists yet (fresh install).
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/snapmulti}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
TAG="[restore-snapmulti-state]"

_log() { echo "$TAG $*" >&2; }

load_owner_from_env() {
    local env_file="$INSTALL_DIR/.env"
    [[ -f "$env_file" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            PUID) [[ "$value" =~ ^[0-9]+$ ]] && PUID="$value" ;;
            PGID) [[ "$value" =~ ^[0-9]+$ ]] && PGID="$value" ;;
        esac
    done < <(grep -E '^(PUID|PGID)=[0-9]+$' "$env_file" 2>/dev/null || true)
}

load_owner_from_env

# Skip restore when overlayroot is inactive (RO mode disabled via
# ro-mode.sh). In that mode /opt/snapmulti/data/server.json lives
# directly on ext4 and is already persistent across reboot; the
# backup mechanism keeps the boot partition copy in sync via the
# .path unit, but copying it back over the authoritative ext4 file
# at every boot would (a) waste a write and (b) risk overwriting a
# fresher live state with a stale backup if the .path unit ever
# stopped firing during a maintenance window. The natural ext4
# persistence is the truth in that mode — defer to it.
if ! mount 2>/dev/null | grep -q ' on / type overlay'; then
    _log "overlayroot inactive — ext4 is already persistent, skipping restore"
    exit 0
fi

# Detect boot partition (same logic as backup-snapmulti-state.sh).
if [[ -d /boot/firmware ]]; then
    BOOT=/boot/firmware
else
    BOOT=/boot
fi
BACKUP_DIR="$BOOT/snapmulti-backup"

if [[ ! -d "$BACKUP_DIR" ]]; then
    _log "no backup directory yet at $BACKUP_DIR — nothing to restore (fresh install)"
    exit 0
fi

restored_any=0

# 1. snapserver group state. Validate before restoring — backup file
# could be a partial cp (rare FAT32 corruption or interrupted backup).
# Pattern: try current → fall back to .prev → fail loud if both rotten.
# This script runs as ExecStartPre on snapmulti-server.service with
# no `-` prefix, so a clean fail blocks the unit (intentional —
# silently booting with empty state would be worse data loss).
_restore_server_json_candidate() {
    local _candidate="$1"
    [[ -s "$_candidate" ]] || return 1
    (( $(wc -c < "$_candidate") >= 64 )) || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$_candidate" >/dev/null 2>&1 || return 1
    fi
    mkdir -p "$INSTALL_DIR/data"
    cp "$_candidate" "$INSTALL_DIR/data/server.json" || return 1
    chown "$PUID:$PGID" "$INSTALL_DIR/data/server.json" 2>/dev/null || true
    return 0
}

if [[ -s "$BACKUP_DIR/data/server.json" || -s "$BACKUP_DIR/data/server.json.prev" ]]; then
    if _restore_server_json_candidate "$BACKUP_DIR/data/server.json"; then
        _log "restored snapserver state: $INSTALL_DIR/data/server.json ($(wc -c < "$INSTALL_DIR/data/server.json") bytes)"
        restored_any=1
    elif _restore_server_json_candidate "$BACKUP_DIR/data/server.json.prev"; then
        _log "WARN: $BACKUP_DIR/data/server.json was corrupt/invalid; restored from .prev fallback"
        restored_any=1
    else
        _log "FATAL: both server.json and server.json.prev are corrupt/invalid; refusing to restart snapserver with empty state"
        _log "       inspect $BACKUP_DIR/data/ on the boot partition and remove the bad file(s) to clear this state"
        exit 1
    fi
fi

# 2. myMPD WHOLE workdir (state + config + smartpls + scripts + pics).
# Narrowing this to state/ alone silently loses user-customised smart
# playlists, scripts, theme, uploaded cover art on reboot. Skip
# silently when absent — first-boot devices never had a chance to
# back up.
if [[ -d "$BACKUP_DIR/mympd/workdir" ]]; then
    mkdir -p "$INSTALL_DIR/mympd"
    # Replace existing workdir atomically: stage as workdir.restore,
    # swap, remove old. Avoids a window where partial restore is
    # visible to mympd if it started in parallel. This script runs as
    # ExecStartPre on the snapmulti-server systemd unit — before
    # docker compose up — so both containers see restored state even
    # if compose starts them concurrently.
    _stage="$INSTALL_DIR/mympd/workdir.restore.$$"
    _old="$INSTALL_DIR/mympd/workdir.old.$$"
    rm -rf "$_stage" "$_old"
    cp -a "$BACKUP_DIR/mympd/workdir" "$_stage"
    if [[ -d "$INSTALL_DIR/mympd/workdir" ]]; then
        mv "$INSTALL_DIR/mympd/workdir" "$_old"
    fi
    mv "$_stage" "$INSTALL_DIR/mympd/workdir"
    rm -rf "$_old"
    chown -R "$PUID:$PGID" "$INSTALL_DIR/mympd/workdir" 2>/dev/null || true
    _log "restored myMPD workdir: $INSTALL_DIR/mympd/workdir (full scope: state + config + smartpls + scripts + pics)"
    restored_any=1
fi

if (( restored_any == 0 )); then
    _log "no backup files to restore at $BACKUP_DIR (backup timer never fired? fresh install?)"
fi
