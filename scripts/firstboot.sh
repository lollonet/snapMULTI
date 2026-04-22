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
checkpoint_done()    { touch "$INSTALLER_STATE/.done-$1"; }
checkpoint_reached() { [[ -f "$INSTALLER_STATE/.done-$1" ]]; }

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

# shellcheck source=common/verify-compose.sh
source "$COMMON/verify-compose.sh"

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
set_module "network"
next_step "Waiting for network..."
start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true
# shellcheck source=common/wait-network.sh
source "$COMMON/wait-network.sh"
wait_for_network
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
if checkpoint_reached "deps"; then
    log_info "Dependencies already installed (checkpoint), skipping"
else
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
    setup_docker
    checkpoint_done "docker"
fi
milestone "$CURRENT_STEP" "Docker installed" 2 2>/dev/null || true

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
        log_error "Server deployment failed"
        log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -50"
        exit 1
    fi
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

    # Run setup.sh — parse output through unified logger (same as deploy.sh)
    set +eo pipefail
    bash scripts/setup.sh "${setup_args[@]}" 2>&1 | while IFS= read -r line; do
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
        log_error "Client setup failed"
        log_error "Troubleshoot: sudo cat $UNIFIED_LOG | tail -50"
        exit 1
    fi
    set -eo pipefail
    unset PROGRESS_MANAGED
    milestone "$CURRENT_STEP" "Client setup complete" 2 2>/dev/null || true

    set_module "verify-client"
    next_step "Verifying client..."
    start_progress_animation "$CURRENT_STEP" "$(cumulative_pct "$CURRENT_STEP")" "$(current_weight)" 2>/dev/null || true

    # Start client via systemd — the lifecycle owner post-install (ADR-005)
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

# Show completion banner on both log and HDMI console
# (log_info only writes to log + PROGRESS_LOG, not tty1 — use direct echo)
_tty() { echo "$*" > /dev/tty1 2>/dev/null || true; log_info "$*"; }

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
