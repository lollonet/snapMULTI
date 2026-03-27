#!/usr/bin/env bash
# Boot-time system tuning for snapMULTI
#
# Re-applies runtime tuning at every boot. Required because:
# - cpufrequtils is not installed (nobody reads /etc/default/cpufrequtils)
# - udev rules don't re-trigger for already-present USB devices at boot
# - networkd-dispatcher is not installed (CAKE/DSCP hook never runs)
#
# Installed as systemd oneshot by deploy.sh. Idempotent and safe on
# both writable and overlayroot filesystems.

set -euo pipefail

# ── CPU governor: performance ─────────────────────────────────────
for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -f "$gov" ] && echo performance > "$gov" 2>/dev/null || true
done

# ── USB autosuspend: disabled ─────────────────────────────────────
[ -f /sys/module/usbcore/parameters/autosuspend ] && \
    echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null || true

# Also apply to any already-connected USB devices
for ctrl in /sys/bus/usb/devices/*/power/autosuspend; do
    [ -f "$ctrl" ] && echo -1 > "$ctrl" 2>/dev/null || true
done

# ── CAKE QoS + DSCP EF on Snapcast ports ─────────────────────────
modprobe sch_cake 2>/dev/null || true

iface=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')
if [ -n "$iface" ]; then
    tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true

    for port in 1704 1705; do
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || true
    done
fi
