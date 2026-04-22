#!/usr/bin/env bash
set -euo pipefail

# ============================================
# Read-Only Mode Management Script
# ============================================
# Manages the read-only overlay filesystem.
# Uses raspi-config's built-in overlayfs support.
#
# Usage:
#   ro-mode enable   - Enable read-only mode (requires reboot)
#   ro-mode disable  - Disable read-only mode (requires reboot)
#   ro-mode status   - Check current mode
# ============================================

usage() {
    cat << 'EOF'
Usage: ro-mode <command>

Commands:
  enable   Enable read-only mode (protects SD card, requires reboot)
  disable  Disable read-only mode (allows writes, requires reboot)
  status   Check current read-only mode status

Examples:
  sudo ro-mode enable   # Enable protection, then reboot
  sudo ro-mode disable  # Disable for updates, then reboot
  ro-mode status        # Check current state (no sudo needed)
EOF
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This command requires root privileges"
        echo "Run: sudo ro-mode $1"
        exit 1
    fi
}

get_status() {
    # Check if root is mounted as overlayfs
    # raspi-config uses overlayroot: "overlayroot on / type overlay"
    if mount | grep -q " on / type overlay"; then
        echo "enabled"
    else
        echo "disabled"
    fi
}

case "${1:-}" in
    enable)
        check_root "enable"
        echo "Enabling read-only mode..."
        # Workaround: trixie systemd-remount-fs fails with overlayroot (systemd#39558)
        mkdir -p /etc/systemd/system.conf.d
        cat > /etc/systemd/system.conf.d/overlayfs-workaround.conf << 'SYSDEOF'
[Manager]
DefaultEnvironment="LIBMOUNT_FORCE_MOUNT2=always"
SYSDEOF
        if ! raspi-config nonint do_overlayfs 0; then
            # Roll back: remove override since overlayroot won't be active
            rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
            echo "ERROR: Failed to enable read-only mode."
            echo "Check that raspi-config is installed and has proper permissions."
            exit 1
        fi
        echo "Read-only mode enabled. Reboot to activate:"
        echo "  sudo reboot"
        ;;
    disable)
        check_root "disable"
        echo "Disabling read-only mode..."
        # Remove trixie workaround from BOTH overlay and lower layer.
        # On overlayroot, /etc is tmpfs — rm only affects the overlay.
        # The real root is at /media/root-ro; delete there to persist after reboot.
        rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
        rm -f /media/root-ro/etc/systemd/system.conf.d/overlayfs-workaround.conf 2>/dev/null || true
        if ! raspi-config nonint do_overlayfs 1; then
            echo "ERROR: Failed to disable read-only mode."
            echo "Check that raspi-config is installed and has proper permissions."
            exit 1
        fi
        echo "Read-only mode disabled. Reboot to activate:"
        echo "  sudo reboot"
        ;;
    status)
        status=$(get_status)
        if [[ "$status" == "enabled" ]]; then
            echo "RO mode: enabled (root filesystem is read-only)"
        else
            echo "RO mode: disabled (root filesystem is writable)"
        fi
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
