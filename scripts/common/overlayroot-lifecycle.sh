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

# Rebuild initramfs for the running kernel so the overlay module is reachable
# by modprobe at boot. Fixes the snapdigi-class failure where modules.dep in
# the cached initramfs is stale (only ~200 bytes) and init-bottom/overlayroot
# aborts with `[failure]: Unable to find a driver. searched: overlay overlayfs`.
#
# PR #317 lesson — see system-tune.sh history — this used to be a silent
# `update-initramfs -u -k all >/dev/null 2>&1`; the rebuild raced with
# raspi-config's own rebuild and aborted with "failed to determine device for
# /". Two fixes baked in here:
#   1. Run AFTER raspi-config has settled (caller's responsibility).
#   2. Capture output to the unified install log so a future race is visible,
#      and use `update-initramfs -u -k $(uname -r)` (running kernel only)
#      instead of `-k all` to skip the cross-kernel paths.
ensure_overlayroot_initramfs_ready() {
    local kver
    kver="$(uname -r)"

    local log_target="${UNIFIED_LOG:-/dev/null}"

    if ! command -v depmod >/dev/null 2>&1; then
        warn "overlayroot: depmod not found — skipping modules.dep refresh"
        return 0
    fi
    if ! command -v update-initramfs >/dev/null 2>&1; then
        warn "overlayroot: update-initramfs not found — skipping initramfs rebuild"
        return 0
    fi

    info "overlayroot: refreshing modules.dep + initramfs for $kver"

    if ! depmod -a "$kver" >> "$log_target" 2>&1; then
        warn "overlayroot: depmod -a $kver failed (see $log_target)"
        return 1
    fi

    if ! update-initramfs -u -k "$kver" >> "$log_target" 2>&1; then
        warn "overlayroot: update-initramfs -u -k $kver failed (see $log_target)"
        return 1
    fi

    ok "overlayroot: initramfs rebuilt for $kver (overlay module reachable)"
}
