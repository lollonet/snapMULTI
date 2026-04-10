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
    echo "Previous install failed. Check /var/log/snapmulti-install.log"
    echo "Remove $FAILED_MARKER to retry."
    exit 1
fi

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
    SMB_USER=$(grep -m1 '^SMB_USER=' "$SNAP_BOOT/install.conf" | cut -d= -f2- | tr -d '[:space:]')
    SMB_PASS=$(grep -m1 '^SMB_PASS=' "$SNAP_BOOT/install.conf" | cut -d= -f2- | tr -d '\r')
fi

# Read advanced options
ENABLE_READONLY="true"
SKIP_UPGRADE="false"
IMAGE_TAG="latest"
AUTO_UPDATE=""
VERBOSE_INSTALL="false"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    _rc() { grep -m1 "^$1=" "$SNAP_BOOT/install.conf" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true; }
    local_val=$(_rc ENABLE_READONLY); [[ -n "$local_val" ]] && ENABLE_READONLY="$local_val"
    local_val=$(_rc SKIP_UPGRADE);    [[ -n "$local_val" ]] && SKIP_UPGRADE="$local_val"
    local_val=$(_rc IMAGE_TAG);       [[ -n "$local_val" ]] && IMAGE_TAG="$local_val"
    local_val=$(_rc AUTO_UPDATE);     [[ -n "$local_val" ]] && AUTO_UPDATE="$local_val"
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

# Source unified logger
COMMON="$SNAP_BOOT/common"
[[ ! -d "$COMMON" ]] && COMMON="$SCRIPT_DIR/common"
# shellcheck source=common/unified-log.sh
source "$COMMON/unified-log.sh"

# Configure progress steps based on install type
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

# ── Error handling ───────────────────────────────────────────────
CURRENT_MODULE="init"
cleanup_on_failure() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        stop_progress_animation 2>/dev/null || true
        log_error "Installation FAILED in module: $CURRENT_MODULE (exit code: $exit_code)"
        log_error "Check log: $UNIFIED_LOG"
        echo "" > /dev/tty1 2>/dev/null || true
        echo "  --- Installation FAILED (module: $CURRENT_MODULE) ---" > /dev/tty1 2>/dev/null || true
        echo "  Check log: $UNIFIED_LOG" > /dev/tty1 2>/dev/null || true
        touch "$FAILED_MARKER"
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

# Headless detection (for client modes)
has_display() {
    [[ -c /dev/fb0 ]] || return 1
    local found_status=false
    for card in /sys/class/drm/card*-HDMI-*/status; do
        [[ -f "$card" ]] || continue
        found_status=true
        grep -q "^connected" "$card" && return 0
    done
    $found_status && return 1
    return 1
}

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
CURRENT_MODULE="network"
next_step "Waiting for network..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
# shellcheck source=common/wait-network.sh
source "$COMMON/wait-network.sh"
wait_for_network
milestone "$CURRENT_STEP" "Network ready" 2 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 2: Copy files
# ══════════════════════════════════════════════════════════════════
CURRENT_MODULE="copy"
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
        cp "$SNAP_BOOT/server/.version" "$SERVER_DIR/" 2>/dev/null || true
        if [[ -f "$SNAP_BOOT/server/mpd/data/mpd.db" ]]; then
            mkdir -p "$SERVER_DIR/mpd/data"
            cp "$SNAP_BOOT/server/mpd/data/mpd.db" "$SERVER_DIR/mpd/data/"
            log_info "Restored MPD database backup"
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
    [[ -d "$CLIENT_DIR/audio-hats" ]] || local_missing+=("audio-hats/")
    if [[ ${#local_missing[@]} -gt 0 ]]; then
        log_error "Critical client files missing: ${local_missing[*]}"
        exit 1
    fi
    log_info "Client files copied to $CLIENT_DIR"
fi

# ══════════════════════════════════════════════════════════════════
# STEP 3: System dependencies
# ══════════════════════════════════════════════════════════════════
CURRENT_MODULE="deps"
next_step "Installing git and dependencies..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
# shellcheck source=common/install-deps.sh
source "$COMMON/install-deps.sh"
install_dependencies
milestone "$CURRENT_STEP" "System dependencies installed" 2 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# STEP 4: Docker
# ══════════════════════════════════════════════════════════════════
CURRENT_MODULE="docker"
next_step "Installing Docker..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
# shellcheck source=common/setup-docker.sh
source "$COMMON/setup-docker.sh"
setup_docker
milestone "$CURRENT_STEP" "Docker installed" 2 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════
# SERVER INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "server" || "$INSTALL_TYPE" == "both" ]]; then
    CURRENT_MODULE="deploy"
    next_step "Deploy server..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    # Mount music source
    # shellcheck source=common/mount-music.sh
    source "$COMMON/mount-music.sh"
    setup_music_source
    scrub_credentials

    # Export IMAGE_TAG + AUTO_UPDATE for deploy.sh
    if [[ "$IMAGE_TAG" != "latest" ]]; then
        export IMAGE_TAG
        log_info "Using image tag: $IMAGE_TAG"
    fi
    if [[ "$AUTO_UPDATE" == "true" ]]; then
        export AUTO_UPDATE
        log_info "Auto-update: enabled"
    fi

    if [[ ! -d "$SERVER_DIR" ]]; then
        log_error "Server directory missing: $SERVER_DIR"
        exit 1
    fi
    cd "$SERVER_DIR"

    # Run deploy.sh — parse output through unified logger
    set +eo pipefail
    bash scripts/deploy.sh 2>&1 | while IFS= read -r line; do
        if [[ "$VERBOSE_INSTALL" == "true" ]]; then
            log_msg INFO deploy "${line:0:200}"
        else
            case "$line" in
                *"[INFO] "*|*"[OK] "*|*"==> "*)
                    local_msg="${line#*] }"
                    local_msg="${local_msg#==> }"
                    log_msg INFO deploy "$local_msg"
                    ;;
                *"Pulling "*|*"pulling "*|*"Downloaded"*|*"Pull complete"*)
                    log_msg INFO deploy "$line"
                    ;;
            esac
        fi
    done
    deploy_rc=${PIPESTATUS[0]}
    set -eo pipefail

    if [[ "$deploy_rc" -ne 0 ]]; then
        log_error "Server deployment failed"
        log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -50"
        exit 1
    fi
    milestone "$CURRENT_STEP" "Server deploy complete" 2 2>/dev/null || true

    # Verify server containers
    CURRENT_MODULE="verify-server"
    next_step "Verifying server containers..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    local_healthy=false
    for attempt in $(seq 1 12); do
        local_total=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps -q 2>/dev/null | wc -l)
        local_running=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps --format '{{.State}}' 2>/dev/null | grep -c '^running' || true)
        if [[ "$local_running" -eq 0 ]] && [[ "$local_total" -gt 0 ]]; then
            local_running=$(docker compose -f "$SERVER_DIR/docker-compose.yml" ps 2>/dev/null | grep -c ' Up ' || true)
        fi
        if [[ "$local_total" -ge 6 ]] && [[ "$local_running" -eq "$local_total" ]]; then
            log_info "All $local_total server containers running"
            local_healthy=true
            break
        fi
        log_info "Attempt $attempt/12: $local_running/$local_total running..."
        sleep 10
    done

    if [[ "$local_healthy" == "false" ]]; then
        log_warn "Not all server containers healthy after 2 minutes"
        docker ps --format '{{.Names}}\t{{.Status}}' | while read -r line; do
            log_warn "  $line"
        done
    fi
fi

# ══════════════════════════════════════════════════════════════════
# CLIENT INSTALL
# ══════════════════════════════════════════════════════════════════
if [[ "$INSTALL_TYPE" == "client" || "$INSTALL_TYPE" == "both" ]]; then
    CURRENT_MODULE="setup"

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
    if [[ -n "$CONFIG_FILE" ]]; then
        if ! bash scripts/setup.sh --auto "$CONFIG_FILE" >> "$UNIFIED_LOG" 2>&1; then
            log_error "Client setup failed"
            log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -50"
            exit 1
        fi
    else
        if ! bash scripts/setup.sh --auto >> "$UNIFIED_LOG" 2>&1; then
            log_error "Client setup failed"
            log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -50"
            exit 1
        fi
    fi
    unset PROGRESS_MANAGED
    milestone "$CURRENT_STEP" "Client setup complete" 2 2>/dev/null || true

    CURRENT_MODULE="verify-client"
    next_step "Verifying client..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
    sleep 5
    local_client_count=$(docker ps --format '{{.Names}}' | grep -c "snapclient" || true)
    if [[ "$local_client_count" -ge 1 ]]; then
        log_info "Client container running"
    else
        log_warn "snapclient container not running"
    fi
fi

# ══════════════════════════════════════════════════════════════════
# FINAL OPERATIONS
# ══════════════════════════════════════════════════════════════════
CURRENT_MODULE="finalize"

# Final package refresh
if [[ "$SKIP_UPGRADE" == "true" ]]; then
    log_info "Skipping final package refresh (SKIP_UPGRADE=true)"
else
    log_info "Final package refresh..."
    # Reuse apt lock waiter from install-deps module
    _wait_for_apt_lock 2>/dev/null || true
    if ! apt-get update >> "$UNIFIED_LOG" 2>&1; then
        log_warn "Final apt-get update failed (non-fatal)"
    elif ! apt-get upgrade -y >> "$UNIFIED_LOG" 2>&1; then
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
CURRENT_MODULE="complete"
touch "$MARKER"

progress_complete 2>/dev/null || true

LOCAL_HOSTNAME=$(hostname 2>/dev/null || echo "snapmulti")
IP_ADDR=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true

log_info ""
log_info "+--------------------------------------------+"
log_info "|       Installation complete!               |"
log_info "+--------------------------------------------+"
log_info ""
case "$INSTALL_TYPE" in
    server|both)
        log_info "Speakers:  http://${IP_ADDR:-$LOCAL_HOSTNAME}:1780"
        log_info "Library:   http://${IP_ADDR:-$LOCAL_HOSTNAME}:8180"
        ;;
    client)
        log_info "Player will auto-discover your server"
        ;;
esac
log_info ""
log_info "Rebooting in 10 seconds..."
sleep 5
for i in 5 4 3 2 1; do
    log_info "Rebooting in $i..."
    sleep 1
done
reboot
