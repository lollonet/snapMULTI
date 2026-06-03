#!/usr/bin/env bash
# Sourced as a function library; `set -euo pipefail` intentionally omitted
# to avoid altering the calling shell's error mode. Every error path below
# is covered with explicit `if !` guards.
#
# overlayroot-lifecycle.sh — SSOT for overlayroot enable/disable persistence.
#
# Sourced by:
#   - scripts/common/system-tune.sh   (server + client firstboot finalize)
#   - client/common/scripts/ro-mode.sh (on-device operator CLI)
#
# Depends on cmdline_ensure_overlayroot / cmdline_remove_overlayroot from
# scripts/common/cmdline-manager.sh — the caller is responsible for sourcing
# cmdline-manager.sh first (both system-tune.sh and ro-mode.sh already do).
#
# Logging: prefers ok/warn/info from logging.sh when present; falls back to
# echo so the file is usable in the bare ro-mode CLI context.

if ! declare -F ok    >/dev/null 2>&1; then ok()   { echo "[OK]   $*";   }; fi
if ! declare -F warn  >/dev/null 2>&1; then warn() { echo "[WARN] $*" >&2; }; fi
if ! declare -F info  >/dev/null 2>&1; then info() { echo "[INFO] $*";   }; fi

# Write the cmdline.txt token and /etc/overlayroot.local.conf that activate
# overlayroot=tmpfs:recurse=0 on next boot. recurse=0 overlays only `/`,
# leaving NFS/USB fstab entries writable (avoids systemd ordering cycles).
persist_overlayroot_enabled() {
    if ! cmdline_ensure_overlayroot; then
        warn "overlayroot: failed to patch cmdline.txt (missing file or sed failed)"
        return 1
    fi

    if ! cat > /etc/overlayroot.local.conf <<'OREOF'
overlayroot="tmpfs:recurse=0"
overlayroot_cfgdisk="disabled"
OREOF
    then
        warn "overlayroot: failed to write /etc/overlayroot.local.conf"
        return 1
    fi

    ok "overlayroot persisted for next boot"
}

# Reverse of persist_overlayroot_enabled. `root_prefix` lets the caller point
# at a non-default rootfs (e.g. /media/root-ro when disabling from inside the
# active overlay — ro-mode.sh disable uses this to clear the lower layer too).
persist_overlayroot_disabled() {
    local root_prefix="${1:-}"

    if ! cmdline_remove_overlayroot; then
        warn "overlayroot: failed to unpatch cmdline.txt (missing file or sed failed)"
        return 1
    fi

    rm -f "${root_prefix}/etc/overlayroot.local.conf"

    if [[ -z "$root_prefix" ]]; then
        ok "overlayroot disabled for next boot"
    fi
}

# Install /etc/initramfs-tools/hooks/snapmulti-lzma so the next
# update-initramfs bundles liblzma.so.5 into the generated image. Required
# because kmod inside initramfs is linked against liblzma and needs it to
# decompress .ko.xz modules — without it, `modprobe -qb overlay` fails with
# "xz: can't load and resolve symbols" and init-bottom/overlayroot falls
# back to ext4 on next boot. Observed live on snapdigi 2026-06-01.
#
# Call sequence — see PR #592:
#   1. install_initramfs_lzma_hook  (this function — installs the hook)
#   2. raspi-config nonint do_overlayfs 0  (caller — internally runs
#      `update-initramfs -c -k all` which picks up the hook on its first
#      pass; this is the ONLY initramfs rebuild on this path)
#   3. persist_overlayroot_enabled  (caller — writes cmdline.txt + the
#      /etc/overlayroot.local.conf tmpfs marker)
#
# Reorder the call BEFORE raspi-config — running it after means the
# hook only matters on the SECOND rebuild round, which is exactly what
# `ensure_overlayroot_initramfs_ready` used to do and which broke under
# /boot/firmware ro at finalize time (PR #586 / #592 historical).
#
# The hook file itself lives in scripts/common/initramfs-hooks/snapmulti-lzma
# (shipped to both /opt/snapmulti/ and /opt/snapclient/ via prepare-sd.sh).
# Caller passes the source path; missing-source is a non-fatal warning so an
# operator running ro-mode on an older install doesn't get hard-blocked.
install_initramfs_lzma_hook() {
    local hook_src="${1:-}"
    local hook_dst="/etc/initramfs-tools/hooks/snapmulti-lzma"

    if [[ -z "$hook_src" ]]; then
        warn "overlayroot: no initramfs lzma hook source provided — skipping"
        return 0
    fi
    if [[ ! -f "$hook_src" ]]; then
        warn "overlayroot: initramfs lzma hook source missing at $hook_src"
        return 0
    fi

    install -m 755 "$hook_src" "$hook_dst" || {
        warn "overlayroot: failed to install $hook_dst"
        return 1
    }
    ok "overlayroot: initramfs lzma hook installed ($hook_dst)"
}

# ensure_overlayroot_initramfs_ready was dropped after PR #592. The function
# ran AFTER `raspi-config nonint do_overlayfs 0` to (1) refresh modules.dep
# per kver and (2) re-run `update-initramfs -u -k all` so the snapmulti-lzma
# hook (installed in the prior step) would actually land in /boot/firmware/
# initramfs*. This was load-bearing because the hook was installed AFTER
# raspi-config's own internal `update-initramfs -c -k all`. The second
# rebuild then collided with /boot/firmware being remounted ro by the
# read-only setup step, producing the cosmetic `cp: cannot create regular
# file '/boot/firmware/initramfs8': Read-only file system` warnings that
# claude-review surfaced as the overlay-may-not-activate failure mode.
#
# PR #592 reorders the install flow so install_initramfs_lzma_hook runs
# BEFORE raspi-config. raspi-config's own update-initramfs then picks up
# the hook on its first pass — liblzma lands in initramfs without a second
# rebuild round, the rc-out-of-subshell pipefail bug fixed in PR #586
# becomes moot, and /boot/firmware ro at finalize is harmless because the
# only update-initramfs call already happened while it was rw.
#
# Removed alongside this function: `_initramfs_target_for_kver`,
# `_initramfs_already_has_liblzma`. They existed only to drive the
# idempotency skip in this function and have no other callers.
