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
#   ./scripts/prepare-sd.sh --dev                  # dev mode: no RO, skip upgrade, verbose
#   ./scripts/prepare-sd.sh --dev /Volumes/bootfs  # dev mode + explicit path
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLIENT_DIR="$PROJECT_DIR/client"

# shellcheck source=common/sanitize.sh
source "$SCRIPT_DIR/common/sanitize.sh"

# ── Preflight: check client directory ─────────────────────────────
check_client_dir() {
    if [[ ! -d "$CLIENT_DIR/common/scripts" ]]; then
        echo "ERROR: client/ directory is missing or incomplete."
        echo "  Expected: $CLIENT_DIR/common/scripts/setup.sh"
        exit 1
    fi
}

patch_user_data_runcmd() {
    local user_data="$1"
    local hook_path="$2"
    local tmp
    tmp=$(mktemp)

    if ! awk -v hook="$hook_path" '
        BEGIN {
            entry = "  - [bash, " hook "]"
            patched = 0
        }
        /^[[:space:]]*runcmd:[[:space:]]*(\[\]|null|~)?[[:space:]]*$/ {
            indent = ""
            if (match($0, /^[[:space:]]*/)) {
                indent = substr($0, 1, RLENGTH)
            }
            print indent "runcmd:"
            print indent entry
            patched = 1
            next
        }
        {
            print
        }
        END {
            if (!patched) {
                print ""
                print "runcmd:"
                print entry
            }
        }
    ' "$user_data" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$user_data"
}

# ── Auto-detect boot partition ────────────────────────────────────
detect_boot() {
    local candidates=()
    # macOS
    [[ -d "/Volumes/bootfs" ]] && candidates+=("/Volumes/bootfs")
    # Linux: common mount points
    for base in "/media/$USER" "/media" "/mnt"; do
        [[ -d "$base/bootfs" ]] && candidates+=("$base/bootfs")
    done
    # Prefer partitions that look like a Pi boot (has cmdline.txt or config.txt)
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate/cmdline.txt" ]] || [[ -f "$candidate/config.txt" ]]; then
            echo "$candidate"
            return
        fi
    done
    # Fall back to first candidate if none have Pi boot files
    if [[ ${#candidates[@]} -gt 0 ]]; then
        echo "${candidates[0]}"
        return
    fi
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
    echo "  Most users choose 1 (streaming). Pick 3 if you"
    echo "  have a music collection on a NAS or server."
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

# ── Advanced options menu ──────────────────────────────────────────
# Defaults (production)
ADV_READONLY="true"
ADV_SKIP_UPGRADE="false"
ADV_IMAGE_TAG="latest"
ADV_VERBOSE_INSTALL="false"

show_advanced_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        Advanced Options                      |"
    echo "  |                                              |"
    echo "  |  Useful for development and testing.         |"
    echo "  |  Press Enter to keep defaults.               |"
    echo "  +---------------------------------------------+"
    echo ""

    local choice

    # 1. Read-only filesystem
    read -rp "  Disable read-only filesystem? [y/N]: " choice
    if [[ "$choice" =~ ^[yY] ]]; then
        ADV_READONLY="false"
        echo "    -> Read-only: DISABLED (changes persist across reboots)"
    else
        echo "    -> Read-only: enabled (default)"
    fi

    # 2. Skip apt upgrade
    read -rp "  Skip apt upgrade (faster install)? [y/N]: " choice
    if [[ "$choice" =~ ^[yY] ]]; then
        ADV_SKIP_UPGRADE="true"
        echo "    -> Apt upgrade: SKIPPED"
    else
        echo "    -> Apt upgrade: enabled (default)"
    fi

    # 3. Image tag
    read -rp "  Docker image tag [latest]: " choice
    if [[ -n "$choice" ]]; then
        ADV_IMAGE_TAG="$choice"
        echo "    -> Image tag: $ADV_IMAGE_TAG"
    else
        echo "    -> Image tag: latest (default)"
    fi

    # 4. Verbose install
    read -rp "  Verbose install output on HDMI? [y/N]: " choice
    if [[ "$choice" =~ ^[yY] ]]; then
        ADV_VERBOSE_INSTALL="true"
        echo "    -> Verbose install: ENABLED"
    else
        echo "    -> Verbose install: disabled (default)"
    fi
    echo ""
}

# Apply all non-default advanced options at once (--dev shortcut)
apply_dev_defaults() {
    ADV_READONLY="false"
    ADV_SKIP_UPGRADE="true"
    ADV_IMAGE_TAG="dev"
    ADV_VERBOSE_INSTALL="true"
    echo ""
    echo "  Dev mode enabled:"
    echo "    -> Read-only: DISABLED"
    echo "    -> Apt upgrade: SKIPPED"
    echo "    -> Image tag: dev (santcasp)"
    echo "    -> Verbose install: ENABLED"
    echo ""
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
            echo "  Try the share name without spaces (e.g. 'My Music' -> 'MyMusic'),"
            echo "  or choose option 4 (manual) to configure fstab yourself."
            continue
        fi
        SMB_SHARE=$(sanitize_smb_share "$raw_share")
        if [[ -n "$SMB_SHARE" ]]; then break; fi
        echo "  Invalid share name. Use only letters, numbers, dots, underscores, hyphens."
    done

    echo ""
    read -rp "  Username (leave empty for guest): " raw_user
    SMB_USER=$(sanitize_smb_user "$raw_user")
    if [[ -n "$raw_user" && "$raw_user" != "$SMB_USER" ]]; then
        echo "  Note: username adjusted to '$SMB_USER' (unsupported characters removed)"
    fi
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
    cp "$SCRIPT_DIR/boot-tune.sh" "$dest/" 2>/dev/null || true
    cp "$SCRIPT_DIR/status.sh" "$dest/" 2>/dev/null || true
    cp "$SCRIPT_DIR/device-smoke.sh" "$dest/" 2>/dev/null || true
    cp "$SCRIPT_DIR/docker-driver-reconcile.sh" "$dest/" 2>/dev/null || true
    # ro-mode helper (client has its own copy, server needs one too)
    [[ -f "$CLIENT_DIR/common/scripts/ro-mode.sh" ]] && cp "$CLIENT_DIR/common/scripts/ro-mode.sh" "$dest/"
    cp -r "$PROJECT_DIR/config" "$dest/"
    cp "$PROJECT_DIR/docker-compose.yml" "$dest/"
    cp "$PROJECT_DIR/.env.example" "$dest/" 2>/dev/null || true

    # Optional: pre-built MPD database (avoids full NFS rescan on deploy)
    if [[ -f "$PROJECT_DIR/mpd/data/mpd.db" ]]; then
        mkdir -p "$dest/mpd/data"
        cp "$PROJECT_DIR/mpd/data/mpd.db" "$dest/mpd/data/"
        echo "  Including pre-built MPD database (fast incremental scan)"
    fi
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

    # Setup scripts + shared modules
    mkdir -p "$dest/scripts" "$dest/scripts/common"
    cp "$CLIENT_DIR/common/scripts/setup.sh" "$dest/scripts/"
    # Shared modules from server scripts/common/ that setup.sh needs
    for _shared in install-deps.sh install-docker.sh system-tune.sh unified-log.sh logging.sh sanitize.sh; do
        [[ -f "$SCRIPT_DIR/common/$_shared" ]] && cp "$SCRIPT_DIR/common/$_shared" "$dest/scripts/common/"
    done
    # boot-tune.sh is a server script but client also needs it for boot-time tuning
    [[ -f "$SCRIPT_DIR/boot-tune.sh" ]] && cp "$SCRIPT_DIR/boot-tune.sh" "$dest/scripts/"
    [[ -f "$SCRIPT_DIR/device-smoke.sh" ]] && cp "$SCRIPT_DIR/device-smoke.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/audio-hat-detect.sh" ]] && cp "$CLIENT_DIR/common/scripts/audio-hat-detect.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/ro-mode.sh" ]] && cp "$CLIENT_DIR/common/scripts/ro-mode.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/discover-server.sh" ]] && cp "$CLIENT_DIR/common/scripts/discover-server.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/display.sh" ]] && cp "$CLIENT_DIR/common/scripts/display.sh" "$dest/scripts/"
    [[ -f "$CLIENT_DIR/common/scripts/display-detect.sh" ]] && cp "$CLIENT_DIR/common/scripts/display-detect.sh" "$dest/scripts/"

    # Systemd service files (display detection boot service)
    if [[ -d "$CLIENT_DIR/common/systemd" ]]; then
        cp -r "$CLIENT_DIR/common/systemd" "$dest/"
    fi
}

# ── Main ──────────────────────────────────────────────────────────
# Parse flags
DEV_MODE=false
BOOT=""
for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=true ;;
        *) BOOT="$arg" ;;
    esac
done
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

# Check client directory if needed
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    check_client_dir
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

# ── Advanced options ──────────────────────────────────────────────
if [[ "$DEV_MODE" == true ]]; then
    apply_dev_defaults
else
    echo ""
    read -rp "  Configure advanced options? [y/N]: " adv_choice
    if [[ "$adv_choice" =~ ^[yY] ]]; then
        show_advanced_menu
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
# Advanced options
ENABLE_READONLY=$ADV_READONLY
SKIP_UPGRADE=$ADV_SKIP_UPGRADE
IMAGE_TAG=$ADV_IMAGE_TAG
VERBOSE_INSTALL=$ADV_VERBOSE_INSTALL
EOF
# Write credentials outside heredoc — unquoted <<EOF expands $, backticks,
# and $() which corrupts passwords containing shell metacharacters.
printf 'SMB_USER=%s\n' "$SMB_USER" >> "$DEST/install.conf"
printf 'SMB_PASS=%s\n' "$SMB_PASS" >> "$DEST/install.conf"

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

# Bake version files so installer scripts can set version vars without a git repo on device.
# Format difference is intentional: server strips "v" (deploy.sh + metadata-service expect
# Both use the same version tag from the monorepo (with "v" prefix).
VERSION=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "dev")
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    echo "$VERSION" > "$DEST/server/.version"
fi
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    echo "$VERSION" > "$DEST/client/VERSION"
fi

echo "  Copied $(du -sh "$DEST" | cut -f1) to boot partition."

# ── Fix USB/I2S conflicts in config.txt ──────────────────────────
# Raspberry Pi Imager sets otg_mode=1 and/or dwc2 with dr_mode=host.
# Both force USB into host mode, which interferes with GPIO I2S/I2C
# communication to audio HATs (PCM5122, WM8804, etc.).
CONFIG_TXT="$BOOT/config.txt"
if [[ -f "$CONFIG_TXT" ]]; then
    # Comment out otg_mode=1 (anywhere in file)
    if grep -q '^otg_mode=1' "$CONFIG_TXT"; then
        sed -i.bak 's/^otg_mode=1/#otg_mode=1 # disabled by snapMULTI (conflicts with I2S HATs)/' "$CONFIG_TXT"
        rm -f "${CONFIG_TXT}.bak"
        echo "  Disabled otg_mode=1 (conflicts with I2S audio HATs)"
    fi
    # Strip dr_mode=host from dwc2 overlay (keep dwc2 for USB gadget support)
    if grep -q '^dtoverlay=dwc2,dr_mode=host' "$CONFIG_TXT"; then
        sed -i.bak 's/^dtoverlay=dwc2,dr_mode=host/dtoverlay=dwc2/' "$CONFIG_TXT"
        rm -f "${CONFIG_TXT}.bak"
        echo "  Removed dr_mode=host from dwc2 overlay (conflicts with I2S HATs)"
    fi
fi

# ── Set temporary 800x600 resolution for setup TUI ────────────────
# KMS driver ignores hdmi_group/hdmi_mode; use kernel video= parameter.
CMDLINE="$BOOT/cmdline.txt"
SETUP_VIDEO="video=HDMI-A-1:800x600@60"
if [[ -f "$CMDLINE" ]] && ! grep -qF "video=HDMI-A-1:" "$CMDLINE"; then
    sed -i.bak "1s/$/ $SETUP_VIDEO/" "$CMDLINE"
    rm -f "${CMDLINE}.bak"
    if grep -qF "$SETUP_VIDEO" "$CMDLINE"; then
        echo "  Set temporary setup resolution (800x600) in cmdline.txt"
    else
        echo "  WARNING: Failed to patch cmdline.txt — display may not work during install"
    fi
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
        if grep -qF "snapmulti/firstboot.sh" "$FIRSTRUN"; then
            echo "  firstrun.sh patched."
        else
            echo "  ERROR: firstrun.sh patch failed — auto-install will NOT run on first boot"
            exit 1
        fi
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
        if ! patch_user_data_runcmd "$USERDATA" "$HOOK_PATH"; then
            echo "  ERROR: failed to patch user-data runcmd"
            exit 1
        fi
        if grep -qF "snapmulti/firstboot.sh" "$USERDATA"; then
            echo "  user-data patched."
        else
            echo "  ERROR: user-data patch failed — auto-install will NOT run on first boot"
            exit 1
        fi
    fi
else
    echo ""
    echo "NOTE: No firstrun.sh or user-data found on boot partition."
    echo "  After booting, SSH into the Pi and run:"
    echo "    sudo bash /boot/firmware/snapmulti/firstboot.sh"
    echo ""
fi

# ── Verify SD card contents ───────────────────────────────────────
echo ""
echo "=== Verifying SD card ==="
VERIFY_ERRORS=0

# -- snapMULTI files --
echo ""
echo "--- snapMULTI files ---"
for f in install.conf firstboot.sh common/progress.sh common/logging.sh common/unified-log.sh common/sanitize.sh common/system-tune.sh common/install-docker.sh common/install-deps.sh common/setup-docker.sh common/wait-network.sh common/mount-music.sh; do
    if [[ -f "$DEST/$f" ]]; then
        echo "  [OK] snapmulti/$f"
    else
        echo "  [MISSING] snapmulti/$f"
        VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
    fi
done

case "$INSTALL_TYPE" in
    server|both)
        for f in server/docker-compose.yml server/deploy.sh server/boot-tune.sh \
                 server/config/snapserver.conf server/config/mpd.conf \
                 server/config/shairport-sync.conf server/config/go-librespot.yml \
                 server/config/tidal-asound.conf server/ro-mode.sh; do
            if [[ -f "$DEST/$f" ]]; then
                echo "  [OK] snapmulti/$f"
            else
                echo "  [MISSING] snapmulti/$f"
                VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
            fi
        done
        # Optional MPD database backup (not an error if missing)
        if [[ -f "$DEST/server/mpd/data/mpd.db" ]]; then
            echo "  [OK] MPD database backup included (fast rescan)"
        else
            echo "  [--] No MPD database backup (full scan on first boot)"
        fi
        ;;
esac

case "$INSTALL_TYPE" in
    client|both)
        for f in client/docker-compose.yml client/scripts/setup.sh \
                 client/scripts/audio-hat-detect.sh \
                 client/scripts/boot-tune.sh client/scripts/ro-mode.sh \
                 client/scripts/discover-server.sh \
                 client/scripts/display.sh client/scripts/display-detect.sh \
                 client/scripts/common/install-deps.sh \
                 client/scripts/common/install-docker.sh \
                 client/snapclient.conf; do
            if [[ -f "$DEST/$f" ]]; then
                echo "  [OK] snapmulti/$f"
            else
                echo "  [MISSING] snapmulti/$f"
                VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
            fi
        done
        # Verify audio HAT configs exist
        hat_count=$(ls -1 "$DEST/client/audio-hats/"*.conf 2>/dev/null | wc -l)
        if [[ "$hat_count" -ge 17 ]]; then
            echo "  [OK] $hat_count audio HAT configs"
        else
            echo "  [WARN] Only $hat_count HAT configs (expected 17+)"
        fi
        ;;
esac

echo "  install.conf -> INSTALL_TYPE=$(grep '^INSTALL_TYPE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> MUSIC_SOURCE=$(grep '^MUSIC_SOURCE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> ENABLE_READONLY=$(grep '^ENABLE_READONLY=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> SKIP_UPGRADE=$(grep '^SKIP_UPGRADE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> IMAGE_TAG=$(grep '^IMAGE_TAG=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> VERBOSE_INSTALL=$(grep '^VERBOSE_INSTALL=' "$DEST/install.conf" | cut -d= -f2)"

# Version files
# Check version files (avoid ;;& which requires Bash 4+, macOS has 3.2)
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    if [[ -f "$DEST/server/.version" ]]; then
        echo "  [OK] Server version: $(cat "$DEST/server/.version")"
    else
        echo "  [WARN] server/.version missing (version will show as 'unknown')"
    fi
fi
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    if [[ -f "$DEST/client/VERSION" ]]; then
        echo "  [OK] Client version: $(cat "$DEST/client/VERSION")"
    else
        echo "  [WARN] client/VERSION missing"
    fi
fi

# -- OS configuration --
echo ""
echo "--- OS configuration ---"

# cmdline.txt: check video= parameter
if [[ -f "$BOOT/cmdline.txt" ]]; then
    if grep -qF "video=HDMI-A-1:" "$BOOT/cmdline.txt"; then
        echo "  [OK] cmdline.txt: install display set to 800x600 (ignored if headless)"
    else
        echo "  [INFO] cmdline.txt: no video= parameter (install TUI uses native resolution)"
    fi
fi

# cloud-init / firstrun hook
if [[ -f "$BOOT/user-data" ]]; then
    if grep -qF "snapmulti/firstboot.sh" "$BOOT/user-data"; then
        echo "  [OK] user-data: runcmd hook present"
    else
        echo "  [MISSING] user-data: runcmd hook for firstboot.sh"
        VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
    fi
elif [[ -f "$BOOT/firstrun.sh" ]]; then
    if grep -qF "snapmulti/firstboot.sh" "$BOOT/firstrun.sh"; then
        echo "  [OK] firstrun.sh: hook present"
    else
        echo "  [MISSING] firstrun.sh: hook for firstboot.sh"
        VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
    fi
else
    echo "  [WARN] No firstrun.sh or user-data found (manual boot required)"
fi

# -- Network configuration --
echo ""
echo "--- Network ---"
if [[ -f "$BOOT/network-config" ]]; then
    echo "  [OK] network-config exists (cloud-init)"
    if grep -q 'wlan\|wifi\|ssid' "$BOOT/network-config" 2>/dev/null; then
        WIFI_SSID=$(sed -n 's/.*"\(.*\)":/\1/p' "$BOOT/network-config" 2>/dev/null | head -1)
        echo "  [OK] WiFi SSID: ${WIFI_SSID:-unknown}"
    else
        echo "  [INFO] No WiFi in network-config (Ethernet only)"
    fi
fi

# Pi Imager stores WiFi in user-data on Bookworm+
if [[ -f "$BOOT/user-data" ]] && grep -qE 'wpa_passphrase|ssid|wifi' "$BOOT/user-data" 2>/dev/null; then
    echo "  [OK] WiFi configured in user-data"
fi

# -- User configuration --
echo ""
echo "--- User ---"
if [[ -f "$BOOT/user-data" ]]; then
    USERNAME=$(sed -n 's/^.*- name: *\([a-z][a-z0-9_-]*\).*/\1/p' "$BOOT/user-data" 2>/dev/null | head -1)
    if [[ -n "$USERNAME" ]]; then
        echo "  [OK] User: $USERNAME"
    else
        echo "  [INFO] No username found in user-data (default: pi)"
    fi
    if grep -q 'ssh_authorized_keys\|ssh_import_id\|ssh-' "$BOOT/user-data" 2>/dev/null; then
        echo "  [OK] SSH keys configured"
    fi
    if grep -q 'lock_passwd.*false\|passwd' "$BOOT/user-data" 2>/dev/null; then
        echo "  [OK] Password configured"
    fi
    HOSTNAME_SET=$(sed -n 's/^hostname: *\(.*\)/\1/p' "$BOOT/user-data" 2>/dev/null | head -1)
    if [[ -n "$HOSTNAME_SET" ]]; then
        echo "  [OK] Hostname: $HOSTNAME_SET"
    fi
fi

# -- Summary --
echo ""
if (( VERIFY_ERRORS > 0 )); then
    echo "WARNING: $VERIFY_ERRORS issue(s) found -- review above before booting."
else
    echo "All checks passed."
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
