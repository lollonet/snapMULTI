#!/usr/bin/env bash
# snapmulti-data-setup — bind-mount snapMULTI state directories
# over persistent locations outside the overlayroot tree so
# container-written state survives reboot.
#
# Covers any path that holds runtime-mutable state which would
# otherwise be lost on reboot (overlayroot tmpfs wipe):
#
#   /opt/snapmulti/data           → server.json (snapcast groups,
#                                   group names, client positions)
#   /opt/snapmulti/mympd/workdir  → myMPD user settings (smart
#                                   playlists, custom scripts, theme)
#
# NOT covered (intentionally volatile or handled elsewhere):
#
#   /opt/snapmulti/mpd/data       — MPD backup timer + boot-partition
#                                   restore already handles this
#   /opt/snapmulti/artwork        — cover-art cache, OK to re-fetch
#   /opt/snapmulti/mympd/cachedir — cover-art cache, OK to re-fetch
#
# Why bind-mount and not sysctl/symlink: /media/root-rw is the
# writable backing fs that holds the overlay upperdir itself
# (`upperdir=/media/root-rw/overlay`). A SIBLING directory there
# is outside the overlay tree → truly persistent. Bind-mount
# masks the staged path with the persistent one so any consumer
# (Docker bind-mount, direct write) lands on persistent storage
# without code changes.
#
# Idempotent: re-running is a no-op once paths are bind-mounted.
# No-op when not on overlayroot — staged paths are already persistent.
set -euo pipefail

PERSIST_ROOT="${PERSIST_ROOT:-/media/root-rw/snapmulti-persist}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
TAG="[snapmulti-data-setup]"

# space-separated list of staged paths to make persistent. Order
# matters only insofar as parent dirs must exist; siblings under
# /opt/snapmulti are independent.
STAGED_PATHS_DEFAULT=(
    "/opt/snapmulti/data"
    "/opt/snapmulti/mympd/workdir"
)
# shellcheck disable=SC2206  # word-splitting is the documented contract
STAGED_PATHS=(${STAGED_PATHS_OVERRIDE:-${STAGED_PATHS_DEFAULT[@]}})

_log() { echo "$TAG $*" >&2; }

# Map /opt/snapmulti/foo/bar → snapmulti-persist/foo/bar (flat namespace
# under PERSIST_ROOT mirrors the staged tree for easy correspondence).
_persist_path_for() {
    local staged="$1"
    local rel="${staged#/opt/snapmulti/}"
    printf '%s/%s' "$PERSIST_ROOT" "$rel"
}

if ! [[ -d /media/root-rw ]]; then
    _log "/media/root-rw missing — host is not on overlayroot, staged paths are already persistent"
    exit 0
fi

mkdir -p "$PERSIST_ROOT"
chown "$PUID:$PGID" "$PERSIST_ROOT"

for staged in "${STAGED_PATHS[@]}"; do
    persist=$(_persist_path_for "$staged")

    if mountpoint -q "$staged" 2>/dev/null; then
        _log "$staged is already a mountpoint — skipping"
        continue
    fi

    mkdir -p "$persist"
    chown "$PUID:$PGID" "$persist"
    chmod 0755 "$persist"

    # First-run migration: PERSIST empty + STAGED has content (live
    # state on upper layer OR lower-layer post-firstboot state) → copy.
    # Must run BEFORE the bind, otherwise the staged path would be
    # masked and the copy would see an empty source.
    if [[ -z "$(ls -A "$persist" 2>/dev/null)" ]] \
       && [[ -d "$staged" ]] \
       && [[ -n "$(ls -A "$staged" 2>/dev/null)" ]]; then
        cp -a "$staged"/. "$persist"/
        _log "migrated $staged -> $persist"
    fi

    # Bind-mount. Any consumer of $staged (Docker bind-mount in the
    # container, direct write from a process) now lands on $persist
    # which is outside the overlayroot tree.
    mkdir -p "$staged"
    if mount --bind "$persist" "$staged"; then
        _log "bind-mounted $persist -> $staged"
    else
        _log "FAILED to bind-mount $persist -> $staged — state for this path will not persist"
    fi
done
