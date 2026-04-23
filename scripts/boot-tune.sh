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

# ── WiFi auto-disable when Ethernet is connected ─────────────────
# Avoids dual mDNS announcements (clients might connect to the wrong IP).
# If Ethernet is unplugged or has no IP, WiFi stays active as fallback.
if command -v nmcli &>/dev/null; then
    eth_ip=$(ip -4 addr show eth0 2>/dev/null | awk '/inet /{print $2; exit}')
    if [[ -n "$eth_ip" ]]; then
        # Ethernet has an IP — safe to disable WiFi
        nmcli radio wifi off 2>/dev/null \
            && logger -t boot-tune "Ethernet $eth_ip — WiFi disabled (single mDNS)" \
            || logger -t boot-tune -p warning "Failed to disable WiFi"
    else
        # No Ethernet IP — ensure WiFi is on (recovery after cable removal)
        nmcli radio wifi on 2>/dev/null || true
    fi
fi

# ── Memory tuning: reduce swappiness for audio workloads ──────────
# Default 60 is too aggressive — audio buffers should stay in RAM
echo 10 > /proc/sys/vm/swappiness 2>/dev/null || true

# ── Hardware watchdog: auto-reboot on system hang ─────────────────
# Pi's bcm2835_wdt triggers reboot if systemd stops petting it
modprobe bcm2835_wdt 2>/dev/null || true

# ── Artwork cache cleanup: remove files older than 30 days ────────
find /opt/snapmulti/artwork -type f -mtime +30 -delete 2>/dev/null || true

# ── Overlayroot tmpfs sizing + monitoring ──────────────────────────
# Default tmpfs is 50% of RAM. On 2GB Pi that's 1GB — tight for Docker
# runtime state + logs. Size to 25% of RAM (Docker images are baked to
# the lower layer, so tmpfs only holds runtime writes).
if mount | grep -q ' on / type overlay'; then
    total_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null) || total_mb=0
    if [ "$total_mb" -gt 0 ] 2>/dev/null; then
        target_mb=$((total_mb / 4))
        # Floor at 256MB, cap at 2048MB
        [ "$target_mb" -lt 256 ] && target_mb=256
        [ "$target_mb" -gt 2048 ] && target_mb=2048
        # Find the tmpfs backing the overlay upper dir.
        # Raspberry Pi OS mounts it at /media/root-rw (not /overlay).
        # Extract upperdir from the overlay mount, then walk up to the tmpfs.
        tmpfs_mp=""
        if command -v findmnt &>/dev/null; then
            # upperdir=/media/root-rw/overlay → parent tmpfs at /media/root-rw
            _upper=$(findmnt -n -o OPTIONS / 2>/dev/null | sed -n 's/.*upperdir=\([^,]*\).*/\1/p') || true
            if [ -n "${_upper:-}" ]; then
                # The tmpfs is the parent of the upperdir (e.g. /media/root-rw)
                tmpfs_mp=$(findmnt -n -o TARGET -T "$(dirname "$_upper")" 2>/dev/null) || true
            fi
        fi
        [ -z "$tmpfs_mp" ] && tmpfs_mp=$(awk '$3 == "tmpfs" && $2 ~ /root-rw|overlay/ {print $2; exit}' /proc/mounts)
        [ -z "$tmpfs_mp" ] && tmpfs_mp="/media/root-rw"  # last resort default
        # Remount with explicit size (idempotent — safe to re-run)
        if mount -o "remount,size=${target_mb}M" "$tmpfs_mp" 2>/dev/null; then
            logger -t boot-tune "Overlayroot tmpfs sized to ${target_mb}MB at $tmpfs_mp (RAM: ${total_mb}MB)"
        else
            logger -t boot-tune -p warning "Failed to resize overlayroot tmpfs at $tmpfs_mp"
        fi
    fi

    # Monitor usage — warn early so user can act before system crashes
    usage=$(df / --output=pcent 2>/dev/null | tail -1 | tr -cd '0-9')
    if [ -n "$usage" ] 2>/dev/null; then
        if [ "$usage" -gt 90 ]; then
            logger -t boot-tune -p crit "CRITICAL: root tmpfs ${usage}% full — reboot imminent. Run: sudo ro-mode disable && sudo reboot"
        elif [ "$usage" -gt 70 ]; then
            logger -t boot-tune -p warning "WARNING: root tmpfs ${usage}% full. Run: sudo ro-mode disable && sudo reboot"
        fi
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
