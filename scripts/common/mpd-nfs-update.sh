#!/usr/bin/env bash
# Trigger an MPD incremental rescan when the music library is on a
# network mount.
#
# Background: `auto_update yes` in mpd.conf is driven by Linux inotify,
# which does NOT propagate across the NFS/SMB kernel boundary. Files
# added on the NAS are invisible to MPD until something explicitly
# triggers a `mpc update`. On local libraries (ext4, tmpfs) inotify
# works and this script exits silently as a no-op.
#
# Runs nightly via snapmulti-mpd-update.timer. Scheduled at 03:00 so
# the 04:00 backup-mpd run picks up freshly-scanned tracks.
set -euo pipefail

INSTALL_DIR="/opt/snapmulti"
if [[ ! -d "$INSTALL_DIR" ]]; then
    # Not a server install (client-only host) — nothing to do.
    exit 0
fi

ENV_FILE="$INSTALL_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    logger -t snapmulti-mpd-update "skip: $ENV_FILE missing"
    exit 0
fi

# MUSIC_PATH is the host-side mount point that maps into the MPD
# container as /music. Tolerant to optional quoting in the .env value.
music_path=$(grep -E '^MUSIC_PATH=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
if [[ -z "$music_path" ]]; then
    logger -t snapmulti-mpd-update "skip: MUSIC_PATH unset in $ENV_FILE"
    exit 0
fi

# Network-mount detection — same predicate as scripts/deploy.sh#is_network_mount.
# df -T returns the underlying fs type even if MUSIC_PATH is a bind mount.
fstype=$(df -T "$music_path" 2>/dev/null | awk 'NR==2 {print $2}')
case "$fstype" in
    nfs|nfs4|cifs|smb|smbfs|fuse.sshfs|fuse.rclone)
        : # network — proceed
        ;;
    *)
        # Local fs: inotify works, MPD's auto_update catches new files
        # in real time, this nightly trigger is unnecessary.
        logger -t snapmulti-mpd-update "skip: library on $fstype (local fs, MPD inotify handles it)"
        exit 0
        ;;
esac

# Only fire if the mpd container is actually up. Failing silently is
# safer than blocking: the next nightly firing retries.
state=$(docker inspect -f '{{.State.Status}}' mpd 2>/dev/null || echo absent)
if [[ "$state" != "running" ]]; then
    logger -t snapmulti-mpd-update "skip: mpd container is $state"
    exit 0
fi

logger -t snapmulti-mpd-update "starting incremental update (library on $fstype)"

# Plain `mpc update` (no path arg) walks the whole music_directory
# tree and adds only files whose mtime is newer than what MPD already
# has in its DB. Much faster than a clean rebuild — observed 1-3 min
# on the snapMULTI fleet with ~75 k tracks. Path-argument variants of
# this command are brittle when path components contain spaces (URI
# parsing in mpc truncates at the first whitespace), so we always
# walk the whole tree.
if ! docker exec mpd mpc update >/dev/null 2>&1; then
    logger -t snapmulti-mpd-update "warn: mpc update failed to enqueue"
    exit 0
fi

# Poll updating_db until it clears. Cap at 30 min — past that, something
# is wrong and the next nightly firing handles it. Each poll is cheap
# (a single `docker exec mpd mpc status`), 10 s cadence is plenty.
deadline=$(( $(date +%s) + 1800 ))
while (( $(date +%s) < deadline )); do
    status=$(docker exec mpd mpc status 2>/dev/null | grep -o 'updating_db: [0-9]*' || true)
    if [[ -z "$status" ]]; then
        logger -t snapmulti-mpd-update "incremental update finished"
        exit 0
    fi
    sleep 10
done

logger -t snapmulti-mpd-update "warn: incremental update still running at 30 min deadline — next nightly firing will retry"
exit 0
