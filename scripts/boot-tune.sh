#!/usr/bin/env bash
# Boot-time system tuning for snapMULTI
#
# Re-applies runtime tuning at every boot. Required because:
# - cpufrequtils is not installed (nobody reads /etc/default/cpufrequtils)
# - udev rules don't re-trigger for already-present USB devices at boot
# - networkd-dispatcher is not installed (CAKE/DSCP hook never runs)
#
# Installed as systemd oneshot by deploy.sh/setup.sh. Idempotent and safe on
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

# ── Memory tuning: reduce swappiness for audio workloads ──────────
# Default 60 is too aggressive — audio buffers should stay in RAM
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true

# ── Hardware watchdog: auto-reboot on system hang ─────────────────
# Pi's bcm2835_wdt triggers reboot if systemd stops petting it
modprobe bcm2835_wdt 2>/dev/null || true

# ── Artwork cache cleanup: remove files older than 30 days ────────
find /opt/snapmulti/artwork -type f -mtime +30 -delete 2>/dev/null || true

# ── CAKE QoS + DSCP EF on Snapcast ports ─────────────────────────
modprobe sch_cake 2>/dev/null || true

# Apply CAKE to all interfaces with a default route (eth + wlan failover).
# CAKE on an idle interface costs nothing; avoids re-applying on failover.
for iface in $(ip -o route show default 2>/dev/null | awk '{print $5}'); do
    tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true
done

# DSCP is interface-agnostic (OUTPUT chain by sport)
for port in 1704 1705; do
    iptables -t mangle -C OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
        || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
        || true
done
