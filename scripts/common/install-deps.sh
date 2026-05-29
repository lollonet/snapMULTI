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
    local _apt_deadline=$(( SECONDS + 300 ))
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        if [[ $SECONDS -ge $_apt_deadline ]]; then
            log_warn "apt lock still held after 5 minutes — proceeding anyway"
            return 0
        fi
        sleep 5
    done
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

    # Prevent interactive debconf prompts during apt installs
    export DEBIAN_FRONTEND=noninteractive
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8

    log_info "Waiting for apt lock..."
    _wait_for_apt_lock

    # ADR-007: snapMULTI disables IPv6 at kernel cmdline level. apt
    # may still try AAAA lookups against debian.org/Docker mirrors and
    # time out (1-5 s per fetch) before falling back to IPv4. Force
    # IPv4 explicitly so first-boot installs aren't slowed by retries
    # against a deliberately-dead stack. Skipped silently when the
    # operator opted to keep IPv6 enabled.
    if [[ "$(cat /proc/cmdline 2>/dev/null)" == *ipv6.disable=1* ]]; then
        if [[ ! -f /etc/apt/apt.conf.d/99force-ipv4 ]]; then
            echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4 || \
                log_warn "Could not write /etc/apt/apt.conf.d/99force-ipv4 (apt may stall on AAAA lookups)"
        fi
    fi

    log_info "Refreshing package index..."
    if ! apt-get update >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
        log_warn "apt-get update failed — upgrade may be incomplete"
    fi

    # Upgrade packages (skip in dev mode for faster installs)
    if [[ "${SKIP_UPGRADE:-false}" == "true" ]]; then
        log_info "Skipping apt upgrade (SKIP_UPGRADE=true)"
    else
        log_info "Upgrading system packages..."
        # dist-upgrade (not upgrade) so kernel meta-packages (linux-image-rpi-*,
        # rpi-eeprom) get pulled even when the new version requires installing
        # NEW packages (the new kernel image deb) or removing OLD ones.
        # Plain `apt-get upgrade` keeps these back — observed on snapvideo
        # 2026-05-29: 6.12.75 → 6.18.29 + rpi-eeprom 28.15 → 28.24 all stuck.
        if ! apt-get dist-upgrade -y >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "apt dist-upgrade failed (non-fatal, continuing)"
        fi
    fi

    # INSTALL_ROLE controls role-specific packages (server/client/both)
    # Falls back to INSTALL_TYPE for backward compatibility with firstboot.sh
    local role="${INSTALL_ROLE:-${INSTALL_TYPE:-both}}"

    # Build package list — base packages always installed
    local pkgs=(curl ca-certificates python3 netcat-openbsd locales)

    if ! command -v git &>/dev/null; then
        pkgs+=(git)
    fi

    # avahi-daemon for mDNS, avahi-utils for avahi-browse (client discovery)
    # Always include avahi-utils — avahi-daemon may be preinstalled without it
    command -v avahi-daemon &>/dev/null || pkgs+=(avahi-daemon)
    command -v avahi-browse &>/dev/null || pkgs+=(avahi-utils)

    # iputils-arping: needed by device-smoke.sh for IP-conflict detection
    # (\`arping -D\` duplicate address probe). Catches the static-IP-squatter
    # scenario that surfaced in 2026-05-07 troubleshooting.
    command -v arping &>/dev/null || pkgs+=(iputils-arping)

    # jq: needed by device-smoke.sh \`--json\` mode (issue #177 status page).
    # Bash printf cannot safely escape arbitrary message text (unicode, embedded
    # quotes/newlines from journalctl/arping output) — jq handles this correctly.
    command -v jq &>/dev/null || pkgs+=(jq)

    # Monitoring tools (sar, iostat, mpstat, pidstat from sysstat;
    # iotop-c) — useful for ad-hoc troubleshooting on any role. Total
    # cost ~3.6 MB. The Pi Zero 2W is the device that most needs
    # `iostat -x 1` and `sar -r` during SD-pressure or RAM-pressure
    # debugging, and it was the only one without these tools installed.
    #
    # Sysstat's *binaries* go everywhere; its *cron collector* (writing
    # /var/log/sysstat/ every 10 min) stays server-only — see the
    # systemctl enable block lower in this file. This keeps overlay
    # tmpfs pressure low on Pi Zero / Pi 3 1 GB.
    #
    # NOTE: these go through a separate `--no-install-recommends` pass
    # below to minimise transitive packages. On Debian trixie neither
    # `sysstat` nor `iotop-c` Depends on pcp (Performance Co-Pilot),
    # so this install does not pull the ~50 MB multi-daemon stack.
    # `dstat` is intentionally NOT in this list: it Depends on
    # `python3-pcp` which would re-introduce the entire pcp tree.
    # `sar` from sysstat already covers dstat's realtime CPU/mem/disk
    # use case. Any orphan pcp from a prior install state is reaped
    # by the `apt-get autoremove --purge` step further below.
    local -a monitoring_pkgs=()
    command -v sar   &>/dev/null || monitoring_pkgs+=(sysstat)
    command -v iotop &>/dev/null || monitoring_pkgs+=(iotop-c)

    # Client: audio + HAT detection tools
    if [[ "$role" == "client" || "$role" == "both" ]]; then
        command -v aplay     &>/dev/null || pkgs+=(alsa-utils)
        command -v i2cdetect &>/dev/null || pkgs+=(i2c-tools)
        command -v modprobe  &>/dev/null || pkgs+=(kmod)
    fi

    # Music source packages
    if [[ "${MUSIC_SOURCE:-}" == "nfs" ]]; then
        pkgs+=(nfs-common)
    fi
    if [[ "${MUSIC_SOURCE:-}" == "smb" ]]; then
        pkgs+=(cifs-utils)
    fi

    # fuse-overlayfs needed when overlayroot will activate post-reboot
    # (kernel overlay2 cannot stack on overlayfs root → Docker needs FUSE driver).
    if [[ "${ENABLE_READONLY:-false}" == "true" ]]; then
        pkgs+=(fuse-overlayfs)
    fi

    log_info "Installing: ${pkgs[*]}"
    if ! _apt_install_with_recovery "${pkgs[@]}"; then
        return 1
    fi

    # Monitoring tools: separate pass with --no-install-recommends to
    # minimise transitive surface (see comment above re. pcp Depends).
    # Failure is not fatal — operator can still install them manually.
    if (( ${#monitoring_pkgs[@]} > 0 )); then
        log_info "Installing monitoring tools (no-recommends): ${monitoring_pkgs[*]}"
        if ! apt-get install -y --no-install-recommends "${monitoring_pkgs[@]}" >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "Monitoring tools install failed — continuing without sar/iotop"
        fi
    fi

    # Generate locales (lightweight alternative to locales-all)
    if command -v locale-gen &>/dev/null; then
        local wanted_locales=(
            it_IT.UTF-8
            en_US.UTF-8
            en_GB.UTF-8
            fr_FR.UTF-8
            de_DE.UTF-8
            es_ES.UTF-8
            pt_PT.UTF-8
        )
        local gen_file="/etc/locale.gen"
        local needs_gen=false
        for loc in "${wanted_locales[@]}"; do
            if ! locale -a 2>/dev/null | grep -qiF "${loc/UTF-8/utf8}"; then
                # Uncomment or append in locale.gen
                local loc_escaped="${loc//./\\.}"
                if [[ -f "$gen_file" ]]; then
                    sed -i "s/^# *${loc_escaped} /${loc} /" "$gen_file" 2>/dev/null || true
                fi
                if ! grep -qF "${loc}" "$gen_file" 2>/dev/null; then
                    echo "${loc} UTF-8" >> "$gen_file"
                fi
                needs_gen=true
            fi
        done
        if [[ "$needs_gen" == "true" ]]; then
            log_info "Generating locales: ${wanted_locales[*]}"
            locale-gen >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || log_warn "locale-gen failed"
        fi
    fi

    # Enable avahi + harden (pin hostname, restrict to physical interfaces)
    if command -v avahi-daemon &>/dev/null; then
        if ! systemctl enable --now avahi-daemon >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "avahi-daemon failed to start — mDNS autodiscovery may not work"
        fi
        # Harden if tune_avahi_daemon is available (sourced by caller from system-tune.sh)
        if declare -F tune_avahi_daemon &>/dev/null; then
            tune_avahi_daemon "$(hostname)"
        fi
    fi

    # Enable sysstat data collection (cron collector → /var/log/sysstat/
    # every 10 min). Server / both only — keeps overlay tmpfs pressure
    # low on Pi Zero 2W (already at 71 % on freshly-reflashed devices).
    # The `sar` / `iostat` / `mpstat` binaries are installed everywhere
    # for ad-hoc operator use; only the continuous writer is role-gated.
    if [[ "$role" == "server" || "$role" == "both" ]] && [[ -f /etc/default/sysstat ]]; then
        sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat
        systemctl enable --now sysstat >> "${UNIFIED_LOG:-/dev/null}" 2>&1 || true
    fi

    # Persist locale setting
    update-locale LANG=C.UTF-8 LC_ALL=C.UTF-8 2>/dev/null || true

    # Drop unused packages pulled in as Recommends earlier in the install
    # (mesa/wayland/GL libs from a previous desktop image, locales, etc.)
    # AND any pcp library set lingering from a base Pi OS image. Observed
    # live on a fresh pi-zero install: 19 packages flagged by apt as
    # "automatically installed and are no longer required" — all of them
    # mesa/wayland/X11 libraries irrelevant to snapMULTI's framebuffer-only
    # display path. Since neither `sysstat` nor `iotop-c` Depends on pcp
    # on Debian trixie, dropping `dstat` (PR #545) means new installs
    # never pull pcp at all — autoremove --purge is the safety net for
    # stale state, not the primary mechanism. `--purge` also removes
    # conffiles for a cleaner appliance state. Best-effort: a failure
    # here must NOT abort the install (we've already done the meaningful
    # work).
    log_info "Removing unused dependencies (apt autoremove --purge)..."
    if apt-get autoremove --purge -y >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
        log_info "apt autoremove --purge complete"
    else
        log_warn "apt autoremove --purge failed (non-fatal — install proceeds)"
    fi

    log_info "System dependencies installed"
}
