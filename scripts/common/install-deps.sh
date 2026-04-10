#!/usr/bin/env bash
# Install system dependencies for snapMULTI.
#
# Handles apt lock contention, package recovery, and conditional
# packages based on install type and music source.
#
# Expects from caller:
#   INSTALL_TYPE  — client|server|both
#   MUSIC_SOURCE  — nfs|smb|usb|streaming|manual
#   SKIP_UPGRADE  — true to skip apt upgrade (--dev mode)
#
# Usage:
#   source scripts/common/install-deps.sh
#   install_dependencies

# shellcheck disable=SC2034
LOG_SOURCE="deps"

# Source unified logger
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] [deps] $*"; }
        log_warn()  { echo "[WARN] [deps] $*" >&2; }
        log_error() { echo "[ERROR] [deps] $*" >&2; }
    }
fi

# Wait for background apt (unattended-upgrades, cloud-init)
_wait_for_apt_lock() {
    local _apt_wait
    for _apt_wait in $(seq 1 60); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || return 0
        sleep 5
    done
    log_warn "apt lock still held after 5 minutes — proceeding anyway"
}

# Install with automatic recovery on failure
_apt_install_with_recovery() {
    if apt-get install -y "$@" >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
        return 0
    fi

    log_warn "apt install failed for: $*"
    log_warn "Attempting dpkg/apt recovery and retry"

    # Recovery: these may fail individually, that's OK — the retry is the real test
    dpkg --configure -a >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || true
    apt-get -f install -y >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || true
    _wait_for_apt_lock

    if apt-get install -y "$@" >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
        return 0
    fi

    log_error "apt install still failing for: $*"
    return 1
}

install_dependencies() {
    # Prerequisite: network ready, NTP synced

    log_info "Waiting for apt lock..."
    _wait_for_apt_lock

    log_info "Refreshing package index..."
    if ! apt-get update >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
        log_warn "apt-get update failed — upgrade may be incomplete"
    fi

    # Upgrade packages (skip in dev mode for faster installs)
    if [[ "${SKIP_UPGRADE:-false}" == "true" ]]; then
        log_info "Skipping apt upgrade (SKIP_UPGRADE=true)"
    else
        log_info "Upgrading system packages..."
        if ! apt-get upgrade -y >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "apt upgrade failed (non-fatal, continuing)"
        fi
    fi

    # Build package list based on install type
    local pkgs=(curl ca-certificates)

    if ! command -v git &>/dev/null; then
        pkgs+=(git)
    fi

    if ! command -v avahi-daemon &>/dev/null; then
        pkgs+=(avahi-daemon)
    fi

    # Client needs I2C tools for HAT detection
    if [[ "${INSTALL_TYPE:-}" == "client" || "${INSTALL_TYPE:-}" == "both" ]]; then
        if ! command -v i2cdetect &>/dev/null; then
            pkgs+=(i2c-tools)
        fi
        if ! command -v modprobe &>/dev/null; then
            pkgs+=(kmod)
        fi
    fi

    # Music source packages
    if [[ "${MUSIC_SOURCE:-}" == "nfs" ]]; then
        pkgs+=(nfs-common)
    fi
    if [[ "${MUSIC_SOURCE:-}" == "smb" ]]; then
        pkgs+=(cifs-utils)
    fi

    log_info "Installing: ${pkgs[*]}"
    if ! _apt_install_with_recovery "${pkgs[@]}"; then
        return 1
    fi

    # Enable avahi
    if command -v avahi-daemon &>/dev/null; then
        if ! systemctl enable --now avahi-daemon >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "avahi-daemon failed to start — mDNS autodiscovery may not work"
        fi
    fi

    log_info "System dependencies installed"
}
