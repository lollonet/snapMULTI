#!/usr/bin/env bash
# Backup MPD database to boot partition (FAT32).
# Runs periodically via systemd timer. The backup survives on the SD card
# so that backup-from-sd.sh can extract it before reflashing.
#
# Also backs up myMPD playlists if present.
set -euo pipefail

# Detect install directory
if [[ -d /opt/snapmulti ]]; then
    INSTALL_DIR="/opt/snapmulti"
elif [[ -d /opt/snapclient ]]; then
    # Client-only — no MPD, nothing to back up
    exit 0
else
    exit 0
fi

# Detect boot partition
if [[ -d /boot/firmware ]]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi

BACKUP_DIR="$BOOT/snapmulti-backup"

# Get MPD database path from container
MPD_DB=""
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mpd$'; then
    # Copy from running container (most up-to-date)
    MPD_DB=$(mktemp)
    if ! docker cp mpd:/data/mpd.db "$MPD_DB" 2>/dev/null; then
        rm -f "$MPD_DB"
        MPD_DB=""
    fi
fi

# Fallback: check host path
if [[ -z "$MPD_DB" ]] && [[ -f "$INSTALL_DIR/mpd/data/mpd.db" ]]; then
    MPD_DB="$INSTALL_DIR/mpd/data/mpd.db"
fi

# Nothing to back up
if [[ -z "$MPD_DB" ]]; then
    exit 0
fi

# Remount boot partition read-write
mount -o remount,rw "$BOOT" 2>/dev/null || true
trap '[[ "${MPD_DB:-}" == /tmp/* ]] && rm -f "$MPD_DB"; mount -o remount,ro "$BOOT" 2>/dev/null || true' EXIT

mkdir -p "$BACKUP_DIR/mpd/data"

# Copy MPD database (temp file cleaned up by EXIT trap)
cp "$MPD_DB" "$BACKUP_DIR/mpd/data/mpd.db"

# Optional: myMPD playlists
if [[ -d "$INSTALL_DIR/mympd/workdir/state" ]]; then
    mkdir -p "$BACKUP_DIR/mympd"
    cp -r "$INSTALL_DIR/mympd/workdir/state" "$BACKUP_DIR/mympd/" 2>/dev/null || true
fi

logger -t backup-mpd "MPD database backed up to $BACKUP_DIR"
