#!/usr/bin/env bash
# snapMULTI Auto-Install — runs once on first boot.
# Copies project files from the boot partition to /opt/snapmulti,
# runs deploy.sh, then reboots.
set -euo pipefail

MARKER="/opt/snapmulti/.auto-installed"

# Skip if already installed
if [ -f "$MARKER" ]; then
    echo "snapMULTI already installed, skipping."
    exit 0
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
    echo "ERROR: $SNAP_BOOT not found on boot partition."
    exit 1
fi

# Helper: write to both log and HDMI console
log_and_tty() { echo "$*" | tee -a "$LOG" /dev/tty1 2>/dev/null || true; }

log_and_tty "========================================="
log_and_tty "snapMULTI Auto-Install"
log_and_tty "========================================="

# Wait for network (needed for Docker install)
log_and_tty "Waiting for network..."
for i in $(seq 1 60); do
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then
        log_and_tty "Network ready."
        break
    fi
    [ $((i % 10)) -eq 0 ] && log_and_tty "  Still waiting... ($i/60)"
    sleep 2
done

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
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    # Add first user to docker group
    FIRST_USER=$(getent passwd 1000 | cut -d: -f1 || true)
    [ -n "$FIRST_USER" ] && usermod -aG docker "$FIRST_USER"
fi

# Run deploy script
log_and_tty "Running deploy.sh ..."
cd "$INSTALL_DIR"
bash scripts/deploy.sh >> "$LOG" 2>&1

# Mark as installed
touch "$MARKER"

log_and_tty ""
log_and_tty "  ━━━ Installation complete! ━━━"
log_and_tty ""
for i in 5 4 3 2 1; do
    log_and_tty "  Rebooting in $i..."
    sleep 1
done
reboot
