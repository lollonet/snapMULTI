#!/usr/bin/env bash
# restore-snapmulti-state — restore snapserver group state and myMPD
# user settings from the boot partition into /opt/snapmulti/ before
# the snapmulti-server.service compose-up starts the containers.
#
# Required because under overlayroot=tmpfs (the snapMULTI standard),
# /opt/ lives in volatile RAM — every reboot wipes server.json (snapcast
# groups, client positions) and mympd/workdir/state (smart playlists,
# theme). The companion timer scripts/common/backup-mpd.sh writes these
# files to /boot/firmware/snapmulti-backup/ (FAT32, persistent) every
# 5 min after boot + daily; this script copies them back at the next
# boot before containers start.
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

# Detect boot partition (same logic as backup-mpd.sh).
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

# 1. snapserver group state. The backup file is small and atomic-mv'd
# by backup-mpd.sh, so a partial read here would only happen if the
# FAT32 partition is corrupt — let the cp fail loudly in that case.
if [[ -s "$BACKUP_DIR/data/server.json" ]]; then
    mkdir -p "$INSTALL_DIR/data"
    cp "$BACKUP_DIR/data/server.json" "$INSTALL_DIR/data/server.json"
    chown "$PUID:$PGID" "$INSTALL_DIR/data/server.json" 2>/dev/null || true
    _log "restored snapserver state: $INSTALL_DIR/data/server.json ($(wc -c < "$INSTALL_DIR/data/server.json") bytes)"
    restored_any=1
fi

# 2. myMPD state subdir. Larger than snapserver state but still small
# (~MB-scale). Skip silently when absent — first-boot devices never
# had a chance to back up.
if [[ -d "$BACKUP_DIR/mympd/state" ]]; then
    mkdir -p "$INSTALL_DIR/mympd/workdir"
    cp -a "$BACKUP_DIR/mympd/state" "$INSTALL_DIR/mympd/workdir/"
    chown -R "$PUID:$PGID" "$INSTALL_DIR/mympd/workdir/state" 2>/dev/null || true
    _log "restored myMPD state subdir: $INSTALL_DIR/mympd/workdir/state"
    restored_any=1
fi

if (( restored_any == 0 )); then
    _log "no backup files to restore at $BACKUP_DIR (backup timer never fired? fresh install?)"
fi
