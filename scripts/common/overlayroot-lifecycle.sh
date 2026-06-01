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

# Rebuild initramfs for every installed kernel so the overlay module is
# reachable by modprobe at boot. Fixes the snapdigi-class failure where
# modules.dep in the cached initramfs is stale (~200 bytes) and
# init-bottom/overlayroot aborts with `[failure]: Unable to find a driver.
# searched: overlay overlayfs`.
#
# Why iterate over /lib/modules/* instead of `update-initramfs -u -k $(uname -r)`:
# during snapMULTI firstboot finalize, `uname -r` is the kernel the image
# booted with (e.g. 6.12.75) — but `apt full-upgrade` earlier in the same
# firstboot installs a newer kernel (e.g. 6.18.29) which becomes the BOOT
# target at next reboot. Rebuilding only the running kernel leaves the
# next-boot kernel's initramfs stale → overlayroot still fails on first
# reflash post-upgrade. Observed on snapdigi 2026-06-01: $(uname -r) was
# 6.12.75, fix landed on 6.12.75's initramfs, device rebooted into 6.18.29
# whose modules.dep was still the truncated 204-byte raspi-config artefact
# → ext4 fallback persisted.
#
# PR #317 lesson — see system-tune.sh history — a silent
# `update-initramfs -u -k all >/dev/null 2>&1` raced with raspi-config's own
# rebuild and aborted with "failed to determine device for /". Two guards
# baked in here:
#   1. Run AFTER raspi-config has settled (caller's responsibility).
#   2. Capture output to the unified install log so a future race is visible
#      (the original bug was the `>/dev/null 2>&1` that hid it).
# Install /etc/initramfs-tools/hooks/snapmulti-lzma so the next
# update-initramfs bundles liblzma.so.5 into the generated image. Required
# because kmod inside initramfs is linked against liblzma and needs it to
# decompress .ko.xz modules — without it, `modprobe -qb overlay` fails with
# "xz: can't load and resolve symbols" and init-bottom/overlayroot falls
# back to ext4 on next boot. Observed live on snapdigi 2026-06-01.
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

ensure_overlayroot_initramfs_ready() {
    local log_target="${UNIFIED_LOG:-/dev/null}"

    if ! command -v depmod >/dev/null 2>&1; then
        warn "overlayroot: depmod not found — skipping modules.dep refresh"
        return 0
    fi
    if ! command -v update-initramfs >/dev/null 2>&1; then
        warn "overlayroot: update-initramfs not found — skipping initramfs rebuild"
        return 0
    fi

    local kver_dir kver any_failed=0 any_attempted=0
    for kver_dir in /lib/modules/*; do
        [[ -d "$kver_dir" ]] || continue
        kver="${kver_dir##*/}"
        any_attempted=1

        info "overlayroot: refreshing modules.dep + initramfs for $kver"

        if ! depmod -a "$kver" >> "$log_target" 2>&1; then
            warn "overlayroot: depmod -a $kver failed (see $log_target)"
            any_failed=1
            continue
        fi

        if ! update-initramfs -u -k "$kver" >> "$log_target" 2>&1; then
            warn "overlayroot: update-initramfs -u -k $kver failed (see $log_target)"
            any_failed=1
            continue
        fi

        ok "overlayroot: initramfs rebuilt for $kver (overlay module reachable)"
    done

    if (( any_attempted == 0 )); then
        warn "overlayroot: no kernel directories found under /lib/modules — initramfs not refreshed"
        return 1
    fi

    return "$any_failed"
}
