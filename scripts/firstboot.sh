#!/usr/bin/env bash
# snapMULTI Auto-Install — runs once on first boot.
# Copies project files from the boot partition to /opt/snapmulti,
# runs deploy.sh, then reboots.
set -euo pipefail

# Secure PATH - prevent PATH hijacking attacks
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MARKER="/opt/snapmulti/.auto-installed"
FAILED_MARKER="/opt/snapmulti/.install-failed"

# Skip if already installed
if [ -f "$MARKER" ]; then
    echo "snapMULTI already installed, skipping."
    exit 0
fi

# Skip if previous install failed (requires manual intervention)
if [ -f "$FAILED_MARKER" ]; then
    echo "Previous install failed. Check /var/log/snapmulti-install.log"
    echo "Remove $FAILED_MARKER to retry."
    exit 1
fi

# Detect boot partition path
if [ -d /boot/firmware ]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi

SNAP_BOOT="$BOOT/snapmulti"
INSTALL_DIR="/opt/snapmulti"
LOG="/var/log/snapmulti-install.log"
export DEBIAN_FRONTEND=noninteractive

# Verify source files exist
if [ ! -d "$SNAP_BOOT" ]; then
    echo "ERROR: $SNAP_BOOT not found on boot partition." | tee -a "$LOG"
    exit 1
fi

# Helper: write to both log and HDMI console
log_and_tty() { echo "$*" | tee -a "$LOG" /dev/tty1 2>/dev/null || true; }

# Source progress display (if available)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    if [ $exit_code -ne 0 ]; then
        stop_progress_animation 2>/dev/null || true
        log_and_tty ""
        log_and_tty "  ━━━ Installation FAILED (exit code: $exit_code) ━━━"
        log_and_tty "  Check log: $LOG"
        log_and_tty ""
        mkdir -p "$INSTALL_DIR"
        touch "$FAILED_MARKER"
    fi
}
trap cleanup_on_failure EXIT

log_and_tty "========================================="
log_and_tty "snapMULTI Auto-Install"
log_and_tty "========================================="

# Initialize progress display
progress_init 2>/dev/null || true

# ── Step 1: Network ───────────────────────────────────────────────
progress 1 "Waiting for network..." 2>/dev/null || true
start_progress_animation 1 0 5 2>/dev/null || true
log_progress "Waiting for network connectivity..." 2>/dev/null || true

NETWORK_READY=false
for i in $(seq 1 60); do
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    if { [ -n "$GATEWAY" ] && ping -c1 -W2 "$GATEWAY" &>/dev/null; } || \
       ping -c1 -W2 1.1.1.1 &>/dev/null || \
       ping -c1 -W2 8.8.8.8 &>/dev/null; then
        log_and_tty "Network ready."
        log_progress "Network ready" 2>/dev/null || true
        NETWORK_READY=true
        break
    fi
    [ $((i % 10)) -eq 0 ] && log_progress "  Still waiting... ($i/60)" 2>/dev/null || true
    sleep 2
done

if [ "$NETWORK_READY" = false ]; then
    log_and_tty "ERROR: Network not available after 2 minutes."
    log_and_tty "Check WiFi credentials or Ethernet connection."
    exit 1
fi

# ── Step 2: Copy files ────────────────────────────────────────────
progress 2 "Copying project files..." 2>/dev/null || true
log_progress "Copying files to $INSTALL_DIR ..." 2>/dev/null || true

mkdir -p "$INSTALL_DIR/scripts"
cp "$SNAP_BOOT/docker-compose.yml" "$INSTALL_DIR/"
cp "$SNAP_BOOT/.env.example" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$SNAP_BOOT/config" "$INSTALL_DIR/"
cp "$SNAP_BOOT/deploy.sh" "$INSTALL_DIR/scripts/"
cp "$SNAP_BOOT/firstboot.sh" "$INSTALL_DIR/scripts/"
cp -r "$SNAP_BOOT/common" "$INSTALL_DIR/scripts/" 2>/dev/null || true

log_progress "Files copied" 2>/dev/null || true

# ── Step 3: Docker ────────────────────────────────────────────────
progress 3 "Installing Docker..." 2>/dev/null || true
start_progress_animation 3 7 35 2>/dev/null || true

if ! command -v docker &>/dev/null; then
    log_progress "apt-get update" 2>/dev/null || true
    apt-get update -qq
    log_progress "apt-get install: curl ca-certificates gnupg" 2>/dev/null || true
    apt-get install -y -qq curl ca-certificates gnupg

    # Install Docker using official repository
    install -m 0755 -d /etc/apt/keyrings
    log_progress "Downloading Docker GPG key..." 2>/dev/null || true
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    ARCH=$(dpkg --print-architecture)
    VERSION_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

    # Docker doesn't support all Debian versions - fallback to bookworm
    case "$VERSION_CODENAME" in
        bullseye|bookworm) DOCKER_CODENAME="$VERSION_CODENAME" ;;
        *) DOCKER_CODENAME="bookworm" ;;
    esac

    log_progress "Adding Docker repo ($DOCKER_CODENAME)..." 2>/dev/null || true
    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $DOCKER_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    log_progress "apt-get install: docker-ce docker-ce-cli..." 2>/dev/null || true
    log_progress "apt-get install: containerd.io docker-compose-plugin..." 2>/dev/null || true
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    log_progress "systemctl enable docker" 2>/dev/null || true
    systemctl enable docker
    systemctl start docker

    FIRST_USER=$(getent passwd 1000 | cut -d: -f1 || true)
    [ -n "$FIRST_USER" ] && usermod -aG docker "$FIRST_USER"
    log_progress "Docker installed" 2>/dev/null || true
else
    log_progress "Docker already installed, skipping" 2>/dev/null || true
fi

# Verify Docker is running
if ! docker info &>/dev/null; then
    log_and_tty "ERROR: Docker failed to start."
    exit 1
fi

# ── Step 4: Deploy ────────────────────────────────────────────────
progress 4 "Deploy & pull images..." 2>/dev/null || true
start_progress_animation 4 42 50 2>/dev/null || true
log_progress "Running deploy.sh ..." 2>/dev/null || true

cd "$INSTALL_DIR"
if ! bash scripts/deploy.sh >> "$LOG" 2>&1; then
    log_and_tty "ERROR: deploy.sh failed."
    exit 1
fi
log_progress "Deploy complete" 2>/dev/null || true

# ── Step 5: Verify ────────────────────────────────────────────────
progress 5 "Verifying containers..." 2>/dev/null || true
start_progress_animation 5 92 8 2>/dev/null || true
log_progress "Waiting for containers to become healthy..." 2>/dev/null || true

HEALTHY=false
for attempt in $(seq 1 12); do
    TOTAL=$(docker ps --format '{{.Names}}' | wc -l)
    HEALTHY_COUNT=$(docker ps --format '{{.Status}}' | grep -c "(healthy)" || true)
    if [ "$TOTAL" -ge 5 ] && [ "$HEALTHY_COUNT" -eq "$TOTAL" ]; then
        log_and_tty "All $TOTAL containers healthy."
        log_progress "All $TOTAL containers healthy" 2>/dev/null || true
        HEALTHY=true
        break
    fi
    log_progress "  Attempt $attempt/12: $HEALTHY_COUNT/$TOTAL healthy..." 2>/dev/null || true
    sleep 10
done

if [ "$HEALTHY" = false ]; then
    log_and_tty "WARNING: Not all containers healthy after 2 minutes."
    docker ps --format '{{.Names}}\t{{.Status}}' | while read -r line; do
        log_and_tty "  $line"
    done
    log_and_tty "Check: docker compose logs"
fi

# ── Complete ──────────────────────────────────────────────────────
touch "$MARKER"

progress_complete 2>/dev/null || true

log_and_tty ""
log_and_tty "  ━━━ Installation complete! ━━━"
log_and_tty ""
for i in 5 4 3 2 1; do
    log_and_tty "  Rebooting in $i..."
    sleep 1
done
reboot
