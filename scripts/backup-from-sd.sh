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

info()  { echo -e "\033[34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

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

    # myMPD state
    if [[ -d "$backup_dir/mympd/state" ]]; then
        mkdir -p "$PROJECT_DIR/mympd/workdir"
        cp -r "$backup_dir/mympd/state" "$PROJECT_DIR/mympd/workdir/"
        ok "myMPD playlists restored → mympd/workdir/state/"
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
