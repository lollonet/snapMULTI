#!/usr/bin/env bash
# Extract MPD database backup from an SD card before reflashing.
#
# Usage: ./scripts/backup-from-sd.sh [boot-partition-path]
#
# The Pi's backup timer copies mpd.db to /boot/firmware/snapmulti-backup/
# every day. This script reads it from the SD card (mounted on your Mac/PC)
# and saves it to mpd/data/mpd.db in the project directory, where
# prepare-sd.sh will pick it up automatically.
#
# If no path is given, the script auto-detects common mount points.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source the canonical logger. backup-from-sd.sh runs ON THE HOST (Mac
# or Linux PC with the SD card mounted), not on the Pi. unified-log.sh
# auto-detects interactive mode here ($UNIFIED_LOG is unwritable) and
# falls back to coloured stderr — preserving the look-and-feel of the
# previous inline definitions. The script REQUIRES being run from the
# project bundle so the helper is reachable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/common/unified-log.sh" ]]; then
    # shellcheck source=common/unified-log.sh
    source "$SCRIPT_DIR/common/unified-log.sh"
else
    echo "ERROR: $SCRIPT_DIR/common/unified-log.sh not found" >&2
    echo "  backup-from-sd.sh must be run from the snapMULTI project bundle." >&2
    exit 1
fi

# Find boot partition
find_boot() {
    local given="$1"

    # User provided a path
    if [[ -n "$given" ]]; then
        if [[ -d "$given/snapmulti-backup" ]]; then
            echo "$given"
            return 0
        fi
        error "No snapmulti-backup/ found on $given"
        return 1
    fi

    # Auto-detect common mount points
    local candidates=(
        # macOS
        /Volumes/bootfs
        /Volumes/boot
        # Linux
        /media/*/bootfs
        /media/*/boot
        /mnt/bootfs
        /mnt/boot
    )

    for pattern in "${candidates[@]}"; do
        # shellcheck disable=SC2086
        for candidate in $pattern; do
            if [[ -d "$candidate/snapmulti-backup" ]]; then
                echo "$candidate"
                return 0
            fi
        done
    done

    return 1
}

main() {
    local boot_path
    boot_path=$(find_boot "${1:-}") || {
        error "Could not find SD card with snapMULTI backup."
        echo ""
        echo "Insert the SD card and try again, or specify the boot partition path:"
        echo "  $0 /Volumes/bootfs"
        echo ""
        echo "The Pi backs up mpd.db to the boot partition daily."
        echo "If this is a fresh SD card, there's nothing to extract."
        exit 1
    }

    info "Found backup on: $boot_path"

    local backup_dir="$boot_path/snapmulti-backup"
    local restored=0

    # MPD database
    if [[ -f "$backup_dir/mpd/data/mpd.db" ]]; then
        mkdir -p "$PROJECT_DIR/mpd/data"
        cp "$backup_dir/mpd/data/mpd.db" "$PROJECT_DIR/mpd/data/mpd.db"
        local size
        size=$(du -h "$PROJECT_DIR/mpd/data/mpd.db" | cut -f1)
        ok "MPD database restored ($size) → mpd/data/mpd.db"
        restored=$((restored + 1))
    fi

    # myMPD workdir — current layout is the whole workdir/ (state +
    # config + smartpls + scripts + pics). Older backups may carry
    # just state/; support both layouts.
    if [[ -d "$backup_dir/mympd/workdir" ]]; then
        mkdir -p "$PROJECT_DIR/mympd"
        # Replace any existing workdir at the destination to avoid
        # merging stale files from the previous SD with the restored
        # backup. Same atomic stage+swap idiom as the boot-time
        # restore script.
        local _stage="$PROJECT_DIR/mympd/workdir.restore.$$"
        local _old="$PROJECT_DIR/mympd/workdir.old.$$"
        rm -rf "$_stage" "$_old"
        cp -a "$backup_dir/mympd/workdir" "$_stage"
        if [[ -d "$PROJECT_DIR/mympd/workdir" ]]; then
            mv "$PROJECT_DIR/mympd/workdir" "$_old"
        fi
        mv "$_stage" "$PROJECT_DIR/mympd/workdir"
        rm -rf "$_old"
        ok "myMPD workdir restored → mympd/workdir/ (state + config + smartpls + scripts + pics)"
        restored=$((restored + 1))
    elif [[ -d "$backup_dir/mympd/state" ]]; then
        # Legacy layout — pre-v0.7.9.x SD card. Only state/ subdir
        # was backed up; user-customised smart playlists / scripts /
        # theme are not present in this backup.
        mkdir -p "$PROJECT_DIR/mympd/workdir"
        cp -r "$backup_dir/mympd/state" "$PROJECT_DIR/mympd/workdir/"
        ok "myMPD state restored (legacy backup layout, state/ only) → mympd/workdir/state/"
        warn "Backup is from a pre-v0.7.9.x install — smart playlists / scripts / theme not present in this backup. Future backups will cover the full workdir."
        restored=$((restored + 1))
    fi

    # snapserver group state (server.json) — added in the
    # post-v0.7.9 persistence pattern. Older backups predate this.
    if [[ -f "$backup_dir/data/server.json" ]]; then
        mkdir -p "$PROJECT_DIR/data"
        cp "$backup_dir/data/server.json" "$PROJECT_DIR/data/server.json"
        ok "snapserver group state restored → data/server.json"
        restored=$((restored + 1))
    fi

    if [[ $restored -eq 0 ]]; then
        warn "Backup directory found but empty — nothing to restore"
        exit 0
    fi

    echo ""
    ok "Backup extracted. Now flash the SD card with Pi Imager, then run:"
    echo "  ./scripts/prepare-sd.sh"
    echo ""
    echo "prepare-sd.sh will include the MPD database automatically."
}

main "$@"
