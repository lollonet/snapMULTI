#!/usr/bin/env bash
# Backup MPD database to the boot partition (FAT32, the only path that
# survives a reboot under overlayroot=tmpfs).
# Runs periodically via snapmulti-backup.timer.
#
# Runtime state (snapserver server.json + myMPD state/) is handled by
# backup-snapmulti-state.sh and snapmulti-state-backup.path so it is
# not coupled to MPD availability.
set -euo pipefail

# Client-only hosts have no MPD — nothing to back up.
INSTALL_DIR="${INSTALL_DIR:-/opt/snapmulti}"
[[ -d "$INSTALL_DIR" ]] || exit 0

if [[ -z "${BOOT:-}" ]]; then
    if [[ -d /boot/firmware ]]; then
        BOOT=/boot/firmware
    else
        BOOT=/boot
    fi
fi

BACKUP_DIR="$BOOT/snapmulti-backup"
BACKUP_DB="$BACKUP_DIR/mpd/data/mpd.db"

# Same gate as restore-snapmulti-state.sh: a truncated or partial copy
# must never replace a good backup (mpd.conf sets compress "yes").
mpd_db_valid() {
    [[ -s "$1" ]] || return 1
    (( $(wc -c < "$1") >= 256 )) || return 1
    gzip -t "$1" 2>/dev/null
}

# On every exit: drop the temp copy taken from the container, and put the
# boot partition back to ro if this run remounted it rw.
MPD_DB=""
container_copy=""
boot_was_ro=false
cleanup() {
    [[ -n "$container_copy" ]] && rm -f "$container_copy"
    if [[ "$boot_was_ro" == "true" ]]; then
        mount -o remount,ro "$BOOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Get MPD database path from container.
# Only `running` is safe: `restarting` / `created` / `exited` may have an
# inconsistent or empty mpd.db that would clobber a good prior backup.
container_state=$(docker inspect -f '{{.State.Status}}' mpd 2>/dev/null || echo "absent")
if [[ "$container_state" == "running" ]]; then
    # Copy from running container (most up-to-date). Retry once on transient
    # failure (mid-restart, fsync race) before falling back to host path.
    container_copy=$(mktemp)
    MPD_DB="$container_copy"
    cp_ok=false
    for _ in 1 2; do
        if docker cp mpd:/data/mpd.db "$MPD_DB" 2>/dev/null; then
            cp_ok=true
            break
        fi
        sleep 2
    done
    # Reject a failed or damaged copy — overwriting a good backup with a
    # partial file is worse than skipping.
    if [[ "$cp_ok" != "true" ]] || ! mpd_db_valid "$MPD_DB"; then
        MPD_DB=""
    fi
fi

# Fallback: check host path
if [[ -z "$MPD_DB" ]] && mpd_db_valid "$INSTALL_DIR/mpd/data/mpd.db"; then
    MPD_DB="$INSTALL_DIR/mpd/data/mpd.db"
fi

# Nothing to back up — log it so the timer's next run is observable.
if [[ -z "$MPD_DB" ]]; then
    logger -t backup-mpd "skipped: no usable mpd.db (container_state=$container_state)"
    exit 0
fi

# Serialise /boot/firmware mount/write with sibling backup scripts. Without
# this lock the EXIT trap of a concurrent writer (e.g. backup-snapmulti-state
# triggered by snapmulti-state-backup.path / .timer at the same tick) can
# remount the partition ro between our findmnt check and the mkdir/cp below,
# producing 'cannot create directory: Read-only file system' on a fs we just
# successfully validated as rw. Observed on snapvideo 2026-05-29 17:16:44:
# state-backup + mpd-backup fired in the same second, state-backup's cleanup
# remounted ro mid-flight, mpd-backup hit the race.
# (SNAPMULTI_BOOT_LOCK only relocates the lock for the test suite.)
if [[ -n "${SNAPMULTI_BOOT_LOCK:-}" ]]; then
    exec 9>"$SNAPMULTI_BOOT_LOCK"
else
    exec 9>/run/snapmulti-boot-write.lock
fi
if ! flock -w 60 9; then
    logger -t backup-mpd "skipped: could not acquire /run/snapmulti-boot-write.lock within 60s"
    exit 0
fi

# Unchanged since the last run (the usual daily case): no remount, no FAT write.
if cmp -s "$MPD_DB" "$BACKUP_DB"; then
    logger -t backup-mpd "skipped: mpd.db unchanged since the last backup"
    exit 0
fi

# Preserve prior boot partition mount state. Defensive consistency
# with backup-snapmulti-state.sh: this script's trigger is the
# snapmulti-backup.timer which doesn't fire during firstboot, but
# match the safe pattern so a future trigger-on-install path can't
# leave /boot/firmware ro mid-install.
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    boot_was_ro=true
fi

mount_err=$(mount -o remount,rw "$BOOT" 2>&1 || true)

# mount(8) can return 0 silently while fs stays ro (snapvideo 2026-05-29 first-boot race); exit 0 so transient remount failure doesn't degrade /status for 24h.
if findmnt -n -o OPTIONS "$BOOT" 2>/dev/null | tr ',' '\n' | grep -qx ro; then
    logger -t backup-mpd \
        "skipped: $BOOT failed to remount rw (mount err: ${mount_err:-none}) — will retry next timer tick"
    exit 0
fi

mkdir -p "$BACKUP_DIR/mpd/data"
# Leftovers of runs killed mid-copy (other PIDs).
rm -f "$BACKUP_DB".tmp.*

# Stage, flush, then rename: a power cut mid-copy leaves the previous
# backup in place instead of a truncated mpd.db that restore would reject.
tmp_db="$BACKUP_DB.tmp.$$"
cp "$MPD_DB" "$tmp_db"
sync "$tmp_db"
mv "$tmp_db" "$BACKUP_DB"
sync "$BACKUP_DIR/mpd/data"

logger -t backup-mpd "MPD database backed up to $BACKUP_DIR"
