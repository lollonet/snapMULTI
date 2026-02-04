#!/usr/bin/env bash
# prepare-sd.sh — Prepare an SD card for snapMULTI auto-install.
#
# Copies project files to the Pi OS boot partition and patches
# firstrun.sh so our installer runs automatically on first boot.
#
# Usage:
#   ./scripts/prepare-sd.sh                        # auto-detect boot partition
#   ./scripts/prepare-sd.sh /Volumes/bootfs        # macOS
#   ./scripts/prepare-sd.sh /media/$USER/bootfs    # Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Auto-detect boot partition ──────────────────────────────────────
detect_boot() {
    # macOS
    if [ -d "/Volumes/bootfs" ]; then
        echo "/Volumes/bootfs"
        return
    fi
    # Linux: common mount points
    for base in "/media/$USER" "/media" "/mnt"; do
        if [ -d "$base/bootfs" ]; then
            echo "$base/bootfs"
            return
        fi
    done
    return 1
}

BOOT="${1:-}"
if [ -z "$BOOT" ]; then
    if BOOT=$(detect_boot); then
        echo "Auto-detected boot partition: $BOOT"
    else
        echo "ERROR: Could not find boot partition."
        echo ""
        echo "Usage: $0 <path-to-boot-partition>"
        echo "  macOS:  $0 /Volumes/bootfs"
        echo "  Linux:  $0 /media/\$USER/bootfs"
        exit 1
    fi
fi

# ── Validate ────────────────────────────────────────────────────────
if [ ! -d "$BOOT" ]; then
    echo "ERROR: $BOOT is not a directory."
    exit 1
fi

if [ ! -f "$BOOT/config.txt" ] && [ ! -f "$BOOT/cmdline.txt" ]; then
    echo "ERROR: $BOOT does not look like a Raspberry Pi boot partition."
    echo "       (missing config.txt and cmdline.txt)"
    exit 1
fi

# ── Copy project files ──────────────────────────────────────────────
DEST="$BOOT/snapmulti"
echo "Copying project files to $DEST ..."

mkdir -p "$DEST"

# Copy install files
cp "$SCRIPT_DIR/firstboot.sh" "$DEST/"
cp "$SCRIPT_DIR/deploy.sh" "$DEST/"

# Copy config files
cp -r "$PROJECT_DIR/config" "$DEST/"
cp "$PROJECT_DIR/docker-compose.yml" "$DEST/"
cp "$PROJECT_DIR/.env.example" "$DEST/" 2>/dev/null || true

echo "  Copied $(du -sh "$DEST" | cut -f1) to boot partition."

# ── Patch firstrun.sh ───────────────────────────────────────────────
FIRSTRUN="$BOOT/firstrun.sh"
HOOK='bash /boot/firmware/snapmulti/firstboot.sh'

if [ -f "$FIRSTRUN" ]; then
    if grep -qF "snapmulti/firstboot.sh" "$FIRSTRUN"; then
        echo "firstrun.sh already patched, skipping."
    else
        echo "Patching firstrun.sh to chain snapmulti installer ..."
        if grep -q '^rm -f.*firstrun\.sh' "$FIRSTRUN"; then
            sed -i.bak '/^rm -f.*firstrun\.sh/i\
# snapMULTI auto-install\
'"$HOOK"'
' "$FIRSTRUN"
            rm -f "${FIRSTRUN}.bak"
        else
            sed -i.bak '/^exit 0/i\
# snapMULTI auto-install\
'"$HOOK"'
' "$FIRSTRUN"
            rm -f "${FIRSTRUN}.bak"
        fi
        echo "  firstrun.sh patched."
    fi
else
    echo ""
    echo "NOTE: No firstrun.sh found on boot partition."
    echo "  After booting, SSH into the Pi and run:"
    echo "    sudo bash /boot/firmware/snapmulti/firstboot.sh"
    echo ""
fi

# ── Done ────────────────────────────────────────────────────────────
echo ""
echo "=== SD card ready! ==="
echo ""
echo "Next steps:"
echo "  1. Eject the SD card"
echo "  2. Insert into Raspberry Pi"
echo "  3. Power on — installation takes ~5-10 minutes, then auto-reboots"
echo "  4. Access http://snapmulti.local:8180"
echo ""
