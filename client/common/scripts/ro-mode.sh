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

# Source the SSOT helpers from scripts/common (single point for both client
# CLI and server/client firstboot finalize):
#   - cmdline-manager.sh: cmdline.txt idempotent patch/unpatch
#   - overlayroot-lifecycle.sh: persist_overlayroot_enabled/disabled +
#     install_initramfs_lzma_hook
# Probe both the dev tree path and the on-device install paths.
_RO_MODE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _common_root in \
    "$_RO_MODE_DIR/../../../scripts/common" \
    "$_RO_MODE_DIR/../../scripts/common" \
    "/opt/snapmulti/scripts/common" \
    "/opt/snapclient/scripts/common"; do
    # Both files must be present in the same install dir: sourcing only
    # cmdline-manager.sh would leave persist_overlayroot_enabled undefined,
    # and `ro-mode enable` would fail with "command not found" at runtime
    # instead of failing cleanly at startup.
    if [[ -f "$_common_root/cmdline-manager.sh" && -f "$_common_root/overlayroot-lifecycle.sh" ]]; then
        # shellcheck disable=SC1091
        source "$_common_root/cmdline-manager.sh"
        # shellcheck disable=SC1091
        source "$_common_root/overlayroot-lifecycle.sh"
        break
    fi
done
unset _common_root

if ! declare -F persist_overlayroot_enabled >/dev/null 2>&1; then
    echo "ERROR: ro-mode could not locate scripts/common (cmdline-manager.sh + overlayroot-lifecycle.sh)." >&2
    echo "       Searched: $_RO_MODE_DIR/../../../scripts/common, $_RO_MODE_DIR/../../scripts/common," >&2
    echo "                 /opt/snapmulti/scripts/common, /opt/snapclient/scripts/common." >&2
    exit 1
fi

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

# persist_overlayroot_enabled / persist_overlayroot_disabled live in
# scripts/common/overlayroot-lifecycle.sh (sourced above).

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
        # Re-install the snapmulti-lzma initramfs hook BEFORE raspi-config
        # so its internal update-initramfs picks the hook up on its first
        # pass — no second rebuild round needed. Idempotent: if the hook
        # is already there with the same content, `install -m 755` just
        # overwrites it. Necessary because a user may have run `ro-mode
        # disable` followed by `apt purge initramfs-tools-core` (or
        # hand-removed the hook) before re-enabling — without the hook,
        # the next boot lands in ext4 fallback with the snapdigi-class
        # failure (overlay module unloadable because liblzma is missing
        # from initramfs and kmod cannot decompress the .ko.xz file).
        _found_hook=0
        for _hook_cand in \
            "$_RO_MODE_DIR/../../../scripts/common/initramfs-hooks/snapmulti-lzma" \
            "$_RO_MODE_DIR/../../scripts/common/initramfs-hooks/snapmulti-lzma" \
            "/opt/snapclient/scripts/common/initramfs-hooks/snapmulti-lzma" \
            "/opt/snapmulti/scripts/common/initramfs-hooks/snapmulti-lzma"; do
            if [[ -f "$_hook_cand" ]]; then
                install_initramfs_lzma_hook "$_hook_cand" || \
                    echo "WARNING: lzma hook install failed — overlay may not activate"
                _found_hook=1
                break
            fi
        done
        unset _hook_cand
        (( _found_hook )) || \
            echo "WARNING: snapmulti-lzma hook source not found — initramfs rebuilt without liblzma, overlay may not activate"
        unset _found_hook

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
