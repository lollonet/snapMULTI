#!/usr/bin/env bash
# snapMULTI Unified Auto-Install — runs once on first boot.
#
# Reads install.conf to determine what to install:
#   client — Audio Player (snapclient + optional display)
#   server — Music Server (Spotify, AirPlay, MPD, etc.)
#   both   — Server + Player on the same Pi
#
# Modular architecture: sources modules from scripts/common/ for each phase.
# All logging goes through unified-log.sh (single log file with timestamps).
#
# Called by cloud-init runcmd or firstrun.sh (patched by prepare-sd.sh).
set -euo pipefail

# Secure PATH
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ══════════════════════════════════════════════════════════════════
# INIT: markers, boot partition, install.conf
# ══════════════════════════════════════════════════════════════════
INSTALLER_STATE="/var/lib/snapmulti-installer"
MARKER="$INSTALLER_STATE/.auto-installed"
FAILED_MARKER="$INSTALLER_STATE/.install-failed"
mkdir -p "$INSTALLER_STATE"

if [[ -f "$MARKER" ]]; then
    echo "snapMULTI already installed, skipping."
    exit 0
fi
if [[ -f "$FAILED_MARKER" ]]; then
    # Allow retry: remove failed marker and resume from last checkpoint
    rm -f "$FAILED_MARKER"
    echo "Retrying install from last checkpoint..."
fi

# Checkpoint helpers: skip completed phases on retry after power loss / crash.
# Each checkpoint is a file in INSTALLER_STATE named after the phase.
# Atomic write (.tmp + sync + rename) — power loss mid-write must NOT leave
# a zero-byte file that checkpoint_reached treats as success.
checkpoint_done() {
    local f="$INSTALLER_STATE/.done-$1"
    printf '%s\n' "$(date -u +%FT%TZ)" > "${f}.tmp"
    sync -- "${f}.tmp" 2>/dev/null || true
    mv -f -- "${f}.tmp" "$f"
}
# Require non-empty: a zero-byte file means truncated mid-write, not "done".
checkpoint_reached() { [[ -s "$INSTALLER_STATE/.done-$1" ]]; }

# Detect boot partition
if [[ -d /boot/firmware ]]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi
SNAP_BOOT="$BOOT/snapmulti"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

if [[ ! -d "$SNAP_BOOT" ]]; then
    echo "ERROR: $SNAP_BOOT not found on boot partition."
    exit 1
fi

# ── Read install.conf ────────────────────────────────────────────
INSTALL_TYPE="server"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    INSTALL_TYPE=$(grep -m1 '^INSTALL_TYPE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')
    INSTALL_TYPE="${INSTALL_TYPE:-server}"
fi

# Read music source config
# Music source config — used by sourced mount-music.sh module
# shellcheck disable=SC2034
{
MUSIC_SOURCE=""
NFS_SERVER=""
NFS_EXPORT=""
SMB_SERVER=""
SMB_SHARE=""
SMB_USER=""
SMB_PASS=""
}
# shellcheck disable=SC2034
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    MUSIC_SOURCE=$(grep -m1 '^MUSIC_SOURCE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')
    # Source sanitize.sh for re-validation
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
    SMB_USER=$(sanitize_smb_user "$(grep -m1 '^SMB_USER=' "$SNAP_BOOT/install.conf" | cut -d= -f2- | tr -d '\r')")
    SMB_PASS=$(grep -m1 '^SMB_PASS=' "$SNAP_BOOT/install.conf" | cut -d= -f2- | tr -d '\r')
fi

# Read advanced options
ENABLE_READONLY="true"
SKIP_UPGRADE="false"
IMAGE_TAG="latest"
VERBOSE_INSTALL="false"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    _rc() { grep -m1 "^$1=" "$SNAP_BOOT/install.conf" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true; }
    local_val=$(_rc ENABLE_READONLY); [[ -n "$local_val" ]] && ENABLE_READONLY="$local_val"
    local_val=$(_rc SKIP_UPGRADE);    [[ -n "$local_val" ]] && SKIP_UPGRADE="$local_val"
    local_val=$(_rc IMAGE_TAG);       [[ -n "$local_val" ]] && IMAGE_TAG="$local_val"
    local_val=$(_rc VERBOSE_INSTALL); [[ -n "$local_val" ]] && VERBOSE_INSTALL="$local_val"
    unset -f _rc
    unset local_val
fi

# Install directories
SERVER_DIR="/opt/snapmulti"
CLIENT_DIR="/opt/snapclient"

# ══════════════════════════════════════════════════════════════════
# LOGGING + PROGRESS
# ══════════════════════════════════════════════════════════════════
# shellcheck disable=SC2034
LOG_SOURCE="firstboot"
export UNIFIED_LOG="/var/log/snapmulti-install.log"

# Move the install TUI to /dev/tty3 so /dev/tty1 (and /dev/fb0 through it)
# can be claimed by fb-display without overlap. We chvt to tty3 so the
# install progress remains visible on the HDMI console; right before
# starting fb-display we switch to tty8 (a blank, autovt-free VT) so the
# kernel fbcon driver clears the framebuffer for fb-display to draw on.
# Standalone runs (no tty3 available) silently fall back via the test below.
if [[ -c /dev/tty3 ]] && command -v chvt &>/dev/null; then
    export PROGRESS_TTY=/dev/tty3
    chvt 3 2>/dev/null || true
    setterm -blank 0 -powersave off >/dev/tty3 2>/dev/null || true
fi

# Source unified logger
COMMON="$SNAP_BOOT/common"
[[ ! -d "$COMMON" ]] && COMMON="$SCRIPT_DIR/common"
# shellcheck source=common/unified-log.sh
source "$COMMON/unified-log.sh"

# Configure progress steps based on install type
# shellcheck disable=SC2034
case "$INSTALL_TYPE" in
    client)
        STEP_NAMES=("Wait for network" "Copy project files"
                    "Install system packages" "Install Docker engine"
                    "Setup audio player (HAT detect, pull, configure)"
                    "Verify services healthy")
        STEP_WEIGHTS=(5 2 10 30 48 5)
        PROGRESS_TITLE="snapMULTI Audio Player"
        ;;
    server)
        STEP_NAMES=("Wait for network" "Copy project files"
                    "Install system packages" "Install Docker engine"
                    "Deploy server (config, pull, start)"
                    "Verify services healthy")
        STEP_WEIGHTS=(5 2 8 30 45 10)
        PROGRESS_TITLE="snapMULTI Music Server"
        ;;
    both)
        STEP_NAMES=("Wait for network" "Copy project files"
                    "Install system packages" "Install Docker engine"
                    "Deploy server (config, pull, start)" "Verify server"
                    "Setup audio player (HAT detect, pull)" "Verify all services")
        STEP_WEIGHTS=(4 2 7 25 35 4 18 5)
        PROGRESS_TITLE="snapMULTI Server + Player"
        ;;
    *)
        log_error "Unknown INSTALL_TYPE=$INSTALL_TYPE"
        exit 1
        ;;
esac
PROGRESS_TITLE="$PROGRESS_TITLE ($(hostname))"

# Verify step arrays match
if [[ ${#STEP_NAMES[@]} -ne ${#STEP_WEIGHTS[@]} ]]; then
    log_error "BUG: STEP_NAMES (${#STEP_NAMES[@]}) != STEP_WEIGHTS (${#STEP_WEIGHTS[@]})"
    exit 1
fi

# Source progress display
# shellcheck source=common/progress.sh
source "$COMMON/progress.sh"

# Source system tuning
# shellcheck source=common/system-tune.sh
if [[ -f "$COMMON/system-tune.sh" ]]; then
    source "$COMMON/system-tune.sh"
fi
if command -v tune_wifi_powersave &>/dev/null; then
    tune_wifi_powersave
fi

# ── Module tracking ──────────────────────────────────────────────
# Sourced modules overwrite LOG_SOURCE — reset it after each call
# so subsequent log lines show the correct source.
set_module() {
    CURRENT_MODULE="$1"
    # shellcheck disable=SC2034
    LOG_SOURCE="$1"
}
set_module "init"
cleanup_on_failure() {
    local exit_code=$?
    # Always clean up subprocess tee logs (see Wave 4 N5) — the explicit
    # rm -f calls handle the common path, but a SIGTERM/OOM between
    # mktemp and the explicit rm would leak. /tmp is tmpfs so harmless,
    # but keeps the contract clean.
    rm -f -- "${deploy_log:-}" "${setup_log:-}" 2>/dev/null || true
    if [[ $exit_code -ne 0 ]]; then
        stop_progress_animation 2>/dev/null || true
        log_error "Installation FAILED in module: $CURRENT_MODULE (exit code: $exit_code)"
        log_error "Check log: $UNIFIED_LOG"

        # Diagnostic snapshot — appended to install log for remote troubleshooting
        {
            echo ""
            echo "=== DIAGNOSTIC DUMP (module: $CURRENT_MODULE, exit: $exit_code) ==="
            echo "--- Memory ---"
            free -m 2>/dev/null || true
            echo "--- Disk ---"
            df -h / /opt 2>/dev/null || true
            echo "--- Docker ---"
            docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || true
            echo "--- Docker logs (last 10 lines per container) ---"
            for ctr in $(docker ps -aq 2>/dev/null); do
                echo ">> $(docker inspect --format '{{.Name}}' "$ctr" 2>/dev/null)"
                docker logs --tail 10 "$ctr" 2>&1 || true
            done
            echo "--- dmesg (last 20 lines) ---"
            dmesg | tail -20 2>/dev/null || true
            echo "=== END DIAGNOSTIC DUMP ==="
        } >> "$UNIFIED_LOG" 2>/dev/null || true

        # Failure messages must be visible regardless of which VT is
        # active. fb-display may have started already (post snapclient),
        # in which case PROGRESS_TTY is no longer the visible VT — so
        # write to both PROGRESS_TTY and /dev/tty1 as a belt+braces.
        for _vt in "$PROGRESS_TTY" /dev/tty1; do
            [[ -c "$_vt" ]] || continue
            echo "" > "$_vt" 2>/dev/null || true
            echo "  --- Installation FAILED (module: $CURRENT_MODULE) ---" > "$_vt" 2>/dev/null || true
            echo "  Check log: $UNIFIED_LOG" > "$_vt" 2>/dev/null || true
        done
        chvt 1 2>/dev/null || true

        # Atomic FAILED_MARKER write: same pattern as checkpoint_done.
        # touch leaves a zero-byte file; if power loss strikes between
        # the syscall and the fs flush, we may end up with an empty file
        # that still satisfies `[[ -f "$FAILED_MARKER" ]]` but the
        # diagnostic dump above may be lost. Atomic write guarantees
        # the marker either has the timestamp or doesn't exist.
        printf '%s\n' "$(date -u +%FT%TZ)" > "${FAILED_MARKER}.tmp" 2>/dev/null || true
        sync -- "${FAILED_MARKER}.tmp" 2>/dev/null || true
        mv -f -- "${FAILED_MARKER}.tmp" "$FAILED_MARKER" 2>/dev/null || true
    fi
}
trap cleanup_on_failure EXIT

# ── Step counter ─────────────────────────────────────────────────
CURRENT_STEP=0
next_step() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    progress "$CURRENT_STEP" "$1" 2>/dev/null || true
}
current_weight() {
    local idx=$(( CURRENT_STEP - 1 ))
    if (( idx >= 0 && idx < ${#STEP_WEIGHTS[@]} )); then
        echo "${STEP_WEIGHTS[$idx]}"
    else
        echo 5
    fi
}
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

# shellcheck source=common/verify-compose.sh
source "$COMMON/verify-compose.sh"

# Headless detection (for client modes) — single source of truth lives in
# client/common/scripts/display.sh (HDMI/DSI/DPI/DP/eDP). Source it from
# the staging copy on the SD card so firstboot agrees with setup.sh and
# display-detect.sh on what counts as a connected display.
_DISPLAY_LIB=""
for _candidate in \
    "$SNAP_BOOT/client/scripts/display.sh" \
    "$CLIENT_DIR/scripts/display.sh" \
    "$CLIENT_DIR/common/scripts/display.sh"; do
    if [[ -f "$_candidate" ]]; then
        _DISPLAY_LIB="$_candidate"
        break
    fi
done
if [[ -n "$_DISPLAY_LIB" ]]; then
    # shellcheck source=../client/common/scripts/display.sh
    source "$_DISPLAY_LIB"
else
    # Fallback if display.sh missing (older SD layout) — same conservative
    # HDMI-only check that was here before; better than crashing.
    has_display() {
        [[ -c /dev/fb0 ]] || return 1
        local found_status=false card
        for card in /sys/class/drm/card*-HDMI-*/status; do
            [[ -f "$card" ]] || continue
            found_status=true
            grep -q "^connected" "$card" && return 0
        done
        $found_status && return 1
        return 1
    }
fi
unset _DISPLAY_LIB _candidate

# Make future boots verbose
CMDLINE_FILE=""
for candidate in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    [[ -f "$candidate" ]] && CMDLINE_FILE="$candidate" && break
done
if [[ -n "$CMDLINE_FILE" ]]; then
    if grep -qE 'quiet|splash|fbcon=map:9' "$CMDLINE_FILE"; then
        sed -i 's/ quiet//; s/ splash//; s/ fbcon=map:9//' "$CMDLINE_FILE"
        log_info "Enabled verbose boot"
    fi
fi

# Initialize progress display
progress_init 2>/dev/null || true

log_info "Starting snapMULTI auto-install ($INSTALL_TYPE) — $(hostname)"

# ══════════════════════════════════════════════════════════════════
# STEP 1: Network + NTP
# ══════════════════════════════════════════════════════════════════
set_module "network"
next_step "Waiting for network..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
# shellcheck source=common/wait-network.sh
source "$COMMON/wait-network.sh"
wait_for_network
# Reset SECONDS after NTP sync — Bash SECONDS uses wall clock (not monotonic),
# so an NTP time jump (Pi boots at epoch 0, sync to 2026) corrupts the counter.
# Installation time is measured from here, excluding network wait.
SECONDS=0
milestone "$CURRENT_STEP" "Network ready" 2 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 2: Copy files
# ══════════════════════════════════════════════════════════════════
set_module "copy"
next_step "Copying project files..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    mkdir -p "$SERVER_DIR/scripts"
    if [[ -d "$SNAP_BOOT/server" ]]; then
        cp "$SNAP_BOOT/server/docker-compose.yml" "$SERVER_DIR/"
        cp "$SNAP_BOOT/server/.env.example" "$SERVER_DIR/" 2>/dev/null || true
        cp -r "$SNAP_BOOT/server/config" "$SERVER_DIR/"
        cp "$SNAP_BOOT/server/deploy.sh" "$SERVER_DIR/scripts/"
        cp "$SNAP_BOOT/server/boot-tune.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/status.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/device-smoke.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/docker-driver-reconcile.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/ro-mode.sh" "$SERVER_DIR/scripts/" 2>/dev/null || true
        cp "$SNAP_BOOT/server/.version" "$SERVER_DIR/" 2>/dev/null || true
        # Restore the MPD database backup only when the music source is on a
        # network mount (NFS/SMB) where a full rescan would take hours.
        # For local sources (USB/local disk) the db may be stale or contain
        # path pointers from a different host's library — skip and let MPD
        # build a fresh db on first scan (fast on local storage). See #278.
        if [[ -f "$SNAP_BOOT/server/mpd/data/mpd.db" ]]; then
            case "${MUSIC_SOURCE:-}" in
                nfs|smb)
                    mkdir -p "$SERVER_DIR/mpd/data"
                    cp "$SNAP_BOOT/server/mpd/data/mpd.db" "$SERVER_DIR/mpd/data/"
                    log_info "Restored MPD database backup ($MUSIC_SOURCE source)"
                    ;;
                *)
                    log_info "Skipping MPD db restore (source=${MUSIC_SOURCE:-unset}, not network)"
                    ;;
            esac
        fi
    fi
    cp -r "$SNAP_BOOT/common" "$SERVER_DIR/scripts/" 2>/dev/null || true
    log_info "Server files copied to $SERVER_DIR"
fi

if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    mkdir -p "$CLIENT_DIR/scripts"
    cp -r "$SNAP_BOOT/common" "$CLIENT_DIR/scripts/" 2>/dev/null || true
    if [[ -d "$SNAP_BOOT/client" ]]; then
        cp -r "$SNAP_BOOT/client/"* "$CLIENT_DIR/" || {
            log_error "Failed to copy client files from $SNAP_BOOT/client/"
            exit 1
        }
        cp -r "$SNAP_BOOT/client/".??* "$CLIENT_DIR/" 2>/dev/null || true
    fi
    local_missing=()
    [[ -f "$CLIENT_DIR/docker-compose.yml" ]] || local_missing+=("docker-compose.yml")
    [[ -f "$CLIENT_DIR/scripts/setup.sh" ]] || local_missing+=("scripts/setup.sh")
    [[ -f "$CLIENT_DIR/scripts/audio-hat-detect.sh" ]] || local_missing+=("scripts/audio-hat-detect.sh")
    [[ -d "$CLIENT_DIR/audio-hats" ]] || local_missing+=("audio-hats/")
    [[ -f "$CLIENT_DIR/scripts/display.sh" ]] || local_missing+=("scripts/display.sh")
    [[ -f "$CLIENT_DIR/scripts/display-detect.sh" ]] || local_missing+=("scripts/display-detect.sh")
    if [[ ${#local_missing[@]} -gt 0 ]]; then
        log_error "Critical client files missing: ${local_missing[*]}"
        exit 1
    fi
    log_info "Client files copied to $CLIENT_DIR"
fi

# ══════════════════════════════════════════════════════════════════
# STEP 3: System dependencies
# ══════════════════════════════════════════════════════════════════
set_module "deps"
next_step "Installing git and dependencies..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
DOCKER_REPO_PRECONFIGURED=false
if checkpoint_reached "deps"; then
    log_info "Dependencies already installed (checkpoint), skipping"
else
    # Pre-add Docker apt repo so install-deps.sh's apt-get update covers
    # both Debian + Docker sources in one shot. The repo file write only
    # needs curl (preinstalled on RPi OS Lite + Debian Bookworm/Trixie).
    # shellcheck source=common/install-docker.sh
    source "$COMMON/install-docker.sh"
    if setup_docker_repo; then
        DOCKER_REPO_PRECONFIGURED=true
    else
        log_warn "Docker repo setup failed (curl/network) — install-docker will retry with its own update"
    fi

    # shellcheck source=common/install-deps.sh
    source "$COMMON/install-deps.sh"
    INSTALL_ROLE="$INSTALL_TYPE" install_dependencies
    checkpoint_done "deps"
fi
milestone "$CURRENT_STEP" "System dependencies installed" 2 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 4: Docker
# ══════════════════════════════════════════════════════════════════
set_module "docker"
next_step "Installing Docker..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
if checkpoint_reached "docker"; then
    log_info "Docker already installed (checkpoint), skipping"
else
    # shellcheck source=common/setup-docker.sh
    source "$COMMON/setup-docker.sh"
    # Skip redundant apt-get update only when install-deps.sh's update already
    # saw the Docker repo. If pre-configuration failed, install_docker_apt must
    # run its own update after the recovery attempt at setup_docker_repo.
    if [[ "$DOCKER_REPO_PRECONFIGURED" == "true" ]]; then
        SKIP_APT_UPDATE=true setup_docker
    else
        setup_docker
    fi
    checkpoint_done "docker"
fi
milestone "$CURRENT_STEP" "Docker installed" 2 2>/dev/null || true

# ── Pre-configure fuse-overlayfs when readonly is planned ─────────
# On first boot root is still writable ext4, so setup-docker.sh keeps
# Docker's default overlay2 driver. But when ENABLE_READONLY=true,
# overlayroot will activate after reboot — Docker must use fuse-overlayfs.
#
# If we defer the switch to boot-time (docker-driver-reconcile.sh),
# overlay2 images from the first boot become invisible to Docker under
# fuse-overlayfs. Docker re-pulls ~1.5 GB into the tmpfs upper layer,
# filling it immediately and leaving no room for client images.
#
# Switch to fuse-overlayfs NOW, before any images are pulled. Images land
# on the writable SD card with the correct driver and survive the
# overlayroot transition in the read-only lower layer.
# docker-driver-reconcile.sh remains as a safety net for edge cases
# (e.g. overlayroot fails to activate → reconciler reverts to overlay2).
#
# Checkpointed: the switch runs `rm -rf /var/lib/docker/*` to drop
# stale overlay2 layers. Without a checkpoint, a crash between this
# `rm -rf` and the subsequent successful pull would re-run the wipe on
# next boot — even when valid images already exist under fuse-overlayfs.
# The checkpoint is set ONLY after the new daemon is up under the new
# driver, so an interrupted switch correctly retries from scratch.
if [[ "${ENABLE_READONLY}" == "true" ]]; then
    if checkpoint_reached "fuse-overlayfs-switched"; then
        log_info "fuse-overlayfs switch already complete (checkpoint), skipping"
    else
        current_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
        if [[ "$current_driver" == "fuse-overlayfs" ]]; then
            # Already on the right driver — record it so we don't repeat the check
            checkpoint_done "fuse-overlayfs-switched"
        else
            log_info "Pre-configuring fuse-overlayfs for read-only mode..."
            # fuse-overlayfs was installed by install-deps.sh (gated on ENABLE_READONLY).
            # Verify the binary works before switching Docker storage driver.
            if fuse-overlayfs --version &>/dev/null; then
                # Source system-tune for tune_docker_daemon if not already loaded
                if ! declare -F tune_docker_daemon &>/dev/null; then
                    # shellcheck source=common/system-tune.sh
                    source "$COMMON/system-tune.sh"
                fi
                tune_docker_daemon --live-restore --fuse-overlayfs
                systemctl stop docker
                rm -rf /var/lib/docker/*
                systemctl start docker
                # Wait briefly for daemon to be responsive before checkpointing
                for _i in 1 2 3 4 5 6 7 8 9 10; do
                    docker info >/dev/null 2>&1 && break
                    sleep 2
                done
                if docker info --format '{{.Driver}}' 2>/dev/null | grep -qx "fuse-overlayfs"; then
                    checkpoint_done "fuse-overlayfs-switched"
                    log_info "Docker switched to fuse-overlayfs (images will persist through overlayroot)"
                else
                    # FAIL HARD before any pull. Continuing here would download
                    # ~1.5 GB into Docker's overlay2 driver — those layers live
                    # in /var/lib/docker which is in the overlayroot LOWER
                    # layer. After the next reboot when overlayroot activates
                    # read-only, Docker won't see them and would re-pull into
                    # tmpfs, immediately exhausting it. Better to abort the
                    # install loud than ship a silently-broken device.
                    log_error "Docker driver switch FAILED — fuse-overlayfs not active after restart."
                    log_error "Continuing would pull images with overlay2 and lose them after reboot."
                    log_error "Diagnose with: vcgencmd get_throttled, dmesg | grep -i fuse, journalctl -u docker"
                    log_error "Workaround: set ENABLE_READONLY=false in install.conf and reflash, OR use a Pi with working fuse module"
                    exit 1
                fi
            else
                # fuse-overlayfs binary missing despite ENABLE_READONLY=true.
                # install-deps.sh should have installed it — reaching here means
                # apt-get failed silently OR the binary was removed afterward.
                log_error "fuse-overlayfs binary missing — install-deps.sh failed silently?"
                log_error "Refusing to continue: pulling images with overlay2 would lose them after reboot"
                exit 1
            fi
        fi
    fi
fi

# ══════════════════════════════════════════════════════════════════
# SERVER INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
  if checkpoint_reached "deploy"; then
    set_module "deploy"
    log_info "Server deploy already complete (checkpoint), skipping"
    next_step "Deploy server (cached)..."
    set_module "verify-server"
    next_step "Verifying server (cached)..."
  else
    set_module "deploy"
    next_step "Deploy server..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    # Mount music source
    # shellcheck source=common/mount-music.sh
    source "$COMMON/mount-music.sh"
    setup_music_source

    # Export IMAGE_TAG for deploy.sh
    if [[ "$IMAGE_TAG" != "latest" ]]; then
        export IMAGE_TAG
        log_info "Using image tag: $IMAGE_TAG"
    fi

    if [[ ! -d "$SERVER_DIR" ]]; then
        log_error "Server directory missing: $SERVER_DIR"
        exit 1
    fi
    cd "$SERVER_DIR"

    # Run deploy.sh — parse output through unified logger.
    # Tee a copy of every line to a temp file so on failure we can dump
    # the full unfiltered output (the case-statement filter below drops
    # most stderr/systemctl/docker noise on the success path; on the
    # failure path that's exactly the noise that matters).
    deploy_log=$(mktemp /tmp/firstboot-deploy-XXXXXX.log)
    set +eo pipefail
    bash scripts/deploy.sh 2>&1 | tee "$deploy_log" | while IFS= read -r line; do
        if [[ "$VERBOSE_INSTALL" == "true" ]]; then
            log_msg INFO deploy "${line:0:200}"
        else
            case "$line" in
                *"[INFO] "*|*"[OK] "*|*"==> "*)
                    local_msg="${line#*] }"
                    local_msg="${local_msg#==> }"
                    log_msg INFO deploy "$local_msg"
                    ;;
                *"Downloaded newer image"*)
                    log_msg INFO deploy "$line"
                    ;;
                *"Pulling "*|*"Pull complete"*|*"pulling "*|*"Downloaded"*)
                    # Skip Docker Compose per-layer progress (floods log).
                    # Pull-images.sh messages have [INFO] prefix, caught above.
                    ;;
            esac
        fi
    done
    deploy_rc=${PIPESTATUS[0]}

    if [[ "$deploy_rc" -ne 0 ]]; then
        set -eo pipefail
        log_error "Server deployment failed (rc=$deploy_rc)"
        log_error "Full subprocess output (last 200 lines):"
        if [[ -f "$deploy_log" ]]; then
            tail -n 200 "$deploy_log" | while IFS= read -r line; do
                log_msg ERROR deploy "${line:0:200}"
            done
        fi
        log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -200"
        rm -f "$deploy_log"
        exit 1
    fi
    rm -f "$deploy_log"
    set -eo pipefail
    milestone "$CURRENT_STEP" "Server deploy complete" 2 2>/dev/null || true

    # Verify server containers
    set_module "verify-server"
    next_step "Verifying server containers..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    if ! verify_compose_stack "$SERVER_DIR/docker-compose.yml" "server" 18 10; then
        log_error "Server verify failed — will retry on next boot"
        exit 1
    fi
    checkpoint_done "deploy"

    # Scrub credentials only AFTER deploy verified. Doing it earlier (the
    # original placement, before deploy.sh) means: if firstboot crashed
    # between the scrub and the deploy checkpoint, the next boot would
    # re-enter setup_music_source() with empty NFS_*/SMB_* vars, yielding
    # a broken fstab line ("//empty/empty cifs guest") that masks the
    # original good line. Now scrub runs only on the success path; on
    # retry, the install.conf creds are still intact.
    scrub_credentials
  fi  # checkpoint guard
fi

# ══════════════════════════════════════════════════════════════════
# CLIENT INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
  if checkpoint_reached "setup"; then
    set_module "setup"
    log_info "Client setup already complete (checkpoint), skipping"
    next_step "Setup client (cached)..."
    set_module "verify-client"
    next_step "Verifying client (cached)..."
  else
    set_module "setup"

    DISPLAY_MODE="framebuffer"
    if ! has_display; then
        DISPLAY_MODE="headless"
        log_info "No display detected — headless mode"
    else
        log_info "Display detected — full visual stack"
    fi

    SNAPSERVER_HOST=""
    if [[ "$INSTALL_TYPE" == "both" ]]; then
        SNAPSERVER_HOST="127.0.0.1"
    fi

    CONFIG_FILE=""
    if [[ -f "$CLIENT_DIR/snapclient.conf" ]]; then
        CONFIG_FILE="$CLIENT_DIR/snapclient.conf"
    fi

    if [[ -n "$CONFIG_FILE" ]]; then
        if grep -q '^DISPLAY_MODE=' "$CONFIG_FILE"; then
            sed -i "s|^DISPLAY_MODE=.*|DISPLAY_MODE=${DISPLAY_MODE}|" "$CONFIG_FILE"
        else
            echo "DISPLAY_MODE=$DISPLAY_MODE" >> "$CONFIG_FILE"
        fi
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

    if [[ ! -d "$CLIENT_DIR" ]]; then
        log_error "Client directory missing: $CLIENT_DIR"
        exit 1
    fi
    cd "$CLIENT_DIR"

    # Pass IMAGE_TAG + progress delegation to setup.sh
    export PROGRESS_MANAGED=1
    export PROGRESS_LOG
    export IMAGE_TAG

    # Build setup.sh args (flags before positional arg)
    setup_args=(--auto)
    [[ "$ENABLE_READONLY" != "true" ]] && setup_args+=(--no-readonly)
    [[ -n "$CONFIG_FILE" ]] && setup_args+=("$CONFIG_FILE")

    # Run setup.sh — parse output through unified logger (same as deploy.sh).
    # Tee a copy of every line so the failure path can dump full unfiltered
    # output (the case-statement filter drops most stderr noise on the
    # success path; on failure that's the noise we need).
    setup_log=$(mktemp /tmp/firstboot-setup-XXXXXX.log)
    set +eo pipefail
    bash scripts/setup.sh "${setup_args[@]}" 2>&1 | tee "$setup_log" | while IFS= read -r line; do
        if [[ "$VERBOSE_INSTALL" == "true" ]]; then
            log_msg INFO setup "${line:0:200}"
        else
            case "$line" in
                *"[INFO] "*|*"[OK] "*|*"==> "*)
                    local_msg="${line#*] }"
                    local_msg="${local_msg#==> }"
                    log_msg INFO setup "$local_msg"
                    ;;
                *ERROR*|*FAIL*|*WARNING*)
                    log_msg WARN setup "$line"
                    ;;
                "Hardware profile:"*|"Detected:"*|"Setup Complete"*|\
                "Audio HAT:"*|"Configuration Summary:"*|"  - "*)
                    log_msg INFO setup "$line"
                    ;;
            esac
        fi
    done
    setup_rc=${PIPESTATUS[0]}

    if [[ "$setup_rc" -ne 0 ]]; then
        set -eo pipefail
        log_error "Client setup failed (rc=$setup_rc)"
        log_error "Full subprocess output (last 200 lines):"
        if [[ -f "$setup_log" ]]; then
            tail -n 200 "$setup_log" | while IFS= read -r line; do
                log_msg ERROR setup "${line:0:200}"
            done
        fi
        log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -200"
        rm -f "$setup_log"
        exit 1
    fi
    rm -f "$setup_log"
    set -eo pipefail
    unset PROGRESS_MANAGED
    milestone "$CURRENT_STEP" "Client setup complete" 2 2>/dev/null || true

    set_module "verify-client"
    next_step "Verifying client..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    # Start client via systemd — the lifecycle owner post-install (ADR-005).
    # Switch to a blank VT first so fb-display has /dev/fb0 to itself.
    # The kernel fbcon driver clears the framebuffer on chvt; fb-display
    # then writes raw pixels without the install TUI fighting for the
    # same surface. VT 8 is outside logind's autovt range (NAutoVTs=6
    # by default) so nothing else fights for it. setterm prevents the
    # 10-minute screen blanker from kicking in mid-render.
    if [[ -c /dev/fb0 ]] && command -v chvt &>/dev/null; then
        chvt 8 2>/dev/null || true
        setterm -blank 0 -powersave off -cursor off >/dev/tty8 2>/dev/null || true
    fi
    log_info "Starting client via systemd..."
    systemctl start snapclient.service || log_warn "systemctl start snapclient failed"

    if ! verify_compose_stack "$CLIENT_DIR/docker-compose.yml" "client" 12 5; then
        log_error "Client verify failed — will retry on next boot"
        exit 1
    fi
    checkpoint_done "setup"
  fi  # checkpoint guard
fi

# ══════════════════════════════════════════════════════════════════
# FINAL OPERATIONS
# ══════════════════════════════════════════════════════════════════
set_module "finalize"

# Final package refresh
if [[ "$SKIP_UPGRADE" == "true" ]]; then
    log_info "Skipping final package refresh (SKIP_UPGRADE=true)"
else
    log_info "Final package refresh..."
    # Wait for apt lock (reuse from install-deps module if sourced)
    if declare -F _wait_for_apt_lock &>/dev/null; then
        _wait_for_apt_lock
    fi
    if ! apt-get update >>"$UNIFIED_LOG" 2>&1; then
        log_warn "Final apt-get update failed (non-fatal)"
    elif ! apt-get upgrade -y >>"$UNIFIED_LOG" 2>&1; then
        log_warn "Final apt upgrade failed (non-fatal)"
    else
        log_info "Final package refresh complete"
    fi
fi

# Diagnostic log persistence
DIAG_SCRIPT=""
for _diag_candidate in \
    "$COMMON/save-diagnostics.sh" \
    "$SERVER_DIR/scripts/common/save-diagnostics.sh" \
    "$CLIENT_DIR/scripts/common/save-diagnostics.sh"; do
    [[ -f "$_diag_candidate" ]] && DIAG_SCRIPT="$_diag_candidate" && break
done
if [[ -n "$DIAG_SCRIPT" ]]; then
    install -m 755 "$DIAG_SCRIPT" /usr/local/bin/save-diagnostics
    DIAG_DIR="$(dirname "$DIAG_SCRIPT")"
    if [[ -f "$DIAG_DIR/snapmulti-diagnostics.service" && \
          -f "$DIAG_DIR/snapmulti-diagnostics.timer" ]]; then
        cp "$DIAG_DIR/snapmulti-diagnostics.service" /etc/systemd/system/
        cp "$DIAG_DIR/snapmulti-diagnostics.timer" /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable snapmulti-diagnostics.timer
    fi
    log_info "Diagnostic log persistence installed"
fi

# MPD database backup to boot partition (server installs only)
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    BACKUP_SCRIPT=""
    for _bk_candidate in \
        "$COMMON/backup-mpd.sh" \
        "$SERVER_DIR/scripts/common/backup-mpd.sh"; do
        [[ -f "$_bk_candidate" ]] && BACKUP_SCRIPT="$_bk_candidate" && break
    done
    if [[ -n "$BACKUP_SCRIPT" ]]; then
        install -m 755 "$BACKUP_SCRIPT" /usr/local/bin/backup-mpd
        bk_dir="$(dirname "$BACKUP_SCRIPT")"
        if [[ -f "$bk_dir/snapmulti-backup.service" && \
              -f "$bk_dir/snapmulti-backup.timer" ]]; then
            cp "$bk_dir/snapmulti-backup.service" /etc/systemd/system/
            cp "$bk_dir/snapmulti-backup.timer" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable snapmulti-backup.timer
        fi
        log_info "MPD backup timer installed (daily to boot partition)"
    fi
fi

# System-status snapshot timer for the /status web page (issue #177).
# Server installs only — the page lives at metadata-service:8083/status,
# and metadata-service runs only in the server stack. Reads the JSON
# snapshot from /opt/snapmulti/audio/system-status.json (volume already
# bind-mounted into the metadata container).
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    STATUS_DIR=""
    for _stat_candidate in \
        "$COMMON" \
        "$SERVER_DIR/scripts/common"; do
        if [[ -f "$_stat_candidate/snapmulti-status.service" && \
              -f "$_stat_candidate/snapmulti-status.timer" ]]; then
            STATUS_DIR="$_stat_candidate"; break
        fi
    done
    if [[ -n "$STATUS_DIR" ]]; then
        cp "$STATUS_DIR/snapmulti-status.service" /etc/systemd/system/
        cp "$STATUS_DIR/snapmulti-status.timer"   /etc/systemd/system/
        systemctl daemon-reload
        systemctl enable snapmulti-status.timer
        log_info "System-status snapshot timer installed (5-min snapshot interval)"
    fi
fi

# Network music bind workaround for overlayroot recurse=0 (issue: NFS/SMB
# mounts land at /media/root-ro/media/<src>-music in the merged root, so
# /media/<src>-music ends up empty and MPD's bind-mount serves nothing).
# Installed for server / both modes only — client-only installs do not run
# the music stack.
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    if [[ "${MUSIC_SOURCE:-}" == "nfs" || "${MUSIC_SOURCE:-}" == "smb" ]]; then
        BIND_DIR=""
        for _bind_candidate in \
            "$COMMON" \
            "$SERVER_DIR/scripts/common"; do
            if [[ -f "$_bind_candidate/snapmulti-music-bind.service" && \
                  -f "$_bind_candidate/snapmulti-music-bind.sh" ]]; then
                BIND_DIR="$_bind_candidate"; break
            fi
        done
        if [[ -n "$BIND_DIR" ]]; then
            install -m 0755 "$BIND_DIR/snapmulti-music-bind.sh" /usr/local/bin/snapmulti-music-bind
            cp "$BIND_DIR/snapmulti-music-bind.service" /etc/systemd/system/
            systemctl daemon-reload
            systemctl enable snapmulti-music-bind.service
            log_info "Music-bind unit installed (overlayroot $MUSIC_SOURCE workaround)"
        fi
        unset BIND_DIR _bind_candidate
    fi
fi

# Read-only filesystem
if [[ "${ENABLE_READONLY}" == "true" ]]; then
    log_info "Configuring read-only filesystem..."
    RO_MODE_SCRIPT=""
    for _ro_candidate in \
        "$SERVER_DIR/scripts/ro-mode.sh" \
        "$CLIENT_DIR/scripts/ro-mode.sh" \
        "$SNAP_BOOT/server/ro-mode.sh" \
        "$SNAP_BOOT/common/ro-mode.sh"; do
        [[ -f "$_ro_candidate" ]] && RO_MODE_SCRIPT="$_ro_candidate" && break
    done
    setup_readonly_fs "$RO_MODE_SCRIPT"
    log_info "Read-only filesystem configured"
else
    log_info "Read-only filesystem: skipped (ENABLE_READONLY=false)"
fi

# ══════════════════════════════════════════════════════════════════
# COMPLETE
# ══════════════════════════════════════════════════════════════════
set_module "complete"
touch "$MARKER"

progress_complete 2>/dev/null || true

LOCAL_HOSTNAME=$(hostname 2>/dev/null || echo "snapmulti")
IP_ADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true

# Show completion banner on both log and HDMI console.
# log_info only writes to the install log + PROGRESS_LOG, not the visible
# console — use a direct echo to the install TUI tty. For server-only this
# is /dev/tty1 (and the user sees it directly); for client/both we already
# switched to /dev/tty8 so fb-display can render — the banner survives in
# the log, and fb-display itself shows the install is finished.
_tty() { echo "$*" > "$PROGRESS_TTY" 2>/dev/null || true; log_info "$*"; }

_elapsed="$((SECONDS / 60))m$((SECONDS % 60))s"
log_info "Installation completed in $_elapsed"
_tty ""
_tty "  +--------------------------------------------+"
_tty "  |       Installation complete!               |"
_tty "  +--------------------------------------------+"
_tty ""
case "$INSTALL_TYPE" in
    server|both)
        _tty "  Speakers:  http://${IP_ADDR:-$LOCAL_HOSTNAME}:1780"
        _tty "  Library:   http://${IP_ADDR:-$LOCAL_HOSTNAME}:8180"
        _tty "  Status:    http://${IP_ADDR:-$LOCAL_HOSTNAME}:8083  (system health page)"
        ;;
    client)
        _tty "  Player will auto-discover your server"
        ;;
esac
_tty ""
_tty "  Rebooting in 10 seconds..."
sleep 5
for i in 5 4 3 2 1; do
    _tty "  Rebooting in $i..."
    sleep 1
done
reboot
