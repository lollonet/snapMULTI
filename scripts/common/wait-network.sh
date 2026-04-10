#!/usr/bin/env bash
# Wait for network connectivity + NTP time sync.
#
# Implements staged recovery for WiFi issues:
#   Stage 1 (30s): Kick WiFi connection via nmcli
#   Stage 2 (60s): Restart NetworkManager
#   Stage 3 (90s): Add fallback DNS (1.1.1.1)
#   Stage 4 (120s): Bounce network interfaces
#
# Also handles WiFi regulatory domain (5 GHz DFS channels)
# and NTP sync (required for apt signature verification).
#
# Usage:
#   source scripts/common/wait-network.sh
#   wait_for_network   # blocks until network + DNS ready, exits 1 on timeout

# shellcheck disable=SC2034
LOG_SOURCE="network"

# Source unified logger (may already be sourced by caller)
if ! declare -F log_info &>/dev/null; then
    # shellcheck source=unified-log.sh
    source "$(dirname "${BASH_SOURCE[0]}")/unified-log.sh" 2>/dev/null || {
        log_info()  { echo "[INFO] [network] $*"; }
        log_warn()  { echo "[WARN] [network] $*" >&2; }
        log_error() { echo "[ERROR] [network] $*" >&2; }
    }
fi

_log_net_state() {
    log_info "--- Network diagnostics ---"
    ip -brief link 2>/dev/null | while read -r line; do
        log_info "  Link: $line"
    done
    ip -brief addr 2>/dev/null | while read -r line; do
        log_info "  Addr: $line"
    done
    log_info "  Route: $(ip route show default 2>/dev/null || echo 'none')"
    if command -v nmcli &>/dev/null; then
        log_info "  NM: $(nmcli -t general status 2>/dev/null || echo 'unavailable')"
        nmcli -t -f NAME,TYPE,STATE connection show 2>/dev/null | while read -r line; do
            log_info "  Conn: $line"
        done
    fi
}

_try_recover_network() {
    local i=$1
    local mode=${2:-full}

    # Stage 1 (30s, 40s): Kick WiFi connection
    if [[ "$mode" != "dns-only" ]] && { (( i == 15 )) || (( i == 20 )); }; then
        if command -v nmcli &>/dev/null; then
            local wifi_conn
            wifi_conn=$(nmcli -t -f NAME,TYPE connection show 2>/dev/null \
                | awk -F: '/wifi/ {print $1; exit}')
            if [[ -n "$wifi_conn" ]]; then
                log_info "Activating WiFi: $wifi_conn"
                nmcli connection up "$wifi_conn" 2>/dev/null || true
            fi
        fi
    fi

    # Stage 2 (60s): Restart NetworkManager
    if [[ "$mode" != "dns-only" ]] && (( i == 30 )); then
        log_warn "Restarting NetworkManager..."
        _log_net_state
        if ! systemctl restart NetworkManager >> "${UNIFIED_LOG:-/dev/null}" 2>&1; then
            log_warn "NetworkManager restart failed"
        fi
        sleep 3
        if command -v nmcli &>/dev/null; then
            nmcli -t -f NAME,TYPE connection show 2>/dev/null | while IFS=: read -r name _type; do
                log_info "Activating: $name"
                nmcli connection up "$name" 2>/dev/null || true
            done
        fi
    fi

    # Stage 3 (90s): Add fallback DNS
    if (( i == 45 )); then
        if ping -c1 -W2 1.1.1.1 &>/dev/null && ! getent hosts deb.debian.org &>/dev/null; then
            log_warn "Adding fallback DNS (1.1.1.1)..."
            if [[ -f /etc/resolv.conf ]]; then
                sed -i '1i nameserver 1.1.1.1' /etc/resolv.conf 2>/dev/null || true
            else
                echo "nameserver 1.1.1.1" > /etc/resolv.conf
            fi
        fi
    fi

    # Stage 4 (120s): Bounce interfaces
    if [[ "$mode" != "dns-only" ]] && (( i == 60 )); then
        log_warn "Bouncing network interfaces..."
        local iface
        for iface in wlan0 eth0; do
            if ip link show "$iface" &>/dev/null; then
                ip link set "$iface" down 2>/dev/null || true
                sleep 1
                ip link set "$iface" up 2>/dev/null || true
            fi
        done
    fi
}

wait_for_network() {
    # Apply WiFi regulatory domain
    local reg_domain
    reg_domain=$(sed -n 's/.*cfg80211.ieee80211_regdom=\([A-Z]*\).*/\1/p' /proc/cmdline)
    if [[ "$reg_domain" =~ ^[A-Z]{2}$ ]] && command -v iw &>/dev/null; then
        iw reg set "$reg_domain" 2>/dev/null || true
        log_info "Set regulatory domain: $reg_domain"
    fi

    # Wait for connectivity + DNS
    local network_ready=false i gateway
    _log_net_state
    for i in $(seq 1 90); do
        gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
        if { [[ -n "$gateway" ]] && ping -c1 -W2 "$gateway" &>/dev/null; } || \
           ping -c1 -W2 1.1.1.1 &>/dev/null || \
           ping -c1 -W2 8.8.8.8 &>/dev/null; then
            if getent hosts deb.debian.org &>/dev/null; then
                log_info "Network ready"
                network_ready=true
                break
            fi
            _try_recover_network "$i" dns-only
            [[ $((i % 10)) -eq 0 ]] && log_warn "DNS not ready ($i/90)..."
        else
            _try_recover_network "$i"
            [[ $((i % 10)) -eq 0 ]] && log_warn "No connectivity ($i/90)..."
        fi
        sleep 2
    done

    if [[ "$network_ready" == "false" ]]; then
        log_error "Network not available after 3 minutes"
        _log_net_state
        log_error "Check WiFi credentials or Ethernet connection"
        return 1
    fi

    # Wait for NTP time sync
    log_info "Waiting for time sync..."
    timedatectl set-ntp true 2>/dev/null || true
    local _ntp_wait
    for _ntp_wait in $(seq 1 30); do
        if timedatectl show --property=NTPSynchronized --value 2>/dev/null | grep -q yes; then
            log_info "Clock synchronized"
            return 0
        fi
        sleep 2
    done
    log_warn "NTP sync not confirmed after 60s — apt signatures may fail"
}
