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

# Cleanup on failure
cleanup_on_failure() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
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

# Wait for network (needed for Docker install)
log_and_tty "Waiting for network..."
NETWORK_READY=false
for i in $(seq 1 60); do
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
        log_and_tty "Network ready."
        NETWORK_READY=true
        break
    fi
    [ $((i % 10)) -eq 0 ] && log_and_tty "  Still waiting... ($i/60)"
    sleep 2
done

if [ "$NETWORK_READY" = false ]; then
    log_and_tty "ERROR: Network not available after 2 minutes."
    log_and_tty "Check WiFi credentials or Ethernet connection."
    exit 1
fi

# Copy project files from boot partition
log_and_tty "Copying files to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR/scripts"
# Copy main files to root
cp "$SNAP_BOOT/docker-compose.yml" "$INSTALL_DIR/"
cp "$SNAP_BOOT/.env.example" "$INSTALL_DIR/" 2>/dev/null || true
cp -r "$SNAP_BOOT/config" "$INSTALL_DIR/"
# Copy scripts to scripts/ (deploy.sh expects this structure)
cp "$SNAP_BOOT/deploy.sh" "$INSTALL_DIR/scripts/"
cp "$SNAP_BOOT/firstboot.sh" "$INSTALL_DIR/scripts/"

# Install Docker if needed
if ! command -v docker &>/dev/null; then
    log_and_tty "Installing Docker..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg

    # Install Docker using official repository (more secure than get.docker.com)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # Detect architecture and OS
    ARCH=$(dpkg --print-architecture)
    VERSION_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

    echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $VERSION_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    # Add first user to docker group
    FIRST_USER=$(getent passwd 1000 | cut -d: -f1 || true)
    [ -n "$FIRST_USER" ] && usermod -aG docker "$FIRST_USER"
fi

# Verify Docker is running
if ! docker info &>/dev/null; then
    log_and_tty "ERROR: Docker failed to start."
    exit 1
fi

# Run deploy script
log_and_tty "Running deploy.sh ..."
cd "$INSTALL_DIR"
if ! bash scripts/deploy.sh >> "$LOG" 2>&1; then
    log_and_tty "ERROR: deploy.sh failed."
    exit 1
fi

# Verify containers are healthy (docker-compose healthchecks)
log_and_tty "Waiting for containers to become healthy..."
HEALTHY=false
for attempt in $(seq 1 12); do
    # Count healthy containers (exact match to avoid "unhealthy" false positive)
    TOTAL=$(docker ps --format '{{.Names}}' | wc -l)
    HEALTHY_COUNT=$(docker ps --format '{{.Status}}' | grep -c "(healthy)" || true)
    if [ "$TOTAL" -ge 5 ] && [ "$HEALTHY_COUNT" -eq "$TOTAL" ]; then
        log_and_tty "All $TOTAL containers healthy."
        HEALTHY=true
        break
    fi
    log_and_tty "  Attempt $attempt/12: $HEALTHY_COUNT/$TOTAL healthy..."
    sleep 10
done

if [ "$HEALTHY" = false ]; then
    log_and_tty "WARNING: Not all containers healthy after 2 minutes."
    docker ps --format '{{.Names}}\t{{.Status}}' | while read -r line; do
        log_and_tty "  $line"
    done
    log_and_tty "Check: docker compose logs"
fi

# Mark as installed (only on success - trap won't fire since we exit 0)
touch "$MARKER"

log_and_tty ""
log_and_tty "  ━━━ Installation complete! ━━━"
log_and_tty ""
for i in 5 4 3 2 1; do
    log_and_tty "  Rebooting in $i..."
    sleep 1
done
reboot
