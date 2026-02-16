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
cp -r "$SCRIPT_DIR/common" "$DEST/"

# Copy config files
cp -r "$PROJECT_DIR/config" "$DEST/"
cp "$PROJECT_DIR/docker-compose.yml" "$DEST/"
cp "$PROJECT_DIR/.env.example" "$DEST/" 2>/dev/null || true

echo "  Copied $(du -sh "$DEST" | cut -f1) to boot partition."

# ── Patch boot scripts ──────────────────────────────────────────────
FIRSTRUN="$BOOT/firstrun.sh"
USERDATA="$BOOT/user-data"
HOOK='bash /boot/firmware/snapmulti/firstboot.sh'

if [ -f "$FIRSTRUN" ]; then
    # Legacy Pi Imager (Bullseye): patch firstrun.sh
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
elif [ -f "$USERDATA" ]; then
    # Modern Pi Imager (Bookworm+): patch cloud-init user-data
    if grep -qF "snapmulti/firstboot.sh" "$USERDATA"; then
        echo "user-data already patched, skipping."
    else
        echo "Patching user-data to run snapmulti installer on first boot ..."
        if grep -q '^runcmd:' "$USERDATA"; then
            # Append to existing runcmd section
            sed -i.bak '/^runcmd:/a\  - [bash, /boot/firmware/snapmulti/firstboot.sh]' "$USERDATA"
            rm -f "${USERDATA}.bak"
        else
            # Add runcmd section
            printf '\nruncmd:\n  - [bash, /boot/firmware/snapmulti/firstboot.sh]\n' >> "$USERDATA"
        fi
        echo "  user-data patched."
    fi
else
    echo ""
    echo "NOTE: No firstrun.sh or user-data found on boot partition."
    echo "  After booting, SSH into the Pi and run:"
    echo "    sudo bash /boot/firmware/snapmulti/firstboot.sh"
    echo ""
fi

# ── Unmount SD card ────────────────────────────────────────────────
echo ""
echo "Unmounting SD card..."
if [[ "$(uname -s)" == "Darwin" ]]; then
    diskutil unmount "$BOOT" || echo "WARNING: Could not unmount — eject manually"
else
    sync
    umount "$BOOT" 2>/dev/null || echo "WARNING: Could not unmount — eject manually"
fi

# ── Done ────────────────────────────────────────────────────────────
echo ""
echo "=== SD card ready! ==="
echo ""
echo "Next steps:"
echo "  1. Remove the SD card"
echo "  2. Insert into Raspberry Pi"
echo "  3. Power on — installation takes ~5-10 minutes, then auto-reboots"
echo "  4. Access http://<your-hostname>.local:8180"
echo ""
