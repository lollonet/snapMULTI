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
    [ -f "$gov" ] && echo performance > "$gov" 2>/dev/null \
        || logger -t boot-tune -p warning "Failed to set CPU governor on $gov"
done

# ── USB autosuspend: disabled ─────────────────────────────────────
if [ -f /sys/module/usbcore/parameters/autosuspend ]; then
    echo -1 > /sys/module/usbcore/parameters/autosuspend 2>/dev/null \
        || logger -t boot-tune -p warning "Failed to disable USB autosuspend"
fi

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

# ── Tmpfs usage warning (overlayroot writes to RAM) ────────────────
# Alert via syslog if tmpfs is >80% full — system will crash if it fills up
if mount | grep -q ' on / type overlay'; then
    usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -cd '0-9')
    if [ -n "$usage" ] && [ "$usage" -gt 80 ] 2>/dev/null; then
        logger -t boot-tune -p warning "WARNING: root tmpfs ${usage}% full — system may crash. Run: sudo ro-mode disable && sudo reboot"
    fi
fi

# ── CAKE QoS + DSCP EF on Snapcast ports (server only) ────────────
# CAKE prioritizes outbound audio packets from snapserver (ports 1704/1705).
# On clients, audio arrives inbound — DSCP OUTPUT marking does nothing,
# and CAKE can hang on Pi Zero 2 W when interfaces are DOWN.
# Skip entirely on client-only systems (no server compose file present).
if [[ -f /opt/snapmulti/docker-compose.yml ]]; then
    modprobe sch_cake 2>/dev/null || true

    for iface in $(ip -o route show default 2>/dev/null | awk '{print $5}'); do
        # Skip interfaces that are not UP — tc qdisc can hang in D-state
        if ! ip link show "$iface" 2>/dev/null | grep -q 'state UP'; then
            continue
        fi
        if echo "$iface" | grep -qE '^(wlan|wlp)'; then
            tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true
        else
            bw=$(cat "/sys/class/net/$iface/speed" 2>/dev/null) || true
            if [ -n "$bw" ] && [ "$bw" -gt 0 ] 2>/dev/null; then
                tc qdisc replace dev "$iface" root cake bandwidth "${bw}mbit" diffserv4 2>/dev/null || true
            else
                tc qdisc replace dev "$iface" root cake diffserv4 2>/dev/null || true
            fi
        fi
    done

    # DSCP is interface-agnostic (OUTPUT chain by sport)
    for port in 1704 1705; do
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || iptables -t mangle -A OUTPUT -p tcp --sport "$port" -j DSCP --set-dscp-class EF 2>/dev/null \
            || true
    done
fi

# ── Restart MPD if music directory wasn't ready at container start ──
# Docker bind-mounts capture directory state at start time. If NFS mounted
# after Docker, MPD sees empty /music. Wait for NFS, then restart.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mpd$'; then
    music_path=$(grep '^MUSIC_PATH=' /opt/snapmulti/.env 2>/dev/null | cut -d= -f2) || true
    if [ -n "$music_path" ] && grep -q "$music_path" /etc/fstab 2>/dev/null; then
        # Wait for network mount (up to 120s)
        wait=0
        while ! findmnt -n "$music_path" >/dev/null 2>&1 && [ "$wait" -lt 120 ]; do
            sleep 5
            wait=$((wait + 5))
        done
    fi
    if ! docker exec mpd find /music -maxdepth 3 -type f \( -name '*.mp3' -o -name '*.flac' \) 2>/dev/null | head -1 | grep -q .; then
        cd /opt/snapmulti && docker compose restart mpd 2>/dev/null || true
    fi
fi
