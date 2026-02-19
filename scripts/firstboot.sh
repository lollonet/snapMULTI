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
    for card in /sys/class/drm/card*-HDMI-*/status; do
        [[ -f "$card" ]] && grep -q "^connected" "$card" && return 0
    done
    # fb0 exists but no HDMI status files found (some Pi firmware versions
    # don't expose DRM status). Default to "display present" — worst case,
    # visual containers start but fail gracefully at runtime.
    return 0
}

# Initialize progress display
progress_init 2>/dev/null || true

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

NETWORK_READY=false
WIFI_KICKED=false
for i in $(seq 1 90); do
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if { [[ -n "$GATEWAY" ]] && ping -c1 -W2 "$GATEWAY" &>/dev/null; } || \
       ping -c1 -W2 1.1.1.1 &>/dev/null || \
       ping -c1 -W2 8.8.8.8 &>/dev/null; then
        # Ping works but DNS may lag behind — verify name resolution
        if getent hosts deb.debian.org &>/dev/null; then
            log_and_tty "Network ready."
            log_progress "Network ready" 2>/dev/null || true
            NETWORK_READY=true
            break
        fi
        [[ $((i % 10)) -eq 0 ]] && log_progress "  DNS not ready yet ($i/90)..." 2>/dev/null || true
    else
        # After 30s without network, try to kick WiFi
        if [[ "$WIFI_KICKED" == "false" ]] && (( i >= 15 )); then
            if command -v nmcli &>/dev/null; then
                WIFI_CONN=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                    | awk -F: '/wifi/ {print $1; exit}')
                if [[ -n "$WIFI_CONN" ]]; then
                    log_progress "Activating WiFi: $WIFI_CONN" 2>/dev/null || true
                    nmcli connection up "$WIFI_CONN" 2>/dev/null || true
                    WIFI_KICKED=true
                fi
            fi
        fi
        [[ $((i % 10)) -eq 0 ]] && log_progress "  Still waiting... ($i/90)" 2>/dev/null || true
    fi
    sleep 2
done

if [[ "$NETWORK_READY" == "false" ]]; then
    log_and_tty "ERROR: Network not available after 3 minutes."
    log_and_tty "Check WiFi credentials or Ethernet connection."
    exit 1
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
    fi
    cp -r "$SNAP_BOOT/common" "$SERVER_DIR/scripts/" 2>/dev/null || true
    log_progress "Server files copied to $SERVER_DIR" 2>/dev/null || true
fi

# Copy client files
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    mkdir -p "$CLIENT_DIR"
    if [[ -d "$SNAP_BOOT/client" ]]; then
        # Copy all client files
        cp -r "$SNAP_BOOT/client/"* "$CLIENT_DIR/" 2>/dev/null || true
        # Copy dotfiles (.env.example) — glob may match nothing, which is OK
        if ! cp -r "$SNAP_BOOT/client/".??* "$CLIENT_DIR/" 2>/dev/null; then
            echo "Note: no dotfiles found in client source (non-fatal)" >> "$LOG"
        fi
    fi
    # Verify critical client files were copied
    if [[ ! -f "$CLIENT_DIR/docker-compose.yml" ]]; then
        log_and_tty "ERROR: Client docker-compose.yml missing after copy."
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

log_progress "apt-get update" 2>/dev/null || true
apt-get update -qq

# Core dependencies (always needed)
PKGS=(curl ca-certificates gnupg)

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

    # daemon.json (live-restore, log rotation) is written by deploy.sh's
    # install_docker() which has python3 merge logic for existing configs.
    # Do not duplicate it here — deploy.sh owns Docker daemon configuration.

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

# In "both" mode, client's read-only filesystem requires fuse-overlayfs storage
# driver. Switch BEFORE any images are pulled so deploy.sh and setup.sh both
# use the same driver — avoids a destructive wipe mid-install.
if [[ "$INSTALL_TYPE" == "both" ]]; then
    current_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "none")
    if [[ "$current_driver" != "fuse-overlayfs" ]]; then
        log_progress "Switching Docker to fuse-overlayfs (read-only FS support)..." 2>/dev/null || true
        fuse_ok=false
        if ! apt-get install -y fuse-overlayfs >> "$LOG" 2>&1; then
            log_and_tty "ERROR: Failed to install fuse-overlayfs — cannot switch storage driver."
            log_and_tty "       Docker data NOT wiped. Continuing with default driver."
        else
            systemctl stop docker
            mkdir -p /etc/docker
            # Merge fuse-overlayfs into existing daemon.json (or create new)
            if [[ -f /etc/docker/daemon.json ]]; then
                if python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
cfg['storage-driver'] = 'fuse-overlayfs'
with open('/etc/docker/daemon.json', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>>"$LOG"; then
                    fuse_ok=true
                else
                    log_and_tty "ERROR: Failed to merge daemon.json — aborting storage driver switch."
                fi
            else
                cat > /etc/docker/daemon.json <<'DJSON'
{
  "storage-driver": "fuse-overlayfs",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DJSON
                fuse_ok=true
            fi
            if [[ "$fuse_ok" == "true" ]]; then
                rm -rf /var/lib/docker/*
                log_progress "Docker storage driver: fuse-overlayfs" 2>/dev/null || true
            fi
            if ! systemctl start docker; then
                log_and_tty "ERROR: Docker failed to start after storage driver switch."
                log_and_tty "       Manual recovery required (reflash SD or fix /etc/docker/daemon.json)."
                exit 1
            fi
        fi
    fi
fi

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
            # No-op: deploy.sh auto-detects USB drives at /media/*
            log_progress "USB mode — deploy.sh will auto-detect" 2>/dev/null || true
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
            log_and_tty "WARNING: Could not scrub some fields from boot partition — remove manually"
        fi
    fi

    if [[ ! -d "$SERVER_DIR" ]]; then
        log_and_tty "ERROR: Server directory missing: $SERVER_DIR"
        exit 1
    fi
    cd "$SERVER_DIR"
    if ! bash scripts/deploy.sh >> "$LOG" 2>&1; then
        log_and_tty "ERROR: deploy.sh failed."
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
        if [[ "$TOTAL" -ge 5 ]] && [[ "$RUNNING_COUNT" -eq "$TOTAL" ]]; then
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
