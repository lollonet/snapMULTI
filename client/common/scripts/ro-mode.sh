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

# cmdline-manager.sh provides the idempotent cmdline.txt helpers
# (cmdline_path, cmdline_ensure_overlayroot, cmdline_remove_overlayroot).
# Probe both the dev tree path and the on-device install path.
_RO_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _cm_candidate in \
    "$_RO_MODE_DIR/../../../scripts/common/cmdline-manager.sh" \
    "$_RO_MODE_DIR/../../scripts/common/cmdline-manager.sh" \
    "/opt/snapmulti/scripts/common/cmdline-manager.sh" \
    "/opt/snapclient/scripts/common/cmdline-manager.sh"; do
    # shellcheck disable=SC1090
    if [[ -f "$_cm_candidate" ]]; then
        source "$_cm_candidate"
        break
    fi
done
unset _cm_candidate

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

# Backwards-compat alias — older callers / debugging snippets used
# cmdline_file. New code calls cmdline_path() from cmdline-manager.sh.
cmdline_file() {
    cmdline_path
}

# Persist overlayroot=tmpfs for next boot:
#   1. Add the token to cmdline.txt (cmdline-manager.sh helper)
#   2. Write /etc/overlayroot.local.conf with `tmpfs:recurse=0`
#      (recurse=0 overlays only `/`, leaving NFS/USB fstab entries
#      writable — prevents systemd ordering cycles).
# Mirrors scripts/common/system-tune.sh:persist_overlayroot_enabled
# (server side) so client and server boot configs stay byte-identical.
persist_overlayroot_enabled() {
    cmdline_ensure_overlayroot || return 1
    cat > /etc/overlayroot.local.conf <<'OREOF' || return 1
overlayroot="tmpfs:recurse=0"
overlayroot_cfgdisk="disabled"
OREOF
}

# Reverse of persist_overlayroot_enabled. `root_prefix` lets the caller
# point at a non-default rootfs (used by recovery / installer images
# that mount a target rootfs under e.g. /mnt — irrelevant for the
# default on-device invocation).
persist_overlayroot_disabled() {
    local root_prefix="${1:-}"
    cmdline_remove_overlayroot || return 1
    rm -f "${root_prefix}/etc/overlayroot.local.conf"
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
        if ! persist_overlayroot_enabled; then
            rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
            rm -f /etc/overlayroot.local.conf
            echo "ERROR: Failed to persist overlayroot configuration."
            exit 1
        fi
        echo "Read-only mode enabled. Reboot to activate:"
        echo "  sudo reboot"
        ;;
    disable)
        check_root "disable"
        echo "Disabling read-only mode..."
        if ! raspi-config nonint do_overlayfs 1; then
            echo "ERROR: Failed to disable read-only mode."
            echo "Check that raspi-config is installed and has proper permissions."
            exit 1
        fi
        persist_overlayroot_disabled "" || true
        persist_overlayroot_disabled "/media/root-ro" || true
        # Remove trixie workaround AFTER disable succeeds.
        # Delete from lower layer (/media/root-ro) so it persists after reboot.
        rm -f /etc/systemd/system.conf.d/overlayfs-workaround.conf
        rm -f /media/root-ro/etc/systemd/system.conf.d/overlayfs-workaround.conf 2>/dev/null || true
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
