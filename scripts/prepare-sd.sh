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

# shellcheck source=common/cmdline-manager.sh
source "$SCRIPT_DIR/common/cmdline-manager.sh"

# shellcheck source=common/release-manifest.sh
source "$SCRIPT_DIR/common/release-manifest.sh"

# shellcheck source=common/install-profile.sh
source "$SCRIPT_DIR/common/install-profile.sh"

# shellcheck source=common/staging-manifest.sh
source "$SCRIPT_DIR/common/staging-manifest.sh"
# install-profile.sh — SSOT for INSTALL_TYPE-derived decisions
# (install_profile_needs_server_stack / _needs_client_stack /
# _configures_music_source / _is_valid). prepare-sd.sh runs on the host
# (Mac/Linux), NOT on the Pi — install_profile_resolve falls through
# unchanged (no is_pi_zero_2w defined here); Pi Zero promotion happens
# on first boot in firstboot.sh:install_profile_resolve.
# Populate MANIFEST_* globals so the advanced-menu default + install.conf
# writer can pin to the manifest's image_set. Returns 0 always (set -e
# safe) — missing manifest yields empty fields and the existing 'latest'
# fallback path is preserved.
parse_release_manifest "$PROJECT_DIR/release-manifest.json"

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
            *) echo "  Invalid choice. Enter 1, 2, or 3." >&2 ;;
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

# ── Audio output menu (client/both only) ─────────────────────────
# Three-level menu:
#   top:    auto-detect | manual HAT | manual built-in
#   HAT:    list 16 supported HATs (excludes internal-audio and usb-audio,
#           both of which are reached via "auto" or sub-menu 3)
#   built:  HDMI vs Headphones (Pi 5 has no jack — flagged in the menu)
#
# Values written to install.conf:
#   AUDIO_HAT=auto             → setup.sh runs full auto-detect (EEPROM → I2C → USB → internal)
#   AUDIO_HAT=<hat-slug>       → setup.sh skips detection, uses the named profile directly
#   AUDIO_HAT=internal-audio   → built-in audio path (no HAT, no USB)
#   AUDIO_INTERNAL_OUTPUT=hdmi|jack   → only when AUDIO_HAT=internal-audio,
#                                       tells setup.sh which built-in card to bind
show_audio_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        Audio output                          |"
    echo "  |                                              |"
    echo "  |  1) Auto-detect (recommended)                |"
    echo "  |     Detects HAT via EEPROM/I2C, falls back   |"
    echo "  |     to USB DAC or built-in audio             |"
    echo "  |                                              |"
    echo "  |  2) I have an audio HAT (choose from list)   |"
    echo "  |                                              |"
    echo "  |  3) No HAT -- use Pi built-in audio          |"
    echo "  |     HDMI (TV/monitor) or 3.5mm jack          |"
    echo "  |                                              |"
    echo "  +---------------------------------------------+"
    echo ""
    echo "  Auto-detect is the right choice for >90% of installs."
    echo "  Use 2 or 3 only if auto-detect failed on a previous attempt."
    echo ""
}

get_audio_type() {
    local choice
    while true; do
        read -rp "  Choose [1-3]: " choice
        case "$choice" in
            1) echo "auto";     return ;;
            2) echo "hat";      return ;;
            3) echo "internal"; return ;;
            *) echo "  Invalid choice. Enter 1, 2, or 3." >&2 ;;
        esac
    done
}

# Enumerate supported HATs from client/common/audio-hats/*.conf.
# Skips `internal-audio` (sub-menu 3) and `usb-audio` (covered by auto-detect).
# Writes "slug|friendly name" pairs to stdout, sorted by friendly name.
_list_supported_hats() {
    local hat_dir="$CLIENT_DIR/common/audio-hats"
    [[ -d "$hat_dir" ]] || return 1
    local f slug name
    for f in "$hat_dir"/*.conf; do
        [[ -f "$f" ]] || continue
        slug=$(basename "$f" .conf)
        case "$slug" in internal-audio|usb-audio) continue ;; esac
        # HAT_NAME="..." line — strip quotes; tolerate either single or double.
        name=$(grep -m1 '^HAT_NAME=' "$f" | cut -d= -f2- | sed 's/^["'"'"']//;s/["'"'"']$//')
        printf '%s|%s\n' "$slug" "${name:-$slug}"
    done | sort -t'|' -k2,2
}

show_hat_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        Choose your audio HAT                 |"
    echo "  +---------------------------------------------+"
    echo ""
    local i=1 name
    while IFS='|' read -r _ name; do
        printf "  %2d) %s\n" "$i" "$name"
        i=$((i + 1))
    done < <(_list_supported_hats)
    echo ""
    echo "  Cancel and return to auto-detect:"
    echo "   0) Back"
    echo ""
}

# Maps the numeric choice from show_hat_menu back to the slug. Returns the
# slug on stdout, "auto" if the user picked 0 (back), or repeats the prompt
# on invalid input. Reads the slug list a second time to keep the menu and
# the resolver in lock-step — anything `_list_supported_hats` shows here
# is selectable here.
get_hat_choice() {
    local hats=()
    while IFS='|' read -r slug _; do
        hats+=("$slug")
    done < <(_list_supported_hats)
    local total=${#hats[@]}
    local choice
    while true; do
        read -rp "  Choose [0-$total]: " choice
        if [[ "$choice" == "0" ]]; then
            echo "auto"
            return
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            echo "${hats[$((choice - 1))]}"
            return
        fi
        echo "  Invalid choice. Enter a number between 0 and $total." >&2
    done
}

show_internal_audio_menu() {
    echo ""
    echo "  +---------------------------------------------+"
    echo "  |        Built-in audio output                 |"
    echo "  |                                              |"
    echo "  |  1) HDMI (TV / monitor)                      |"
    echo "  |     Works on Pi 3, Pi 4, Pi 5                |"
    echo "  |                                              |"
    echo "  |  2) 3.5mm jack (Headphones)                  |"
    echo "  |     Works on Pi 3, Pi 4 only                 |"
    echo "  |     (Pi 5 has no analog jack -- pick 1)      |"
    echo "  |                                              |"
    echo "  +---------------------------------------------+"
    echo ""
    echo "  On Bookworm/Trixie the real ALSA card name is"
    echo "  detected at first boot via 'aplay -L' -- you do"
    echo "  not need to know it here."
    echo ""
}

get_internal_output() {
    local choice
    while true; do
        read -rp "  Choose [1-2]: " choice
        case "$choice" in
            1) echo "hdmi"; return ;;
            2) echo "jack"; return ;;
            *) echo "  Invalid choice. Enter 1 or 2." >&2 ;;
        esac
    done
}

# ── Advanced options menu ──────────────────────────────────────────
# Defaults (production)
ADV_READONLY="true"
ADV_SKIP_UPGRADE="false"
# Image tag default follows the release manifest (image_set field) so a
# fresh SD card pins to the shipped images. Fallback 'latest' preserves
# the legacy behaviour when the manifest is missing.
ADV_IMAGE_TAG="${MANIFEST_IMAGE_SET:-latest}"
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

    # Required entries — abort prep if any are missing.
    local i
    for i in "${!STAGING_SERVER_REQUIRED[@]}"; do
        stage_manifest_entry \
            "${STAGING_SERVER_REQUIRED[$i]}" \
            "$dest" \
            "${STAGING_SERVER_REQUIRED_DESTS[$i]}" \
            "true"
    done

    # Optional entries — silently skipped if absent in source tree.
    for i in "${!STAGING_SERVER_OPTIONAL[@]}"; do
        stage_manifest_entry \
            "${STAGING_SERVER_OPTIONAL[$i]}" \
            "$dest" \
            "${STAGING_SERVER_OPTIONAL_DESTS[$i]}" \
            "false"
    done

    # ─── Special-case inline copies ────────────────────────────────
    # See STAGING_SERVER_SPECIAL_INLINE in staging-manifest.sh.

    # scripts/tidal/ → server/scripts/tidal/ (subdir under scripts/,
    # not the basename location stage_manifest_entry would compute).
    # Contains bind-mounted runtime scripts used by docker-compose.yml.
    if [[ -d "$SCRIPT_DIR/tidal" ]]; then
        mkdir -p "$dest/scripts/tidal"
        cp -r "$SCRIPT_DIR/tidal/." "$dest/scripts/tidal/"
    fi

    # docker/ → server/docker/ via `cp -r src/. dst/` idiom. macOS `cp`
    # lacks `-T` so plain `cp -r src dst/` would nest as `dst/docker/
    # docker/` on re-prep. The bind-mount targets (metadata-service.py
    # etc.) require these files; without the copy Docker creates an
    # empty dir and the container fails with "not a directory" on
    # bind. See PR #319 + the post-merge install failure on pi-server.
    if [[ -d "$PROJECT_DIR/docker" ]]; then
        mkdir -p "$dest/docker"
        cp -r "$PROJECT_DIR/docker/." "$dest/docker/"
    fi

    # mpd/data/mpd.db → only when MUSIC_SOURCE is a network mount. Local
    # USB/disk libraries have different path pointers in the db, so we
    # ship a fresh-scan-on-first-boot instead. See #278.
    if [[ -f "$PROJECT_DIR/mpd/data/mpd.db" ]]; then
        case "${MUSIC_SOURCE:-}" in
            nfs|smb)
                mkdir -p "$dest/mpd/data"
                cp "$PROJECT_DIR/mpd/data/mpd.db" "$dest/mpd/data/"
                echo "  Including pre-built MPD database (fast incremental scan, $MUSIC_SOURCE source)"
                ;;
            *)
                echo "  Skipping MPD db copy (source=${MUSIC_SOURCE:-unset}, fresh scan on first boot)"
                ;;
        esac
    fi
}

# ── Copy client files ─────────────────────────────────────────────
copy_client_files() {
    local dest="$1/client"
    echo "  Copying client files..."
    mkdir -p "$dest" "$dest/scripts" "$dest/scripts/common"

    # Required entries.
    local i
    for i in "${!STAGING_CLIENT_REQUIRED[@]}"; do
        stage_manifest_entry \
            "${STAGING_CLIENT_REQUIRED[$i]}" \
            "$dest" \
            "${STAGING_CLIENT_REQUIRED_DESTS[$i]}" \
            "true"
    done

    # Optional entries.
    for i in "${!STAGING_CLIENT_OPTIONAL[@]}"; do
        stage_manifest_entry \
            "${STAGING_CLIENT_OPTIONAL[$i]}" \
            "$dest" \
            "${STAGING_CLIENT_OPTIONAL_DESTS[$i]}" \
            "false"
    done

    # Shared common/ modules. Each goes to client/scripts/common/. The
    # intentional duplication under /opt/snapclient/scripts/common/ vs
    # /opt/snapmulti/scripts/common/ in `both` mode is bounded by
    # DEC-003 reflash-first — no in-place upgrade path can touch one
    # copy and leave the other stale.
    for shared in "${STAGING_COMMON_SHARED_MODULES[@]}"; do
        stage_manifest_entry \
            "$shared" \
            "$dest" \
            "$STAGING_COMMON_SHARED_MODULES_DEST" \
            "false"
    done

    # ─── Special-case inline copies ────────────────────────────────
    # See STAGING_CLIENT_SPECIAL_INLINE in staging-manifest.sh.

    # initramfs-hooks/ → client/scripts/common/initramfs-hooks/. Runtime
    # glob `_hooks=("$SCRIPT_DIR/common/initramfs-hooks/"*)` with
    # nullglob guard — unmatched glob under `set -euo pipefail` would
    # otherwise abort the whole prepare-sd run. Required by
    # overlayroot-lifecycle.sh:install_initramfs_lzma_hook at finalize
    # time (without it the next boot lands in ext4 fallback —
    # snapdigi 2026-06-01).
    if [[ -d "$SCRIPT_DIR/common/initramfs-hooks" ]]; then
        mkdir -p "$dest/scripts/common/initramfs-hooks"
        shopt -s nullglob
        local _hooks=("$SCRIPT_DIR/common/initramfs-hooks/"*)
        shopt -u nullglob
        if (( ${#_hooks[@]} > 0 )); then
            cp "${_hooks[@]}" "$dest/scripts/common/initramfs-hooks/"
        fi
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

# Defense-in-depth contract consistency with firstboot.sh — see
# install-profile.sh docstring. Additionally, prepare-sd.sh accepts only
# the user-selectable types from get_install_type's menu (client /
# server / both). `client-native` is a runtime derivation performed by
# firstboot.sh on Pi Zero 2W and cannot appear as an SD-prep choice;
# explicit reject surfaces config drift here (where there's no UI yet)
# rather than at first boot 15 minutes later. install_profile_is_valid
# alone would accept client-native because the predicate is shared with
# firstboot.sh's runtime gate.
if ! install_profile_is_valid "$INSTALL_TYPE" || [[ "$INSTALL_TYPE" == "client-native" ]]; then
    echo "ERROR: Invalid INSTALL_TYPE=$INSTALL_TYPE for prepare-sd.sh (valid: client / server / both — client-native is a runtime derivation, not an SD-prep choice)." >&2
    exit 1
fi

# Check client directory if needed
if install_profile_needs_client_stack "$INSTALL_TYPE"; then
    check_client_dir
fi

echo ""
echo "Installing as: $INSTALL_TYPE"
echo ""

# ── Audio output (client/both only) ──────────────────────────────
# AUDIO_HAT default `auto` matches setup.sh's current behaviour: when the
# install is server-only, no audio is configured, so the variable is
# never read on the device. We still emit it to install.conf so the file
# format stays stable across install types — easier to diff and to spot
# manually-edited typos.
AUDIO_HAT="auto"
AUDIO_INTERNAL_OUTPUT=""
if install_profile_needs_client_stack "$INSTALL_TYPE"; then
    show_audio_menu
    audio_type=$(get_audio_type)
    case "$audio_type" in
        auto)
            AUDIO_HAT="auto"
            ;;
        hat)
            show_hat_menu
            AUDIO_HAT=$(get_hat_choice)
            ;;
        internal)
            AUDIO_HAT="internal-audio"
            show_internal_audio_menu
            AUDIO_INTERNAL_OUTPUT=$(get_internal_output)
            ;;
    esac
    echo ""
    echo "Audio: $AUDIO_HAT${AUDIO_INTERNAL_OUTPUT:+ ($AUDIO_INTERNAL_OUTPUT)}"
    echo ""
fi

# ── Music source (server/both only) ─────────────────────────────
MUSIC_SOURCE=""
NFS_SERVER=""
NFS_EXPORT=""
SMB_SERVER=""
SMB_SHARE=""
SMB_USER=""
SMB_PASS=""

if install_profile_needs_server_stack "$INSTALL_TYPE"; then
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
# Audio output (client/both only — server installs ignore these)
#   AUDIO_HAT=auto             → full detection (EEPROM → I2C → USB → built-in)
#   AUDIO_HAT=<hat-slug>       → skip detection, use named profile
#   AUDIO_HAT=internal-audio   → built-in (HDMI or 3.5mm jack)
# AUDIO_INTERNAL_OUTPUT only honoured when AUDIO_HAT=internal-audio:
#   hdmi → bind to vc4-hdmi-0 / vc4hdmi0 / HDMI (kernel-dependent name)
#   jack → bind to "Headphones" card (Pi 3/4 only — Pi 5 falls back to HDMI)
AUDIO_HAT=$AUDIO_HAT
AUDIO_INTERNAL_OUTPUT=$AUDIO_INTERNAL_OUTPUT
# Release identity comes from release-manifest.json on the SD (single SSOT,
# staged below). SNAPMULTI_RELEASE / SNAPMULTI_IMAGE_SET are deliberately NOT
# written here — duplicating them in install.conf shadows the manifest and
# diverges if prepare-sd.sh runs twice across a tag bump.
# Advanced options
ENABLE_READONLY=$ADV_READONLY
SKIP_UPGRADE=$ADV_SKIP_UPGRADE
# IMAGE_TAG is a legitimate operator override (pin to :dev or a specific tag
# while keeping the manifest pinned to a different version). When unset, the
# precedence chain falls back to manifest image_set automatically.
IMAGE_TAG=$ADV_IMAGE_TAG
VERBOSE_INSTALL=$ADV_VERBOSE_INSTALL
TEST_TONE=true
EOF
# Write credentials outside heredoc — unquoted <<EOF expands $, backticks,
# and $() which corrupts passwords containing shell metacharacters.
printf 'SMB_USER=%s\n' "$SMB_USER" >> "$DEST/install.conf"
printf 'SMB_PASS=%s\n' "$SMB_PASS" >> "$DEST/install.conf"

cp "$SCRIPT_DIR/firstboot.sh" "$DEST/"
cp -r "$SCRIPT_DIR/common" "$DEST/"

# Stage release-manifest.json next to install.conf so firstboot can read
# it via "$SNAP_BOOT/release-manifest.json". Guarded copy so set -e
# tolerates the manifest being absent in a custom-built staging tree
# (the parser already returns empty in that case).
if [[ -f "$PROJECT_DIR/release-manifest.json" ]]; then
    cp "$PROJECT_DIR/release-manifest.json" "$DEST/"
fi

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

# Strip host-side junk that `cp -r` can drag onto the FAT boot
# partition. macOS AppleDouble files (`._*`) are especially noisy:
# they preserve host metadata as executable-looking files and then
# firstboot copies them into /opt, confusing diagnostics and humans.
find "$DEST" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
find "$DEST" -type f -name '*.pyc' -delete 2>/dev/null || true
find "$DEST" -type f \( -name '._*' -o -name '.DS_Store' \) -delete 2>/dev/null || true
find "$DEST" -type d -name '__MACOSX' -exec rm -rf {} + 2>/dev/null || true

# Bake version files so installer scripts can set version vars without a git repo on device.
# Format difference is intentional: server strips "v" (deploy.sh + metadata-service expect
# Both use the same version tag from the monorepo (with "v" prefix).
VERSION=$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "dev")
if install_profile_needs_server_stack "$INSTALL_TYPE"; then
    echo "$VERSION" > "$DEST/server/.version"
fi
if install_profile_needs_client_stack "$INSTALL_TYPE"; then
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
# Use cmdline-manager helpers here too — they are pure-bash (no sed)
# and work cross-platform on the host (Mac/Linux/Windows-via-WSL). The
# helper's cmdline_path() defaults to /boot/firmware/cmdline.txt; we
# point it at the SD card's cmdline.txt with a one-shot override.
CMDLINE="$BOOT/cmdline.txt"
SETUP_VIDEO="video=HDMI-A-1:800x600@60"
if [[ -f "$CMDLINE" ]] && ! grep -qF "video=HDMI-A-1:" "$CMDLINE"; then
    # Override cmdline_path() in a subshell so the override doesn't leak
    # to other callers later in this script. The subshell sources the
    # already-loaded function and re-defines cmdline_path locally.
    if ( cmdline_path() { printf '%s\n' "$CMDLINE"; }
         cmdline_add_token "$SETUP_VIDEO" ); then
        if grep -qF "$SETUP_VIDEO" "$CMDLINE"; then
            echo "  Set temporary setup resolution (800x600) in cmdline.txt"
        else
            echo "  WARNING: Failed to patch cmdline.txt — display may not work during install"
        fi
    else
        echo "  WARNING: cmdline_add_token failed — display may not work during install"
    fi
fi
if [[ -f "$CMDLINE" ]]; then
    # Disable Pi OS rpi-swap/zram before systemd starts. firstboot also
    # masks/stops these units, but rpi-resize-swap-file runs before
    # cloud-init; cmdline masks are the only cross-platform way to prevent
    # swap creation during the very first boot without mounting ext4 rootfs.
    SWAP_MASK_UNITS=(
        rpi-resize-swap-file.service
        rpi-setup-loop@var-swap.service
        dev-zram0.swap
        systemd-zram-setup@zram0.service
        rpi-zram-writeback.service
        rpi-zram-writeback.timer
    )
    for _swap_unit in "${SWAP_MASK_UNITS[@]}"; do
        if ! ( cmdline_path() { printf '%s\n' "$CMDLINE"; }
               cmdline_add_token "systemd.mask=${_swap_unit}" ); then
            echo "  WARNING: Failed to mask ${_swap_unit} in cmdline.txt — swap may start before firstboot"
        fi
    done
    unset _swap_unit SWAP_MASK_UNITS

    # Mask non-swap units that we know we never want active. Cmdline
    # masks survive overlayroot upper-layer wipes (a systemctl mask
    # written into /etc/systemd/system/ after overlayroot activates
    # would be lost on every reboot). Parsed by PID 1 before any unit
    # starts.
    BOOT_MASK_UNITS=(
        # NetworkManager-wait-online stalls up to 75s when Imager-staged
        # WiFi credentials don't authenticate (profile in need-auth, no
        # secret agent). snapMULTI doesn't need wait-online: NFS uses
        # lazy automount, containers self-retry.
        NetworkManager-wait-online.service
    )
    for _boot_mask_unit in "${BOOT_MASK_UNITS[@]}"; do
        if ! ( cmdline_path() { printf '%s\n' "$CMDLINE"; }
               cmdline_add_token "systemd.mask=${_boot_mask_unit}" ); then
            echo "  WARNING: Failed to mask ${_boot_mask_unit} in cmdline.txt"
        fi
    done
    unset _boot_mask_unit BOOT_MASK_UNITS

    # ADR-008: IPv6 ON by default — software defenses (Avahi use-ipv6=no, PR #521 #306, boot-tune.sh) cover the original ADR-007 races; kernel disable broke Tidal Connect WebSocket [::] listen.
    if [[ "${DISABLE_IPV6:-false}" == "true" ]]; then
        if ! ( cmdline_path() { printf '%s\n' "$CMDLINE"; }
               cmdline_add_token "ipv6.disable=1" ); then
            echo "  WARNING: Failed to add ipv6.disable=1 to cmdline.txt"
        else
            echo "  IPv6 disabled at kernel cmdline (DISABLE_IPV6=true)"
        fi
    else
        echo "  IPv6 left enabled at kernel (default — Tidal Connect needs it)"
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

# ── Refresh cloud-init meta-data (NoCloud instance-id) ────────────
# Cloud-init treats two boots with the same `instance-id` as the SAME
# instance and skips per-instance modules (incl. runcmd / firstboot).
# When the user re-prepares an SD that was already booted (without a
# fresh Imager flash), the stale `meta-data` would make cloud-init
# skip firstboot. Always write a fresh ID so this boot is "new".
METADATA="$BOOT/meta-data"
if [[ -f "$USERDATA" ]]; then
    if command -v uuidgen >/dev/null 2>&1; then
        NEW_INSTANCE_ID="snapmulti-$(uuidgen | tr 'A-Z' 'a-z')"
    else
        NEW_INSTANCE_ID="snapmulti-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
    fi
    if [[ -f "$METADATA" ]]; then
        OLD_INSTANCE_ID=$(awk -F': *' '/^instance-id:/ {print $2; exit}' "$METADATA" 2>/dev/null || true)
        if [[ -n "${OLD_INSTANCE_ID:-}" ]]; then
            echo "WARNING: meta-data already had instance-id=${OLD_INSTANCE_ID}."
            echo "         If this SD was previously booted, cloud-init would have skipped firstboot."
            echo "         Refreshing to instance-id=${NEW_INSTANCE_ID}."
        fi
    fi
    {
        echo "instance-id: $NEW_INSTANCE_ID"
        echo "# Regenerated by prepare-sd.sh on every run so cloud-init sees a new instance."
    } > "$METADATA"
    echo "  meta-data written (instance-id=$NEW_INSTANCE_ID)"
fi

# ── Verify SD card contents ───────────────────────────────────────
echo ""
echo "=== Verifying SD card ==="
VERIFY_ERRORS=0

# -- snapMULTI files --
echo ""
echo "--- snapMULTI files ---"
for f in install.conf firstboot.sh release-manifest.json common/progress.sh common/logging.sh common/unified-log.sh common/sanitize.sh common/system-tune.sh common/install-docker.sh common/install-deps.sh common/setup-docker.sh common/wait-network.sh common/mount-music.sh common/systemd-snippets.sh common/release-manifest.sh common/play-smoke-tone.sh common/auto-boot-smoke.sh common/restore-snapmulti-state.sh common/backup-snapmulti-state.sh common/snapmulti-state-backup.service common/snapmulti-state-backup.path common/snapmulti-state-backup.timer common/path-resolve.sh common/install-conf-reader.sh common/audio/smoke-pass.wav common/audio/smoke-warn.wav common/audio/smoke-fail.wav common/audio/smoke-skip.wav; do
    if [[ -f "$DEST/$f" ]]; then
        echo "  [OK] snapmulti/$f"
    else
        echo "  [MISSING] snapmulti/$f"
        VERIFY_ERRORS=$(( VERIFY_ERRORS + 1 ))
    fi
done

if install_profile_needs_server_stack "$INSTALL_TYPE"; then
    for f in server/docker-compose.yml server/deploy.sh server/boot-tune.sh \
             server/device-smoke.sh server/docker-driver-reconcile.sh \
             server/scripts/tidal/tidal-meta-bridge.sh \
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
fi

if install_profile_needs_client_stack "$INSTALL_TYPE"; then
    for f in client/docker-compose.yml client/scripts/setup.sh \
             client/scripts/audio-hat-detect.sh \
             client/scripts/boot-tune.sh client/scripts/ro-mode.sh \
             client/scripts/docker-driver-reconcile.sh \
             client/scripts/discover-server.sh \
             client/scripts/display.sh client/scripts/display-detect.sh \
             client/scripts/common/install-deps.sh \
             client/scripts/common/install-docker.sh \
             client/scripts/common/system-tune.sh \
             client/scripts/common/unified-log.sh \
             client/scripts/common/logging.sh \
             client/scripts/common/sanitize.sh \
             client/scripts/common/systemd-snippets.sh \
             client/scripts/common/path-resolve.sh \
             client/scripts/common/install-conf-reader.sh \
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
fi

echo "  install.conf -> INSTALL_TYPE=$(grep '^INSTALL_TYPE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> MUSIC_SOURCE=$(grep '^MUSIC_SOURCE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  release-manifest -> SNAPMULTI_RELEASE=$MANIFEST_RELEASE (SSOT on SD)"
echo "  release-manifest -> SNAPMULTI_IMAGE_SET=$MANIFEST_IMAGE_SET (SSOT on SD)"
echo "  install.conf -> ENABLE_READONLY=$(grep '^ENABLE_READONLY=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> SKIP_UPGRADE=$(grep '^SKIP_UPGRADE=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> IMAGE_TAG=$(grep '^IMAGE_TAG=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> VERBOSE_INSTALL=$(grep '^VERBOSE_INSTALL=' "$DEST/install.conf" | cut -d= -f2)"
echo "  install.conf -> TEST_TONE=$(grep '^TEST_TONE=' "$DEST/install.conf" | cut -d= -f2)"

# Version files
# Check version files (avoid ;;& which requires Bash 4+, macOS has 3.2)
if install_profile_needs_server_stack "$INSTALL_TYPE"; then
    if [[ -f "$DEST/server/.version" ]]; then
        echo "  [OK] Server version: $(cat "$DEST/server/.version")"
    else
        echo "  [WARN] server/.version missing (version will show as 'unknown')"
    fi
fi
if install_profile_needs_client_stack "$INSTALL_TYPE"; then
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
    if [[ -f "$BOOT/meta-data" ]] && grep -qE '^instance-id:[[:space:]]*snapmulti-' "$BOOT/meta-data"; then
        echo "  [OK] meta-data: fresh instance-id ($(awk -F': *' '/^instance-id:/ {print $2; exit}' "$BOOT/meta-data"))"
    else
        echo "  [MISSING] meta-data: instance-id not refreshed — cloud-init may skip firstboot on reused SDs"
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
echo "  3. Power on -- installation takes ~10-15 minutes, then auto-reboots"
if install_profile_needs_server_stack "$INSTALL_TYPE"; then
    echo "  4. Open this URL in a browser (replace <hostname> with the one you set in Imager):"
    echo "       http://<hostname>.local:8083/         <-- start here: lists every server endpoint"
    echo ""
    echo "     Direct links if you prefer:"
    echo "       http://<hostname>.local:1780          Snapweb (volume, rooms, source)"
    echo "       http://<hostname>.local:8180          myMPD (browse and play library)"
    echo "       http://<hostname>.local:8083/status   Status page (containers, audio, mDNS)"
    echo "  5. Cast from your apps:"
    echo "       Spotify  -> select '<hostname> Spotify' in the Spotify app (Premium required)"
    echo "       AirPlay  -> AirPlay icon -> '<hostname> AirPlay'"
    echo "       Tidal    -> cast to '<hostname> Tidal' (ARM/Pi only, enabled by default)"
elif install_profile_needs_client_stack "$INSTALL_TYPE"; then
    # `client-native` was rejected by the gate above, so this branch
    # fires only for `client` (the predicate is also true for `both`
    # which the if-branch above consumes first).
    echo "  4. The player auto-discovers your snapMULTI server via mDNS"
    echo "  5. Check it joined on the server's landing page:"
    echo "       http://<server-hostname>.local:8083/  (lists Snapweb, myMPD, status, ...)"
fi
echo ""
