#!/usr/bin/env bash
# Shared system tuning for snapMULTI (server + client)
#
# Provides idempotent functions for CPU governor, USB autosuspend,
# WiFi power save, and Docker daemon configuration. Sourced by both
# deploy.sh (server) and setup.sh (client) to avoid configuration drift.
#
# Requires: scripts/common/logging.sh (info, warn, ok, error)

# Guard: source logging.sh if not already loaded
if ! command -v info &>/dev/null; then
    TUNE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=logging.sh
    source "$TUNE_DIR/logging.sh"
fi

# ── Overlayroot detection ─────────────────────────────────────────
is_overlayroot() {
    mount 2>/dev/null | grep -q " on / type overlay"
}

# ── CPU governor ──────────────────────────────────────────────────
# Sets all CPUs to 'performance' and persists via cpufrequtils.
# Audio playback needs consistent CPU speed — ramp-up latency
# from ondemand/schedutil causes buffer underruns.
tune_cpu_governor() {
    [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] || return 0

    local set_count=0
    for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$gov" 2>/dev/null && (( set_count++ )) || true
    done

    if [[ -d /etc/default ]]; then
        if ! echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils 2>/dev/null; then
            is_overlayroot && warn "CPU governor: /etc write skipped (overlayroot)"
        fi
    fi

    if (( set_count > 0 )); then
        ok "CPU governor set to performance ($set_count CPUs)"
    else
        warn "CPU governor: no cpufreq paths writable, skipped"
    fi
}

# ── USB autosuspend ───────────────────────────────────────────────
# Disables USB autosuspend to prevent DAC/audio device sleep.
# Sets runtime parameter and creates persistent udev rule.
tune_usb_autosuspend() {
    [[ -f /sys/module/usbcore/parameters/autosuspend ]] || return 0

    if echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null; then
        if mkdir -p /etc/udev/rules.d 2>/dev/null; then
            if ! echo 'ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"' \
                > /etc/udev/rules.d/50-usb-no-autosuspend.rules 2>/dev/null; then
                is_overlayroot && warn "USB autosuspend: udev rule skipped (overlayroot)"
            fi
        fi
        ok "USB autosuspend disabled"
    else
        warn "USB autosuspend: not writable, skipped"
    fi
}

# ── WiFi power save ───────────────────────────────────────────────
# Disables WiFi power management to prevent connection drops.
# Uses NetworkManager dispatcher script for persistence — this
# survives overlayroot because it runs `iw` on every interface-up
# event rather than relying on a static config file.
tune_wifi_powersave() {
    # Disable immediately on any active WiFi interface
    local iface
    iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^wl/ && /state UP/ {print $2; exit}')
    if [[ -n "$iface" ]]; then
        if command -v iw &>/dev/null || [[ -x /usr/sbin/iw ]]; then
            iw dev "$iface" set power_save off 2>/dev/null \
                || /usr/sbin/iw dev "$iface" set power_save off 2>/dev/null \
                || true
        else
            warn "WiFi power save: iw not found, skipping immediate disable"
        fi
    fi

    # Persistent: NM dispatcher runs iw on every interface-up
    if [[ -d /etc/NetworkManager/dispatcher.d ]]; then
        local hook="/etc/NetworkManager/dispatcher.d/99-wifi-powersave-off"
        if [[ ! -f "$hook" ]]; then
            if cat > "$hook" <<'WEOF'
#!/bin/sh
[ "$2" = "up" ] && [ -n "$1" ] && /usr/sbin/iw dev "$1" set power_save off 2>/dev/null
WEOF
            then
                chmod +x "$hook"
                ok "WiFi power save disabled (persistent via NM dispatcher)"
            else
                is_overlayroot && warn "WiFi power save: dispatcher script skipped (overlayroot)"
            fi
        else
            ok "WiFi power save already configured"
        fi
    fi
}

# ── Docker daemon.json ────────────────────────────────────────────
# Merges settings into /etc/docker/daemon.json.
# Usage:
#   tune_docker_daemon                        # log rotation only
#   tune_docker_daemon --live-restore         # + live-restore
#   tune_docker_daemon --fuse-overlayfs       # + fuse-overlayfs storage driver
#   tune_docker_daemon --live-restore --fuse-overlayfs  # all modes (read-only FS support)
#
# Uses Python JSON merge to safely update existing configs.
# Returns 0 on success, 1 on failure.
tune_docker_daemon() {
    local want_live_restore=false
    local want_fuse_overlayfs=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --live-restore)     want_live_restore=true ;;
            --fuse-overlayfs)   want_fuse_overlayfs=true ;;
            *) warn "tune_docker_daemon: unknown option $1" ;;
        esac
        shift
    done

    mkdir -p /etc/docker 2>/dev/null || true

    # Build desired config as Python dict literal
    local py_updates='cfg.setdefault("log-driver", "json-file"); cfg.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})'
    [[ "$want_live_restore" == "true" ]] && py_updates="$py_updates; cfg['live-restore'] = True"
    if [[ "$want_fuse_overlayfs" == "true" ]]; then
        py_updates="$py_updates; cfg['storage-driver'] = 'fuse-overlayfs'"
    else
        # Remove storage-driver if present — reverts Docker to its default (overlay2)
        py_updates="$py_updates; cfg.pop('storage-driver', None)"
    fi

    if [[ -f /etc/docker/daemon.json ]]; then
        # Check if already configured
        local needs_update=false
        if [[ "$want_live_restore" == "true" ]] && ! grep -q '"live-restore"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        if [[ "$want_fuse_overlayfs" == "true" ]] && ! grep -q '"fuse-overlayfs"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        # Also update if fuse-overlayfs is present but not wanted (rollback)
        if [[ "$want_fuse_overlayfs" != "true" ]] && grep -q '"storage-driver"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi
        if ! grep -q '"log-driver"' /etc/docker/daemon.json 2>/dev/null; then
            needs_update=true
        fi

        if [[ "$needs_update" == "true" ]]; then
            if ! command -v python3 &>/dev/null; then
                warn "Docker daemon.json: python3 not found, cannot merge config"
                return 1
            fi
            info "Updating /etc/docker/daemon.json..."
            local tmp
            tmp=$(mktemp)
            if python3 -c "
import json
with open('/etc/docker/daemon.json') as f:
    cfg = json.load(f)
$py_updates
with open('$tmp', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
" 2>/dev/null && mv "$tmp" /etc/docker/daemon.json; then
                ok "Docker daemon.json updated"
            else
                rm -f "$tmp"
                warn "Docker daemon.json: merge failed"
                return 1
            fi
        else
            info "Docker daemon.json already configured"
        fi
    else
        # Create fresh
        info "Writing /etc/docker/daemon.json..."
        local json_content='{'
        [[ "$want_fuse_overlayfs" == "true" ]] && json_content="$json_content"$'\n  "storage-driver": "fuse-overlayfs",'
        [[ "$want_live_restore" == "true" ]] && json_content="$json_content"$'\n  "live-restore": true,'
        json_content="$json_content"'
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}'
        echo "$json_content" > /etc/docker/daemon.json
        ok "Docker daemon.json created"
    fi
}

# ── Avahi hardening ─────────────────────────────────────────────
# Pins mDNS hostname and restricts to physical network interfaces.
# Prevents Docker veth interfaces from polluting mDNS announcements.
tune_avahi_daemon() {
    local hostname="${1:-$(hostname)}"
    local conf="/etc/avahi/avahi-daemon.conf"
    [[ -f "$conf" ]] || return 0

    local avahi_changed=false

    # Pin hostname to prevent avahi from appending -2, -3, etc.
    if grep -q '^\[server\]' "$conf"; then
        if ! grep -q "^host-name=" "$conf"; then
            sed -i "/^\[server\]/a host-name=${hostname}" "$conf"
            avahi_changed=true
        fi
    fi

    # Restrict to physical interfaces (exclude Docker veth*)
    local ifaces=""
    local iface
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^(eth|wlan|en)/ {print $2}'); do
        [[ -n "$ifaces" ]] && ifaces="${ifaces},"
        ifaces="${ifaces}${iface}"
    done
    if [[ -n "$ifaces" ]]; then
        if ! grep -q "^allow-interfaces=${ifaces}$" "$conf"; then
            if grep -q '^allow-interfaces=' "$conf"; then
                sed -i "s/^allow-interfaces=.*/allow-interfaces=${ifaces}/" "$conf"
            elif grep -q '^\[server\]' "$conf"; then
                sed -i "/^\[server\]/a allow-interfaces=${ifaces}" "$conf"
            fi
            avahi_changed=true
        fi
    fi

    if [[ "$avahi_changed" == "true" ]]; then
        systemctl restart avahi-daemon 2>/dev/null || true
        ok "Avahi hardened: host-name=${hostname}, interfaces=${ifaces:-all}"
    else
        ok "Avahi already configured"
    fi
}

# ── Read-only filesystem (overlayroot) ──────────────────────────
# Configures overlayfs for SD card protection. Requires raspi-config.
# Call from firstboot.sh/deploy.sh/setup.sh when ENABLE_READONLY=true.
# Assumes fuse-overlayfs and Docker storage driver are already configured.
setup_readonly_fs() {
    local ro_mode_script="${1:-}"

    # Install ro-mode helper if available
    if [[ -n "$ro_mode_script" ]] && [[ -f "$ro_mode_script" ]]; then
        install -m 755 "$ro_mode_script" /usr/local/bin/ro-mode
        ok "ro-mode helper installed"
    fi

    # Persist SSH host keys across reboots
    if [[ -d /etc/ssh ]]; then
        mkdir -p /etc/ssh/keys_permanent
        cp -n /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub /etc/ssh/keys_permanent/ 2>/dev/null || true
        cat > /etc/systemd/system/ssh-keys-restore.service << 'SSHEOF'
[Unit]
Description=Restore SSH host keys from permanent storage
Before=ssh.service sshd.service
ConditionPathExists=/etc/ssh/keys_permanent

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'cp /etc/ssh/keys_permanent/ssh_host_* /etc/ssh/ 2>/dev/null && chmod 600 /etc/ssh/ssh_host_*_key'

[Install]
WantedBy=multi-user.target
SSHEOF
        systemctl daemon-reload
        systemctl enable ssh-keys-restore.service 2>/dev/null
        ok "SSH host keys persisted"
    fi

    # Enable overlayfs via raspi-config (takes effect after reboot)
    if command -v raspi-config &>/dev/null; then
        raspi-config nonint do_overlayfs 0
        ok "Read-only filesystem enabled (activates after reboot)"
    else
        warn "raspi-config not found — overlayroot not enabled"
    fi
}

# ── Boot tuning service ─────────────────────────────────────────
# Installs systemd oneshot that re-applies runtime tuning at every boot.
# Required because cpufrequtils/networkd-dispatcher aren't installed.
install_boot_tune_service() {
    local boot_tune_script="${1:-}"
    [[ -f "$boot_tune_script" ]] || return 0

    # Always overwrite — ensures fixes propagate even on overlayroot systems
    # where the lower layer may have a stale copy from a previous install.
    install -m 755 "$boot_tune_script" /usr/local/bin/snapmulti-boot-tune.sh

    # Enable hardware watchdog — auto-reboot on system hang (60s timeout)
    mkdir -p /etc/systemd/system.conf.d
    cat > /etc/systemd/system.conf.d/watchdog.conf <<'WEOF'
[Manager]
RuntimeWatchdogSec=60
WEOF
    cat > /etc/systemd/system/snapmulti-boot-tune.service <<'SEOF'
[Unit]
Description=snapMULTI boot-time system tuning
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snapmulti-boot-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SEOF
    systemctl daemon-reload
    systemctl enable snapmulti-boot-tune.service 2>/dev/null
    ok "Boot tuning service installed (CPU, USB, CAKE persist across reboots)"
}
