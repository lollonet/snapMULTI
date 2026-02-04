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

# --- Detect Pi OS version ---
detect_pi_os_version() {
    local boot_dir="$1"

    # Bookworm has kernel_2712.img (Pi 5 support) or specific markers
    if [[ -f "$boot_dir/kernel_2712.img" ]]; then
        echo "bookworm"
        return
    fi

    # Check config.txt for Bookworm-specific entries
    if grep -q "camera_auto_detect" "$boot_dir/config.txt" 2>/dev/null; then
        echo "bookworm"
        return
    fi

    # Default to Bullseye for older images
    echo "bullseye"
}

# --- Create snapMULTI install script ---
create_install_script() {
    local boot_dir="$1"

    # Create our install script (separate from Pi Imager's firstrun.sh)
    cat > "$boot_dir/snapmulti-install.sh" << 'INSTALL_EOF'
#!/bin/bash
# snapMULTI Installation Script
# Called after Pi Imager's firstrun completes (WiFi/user already configured)

set -e

# --- Detect boot directory (Bullseye vs Bookworm) ---
if [[ -d /boot/firmware ]]; then
    BOOT_DIR="/boot/firmware"
else
    BOOT_DIR="/boot"
fi

# --- Logging ---
LOG_FILE="/var/log/snapmulti-install.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/snapmulti-install.log"

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

tty_msg() { echo "$*" > /dev/tty1 2>/dev/null || true; }

log "=== snapMULTI Installation Starting ==="
tty_msg "snapMULTI: Starting installation..."

# --- Wait for network (should already be up from Pi Imager config) ---
wait_for_network() {
    log "Checking network connectivity..."
    local attempts=0
    local max_attempts=30

    while [[ $attempts -lt $max_attempts ]]; do
        if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1; then
            log "Network ready"
            return 0
        fi
        attempts=$((attempts + 1))
        log "Waiting for network... (attempt $attempts/$max_attempts)"
        sleep 2
    done

    log "WARNING: Network not available after $max_attempts attempts"
    return 1
}

if ! wait_for_network; then
    log "ERROR: No network connectivity. WiFi configured in Pi Imager?"
    tty_msg "ERROR: No network! Check WiFi config."
    exit 1
fi

# --- Wait for time sync (important for HTTPS) ---
log "Waiting for time sync..."
attempts=0
while [[ $attempts -lt 30 ]]; do
    if [[ $(date +%Y) -ge 2025 ]]; then
        log "Time synchronized: $(date)"
        break
    fi
    attempts=$((attempts + 1))
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
    apt-get install -y -qq curl ca-certificates git

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

        # Create .env file
        FIRST_USER=$(getent passwd 1000 | cut -d: -f1)
        PUID=$(id -u "$FIRST_USER" 2>/dev/null || echo 1000)
        PGID=$(id -g "$FIRST_USER" 2>/dev/null || echo 1000)
        TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Berlin")

        cat > .env << EOF
MUSIC_PATH=/media/music
TZ=$TZ
PUID=$PUID
PGID=$PGID
EOF

        chown -R "$PUID:$PGID" "$INSTALL_DIR"

        # Pull and start services
        docker compose pull
        docker compose up -d
    fi

    log "Installation complete"
}

install_snapmulti

# --- Verify installation ---
log "Verifying installation..."
sleep 10

RUNNING=$(docker ps --format '{{.Names}}' | wc -l)
log "Running containers: $RUNNING"

if [[ $RUNNING -ge 4 ]]; then
    log "Installation successful!"
    tty_msg "snapMULTI: Installation complete!"
else
    log "WARNING: Expected 4+ containers, found $RUNNING"
    docker ps
fi

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
log "  Logs: $LOG_FILE"
log "============================================"

tty_msg ""
tty_msg "================================"
tty_msg " snapMULTI Ready!"
tty_msg " Web UI: http://$IP_ADDR:8180"
tty_msg "================================"

# --- Cleanup ---
log "Cleaning up install script..."
rm -f "$BOOT_DIR/snapmulti-install.sh"

log "Done."
INSTALL_EOF

    chmod +x "$boot_dir/snapmulti-install.sh"
    success "Created snapmulti-install.sh"
}

# --- Setup firstrun hook ---
setup_firstrun_hook() {
    local boot_dir="$1"
    local pi_os="$2"

    local firstrun_path
    if [[ "$pi_os" == "bookworm" ]]; then
        firstrun_path="$boot_dir/firstrun.sh"
    else
        firstrun_path="$boot_dir/firstrun.sh"
    fi

    local install_script_path
    if [[ "$pi_os" == "bookworm" ]]; then
        install_script_path="/boot/firmware/snapmulti-install.sh"
    else
        install_script_path="/boot/snapmulti-install.sh"
    fi

    if [[ -f "$firstrun_path" ]]; then
        # Pi Imager's firstrun.sh exists - append our hook BEFORE it exits
        info "Found Pi Imager's firstrun.sh - appending snapMULTI hook"

        # Check if we already added our hook
        if grep -q "snapmulti-install.sh" "$firstrun_path" 2>/dev/null; then
            warn "snapMULTI hook already present in firstrun.sh"
            return 0
        fi

        # Find the exit or end of script and insert our hook before it
        # Pi Imager's firstrun.sh typically ends with cleanup and rm -f
        # We insert our script call before the final cleanup

        # Create a temp file with our addition
        local temp_file
        temp_file=$(mktemp)

        # Read the original, insert our hook before 'rm -f' or at the end
        awk -v install_path="$install_script_path" '
        /^rm -f.*firstrun/ {
            print "# --- snapMULTI Installation ---"
            print "if [[ -x \"" install_path "\" ]]; then"
            print "    \"" install_path "\""
            print "fi"
            print ""
        }
        { print }
        ' "$firstrun_path" > "$temp_file"

        # If we didn't find rm -f pattern, append at end
        if ! grep -q "snapmulti-install.sh" "$temp_file"; then
            cat >> "$temp_file" << EOF

# --- snapMULTI Installation ---
if [[ -x "$install_script_path" ]]; then
    "$install_script_path"
fi
EOF
        fi

        mv "$temp_file" "$firstrun_path"
        chmod +x "$firstrun_path"
        success "Hooked snapMULTI into Pi Imager's firstrun.sh"
    else
        # No Pi Imager firstrun.sh - create minimal one
        info "No Pi Imager firstrun.sh found - creating standalone"

        cat > "$firstrun_path" << EOF
#!/bin/bash
# Minimal firstrun for snapMULTI (no Pi Imager config detected)
set -e

# Run snapMULTI installation
if [[ -x "$install_script_path" ]]; then
    "$install_script_path"
fi

# Cleanup and reboot
BOOT_DIR="\$(dirname "\$0")"
rm -f "\$BOOT_DIR/firstrun.sh"

# Remove kernel cmdline hook
sed -i 's| systemd.run=[^ ]*||g' "\$BOOT_DIR/cmdline.txt"
sed -i 's| systemd.run_success_action=[^ ]*||g' "\$BOOT_DIR/cmdline.txt"

sleep 2
reboot
EOF
        chmod +x "$firstrun_path"

        # Also need to add systemd.run to cmdline.txt
        patch_cmdline "$boot_dir" "$pi_os"
    fi
}

# --- Patch cmdline.txt (only if no Pi Imager firstrun) ---
patch_cmdline() {
    local boot_dir="$1"
    local pi_os="$2"
    local cmdline="$boot_dir/cmdline.txt"

    # Check if systemd.run already present (from Pi Imager)
    if grep -q "systemd.run=" "$cmdline" 2>/dev/null; then
        info "cmdline.txt already has systemd.run (Pi Imager) - skipping"
        return 0
    fi

    # Backup original
    cp "$cmdline" "$cmdline.bak"

    local firstrun_path
    if [[ "$pi_os" == "bookworm" ]]; then
        firstrun_path="/boot/firmware/firstrun.sh"
    else
        firstrun_path="/boot/firstrun.sh"
    fi

    # Append systemd.run directive
    local current
    current=$(cat "$cmdline" | tr -d '\n')
    echo "$current systemd.run=$firstrun_path systemd.run_success_action=reboot" > "$cmdline"

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

    # Detect Pi OS version
    local pi_os
    pi_os=$(detect_pi_os_version "$boot_dir")
    info "Detected Pi OS: $pi_os"

    # Check for existing snapmulti-install.sh
    if [[ -f "$boot_dir/snapmulti-install.sh" ]]; then
        warn "snapmulti-install.sh already exists!"
        echo -n "Overwrite? [y/N]: "
        read -r confirm
        [[ "$confirm" =~ ^[Yy] ]] || exit 0
    fi

    # Create our install script
    create_install_script "$boot_dir"

    # Setup firstrun hook (appends to Pi Imager's or creates new)
    setup_firstrun_hook "$boot_dir" "$pi_os"

    echo ""
    success "SD card prepared for zero-touch install!"
    echo ""
    echo "Next steps:"
    echo "  1. Safely eject the SD card"
    echo "  2. Insert into Raspberry Pi"
    echo "  3. Power on and wait for installation to complete"
    echo "  4. Connect to http://snapmulti.local:8180"
    echo ""
    if [[ -f "$boot_dir/firstrun.sh" ]] && grep -q "raspberrypi\|imager" "$boot_dir/firstrun.sh" 2>/dev/null; then
        info "Pi Imager config detected - WiFi/user will be configured first"
    else
        warn "No Pi Imager config - ensure WiFi is set up or use Ethernet"
    fi
    echo ""
}

main "$@"
