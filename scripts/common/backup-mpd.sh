#!/usr/bin/env bash
# Backup MPD database to the boot partition (FAT32, the only path that
# survives a reboot under overlayroot=tmpfs).
# Runs periodically via snapmulti-backup.timer.
#
# Runtime state (snapserver server.json + myMPD state/) is handled by
# backup-snapmulti-state.sh and snapmulti-state-backup.path so it is
# not coupled to MPD availability.
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

# Get MPD database path from container.
# Only `running` is safe: `restarting` / `created` / `exited` may have an
# inconsistent or empty mpd.db that would clobber a good prior backup.
MPD_DB=""
container_state=$(docker inspect -f '{{.State.Status}}' mpd 2>/dev/null || echo "absent")
if [[ "$container_state" == "running" ]]; then
    # Copy from running container (most up-to-date). Retry once on transient
    # failure (mid-restart, fsync race) before falling back to host path.
    MPD_DB=$(mktemp)
    cp_ok=false
    for _ in 1 2; do
        if docker cp mpd:/data/mpd.db "$MPD_DB" 2>/dev/null; then
            cp_ok=true
            break
        fi
        sleep 2
    done
    # Reject empty / suspiciously-small copy (< 256 bytes) — overwriting a
    # good backup with a partial file is worse than skipping.
    if [[ "$cp_ok" != "true" ]] || [[ ! -s "$MPD_DB" ]] || (( $(wc -c < "$MPD_DB") < 256 )); then
        rm -f "$MPD_DB"
        MPD_DB=""
    fi
fi

# Fallback: check host path
if [[ -z "$MPD_DB" ]] && [[ -s "$INSTALL_DIR/mpd/data/mpd.db" ]]; then
    MPD_DB="$INSTALL_DIR/mpd/data/mpd.db"
fi

# Nothing to back up — log it so the timer's next run is observable.
if [[ -z "$MPD_DB" ]]; then
    logger -t backup-mpd "skipped: no usable mpd.db (container_state=$container_state)"
    exit 0
fi

# Remount boot partition read-write
mount -o remount,rw "$BOOT" 2>/dev/null || true
trap '[[ "${MPD_DB:-}" == /tmp/* ]] && rm -f "$MPD_DB"; mount -o remount,ro "$BOOT" 2>/dev/null || true' EXIT

mkdir -p "$BACKUP_DIR/mpd/data"

# Copy MPD database (temp file cleaned up by EXIT trap)
cp "$MPD_DB" "$BACKUP_DIR/mpd/data/mpd.db"

logger -t backup-mpd "MPD database backed up to $BACKUP_DIR"
