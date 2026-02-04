#!/usr/bin/env bash
# prepare-sd.sh — Zero-touch SD card preparation for snapMULTI
#
# Prepares a freshly-flashed Raspberry Pi OS SD card for automatic
# snapMULTI installation on first boot.
#
# Prerequisites:
#   1. Flash SD card with Raspberry Pi Imager
#   2. In Imager settings, configure:
#      - Hostname (e.g., snapmulti)
#      - Username/password
#      - WiFi (if needed)
#      - Enable SSH
#   3. Run this script with SD card still mounted
#
# Usage:
#   ./scripts/prepare-sd.sh [boot_partition_path]
#
# Examples:
#   ./scripts/prepare-sd.sh                      # Auto-detect on macOS
#   ./scripts/prepare-sd.sh /Volumes/bootfs     # Explicit path
#   ./scripts/prepare-sd.sh /media/user/bootfs  # Linux path

set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# --- Detect boot partition ---
detect_boot_partition() {
    local candidates=()

    # macOS: /Volumes/bootfs or /Volumes/boot
    if [[ "$(uname)" == "Darwin" ]]; then
        for name in bootfs boot; do
            [[ -d "/Volumes/$name" ]] && candidates+=("/Volumes/$name")
        done
    fi

    # Linux: /media/$USER/bootfs or /mnt/bootfs
    if [[ "$(uname)" == "Linux" ]]; then
        for base in "/media/$USER" "/media" "/mnt"; do
            for name in bootfs boot; do
                [[ -d "$base/$name" ]] && candidates+=("$base/$name")
            done
        done
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        return 1
    elif [[ ${#candidates[@]} -eq 1 ]]; then
        echo "${candidates[0]}"
    else
        warn "Multiple boot partitions found:"
        for i in "${!candidates[@]}"; do
            echo "  [$i] ${candidates[$i]}"
        done
        echo -n "Select [0]: "
        read -r choice
        choice=${choice:-0}
        echo "${candidates[$choice]}"
    fi
}

# --- Validate boot partition ---
validate_boot_partition() {
    local boot_dir="$1"

    if [[ ! -d "$boot_dir" ]]; then
        error "Directory not found: $boot_dir"
        return 1
    fi

    # Check for Pi boot partition markers
    if [[ ! -f "$boot_dir/config.txt" ]]; then
        error "Not a Raspberry Pi boot partition (no config.txt)"
        return 1
    fi

    if [[ ! -f "$boot_dir/cmdline.txt" ]]; then
        error "No cmdline.txt found"
        return 1
    fi

    return 0
}

# --- Check if already configured ---
check_existing_config() {
    local boot_dir="$1"

    if [[ -f "$boot_dir/firstrun.sh" ]]; then
        warn "firstrun.sh already exists!"
        echo -n "Overwrite? [y/N]: "
        read -r confirm
        [[ "$confirm" =~ ^[Yy] ]] || exit 0
    fi

    if grep -q "systemd.run=" "$boot_dir/cmdline.txt" 2>/dev/null; then
        warn "cmdline.txt already has systemd.run configuration"
        info "This may be from Pi Imager - will be replaced"
    fi
}

# --- Create firstrun.sh ---
create_firstrun_script() {
    local boot_dir="$1"

    cat > "$boot_dir/firstrun.sh" << 'FIRSTRUN_EOF'
#!/bin/bash
# snapMULTI Zero-Touch Install
# This script runs once on first boot, installs snapMULTI, then self-deletes

set -e

# --- Detect boot directory (Bullseye vs Bookworm) ---
if [[ -d /boot/firmware ]]; then
    BOOT_DIR="/boot/firmware"
else
    BOOT_DIR="/boot"
fi

# --- Logging ---
LOG_FILE="/var/log/snapmulti-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date '+%H:%M:%S')] $*"; }
tty_msg() { echo "$*" > /dev/tty1 2>/dev/null || true; }

log "=== snapMULTI Zero-Touch Install Starting ==="
tty_msg "snapMULTI: Starting installation..."

# --- Disable cloud-init if present (prevents conflicts) ---
if command -v cloud-init &>/dev/null; then
    touch /etc/cloud/cloud-init.disabled
    log "Disabled cloud-init"
fi

# --- Wait for network ---
wait_for_network() {
    log "Waiting for network..."
    tty_msg "snapMULTI: Waiting for network..."
    for i in {1..60}; do
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            log "Network ready"
            return 0
        fi
        sleep 2
    done
    log "WARNING: Network not available after 2 minutes"
    return 1
}

wait_for_network || true

# --- Wait for time sync (important for HTTPS) ---
log "Waiting for time sync..."
for i in {1..30}; do
    if [[ $(date +%Y) -ge 2025 ]]; then
        log "Time synchronized: $(date)"
        break
    fi
    sleep 2
done

# --- Install Docker ---
install_docker() {
    log "Installing Docker..."
    tty_msg "snapMULTI: Installing Docker..."

    export DEBIAN_FRONTEND=noninteractive

    # Update package list
    apt-get update -qq

    # Install prerequisites
    apt-get install -y -qq curl ca-certificates

    # Install Docker via convenience script
    curl -fsSL https://get.docker.com | sh

    # Enable Docker service
    systemctl enable docker
    systemctl start docker

    # Add first user to docker group
    FIRST_USER=$(getent passwd 1000 | cut -d: -f1)
    if [[ -n "$FIRST_USER" ]]; then
        usermod -aG docker "$FIRST_USER"
        log "Added $FIRST_USER to docker group"
    fi

    log "Docker installed successfully"
}

# Check if Docker is already installed
if ! command -v docker &>/dev/null; then
    install_docker
else
    log "Docker already installed"
fi

# --- Install and deploy snapMULTI ---
install_snapmulti() {
    log "Installing snapMULTI..."
    tty_msg "snapMULTI: Installing application..."

    INSTALL_DIR="/opt/snapmulti"
    REPO_URL="https://github.com/lollonet/snapMULTI.git"

    # Clone repository
    if [[ -d "$INSTALL_DIR" ]]; then
        log "Updating existing installation..."
        cd "$INSTALL_DIR"
        git pull --ff-only || true
    else
        log "Cloning repository..."
        git clone "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    # Use deploy.sh for setup (handles hardware detection, profiles, directories)
    if [[ -x "$INSTALL_DIR/scripts/deploy.sh" ]]; then
        log "Running deploy.sh for hardware-optimized setup..."
        tty_msg "snapMULTI: Configuring for your hardware..."
        bash "$INSTALL_DIR/scripts/deploy.sh"
    else
        # Fallback if deploy.sh not available (shouldn't happen)
        log "WARNING: deploy.sh not found, using minimal setup"

        # Create required directories
        mkdir -p audio data config mpd/data mpd/playlists mympd/workdir mympd/cachedir tidal

        # Detect music library
        MUSIC_PATH=""
        for path in /media/*/Music /media/*/music /mnt/*/Music /mnt/*/music /media/music /mnt/music; do
            if [[ -d "$path" ]]; then
                MUSIC_PATH="$path"
                log "Found music library: $MUSIC_PATH"
                break
            fi
        done

        # Create .env file
        FIRST_USER=$(getent passwd 1000 | cut -d: -f1)
        PUID=$(id -u "$FIRST_USER" 2>/dev/null || echo 1000)
        PGID=$(id -g "$FIRST_USER" 2>/dev/null || echo 1000)
        TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Berlin")

        cat > .env << EOF
# snapMULTI environment configuration
# Generated by zero-touch install on $(date)

MUSIC_PATH=${MUSIC_PATH:-/media/music}
TZ=$TZ
PUID=$PUID
PGID=$PGID
TIDAL_QUALITY=high_lossless
EOF

        # Set ownership
        chown -R "$PUID:$PGID" "$INSTALL_DIR"

        log ".env created with MUSIC_PATH=${MUSIC_PATH:-/media/music}"

        # Pull and start services
        docker compose pull
        docker compose up -d
    fi

    log "Installation complete"
}

install_snapmulti

# --- Verify installation ---
verify_install() {
    log "Verifying installation..."
    sleep 10

    RUNNING=$(docker ps --format '{{.Names}}' | wc -l)
    log "Running containers: $RUNNING"

    if [[ $RUNNING -ge 4 ]]; then
        log "Installation successful!"
        tty_msg "snapMULTI: Installation complete!"
        return 0
    else
        log "WARNING: Expected 4+ containers, found $RUNNING"
        docker ps
        return 1
    fi
}

verify_install || true

# --- Get IP address ---
IP_ADDR=$(hostname -I | awk '{print $1}')

# --- Print summary ---
log ""
log "============================================"
log "  snapMULTI Installation Complete!"
log "============================================"
log ""
log "  myMPD Web UI:  http://$IP_ADDR:8180"
log "  Snapcast API:  http://$IP_ADDR:1780"
log "  MPD Control:   $IP_ADDR:6600"
log ""
log "  Connect clients:"
log "    apt install snapclient"
log "    snapclient --host $IP_ADDR"
log ""
log "  Logs: $LOG_FILE"
log "============================================"

tty_msg ""
tty_msg "================================"
tty_msg " snapMULTI Ready!"
tty_msg " Web UI: http://$IP_ADDR:8180"
tty_msg "================================"

# --- Cleanup ---
log "Cleaning up firstrun script..."

# Remove systemd.run from cmdline.txt
sed -i 's| systemd.run=[^ ]*||g' "$BOOT_DIR/cmdline.txt"
sed -i 's| systemd.run_success_action=[^ ]*||g' "$BOOT_DIR/cmdline.txt"
sed -i 's| systemd.unit=[^ ]*||g' "$BOOT_DIR/cmdline.txt"

# Remove this script
rm -f "$BOOT_DIR/firstrun.sh"

log "Cleanup complete. Rebooting in 5 seconds..."
sleep 5

exit 0
FIRSTRUN_EOF

    chmod +x "$boot_dir/firstrun.sh"
    success "Created firstrun.sh"
}

# --- Detect Pi OS version ---
detect_pi_os_version() {
    local boot_dir="$1"

    # Bookworm has kernel_2712.img (Pi 5 support) or specific markers
    # Also check for /boot/firmware references in existing cmdline.txt
    if [[ -f "$boot_dir/kernel_2712.img" ]]; then
        echo "bookworm"
        return
    fi

    # Check cmdline.txt for /boot/firmware references (Bookworm default)
    if grep -q "root=PARTUUID=" "$boot_dir/cmdline.txt" 2>/dev/null; then
        # Modern Pi OS (Bookworm uses PARTUUID by default)
        # Check if it's a recent image by looking for overlays directory structure
        if [[ -d "$boot_dir/overlays" ]] && [[ -f "$boot_dir/config.txt" ]]; then
            # Check config.txt for Bookworm-specific entries
            if grep -q "camera_auto_detect" "$boot_dir/config.txt" 2>/dev/null; then
                echo "bookworm"
                return
            fi
        fi
    fi

    # Default to Bullseye for older images
    echo "bullseye"
}

# --- Patch cmdline.txt ---
patch_cmdline() {
    local boot_dir="$1"
    local cmdline="$boot_dir/cmdline.txt"

    # Backup original
    cp "$cmdline" "$cmdline.bak"

    # Remove any existing systemd.run entries
    sed -i.tmp 's| systemd.run=[^ ]*||g' "$cmdline"
    sed -i.tmp 's| systemd.run_success_action=[^ ]*||g' "$cmdline"
    sed -i.tmp 's| systemd.unit=[^ ]*||g' "$cmdline"
    rm -f "$cmdline.tmp"

    # Detect Pi OS version and set correct boot path
    local pi_os
    pi_os=$(detect_pi_os_version "$boot_dir")

    local firstrun_path
    if [[ "$pi_os" == "bookworm" ]]; then
        firstrun_path="/boot/firmware/firstrun.sh"
        info "Detected Bookworm - using $firstrun_path"
    else
        firstrun_path="/boot/firstrun.sh"
        info "Detected Bullseye - using $firstrun_path"
    fi

    # Append systemd.run directive
    # Must be on same line (cmdline.txt is single line)
    local current
    current=$(cat "$cmdline" | tr -d '\n')
    echo "$current systemd.run=$firstrun_path systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" > "$cmdline"

    success "Patched cmdline.txt"
    info "Backup saved to cmdline.txt.bak"
}

# --- Main ---
main() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║  snapMULTI SD Card Preparation           ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""

    # Get boot partition path
    local boot_dir="${1:-}"

    if [[ -z "$boot_dir" ]]; then
        info "Detecting boot partition..."
        boot_dir=$(detect_boot_partition) || {
            error "Could not auto-detect boot partition"
            echo ""
            echo "Usage: $0 /path/to/boot/partition"
            echo ""
            echo "Examples:"
            echo "  macOS:  $0 /Volumes/bootfs"
            echo "  Linux:  $0 /media/\$USER/bootfs"
            exit 1
        }
    fi

    info "Using boot partition: $boot_dir"

    # Validate
    validate_boot_partition "$boot_dir" || exit 1

    # Check for existing config
    check_existing_config "$boot_dir"

    # Create firstrun script
    create_firstrun_script "$boot_dir"

    # Patch cmdline.txt
    patch_cmdline "$boot_dir"

    echo ""
    success "SD card prepared for zero-touch install!"
    echo ""
    echo "Next steps:"
    echo "  1. Safely eject the SD card"
    echo "  2. Insert into Raspberry Pi"
    echo "  3. Power on and wait for installation to complete"
    echo "  4. Connect to http://snapmulti.local:8180"
    echo ""
    warn "Note: First boot takes longer due to Docker image pulls"
    echo ""
}

main "$@"
