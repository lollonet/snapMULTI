#!/usr/bin/env bash
# snapMULTI Unified Auto-Install — runs once on first boot.
#
# Reads install.conf to determine what to install:
#   client — Audio Player (snapclient + optional display)
#   server — Music Server (Spotify, AirPlay, MPD, etc.)
#   both   — Server + Player on the same Pi
#
# Called by cloud-init runcmd or firstrun.sh (patched by prepare-sd.sh).
set -euo pipefail

# Secure PATH - prevent PATH hijacking attacks
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Mode-neutral marker directory (works for client, server, or both)
INSTALLER_STATE="/var/lib/snapmulti-installer"
MARKER="$INSTALLER_STATE/.auto-installed"
FAILED_MARKER="$INSTALLER_STATE/.install-failed"
mkdir -p "$INSTALLER_STATE"

# Skip if already installed
if [[ -f "$MARKER" ]]; then
    echo "snapMULTI already installed, skipping."
    exit 0
fi

# Skip if previous install failed (requires manual intervention)
if [[ -f "$FAILED_MARKER" ]]; then
    echo "Previous install failed. Check /var/log/snapmulti-install.log"
    echo "Remove $FAILED_MARKER to retry."
    exit 1
fi

# Detect boot partition path
if [[ -d /boot/firmware ]]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi

SNAP_BOOT="$BOOT/snapmulti"
LOG="/var/log/snapmulti-install.log"
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

# Verify source files exist
if [[ ! -d "$SNAP_BOOT" ]]; then
    echo "ERROR: $SNAP_BOOT not found on boot partition." | tee -a "$LOG"
    exit 1
fi

# Read install type (targeted parse — do not source FAT32 files as root)
INSTALL_TYPE="server"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    INSTALL_TYPE=$(grep -m1 '^INSTALL_TYPE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')
    INSTALL_TYPE="${INSTALL_TYPE:-server}"
fi

# Read music source config (server/both only)
MUSIC_SOURCE=""
NFS_SERVER=""
NFS_EXPORT=""
SMB_SERVER=""
SMB_SHARE=""
SMB_USER=""
SMB_PASS=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    MUSIC_SOURCE=$(grep -m1 '^MUSIC_SOURCE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')
    # Source sanitize.sh for re-validation (FAT32 has no file permissions —
    # values could be hand-edited before first boot)
    if [[ -f "$SNAP_BOOT/common/sanitize.sh" ]]; then
        # shellcheck source=common/sanitize.sh
        source "$SNAP_BOOT/common/sanitize.sh"
    elif [[ -f "$SCRIPT_DIR/common/sanitize.sh" ]]; then
        # shellcheck source=common/sanitize.sh
        source "$SCRIPT_DIR/common/sanitize.sh"
    fi
    NFS_SERVER=$(sanitize_hostname "$(grep -m1 '^NFS_SERVER=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')")
    NFS_EXPORT=$(sanitize_nfs_export "$(grep -m1 '^NFS_EXPORT=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')")
    SMB_SERVER=$(sanitize_hostname "$(grep -m1 '^SMB_SERVER=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')")
    SMB_SHARE=$(sanitize_smb_share "$(grep -m1 '^SMB_SHARE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')")
    SMB_USER=$(grep -m1 '^SMB_USER=' "$SNAP_BOOT/install.conf" | cut -d= -f2- | tr -d '[:space:]')
    SMB_PASS=$(grep -m1 '^SMB_PASS=' "$SNAP_BOOT/install.conf" | cut -d= -f2-)
fi

# Set install directories
SERVER_DIR="/opt/snapmulti"
CLIENT_DIR="/opt/snapclient"

# Helper: write to both log and HDMI console
log_and_tty() { echo "$*" | tee -a "$LOG" /dev/tty1 2>/dev/null || true; }

# ── Configure progress steps based on install type ────────────────
# These variables are read by progress.sh when sourced below
# shellcheck disable=SC2034
case "$INSTALL_TYPE" in
    client)
        STEP_NAMES=("Network connectivity" "Copy project files"
                    "Install git and dependencies" "Install Docker"
                    "Setup audio player" "Verify containers")
        STEP_WEIGHTS=(5 2 10 30 48 5)
        PROGRESS_TITLE="snapMULTI Audio Player"
        ;;
    server)
        STEP_NAMES=("Network connectivity" "Copy project files"
                    "Install git and dependencies" "Install Docker"
                    "Deploy server" "Verify containers")
        STEP_WEIGHTS=(5 2 8 30 45 10)
        PROGRESS_TITLE="snapMULTI Music Server"
        ;;
    both)
        STEP_NAMES=("Network connectivity" "Copy project files"
                    "Install git and dependencies" "Install Docker"
                    "Deploy server" "Verify server"
                    "Setup audio player" "Verify containers")
        STEP_WEIGHTS=(4 2 7 25 35 4 18 5)
        PROGRESS_TITLE="snapMULTI Server + Player"
        ;;
    *)
        log_and_tty "ERROR: Unknown INSTALL_TYPE=$INSTALL_TYPE"
        exit 1
        ;;
esac

# Guard: step names and weights must match
if [[ ${#STEP_NAMES[@]} -ne ${#STEP_WEIGHTS[@]} ]]; then
    echo "BUG: STEP_NAMES (${#STEP_NAMES[@]}) != STEP_WEIGHTS (${#STEP_WEIGHTS[@]})" | tee -a "$LOG"
    exit 1
fi

# Source progress display (boot partition copy, or local fallback for manual testing)
if [[ -f "$SNAP_BOOT/common/progress.sh" ]]; then
    # shellcheck source=common/progress.sh
    source "$SNAP_BOOT/common/progress.sh"
elif [[ -f "$SCRIPT_DIR/common/progress.sh" ]]; then
    # shellcheck source=common/progress.sh
    source "$SCRIPT_DIR/common/progress.sh"
fi

# Cleanup on failure
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        stop_progress_animation 2>/dev/null || true
        log_and_tty ""
        log_and_tty "  --- Installation FAILED (exit code: $exit_code) ---"
        log_and_tty "  Check log: $LOG"
        log_and_tty ""
        touch "$FAILED_MARKER"
    fi
}
trap cleanup_on_failure EXIT

log_and_tty "========================================="
log_and_tty "snapMULTI Auto-Install ($INSTALL_TYPE)"
log_and_tty "========================================="

# ── Headless detection (for client modes) ─────────────────────────
has_display() {
    [[ -c /dev/fb0 ]] || return 1
    local found_status=false
    for card in /sys/class/drm/card*-HDMI-*/status; do
        [[ -f "$card" ]] || continue
        found_status=true
        grep -q "^connected" "$card" && return 0
    done
    # DRM status files exist but none say "connected" → headless
    $found_status && return 1
    # No DRM status files at all (very old firmware / virtual fb) → assume headless
    return 1
}

# Initialize progress display
progress_init 2>/dev/null || true

# ── Make future boots verbose (kernel messages on HDMI) ───────────
# Stock images ship with "quiet splash" and setup.sh may have added
# "fbcon=map:9" — both hide boot diagnostics. fb-display (client)
# overwrites /dev/fb0 once started, so kernel text doesn't interfere.
CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "$candidate" ]] && CMDLINE_FILE="$candidate" && break
done
if [[ -n "$CMDLINE_FILE" ]]; then
    if grep -qE 'quiet|splash|fbcon=map:9' "$CMDLINE_FILE"; then
        sed -i 's/ quiet//; s/ splash//; s/ fbcon=map:9//' "$CMDLINE_FILE"
        log_and_tty "Enabled verbose boot (removed quiet/splash/fbcon=map:9)"
    fi
fi

# ── System tuning (shared with server/client — runs before overlayroot) ──
# shellcheck source=common/system-tune.sh
if [[ -f "$SNAP_BOOT/common/system-tune.sh" ]]; then
    source "$SNAP_BOOT/common/system-tune.sh"
elif [[ -f "$SCRIPT_DIR/common/system-tune.sh" ]]; then
    source "$SCRIPT_DIR/common/system-tune.sh"
fi
if command -v tune_wifi_powersave &>/dev/null; then
    tune_wifi_powersave
fi

# ── Step counter (tracks current step across install phases) ──────
CURRENT_STEP=0
next_step() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    progress "$CURRENT_STEP" "$1" 2>/dev/null || true
}

# Get weight for the current step (safe accessor, returns 5 as fallback)
current_weight() {
    local idx=$(( CURRENT_STEP - 1 ))
    if (( idx >= 0 && idx < ${#STEP_WEIGHTS[@]} )); then
        echo "${STEP_WEIGHTS[$idx]}"
    else
        echo 5
    fi
}

# Compute cumulative base percentage for completed steps
cumulative_pct() {
    local step=$1
    local total_weight=0 weight_sum=0
    for w in "${STEP_WEIGHTS[@]}"; do
        total_weight=$(( total_weight + w ))
    done
    if (( total_weight == 0 )); then echo 0; return; fi
    for ((i=0; i < step - 1; i++)); do
        weight_sum=$(( weight_sum + STEP_WEIGHTS[i] ))
    done
    echo $(( weight_sum * 100 / total_weight ))
}

# ══════════════════════════════════════════════════════════════════
# STEP 1: Network
# ══════════════════════════════════════════════════════════════════
next_step "Waiting for network..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
log_progress "Waiting for network connectivity..." 2>/dev/null || true

# Ensure WiFi regulatory domain is applied (brcmfmac may ignore the
# kernel parameter on first boot, blocking 5 GHz DFS channels).
REG_DOMAIN=$(sed -n 's/.*cfg80211.ieee80211_regdom=\([A-Z]*\).*/\1/p' /proc/cmdline)
if [[ "$REG_DOMAIN" =~ ^[A-Z]{2}$ ]] && command -v iw &>/dev/null; then
    iw reg set "$REG_DOMAIN" 2>/dev/null || true
    log_progress "Set regulatory domain: $REG_DOMAIN" 2>/dev/null || true
fi

# Diagnostic: log interface states for troubleshooting
log_net_state() {
    log_progress "--- Network diagnostics ---" 2>/dev/null || true
    ip -brief link 2>/dev/null | while read -r line; do
        log_progress "  Link: $line" 2>/dev/null || true
    done
    ip -brief addr 2>/dev/null | while read -r line; do
        log_progress "  Addr: $line" 2>/dev/null || true
    done
    log_progress "  Route: $(ip route show default 2>/dev/null || echo 'none')" 2>/dev/null || true
    if command -v nmcli &>/dev/null; then
        log_progress "  NM: $(nmcli -t general status 2>/dev/null || echo 'unavailable')" 2>/dev/null || true
        nmcli -t -f NAME,TYPE,STATE connection show 2>/dev/null | while read -r line; do
            log_progress "  Conn: $line" 2>/dev/null || true
        done
    fi
}

# Staged network recovery — escalates with each threshold
# Usage: try_recover_network <iteration> [dns-only]
#   dns-only: skip destructive stages (1,2,4) when IP already works
try_recover_network() {
    local i=$1
    local mode=${2:-full}

    # Stage 1 (30s, 40s): Kick WiFi connection
    if [[ "$mode" != "dns-only" ]] && { (( i == 15 )) || (( i == 20 )); }; then
        if command -v nmcli &>/dev/null; then
            local wifi_conn
            wifi_conn=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                | awk -F: '/wifi/ {print $1; exit}')
            if [[ -n "$wifi_conn" ]]; then
                log_progress "Activating WiFi: $wifi_conn" 2>/dev/null || true
                nmcli connection up "$wifi_conn" 2>/dev/null || true
            fi
        fi
    fi

    # Stage 2 (60s): Restart NetworkManager, re-activate all connections
    if [[ "$mode" != "dns-only" ]] && (( i == 30 )); then
        log_progress "Restarting NetworkManager..." 2>/dev/null || true
        log_net_state
        systemctl restart NetworkManager 2>/dev/null || true
        sleep 3
        if command -v nmcli &>/dev/null; then
            nmcli -t -f NAME,TYPE connection show 2>/dev/null | while IFS=: read -r name _type; do
                log_progress "Activating: $name" 2>/dev/null || true
                nmcli connection up "$name" 2>/dev/null || true
            done
        fi
    fi

    # Stage 3 (90s): Add fallback DNS if ping works but resolution fails
    if (( i == 45 )); then
        if ping -c1 -W2 1.1.1.1 &>/dev/null && ! getent hosts deb.debian.org &>/dev/null; then
            log_progress "Adding fallback DNS (1.1.1.1)..." 2>/dev/null || true
            if [[ -f /etc/resolv.conf ]]; then
                sed -i '1i nameserver 1.1.1.1' /etc/resolv.conf 2>/dev/null || true
            else
                echo "nameserver 1.1.1.1" > /etc/resolv.conf
            fi
        fi
    fi

    # Stage 4 (120s): Bounce interfaces to force re-negotiation
    if [[ "$mode" != "dns-only" ]] && (( i == 60 )); then
        log_progress "Bouncing network interfaces..." 2>/dev/null || true
        for iface in wlan0 eth0; do
            if ip link show "$iface" &>/dev/null; then
                ip link set "$iface" down 2>/dev/null || true
                sleep 1
                ip link set "$iface" up 2>/dev/null || true
            fi
        done
    fi
}

NETWORK_READY=false
log_net_state
for i in $(seq 1 90); do
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if { [[ -n "$GATEWAY" ]] && ping -c1 -W2 "$GATEWAY" &>/dev/null; } || \
       ping -c1 -W2 1.1.1.1 &>/dev/null || \
       ping -c1 -W2 8.8.8.8 &>/dev/null; then
        if getent hosts deb.debian.org &>/dev/null; then
            log_and_tty "Network ready."
            log_progress "Network ready" 2>/dev/null || true
            NETWORK_READY=true
            break
        fi
        # IP works but DNS fails — only Stage 3 (fallback DNS), skip destructive stages
        try_recover_network "$i" dns-only
        [[ $((i % 10)) -eq 0 ]] && log_progress "  DNS not ready ($i/90)..." 2>/dev/null || true
    else
        try_recover_network "$i"
        [[ $((i % 10)) -eq 0 ]] && log_progress "  No connectivity ($i/90)..." 2>/dev/null || true
    fi
    sleep 2
done

if [[ "$NETWORK_READY" == "false" ]]; then
    log_and_tty "ERROR: Network not available after 3 minutes."
    log_net_state
    log_and_tty "Check WiFi credentials or Ethernet connection."
    exit 1
fi

# ── Wait for NTP time sync before apt operations ─────────────────
# Pi has no hardware RTC — clock starts at image build date.
# apt signature verification (sqv) rejects repos with "Not live until"
# timestamps in the future relative to the Pi's stale clock.
log_progress "Waiting for time sync..." 2>/dev/null || true
timedatectl set-ntp true 2>/dev/null || true
for _ntp_wait in $(seq 1 30); do
    if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q yes; then
        log_progress "Clock synchronized" 2>/dev/null || true
        break
    fi
    sleep 2
done
if ! timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q yes; then
    log_and_tty "WARNING: NTP sync not confirmed after 60s — apt signatures may fail"
fi

# ══════════════════════════════════════════════════════════════════
# STEP 2: Copy files
# ══════════════════════════════════════════════════════════════════
next_step "Copying project files..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
log_progress "Copying files from boot partition..." 2>/dev/null || true

# Copy server files
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    mkdir -p "$SERVER_DIR/scripts"
    if [[ -d "$SNAP_BOOT/server" ]]; then
        cp "$SNAP_BOOT/server/docker-compose.yml" "$SERVER_DIR/"
        cp "$SNAP_BOOT/server/.env.example" "$SERVER_DIR/" 2>/dev/null || true
        cp -r "$SNAP_BOOT/server/config" "$SERVER_DIR/"
        cp "$SNAP_BOOT/server/deploy.sh" "$SERVER_DIR/scripts/"
        cp "$SNAP_BOOT/server/boot-tune.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/status.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/.version" "$SERVER_DIR/" 2>/dev/null || true
    fi
    cp -r "$SNAP_BOOT/common" "$SERVER_DIR/scripts/" 2>/dev/null || true
    log_progress "Server files copied to $SERVER_DIR" 2>/dev/null || true
fi

# Copy client files
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    mkdir -p "$CLIENT_DIR/scripts"
    # Copy shared libs (system-tune.sh, logging.sh, etc.) so setup.sh can source them
    cp -r "$SNAP_BOOT/common" "$CLIENT_DIR/scripts/" 2>/dev/null || true
    if [[ -d "$SNAP_BOOT/client" ]]; then
        # Copy all client files — fail loudly on errors
        cp -r "$SNAP_BOOT/client/"* "$CLIENT_DIR/" || {
            log_and_tty "ERROR: Failed to copy client files from $SNAP_BOOT/client/"
            exit 1
        }
        # Copy dotfiles (.env.example) — glob may match nothing, which is OK
        if ! cp -r "$SNAP_BOOT/client/".??* "$CLIENT_DIR/" 2>/dev/null; then
            echo "Note: no dotfiles found in client source (non-fatal)" >> "$LOG"
        fi
    fi
    # Verify critical client files were copied
    missing=()
    [[ -f "$CLIENT_DIR/docker-compose.yml" ]] || missing+=("docker-compose.yml")
    [[ -f "$CLIENT_DIR/scripts/setup.sh" ]] || missing+=("scripts/setup.sh")
    [[ -d "$CLIENT_DIR/audio-hats" ]] || missing+=("audio-hats/")
    [[ -f "$CLIENT_DIR/scripts/display.sh" ]] || missing+=("scripts/display.sh")
    [[ -f "$CLIENT_DIR/scripts/display-detect.sh" ]] || missing+=("scripts/display-detect.sh")
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_and_tty "ERROR: Critical client files missing after copy: ${missing[*]}"
        exit 1
    fi
    log_progress "Client files copied to $CLIENT_DIR" 2>/dev/null || true
fi

log_progress "Files copied" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 3: Install git + system dependencies
# ══════════════════════════════════════════════════════════════════
next_step "Installing git and dependencies..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

# Wait for any background apt (unattended-upgrades, cloud-init) to finish.
# First boot often triggers apt-daily.service concurrently.
wait_for_apt_lock() {
    local _apt_wait
    for _apt_wait in $(seq 1 60); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
        sleep 5
    done
    log_and_tty "WARNING: apt lock still held after 5 minutes — proceeding anyway"
}

log_progress "Waiting for apt lock..." 2>/dev/null || true
wait_for_apt_lock

log_progress "apt-get update" 2>/dev/null || true
apt-get update -qq

# Upgrade all packages (security patches, bug fixes, kernel).
# Runs before overlayroot — changes persist in the base layer.
# The reboot at the end of firstboot activates any new kernel.
log_progress "Upgrading system packages..." 2>/dev/null || true
if ! apt-get upgrade -y -qq >> "$LOG" 2>&1; then
    log_and_tty "WARNING: apt upgrade failed (non-fatal, continuing with existing packages)"
fi

# Core dependencies (always needed)
PKGS=(curl ca-certificates)

# Git for updates
if ! command -v git &>/dev/null; then
    PKGS+=(git)
fi

# Avahi for mDNS (server needs it for Spotify/AirPlay, client for discovery)
if ! command -v avahi-daemon &>/dev/null; then
    PKGS+=(avahi-daemon)
fi

# NFS/SMB packages for music source mounts
if [[ "$MUSIC_SOURCE" == "nfs" ]]; then
    PKGS+=(nfs-common)
fi
if [[ "$MUSIC_SOURCE" == "smb" ]]; then
    PKGS+=(cifs-utils)
fi

log_progress "Installing: ${PKGS[*]}" 2>/dev/null || true
apt-get install -y -qq "${PKGS[@]}" >/dev/null

# Enable avahi if just installed
if command -v avahi-daemon &>/dev/null; then
    systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
fi

log_progress "System dependencies installed" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 4: Docker
# ══════════════════════════════════════════════════════════════════
next_step "Installing Docker..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

if ! command -v docker &>/dev/null; then
    log_progress "Setting up Docker repository..." 2>/dev/null || true
    # shellcheck source=common/install-docker.sh
    if [[ -f "$SNAP_BOOT/common/install-docker.sh" ]]; then
        source "$SNAP_BOOT/common/install-docker.sh"
    else
        source "$SCRIPT_DIR/common/install-docker.sh"
    fi
    log_progress "Installing docker-ce..." 2>/dev/null || true
    install_docker_apt

    # Docker daemon config: live-restore now, fuse-overlayfs added below
    # after the package is installed.
    tune_docker_daemon --live-restore

    systemctl enable docker
    systemctl start docker

    FIRST_USER=$(getent passwd 1000 | cut -d: -f1 || true)
    [[ -n "$FIRST_USER" ]] && usermod -aG docker "$FIRST_USER"

    # cgroup memory controller (cmdline.txt) is also handled by deploy.sh

    log_progress "Docker installed" 2>/dev/null || true
else
    log_progress "Docker already installed, skipping" 2>/dev/null || true
fi

# Verify Docker is running
if ! docker info &>/dev/null; then
    log_and_tty "ERROR: Docker failed to start."
    exit 1
fi

# All modes use fuse-overlayfs — required for read-only filesystem support.
# Install the package and switch Docker's storage driver.
{
    current_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "none")
    if [[ "$current_driver" != "fuse-overlayfs" ]]; then
        log_progress "Switching Docker to fuse-overlayfs (read-only FS support)..." 2>/dev/null || true
        wait_for_apt_lock
        if apt-get install -y fuse-overlayfs >> "$LOG" 2>&1; then
            tune_docker_daemon --fuse-overlayfs
            systemctl stop docker
            rm -rf /var/lib/docker/*
            if ! systemctl start docker; then
                log_and_tty "ERROR: Docker failed to start after storage driver switch."
                exit 1
            fi
            # Verify driver actually switched
            new_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
            if [[ "$new_driver" == "fuse-overlayfs" ]]; then
                log_progress "Docker storage driver: fuse-overlayfs" 2>/dev/null || true
            else
                log_and_tty "WARNING: Docker started but driver is '$new_driver', not fuse-overlayfs."
                log_and_tty "         Read-only mode may not work correctly."
            fi
        else
            log_and_tty "ERROR: Failed to install fuse-overlayfs — required for read-only mode."
            exit 1
        fi
    fi
}

# ══════════════════════════════════════════════════════════════════
# Music source setup (runs inside deploy step — no extra progress step)
# ══════════════════════════════════════════════════════════════════
setup_music_source() {
    case "${MUSIC_SOURCE:-}" in
        streaming)
            mkdir -p /media/music
            export MUSIC_PATH="/media/music"
            export SKIP_MUSIC_SCAN=1
            log_progress "Streaming-only mode — no local music library" 2>/dev/null || true
            ;;
        usb)
            # Find and mount the first USB block device with a filesystem.
            # Headless Debian doesn't auto-mount — we need to do it explicitly.
            local usb_dev="" usb_mount="/media/usb-music"
            for dev in /dev/sd?1 /dev/sd?; do
                [[ -b "$dev" ]] || continue
                # Skip the SD card (mmcblk) and only match USB/SATA
                blkid "$dev" &>/dev/null && { usb_dev="$dev"; break; }
            done
            if [[ -n "$usb_dev" ]]; then
                mkdir -p "$usb_mount"
                log_progress "Mounting USB: $usb_dev → $usb_mount" 2>/dev/null || true
                if mount "$usb_dev" "$usb_mount" -o ro; then
                    if ! grep -qF "$usb_dev" /etc/fstab; then
                        echo "$usb_dev $usb_mount auto ro,nofail 0 0" >> /etc/fstab
                    fi
                    export MUSIC_PATH="$usb_mount"
                    log_progress "USB mounted: $usb_dev at $usb_mount" 2>/dev/null || true
                else
                    log_and_tty "WARNING: Failed to mount $usb_dev — deploy.sh will try auto-detect"
                fi
            else
                log_and_tty "WARNING: No USB drive found — plug in before powering on"
                log_progress "USB mode — no drive detected, deploy.sh will scan /media/*" 2>/dev/null || true
            fi
            ;;
        nfs)
            local mount_point="/media/nfs-music"
            mkdir -p "$mount_point"
            log_progress "Mounting NFS: $NFS_SERVER:$NFS_EXPORT" 2>/dev/null || true
            if mount -t nfs "$NFS_SERVER:$NFS_EXPORT" "$mount_point" -o ro,soft,timeo=50,_netdev; then
                # Persist in fstab for reboots
                if ! grep -qF "$NFS_SERVER:$NFS_EXPORT" /etc/fstab; then
                    echo "$NFS_SERVER:$NFS_EXPORT $mount_point nfs ro,soft,timeo=50,_netdev,nofail 0 0" >> /etc/fstab
                fi
                export MUSIC_PATH="$mount_point"
                log_progress "NFS mounted: $mount_point" 2>/dev/null || true
            else
                log_and_tty "WARNING: NFS mount failed — falling back to auto-detect"
            fi
            ;;
        smb)
            local mount_point="/media/smb-music"
            local creds_file="/etc/snapmulti-smb-credentials"
            mkdir -p "$mount_point"
            log_progress "Mounting SMB: //$SMB_SERVER/$SMB_SHARE" 2>/dev/null || true

            # Build mount options
            local mount_opts="ro,_netdev,iocharset=utf8"
            if [[ -n "$SMB_USER" ]]; then
                # Write credentials to a root-only file
                printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASS" > "$creds_file"
                chmod 600 "$creds_file"
                mount_opts="${mount_opts},credentials=$creds_file"
            else
                mount_opts="${mount_opts},guest"
            fi

            if timeout 60 mount -t cifs "//$SMB_SERVER/$SMB_SHARE" "$mount_point" -o "$mount_opts"; then
                # Persist in fstab
                if ! grep -qF "//$SMB_SERVER/$SMB_SHARE" /etc/fstab; then
                    echo "//$SMB_SERVER/$SMB_SHARE $mount_point cifs ${mount_opts},nofail 0 0" >> /etc/fstab
                fi
                export MUSIC_PATH="$mount_point"
                log_progress "SMB mounted: $mount_point" 2>/dev/null || true
            else
                log_and_tty "WARNING: SMB mount failed — falling back to auto-detect"
            fi
            ;;
        manual|"")
            # No-op: deploy.sh auto-detect fallback
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════
# SERVER INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then

    # ── Deploy server ─────────────────────────────────────────────
    next_step "Deploy server..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
    log_progress "Running deploy.sh ..." 2>/dev/null || true

    # Set up music source before deploy.sh (mounts NFS/SMB, exports MUSIC_PATH)
    setup_music_source

    # Scrub credentials and network topology from boot partition
    # (FAT32 has no file permissions — anyone mounting the SD can read these)
    if [[ -f "$SNAP_BOOT/install.conf" ]]; then
        scrub_failed=false
        for field in SMB_PASS SMB_USER SMB_SERVER SMB_SHARE NFS_SERVER NFS_EXPORT; do
            sed -i "s/^${field}=.*/${field}=/" "$SNAP_BOOT/install.conf" 2>/dev/null \
                || scrub_failed=true
        done
        if [[ "$scrub_failed" == "true" ]]; then
            log_and_tty "WARNING: Could not scrub credentials via sed — removing install.conf"
            rm -f "$SNAP_BOOT/install.conf" 2>/dev/null || true
        fi
    fi

    if [[ ! -d "$SERVER_DIR" ]]; then
        log_and_tty "ERROR: Server directory missing: $SERVER_DIR"
        exit 1
    fi
    cd "$SERVER_DIR"

    # Run deploy.sh with progress forwarded to TUI.
    # logging.sh outputs plain text when piped (no ANSI codes since stderr
    # is not a TTY), so we match on [INFO]/[OK]/==> prefixes directly.
    set +eo pipefail
    bash scripts/deploy.sh 2>&1 | while IFS= read -r line; do
        printf '%s\n' "$line" >> "$LOG"
        case "$line" in
            *"[INFO] Pulling "*|*"[OK] All "*"images ready"*|\
            *"[INFO] Building metadata"*|\
            *"==> Starting services"*|*"[OK] Services started"*|\
            *"[INFO] Using profile:"*|*"[OK] Configuration valid"*)
                # Strip [INFO]/[OK] prefix or ==> prefix for clean display
                msg="${line#*] }"
                msg="${msg#==> }"
                log_progress "  $msg" 2>/dev/null || true
                ;;
        esac
    done
    deploy_rc=${PIPESTATUS[0]}
    set -eo pipefail

    if [[ "$deploy_rc" -ne 0 ]]; then
        log_and_tty "ERROR: deploy.sh failed. Check $LOG"
        exit 1
    fi
    log_progress "Server deploy complete" 2>/dev/null || true

    # ── Verify server containers ──────────────────────────────────
    next_step "Verifying server containers..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
    log_progress "Waiting for containers to become healthy..." 2>/dev/null || true

    HEALTHY=false
    for attempt in $(seq 1 12); do
        TOTAL=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps -q 2>/dev/null | wc -l)
        RUNNING_COUNT=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps --format '{{.State}}' 2>/dev/null | grep -c '^running' || true)
        # Fallback for Compose < v2.23 where --format may not work
        if [[ "$RUNNING_COUNT" -eq 0 ]] && [[ "$TOTAL" -gt 0 ]]; then
            RUNNING_COUNT=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps 2>/dev/null | grep -c ' Up ' || true)
        fi
        if [[ "$TOTAL" -ge 6 ]] && [[ "$RUNNING_COUNT" -eq "$TOTAL" ]]; then
            log_and_tty "All $TOTAL server containers running."
            log_progress "All $TOTAL server containers running" 2>/dev/null || true
            HEALTHY=true
            break
        fi
        log_progress "  Attempt $attempt/12: $RUNNING_COUNT/$TOTAL running..." 2>/dev/null || true
        sleep 10
    done

    if [[ "$HEALTHY" == "false" ]]; then
        log_and_tty "WARNING: Not all server containers healthy after 2 minutes."
        docker ps --format '{{.Names}}\t{{.Status}}' | while read -r line; do
            log_and_tty "  $line"
        done
    fi
fi

# ══════════════════════════════════════════════════════════════════
# CLIENT INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then

    # Detect display for headless mode
    DISPLAY_MODE="framebuffer"
    if ! has_display; then
        DISPLAY_MODE="headless"
        log_progress "No display detected -- headless mode" 2>/dev/null || true
    else
        log_progress "Display detected -- full visual stack" 2>/dev/null || true
    fi

    # For "both" mode, set client to connect to local server
    SNAPSERVER_HOST=""
    if [[ "$INSTALL_TYPE" == "both" ]]; then
        SNAPSERVER_HOST="127.0.0.1"
    fi

    CONFIG_FILE=""
    if [[ -f "$CLIENT_DIR/snapclient.conf" ]]; then
        CONFIG_FILE="$CLIENT_DIR/snapclient.conf"
    fi

    # Write display mode override to config so setup.sh picks it up
    if [[ -n "$CONFIG_FILE" ]]; then
        # Override DISPLAY_MODE in the config
        if grep -q '^DISPLAY_MODE=' "$CONFIG_FILE"; then
            sed -i "s|^DISPLAY_MODE=.*|DISPLAY_MODE=${DISPLAY_MODE}|" "$CONFIG_FILE"
        else
            echo "DISPLAY_MODE=$DISPLAY_MODE" >> "$CONFIG_FILE"
        fi
        # Set snapserver host for "both" mode
        if [[ -n "$SNAPSERVER_HOST" ]]; then
            if grep -q '^SNAPSERVER_HOST=' "$CONFIG_FILE"; then
                sed -i "s|^SNAPSERVER_HOST=.*|SNAPSERVER_HOST=${SNAPSERVER_HOST}|" "$CONFIG_FILE"
            else
                echo "SNAPSERVER_HOST=$SNAPSERVER_HOST" >> "$CONFIG_FILE"
            fi
        fi
    fi

    next_step "Setting up audio player..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
    log_progress "Running client setup.sh --auto ..." 2>/dev/null || true

    if [[ ! -d "$CLIENT_DIR" ]]; then
        log_and_tty "ERROR: Client directory missing: $CLIENT_DIR"
        exit 1
    fi
    cd "$CLIENT_DIR"
    # Tell setup.sh that firstboot.sh owns the progress display — it should
    # not render its own TUI, and should log to our progress log instead.
    export PROGRESS_MANAGED=1
    export PROGRESS_LOG
    if [[ -n "$CONFIG_FILE" ]]; then
        if ! bash scripts/setup.sh --auto "$CONFIG_FILE" >> "$LOG" 2>&1; then
            log_and_tty "ERROR: client setup.sh failed."
            exit 1
        fi
    else
        if ! bash scripts/setup.sh --auto >> "$LOG" 2>&1; then
            log_and_tty "ERROR: client setup.sh failed."
            exit 1
        fi
    fi
    unset PROGRESS_MANAGED
    log_progress "Client setup complete" 2>/dev/null || true

    next_step "Verifying client..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
    log_progress "Checking client containers..." 2>/dev/null || true

    # Brief wait for containers
    sleep 5
    CLIENT_CONTAINERS=$(docker ps --format '{{.Names}}' | grep -c "snapclient" || true)
    if [[ "$CLIENT_CONTAINERS" -ge 1 ]]; then
        log_progress "Client container running" 2>/dev/null || true
    else
        log_and_tty "WARNING: snapclient container not running."
    fi
fi

# ══════════════════════════════════════════════════════════════════
# COMPLETE
# ══════════════════════════════════════════════════════════════════
touch "$MARKER"

progress_complete 2>/dev/null || true

log_and_tty ""
log_and_tty "  --- Installation complete! ($INSTALL_TYPE) ---"
log_and_tty ""
for i in 5 4 3 2 1; do
    log_and_tty "  Rebooting in $i..."
    sleep 1
done
reboot
