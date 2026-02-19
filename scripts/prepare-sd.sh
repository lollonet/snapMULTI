#!/usr/bin/env bash
# prepare-sd.sh — Unified SD card preparation for snapMULTI.
#
# Asks what to install (Audio Player, Music Server, or both), copies
# the right files to the boot partition, and patches firstrun/cloud-init
# so the Pi auto-installs everything on first boot.
#
# Usage:
#   ./scripts/prepare-sd.sh                        # auto-detect boot partition
#   ./scripts/prepare-sd.sh /Volumes/bootfs        # macOS
#   ./scripts/prepare-sd.sh /media/$USER/bootfs    # Linux
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$PROJECT_DIR/client"

# shellcheck source=common/sanitize.sh
source "$SCRIPT_DIR/common/sanitize.sh"

# ── Preflight: check submodule ────────────────────────────────────
check_client_submodule() {
    # .git is a file (gitlink) in submodules, a directory in standalone clones
    if [[ ! -d "$CLIENT_DIR/.git" ]] && [[ ! -f "$CLIENT_DIR/.git" ]]; then
        echo "Client submodule not initialized. Fetching..."
        git -C "$PROJECT_DIR" submodule update --init --recursive
        if [[ ! -d "$CLIENT_DIR/.git" ]] && [[ ! -f "$CLIENT_DIR/.git" ]]; then
            echo "ERROR: client/ submodule is missing."
            echo "  Run: git submodule update --init --recursive"
            exit 1
        fi
    fi
}

# ── Auto-detect boot partition ────────────────────────────────────
detect_boot() {
    # macOS
    if [[ -d "/Volumes/bootfs" ]]; then
        echo "/Volumes/bootfs"
        return
    fi
    # Linux: common mount points
    for base in "/media/$USER" "/media" "/mnt"; do
        if [[ -d "$base/bootfs" ]]; then
            echo "$base/bootfs"
            return
        fi
    done
    return 1
}

# ── Show install menu ─────────────────────────────────────────────
show_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        snapMULTI -- SD Card Setup            |"
    echo "  |                                              |"
    echo "  |  What should this Pi do?                     |"
    echo "  |                                              |"
    echo "  |  1) Audio Player                             |"
    echo "  |     Play music from your server on speakers  |"
    echo "  |                                              |"
    echo "  |  2) Music Server                             |"
    echo "  |     Central hub for Spotify, AirPlay, etc.   |"
    echo "  |                                              |"
    echo "  |  3) Server + Player                          |"
    echo "  |     Both server and local speaker output     |"
    echo "  |                                              |"
    echo "  +---------------------------------------------+"
    echo ""
}

get_install_type() {
    local choice
    while true; do
        read -rp "  Choose [1-3]: " choice
        case "$choice" in
            1) echo "client"; return ;;
            2) echo "server"; return ;;
            3) echo "both";   return ;;
            *) echo "  Invalid choice. Enter 1, 2, or 3." ;;
        esac
    done
}

# ── Music source menu (server/both only) ─────────────────────────
show_music_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        Where is your music?                  |"
    echo "  |                                              |"
    echo "  |  1) Streaming only                           |"
    echo "  |     Spotify, AirPlay, Tidal (no local files) |"
    echo "  |                                              |"
    echo "  |  2) USB drive                                |"
    echo "  |     Plug in before powering on the Pi        |"
    echo "  |                                              |"
    echo "  |  3) Network share (NFS/SMB)                  |"
    echo "  |     Music on a NAS or another computer       |"
    echo "  |                                              |"
    echo "  |  4) I'll set it up later                     |"
    echo "  |     Mount music dir manually after install   |"
    echo "  |                                              |"
    echo "  +---------------------------------------------+"
    echo ""
}

get_music_source() {
    local choice
    while true; do
        read -rp "  Choose [1-4]: " choice
        case "$choice" in
            1) echo "streaming"; return ;;
            2) echo "usb";       return ;;
            3) echo "network";   return ;;
            4) echo "manual";    return ;;
            *) echo "  Invalid choice. Enter 1, 2, 3, or 4." >&2 ;;
        esac
    done
}

get_network_type() {
    local choice
    echo "" >&2
    echo "  Share type:" >&2
    echo "    a) NFS  (Linux/Mac/NAS — most common)" >&2
    echo "    b) SMB  (Windows share)" >&2
    echo "" >&2
    while true; do
        read -rp "  Choose [a/b]: " choice
        case "$choice" in
            a|A) echo "nfs"; return ;;
            b|B) echo "smb"; return ;;
            *) echo "  Invalid choice. Enter a or b." >&2 ;;
        esac
    done
}

get_nfs_config() {
    local raw_server raw_export
    echo ""
    echo "  NFS Server Configuration"
    echo "  Example: nas.local:/volume1/music"

    while true; do
        echo ""
        read -rp "  Server hostname or IP: " raw_server
        NFS_SERVER=$(sanitize_hostname "$raw_server")
        if [[ -n "$NFS_SERVER" ]]; then break; fi
        echo "  Invalid hostname. Use only letters, numbers, dots, hyphens."
    done

    while true; do
        read -rp "  Export path (e.g. /volume1/music): " raw_export
        NFS_EXPORT=$(sanitize_nfs_export "$raw_export")
        if [[ -n "$NFS_EXPORT" ]]; then break; fi
        echo "  Invalid path. Must start with / (e.g. /volume1/music)."
    done

    echo ""
    echo "  Will mount: $NFS_SERVER:$NFS_EXPORT"
}

get_smb_config() {
    local raw_server raw_share
    echo ""
    echo "  SMB/CIFS Configuration"
    printf '  Example: \\\\mypc\\Music  or  mynas/Music\n'

    while true; do
        echo ""
        read -rp "  Server hostname or IP: " raw_server
        SMB_SERVER=$(sanitize_hostname "$raw_server")
        if [[ -n "$SMB_SERVER" ]]; then break; fi
        echo "  Invalid hostname. Use only letters, numbers, dots, hyphens."
    done

    while true; do
        read -rp "  Share name (e.g. Music): " raw_share
        # Detect spaces early — SMB shares with spaces need manual fstab escaping
        if [[ "$raw_share" == *" "* ]]; then
            echo "  Share names with spaces are not supported in auto-setup."
            echo "  Choose option 4 (manual) and see docs/USAGE.md for instructions."
            exit 1
        fi
        SMB_SHARE=$(sanitize_smb_share "$raw_share")
        if [[ -n "$SMB_SHARE" ]]; then break; fi
        echo "  Invalid share name. Use only letters, numbers, dots, underscores, hyphens."
    done

    echo ""
    read -rp "  Username (leave empty for guest): " SMB_USER
    if [[ -n "$SMB_USER" ]]; then
        read -rsp "  Password: " SMB_PASS
        echo ""
    else
        SMB_PASS=""
    fi
    echo ""
    echo "  Will mount: //$SMB_SERVER/$SMB_SHARE"
}

# ── Copy server files ─────────────────────────────────────────────
copy_server_files() {
    local dest="$1/server"
    echo "  Copying server files..."
    mkdir -p "$dest"

    cp "$SCRIPT_DIR/deploy.sh" "$dest/"
    cp -r "$PROJECT_DIR/config" "$dest/"
    cp "$PROJECT_DIR/docker-compose.yml" "$dest/"
    cp "$PROJECT_DIR/.env.example" "$dest/" 2>/dev/null || true
}

# ── Copy client files ─────────────────────────────────────────────
copy_client_files() {
    local dest="$1/client"
    echo "  Copying client files..."
    mkdir -p "$dest"

    # Core install files
    cp "$CLIENT_DIR/install/snapclient.conf" "$dest/"

    # Project files from common/
    for item in docker-compose.yml .env.example audio-hats docker public; do
        if [[ -e "$CLIENT_DIR/common/$item" ]]; then
            cp -r "$CLIENT_DIR/common/$item" "$dest/"
        fi
    done

    # Setup script
    mkdir -p "$dest/scripts"
    cp "$CLIENT_DIR/common/scripts/setup.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/ro-mode.sh" ]] && cp "$CLIENT_DIR/common/scripts/ro-mode.sh" "$dest/scripts/"
}

# ── Main ──────────────────────────────────────────────────────────
BOOT="${1:-}"
if [[ -z "$BOOT" ]]; then
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

# ── Validate ──────────────────────────────────────────────────────
if [[ ! -d "$BOOT" ]]; then
    echo "ERROR: $BOOT is not a directory."
    exit 1
fi

if [[ ! -f "$BOOT/config.txt" ]] && [[ ! -f "$BOOT/cmdline.txt" ]]; then
    echo "ERROR: $BOOT does not look like a Raspberry Pi boot partition."
    echo "       (missing config.txt and cmdline.txt)"
    exit 1
fi

# ── Choose install type ───────────────────────────────────────────
show_menu
INSTALL_TYPE=$(get_install_type)

# Check client submodule if needed
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    check_client_submodule
fi

echo ""
echo "Installing as: $INSTALL_TYPE"
echo ""

# ── Music source (server/both only) ─────────────────────────────
MUSIC_SOURCE=""
NFS_SERVER=""
NFS_EXPORT=""
SMB_SERVER=""
SMB_SHARE=""
SMB_USER=""
SMB_PASS=""

if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    show_music_menu
    MUSIC_SOURCE=$(get_music_source)

    if [[ "$MUSIC_SOURCE" == "network" ]]; then
        NET_TYPE=$(get_network_type)
        MUSIC_SOURCE="$NET_TYPE"
        if [[ "$NET_TYPE" == "nfs" ]]; then
            get_nfs_config
        else
            get_smb_config
        fi
    fi
fi

# ── Copy files to SD card ─────────────────────────────────────────
DEST="$BOOT/snapmulti"
echo "Copying files to $DEST ..."

# Clean previous install (if re-running)
if [[ "$DEST" == */snapmulti ]]; then
    rm -rf "$DEST"
fi
mkdir -p "$DEST"

# Always: install.conf + firstboot + common utilities
# Note: firstboot.sh runs once from the boot partition, then the marker
# file prevents re-runs. It is NOT copied to /opt/ and is not updated by
# git pull — this is intentional (it's a one-shot provisioning script).
cat > "$DEST/install.conf" <<EOF
# snapMULTI Installation Configuration
# Generated by prepare-sd.sh on $(date -Iseconds)
INSTALL_TYPE=$INSTALL_TYPE
MUSIC_SOURCE=$MUSIC_SOURCE
NFS_SERVER=$NFS_SERVER
NFS_EXPORT=$NFS_EXPORT
SMB_SERVER=$SMB_SERVER
SMB_SHARE=$SMB_SHARE
SMB_USER=$SMB_USER
SMB_PASS=$SMB_PASS
EOF

cp "$SCRIPT_DIR/firstboot.sh" "$DEST/"
cp -r "$SCRIPT_DIR/common" "$DEST/"

# Mode-specific files
case "$INSTALL_TYPE" in
    server)
        copy_server_files "$DEST"
        ;;
    client)
        copy_client_files "$DEST"
        ;;
    both)
        copy_server_files "$DEST"
        copy_client_files "$DEST"
        ;;
esac

echo "  Copied $(du -sh "$DEST" | cut -f1) to boot partition."

# ── Set temporary 800x600 resolution for setup TUI ────────────────
# KMS driver ignores hdmi_group/hdmi_mode; use kernel video= parameter.
CMDLINE="$BOOT/cmdline.txt"
SETUP_VIDEO="video=HDMI-A-1:800x600@60"
if [[ -f "$CMDLINE" ]] && ! grep -qF "video=HDMI-A-1:" "$CMDLINE"; then
    sed -i.bak "1s/$/ $SETUP_VIDEO/" "$CMDLINE"
    rm -f "${CMDLINE}.bak"
    echo "  Set temporary setup resolution (800x600) in cmdline.txt"
fi

# ── Patch boot scripts ────────────────────────────────────────────
FIRSTRUN="$BOOT/firstrun.sh"
USERDATA="$BOOT/user-data"
# Bullseye mounts boot at /boot, Bookworm+ at /boot/firmware
HOOK_BOOKWORM='bash /boot/firmware/snapmulti/firstboot.sh'
HOOK_BULLSEYE='bash /boot/snapmulti/firstboot.sh'

if [[ -f "$FIRSTRUN" ]]; then
    # Legacy Pi Imager (Bullseye): boot partition is /boot
    HOOK="$HOOK_BULLSEYE"
    if grep -qF "snapmulti/firstboot.sh" "$FIRSTRUN"; then
        echo "firstrun.sh already patched, skipping."
    else
        echo "Patching firstrun.sh to chain installer ..."
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
elif [[ -f "$USERDATA" ]]; then
    # Modern Pi Imager (Bookworm+): boot partition is /boot/firmware
    HOOK="$HOOK_BOOKWORM"
    if grep -qF "snapmulti/firstboot.sh" "$USERDATA"; then
        echo "user-data already patched, skipping."
    else
        echo "Patching user-data to run installer on first boot ..."
        # Convert "bash /path/to/firstboot.sh" to YAML list "[bash, /path/to/firstboot.sh]"
        HOOK_PATH="${HOOK#bash }"
        RUNCMD_ENTRY="  - [bash, $HOOK_PATH]"
        if grep -q '^runcmd:' "$USERDATA"; then
            # Append to existing runcmd section
            sed -i.bak "/^runcmd:/a\\
$RUNCMD_ENTRY" "$USERDATA"
            rm -f "${USERDATA}.bak"
        else
            # Add runcmd section
            printf '\nruncmd:\n%s\n' "$RUNCMD_ENTRY" >> "$USERDATA"
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

# ── Unmount SD card ───────────────────────────────────────────────
echo ""
echo "Unmounting SD card..."
if [[ "$(uname -s)" == "Darwin" ]]; then
    diskutil unmount "$BOOT" || echo "WARNING: Could not unmount -- eject manually"
else
    sync
    umount "$BOOT" 2>/dev/null || echo "WARNING: Could not unmount -- eject manually"
fi

# ── Done ──────────────────────────────────────────────────────────
echo ""
echo "=== SD card ready! ==="
echo ""
echo "Next steps:"
echo "  1. Remove the SD card"
echo "  2. Insert into Raspberry Pi"
echo "  3. Power on -- installation takes ~5-10 minutes, then auto-reboots"
case "$INSTALL_TYPE" in
    server|both)
        echo "  4. Access http://<your-hostname>.local:8180"
        ;;
    client)
        echo "  4. The player will auto-discover your snapMULTI server"
        ;;
esac
echo ""
