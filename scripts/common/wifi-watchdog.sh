#!/usr/bin/env bash
# WiFi connectivity watchdog for Raspberry Pi 4 BCM43455.
#
# Root cause this guards against:
#   brcmfmac firmware on the BCM43455 occasionally locks during scan/CSA
#   ("brcmf_run_escan: error (-52)" in dmesg). The chip reports UP at the
#   kernel level but the LAN becomes silently unreachable: snapserver
#   sees "Host is unreachable" / "Broken pipe" on every client, but
#   nothing in userland is broken — only the radio. Recovery requires
#   resetting the WiFi connection at the NetworkManager level, or in
#   the worst case a full reboot.
#
# Behaviour:
#   1. Detect WiFi-only operation (no Ethernet carrier). On Ethernet
#      hosts the script exits — wired networks don't have this failure
#      mode and the watchdog would be noise.
#   2. Ping the default gateway every WIFI_WATCHDOG_INTERVAL seconds.
#   3. After WIFI_WATCHDOG_SOFT_FAILURES consecutive ping failures,
#      issue an `nmcli connection down/up` on the WiFi connection.
#      Re-association usually wakes the firmware.
#   4. After WIFI_WATCHDOG_HARD_FAILURES consecutive failures (i.e. the
#      soft recovery also failed), reboot. Resetting the chip via cold
#      boot is the only deterministic fix when firmware is fully wedged.
#   5. Reset the failure counter on every successful ping.
#
# Configurable via /opt/snapmulti/.env (or /opt/snapclient/.env on
# client-only installs). Sensible defaults baked in.
set -euo pipefail

# ---------- Configuration ---------------------------------------------------

# Detect install dir. Both server (/opt/snapmulti) and client-only
# (/opt/snapclient) installs benefit from this watchdog.
INSTALL_DIR=""
for _candidate in /opt/snapmulti /opt/snapclient; do
    if [[ -d "$_candidate" ]]; then
        INSTALL_DIR="$_candidate"
        break
    fi
done

# Read configurable knobs from .env if present. Defaults are conservative:
# 60 s interval × 3 failures = ~3 min before soft recovery; × 10 = ~10 min
# before hard reboot. Big enough to ignore a transient AP rekey / channel
# switch, small enough to bound the LAN-down window.
INTERVAL="60"
SOFT_FAILURES="3"
HARD_FAILURES="10"
TARGET=""
WIFI_IFACE="wlan0"

log() { logger -t snapmulti-wifi-watchdog "$@"; }

# Canary: emit a log line immediately so a startup failure in the
# config-read code below is distinguishable in the journal from a
# silent failure earlier in the script.
log "boot: install_dir=${INSTALL_DIR:-none}"

if [[ -n "$INSTALL_DIR" && -f "$INSTALL_DIR/.env" ]]; then
    # Tolerate CRLF (Windows-edited .env) and optional quoting. The
    # `|| true` on the pipeline is mandatory under `set -o pipefail`:
    # grep returns 1 on no-match, which under pipefail propagates
    # through and would otherwise cause the assignment to fail.
    _read_env() {
        local val
        val=$(grep -E "^$1=" "$INSTALL_DIR/.env" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d $'\r' \
            || true)
        printf '%s' "$val"
    }
    # Integer-validate the numeric knobs. A non-integer override (e.g.
    # `WIFI_WATCHDOG_HARD_FAILURES=10s` from a typo or unsubstituted
    # template variable) silently resolves to 0 inside `(( ))`, which
    # makes `(( failures >= HARD_FAILURES ))` true on the first iteration
    # and fires hard_recovery → reboot. A non-numeric INTERVAL crashes
    # `sleep` under `set -e`. Both failure modes are far worse than
    # falling back to the built-in defaults.
    _v=$(_read_env "WIFI_WATCHDOG_INTERVAL")
    [[ -n "$_v" && "$_v" =~ ^[0-9]+$ ]] && INTERVAL="$_v"
    _v=$(_read_env "WIFI_WATCHDOG_SOFT_FAILURES")
    [[ -n "$_v" && "$_v" =~ ^[0-9]+$ ]] && SOFT_FAILURES="$_v"
    _v=$(_read_env "WIFI_WATCHDOG_HARD_FAILURES")
    [[ -n "$_v" && "$_v" =~ ^[0-9]+$ ]] && HARD_FAILURES="$_v"
    # TARGET / IFACE are strings, no integer constraint.
    _v=$(_read_env "WIFI_WATCHDOG_TARGET"); [[ -n "$_v" ]] && TARGET="$_v"
    _v=$(_read_env "WIFI_WATCHDOG_IFACE"); [[ -n "$_v" ]] && WIFI_IFACE="$_v"
fi

# ---------- Preflight: is this a WiFi host? --------------------------------

# Skip on wired-only hosts. "Wired" means eth0 has an IPv4 address (DHCP
# completed and the host is actually using Ethernet for connectivity).
# Carrier alone is too loose: a cable can be plugged in without any IP
# (carrier=1, no DHCP) while real traffic still goes via wlan0 — this is
# the actual state observed on snapvideo 2026-05-31 (eth0 carrier=1
# but `default via 192.168.63.1 dev wlan0` in the route table).
if ip -4 addr show eth0 2>/dev/null | grep -qE 'inet [0-9]'; then
    log "exit: eth0 has an IPv4 address — WiFi watchdog not needed on wired hosts"
    exit 0
fi

# WiFi interface must exist. Pi without WiFi (rare on snapMULTI hosts but
# possible on x86 manual deploys) → no-op.
if [[ ! -e "/sys/class/net/$WIFI_IFACE" ]]; then
    log "exit: $WIFI_IFACE not present — skipping watchdog"
    exit 0
fi

# ---------- Target detection ----------------------------------------------

resolve_target() {
    # Explicit override (from .env) wins. Otherwise default-route gateway.
    if [[ -n "$TARGET" ]]; then
        printf '%s' "$TARGET"
        return
    fi
    # `ip route show default` may emit several lines (multi-homed). Take
    # the first one that goes out of the WiFi interface; otherwise the
    # first default route at all.
    local gw
    gw=$(ip -4 route show default 2>/dev/null \
        | awk -v iface="$WIFI_IFACE" '$5==iface {print $3; exit}')
    if [[ -z "$gw" ]]; then
        gw=$(ip -4 route show default 2>/dev/null | awk 'NR==1 {print $3}')
    fi
    printf '%s' "$gw"
}

# ---------- NM connection lookup ------------------------------------------

resolve_wifi_connection() {
    # NetworkManager connection name bound to wlan0. There is normally
    # exactly one. `nmcli -t` gives a NUL-safe tabular output.
    nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
        | awk -F: -v iface="$WIFI_IFACE" '$2==iface {print $1; exit}'
}

soft_recovery() {
    local conn
    conn=$(resolve_wifi_connection)
    if [[ -z "$conn" ]]; then
        log "soft recovery: no active NM connection on $WIFI_IFACE — skipping nmcli cycle"
        return 1
    fi
    log "soft recovery: cycling NM connection '$conn' on $WIFI_IFACE"
    # Down/up is the standard way to force re-association. Errors are
    # logged but don't fail the watchdog — the next ping cycle will
    # decide whether the recovery worked.
    nmcli connection down "$conn" >/dev/null 2>&1 || log "soft recovery: nmcli down failed (ignored)"
    sleep 2
    nmcli connection up   "$conn" >/dev/null 2>&1 || log "soft recovery: nmcli up failed (ignored)"
    return 0
}

hard_recovery() {
    log "hard recovery: $HARD_FAILURES consecutive failures — rebooting (firmware likely wedged)"
    # Best-effort: save a marker on /boot/firmware so the next boot's
    # /status page can surface "previous boot ended in WiFi-watchdog
    # reboot" once that UI piece lands.
    if [[ -d /boot/firmware ]]; then
        date -Iseconds > /boot/firmware/snapmulti-wifi-watchdog-reboot.marker 2>/dev/null || true
    fi
    # Use systemctl reboot rather than `reboot` so systemd does an orderly
    # shutdown of containers first. The audio glitch on healthy clients
    # is unavoidable; preserving filesystem integrity matters more.
    systemctl reboot
    # Guard against systemctl returning without actually rebooting.
    sleep 30
    exit 0
}

# ---------- Main loop -----------------------------------------------------

failures=0
soft_recovery_attempted=false

log "starting (iface=$WIFI_IFACE, interval=${INTERVAL}s, soft=$SOFT_FAILURES, hard=$HARD_FAILURES)"

while :; do
    target=$(resolve_target)
    if [[ -z "$target" ]]; then
        # No default gateway yet — host is still coming up (no DHCP lease)
        # or has lost the route entirely. Treat as a failure: this is the
        # exact state we want to catch on a wedged radio.
        log "no default gateway — counting as failure ($failures)"
        failures=$((failures + 1))
    else
        # `ping -c 1 -W 5` returns 0 on a single response, non-zero on
        # timeout. We don't care about latency — a 5 s round-trip wedge
        # is already an outage by snapcast's standards.
        if ping -c 1 -W 5 -I "$WIFI_IFACE" "$target" >/dev/null 2>&1; then
            if (( failures > 0 )); then
                log "ping ok ($target) — clearing failure counter (was $failures)"
            fi
            failures=0
            soft_recovery_attempted=false
        else
            failures=$((failures + 1))
            log "ping fail #$failures ($target via $WIFI_IFACE)"
        fi
    fi

    if (( failures >= HARD_FAILURES )); then
        hard_recovery
        # hard_recovery does not return (systemctl reboot + exit).
    fi

    if (( failures >= SOFT_FAILURES )) && ! $soft_recovery_attempted; then
        soft_recovery_attempted=true
        # Bare call would exit the watchdog under `set -e` when
        # soft_recovery returns 1 (no active NM connection) — exactly
        # the failure scenario where we most need the watchdog alive.
        # The function logs its own failure paths; the watchdog must
        # keep counting until HARD_FAILURES regardless of recovery
        # outcome.
        soft_recovery || true
    fi

    sleep "$INTERVAL"
done
