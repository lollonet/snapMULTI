#!/usr/bin/env bash
# Install Docker CE and configure storage driver.
#
# Uses overlay2 (kernel native) by default. Only switches to
# fuse-overlayfs when overlayroot is actually active — kernel
# overlay2 cannot work on an overlayfs root filesystem.
#
# Decision is based on actual filesystem state (/proc/mounts),
# NOT the ENABLE_READONLY config flag (which expresses intent,
# not current state).
#
# Expects:
#   install-docker.sh sourced (provides install_docker_apt, tune_docker_daemon)
#
# Usage:
#   source scripts/common/setup-docker.sh
#   setup_docker

# shellcheck disable=SC2034
LOG_SOURCE="docker"

# Source unified logger
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] [docker] $*"; }
        log_warn()  { echo "[WARN] [docker] $*" >&2; }
        log_error() { echo "[ERROR] [docker] $*" >&2; }
    }
fi

# Source Docker CE installer if not already available
if ! declare -F install_docker_apt &>/dev/null; then
    local_dir="$(dirname "${BASH_SOURCE[0]}")"
    # shellcheck source=install-docker.sh
    if [[ -f "$local_dir/install-docker.sh" ]]; then
        source "$local_dir/install-docker.sh"
    elif [[ -n "${SNAP_BOOT:-}" && -f "$SNAP_BOOT/common/install-docker.sh" ]]; then
        source "$SNAP_BOOT/common/install-docker.sh"
    fi
fi

setup_docker() {
    # Prerequisite: system dependencies installed (curl, ca-certificates)

    if ! command -v docker &>/dev/null; then
        log_info "Setting up Docker repository..."
        install_docker_apt

        # Docker daemon config: live-restore
        tune_docker_daemon --live-restore

        if ! systemctl enable docker >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "Docker will not start automatically on boot"
        fi
        if ! systemctl start docker; then
            log_error "Docker daemon failed to start"
            return 1
        fi

        local first_user
        first_user=$(getent passwd 1000 | cut -d: -f1 || true)
        [[ -n "$first_user" ]] && usermod -aG docker "$first_user"

        log_info "Docker CE installed"
    else
        log_info "Docker already installed, skipping"
    fi

    # Verify Docker is running
    if ! docker info &>/dev/null; then
        log_error "Docker failed to start"
        return 1
    fi

    # Switch to fuse-overlayfs ONLY when overlayroot is actually active.
    # Kernel overlay2 cannot work on an overlayfs root, so fuse-overlayfs
    # is required. But on a normal writable ext4 root, overlay2 is faster
    # (no FUSE userspace overhead).
    #
    # Detection uses the same pattern as system-tune.sh:is_overlayroot()
    # and ro-mode.sh: "on / type overlay" in mount output.
    # NOT gated on ENABLE_READONLY — that flag expresses intent (will be
    # readonly after reboot), not current state.
    if ! mount 2>/dev/null | grep -q ' on / type overlay'; then
        log_info "Docker ready (overlay2, writable root filesystem)"
        return 0
    fi

    local current_driver
    current_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "none")
    if [[ "$current_driver" != "fuse-overlayfs" ]]; then
        log_info "Switching Docker to fuse-overlayfs..."

        # Wait for apt lock (Docker CE post-install hooks may hold it)
        if declare -F _wait_for_apt_lock &>/dev/null; then
            _wait_for_apt_lock
        fi
        # Install fuse-overlayfs package
        if ! apt-get install -y fuse-overlayfs >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_error "Failed to install fuse-overlayfs — required for read-only mode"
            return 1
        fi

        # Verify binary works BEFORE wiping Docker storage
        if ! fuse-overlayfs --version >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_error "fuse-overlayfs installed but binary is broken"
            log_error "Read-only mode cannot be configured — aborting storage switch"
            return 1
        fi

        log_info "Verified fuse-overlayfs binary"
        tune_docker_daemon --fuse-overlayfs
        systemctl stop docker
        rm -rf /var/lib/docker/*
        if ! systemctl start docker; then
            log_error "Docker failed to start after storage driver switch"
            return 1
        fi

        # Verify driver actually switched
        local new_driver
        new_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
        if [[ "$new_driver" == "fuse-overlayfs" ]]; then
            log_info "Docker storage driver: fuse-overlayfs"
        else
            log_warn "Docker started but driver is '$new_driver', not fuse-overlayfs"
            log_warn "Read-only mode may not work correctly"
        fi
    fi
}
