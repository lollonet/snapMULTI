#!/usr/bin/env bash
# Save diagnostic logs to boot partition (FAT32) so they survive
# overlayroot reboots. Runs periodically via systemd timer.
#
# Captures: dmesg (I2S/ALSA errors), docker container status,
# snapclient logs, and system state. Keeps last 3 snapshots
# to avoid filling the boot partition.
set -euo pipefail

# Detect boot partition
if [[ -d /boot/firmware ]]; then
    BOOT="/boot/firmware"
else
    BOOT="/boot"
fi

DIAG_DIR="$BOOT/diagnostics"
MAX_SNAPSHOTS=3
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT="$DIAG_DIR/$TIMESTAMP"

# Remount boot partition read-write
remount_rw() {
    mount -o remount,rw "$BOOT" 2>/dev/null || true
}

remount_ro() {
    mount -o remount,ro "$BOOT" 2>/dev/null || true
}

remount_rw
mkdir -p "$DIAG_DIR"

# Rotate: keep only the last MAX_SNAPSHOTS
# shellcheck disable=SC2012
existing=$(ls -1d "$DIAG_DIR"/[0-9]* 2>/dev/null | sort | head -n -"$MAX_SNAPSHOTS")
if [[ -n "$existing" ]]; then
    echo "$existing" | while IFS= read -r old; do
        rm -rf "$old"
    done
fi

mkdir -p "$SNAPSHOT"

# 1. Kernel audio/I2S errors
dmesg 2>/dev/null | grep -iE 'i2s|alsa|snd|hifiberry|underrun|xrun|pcm|wm8804|error' \
    > "$SNAPSHOT/dmesg-audio.log" 2>/dev/null || true

# 2. Docker container status
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}' \
    > "$SNAPSHOT/docker-ps.log" 2>/dev/null || true

# 3. Snapclient logs (last 100 lines)
docker logs snapclient --tail 100 \
    > "$SNAPSHOT/snapclient.log" 2>&1 || true

# 4. fb-display logs (last 50 lines)
docker logs fb-display --tail 50 \
    > "$SNAPSHOT/fb-display.log" 2>&1 || true

# 5. Audio visualizer logs (last 50 lines)
docker logs audio-visualizer --tail 50 \
    > "$SNAPSHOT/audio-visualizer.log" 2>&1 || true

# 6. Server containers (if running — "both" mode)
docker logs snapserver --tail 50 \
    > "$SNAPSHOT/snapserver.log" 2>&1 || true

# 7. ALSA state
if command -v aplay &>/dev/null; then
    aplay -l > "$SNAPSHOT/alsa-devices.log" 2>&1 || true
fi
cat /proc/asound/cards > "$SNAPSHOT/asound-cards.log" 2>/dev/null || true

# 8. System state
{
    echo "=== uptime ==="
    uptime
    echo "=== memory ==="
    free -h
    echo "=== disk ==="
    df -h / /boot/firmware 2>/dev/null || df -h / /boot
    echo "=== temperature ==="
    cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null \
        | awk '{printf "%.1f°C\n", $1/1000}' || echo "N/A"
    echo "=== overlayroot ==="
    if mount | grep -q 'overlayroot'; then
        echo "active"
    else
        echo "inactive"
    fi
} > "$SNAPSHOT/system.log" 2>/dev/null || true

# 9. Network state (brief)
{
    echo "=== interfaces ==="
    ip -brief addr 2>/dev/null
    echo "=== route ==="
    ip route show default 2>/dev/null
} > "$SNAPSHOT/network.log" 2>/dev/null || true

remount_ro

echo "Diagnostics saved to $SNAPSHOT"
