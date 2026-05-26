#!/usr/bin/env bash
# scripts/smoke/check_qos.sh — CAKE qdisc + DSCP EF marking (server only)
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
# `deploy.sh:setup_server_host` configures CAKE on the egress interface
# (root qdisc replace) and tags Snapcast streaming + RPC ports (1704/1705)
# with DSCP EF (0x2e) via iptables OUTPUT mangle. Persistence is via a
# NetworkManager dispatcher hook at /etc/NetworkManager/dispatcher.d/
# (Pi OS uses NM, not systemd-networkd; the pre-v0.7.8.11 hook lived in
# /etc/networkd-dispatcher/routable.d/ and silently never fired).
# If any of these are missing the audio stream still works in steady
# state, but under bufferbloat (someone else uploading large files on
# the LAN) audio synchronisation between rooms will drift. The user
# notices this as "click between rooms" or "one room lags".

# shellcheck disable=SC2154

check_qos() {
    [[ "$MODE" == "server" || "$MODE" == "both" ]] || return 0

    section "Network QoS"

    # 1. CAKE root qdisc on the default egress interface.
    local egress_iface
    egress_iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$egress_iface" ]]; then
        warn "No default route — CAKE qdisc check skipped"
        return 0
    fi

    if command -v tc >/dev/null 2>&1; then
        local qdisc_root
        qdisc_root=$(tc qdisc show dev "$egress_iface" 2>/dev/null | awk '/^qdisc / && /root/ {print $2; exit}')
        case "$qdisc_root" in
            cake)
                pass_check "CAKE qdisc active on $egress_iface (root)"
                ;;
            "")
                fail_check "No qdisc readable on $egress_iface — tc command output empty"
                ;;
            *)
                warn "Default qdisc on $egress_iface is '$qdisc_root', expected 'cake' (kernel may lack sch_cake module)"
                ;;
        esac
    else
        warn "tc not installed — CAKE qdisc check skipped"
    fi

    # 2. DSCP EF (0x2e) marking on Snapcast streaming + RPC. The actual
    # ports are configurable via .env (SNAPSERVER_RPC_PORT defaults to
    # 1705); read the .env to honour overrides, fall back to defaults.
    local server_env rpc_port
    server_env="${SERVER_DIR:-/opt/snapmulti}/.env"
    rpc_port=1705
    if [[ -f "$server_env" ]]; then
        local override
        override=$(grep '^SNAPSERVER_RPC_PORT=' "$server_env" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*$//' || true)
        [[ -n "$override" ]] && rpc_port="$override"
    fi

    if command -v iptables >/dev/null 2>&1; then
        local mangle_dump dscp_streaming dscp_rpc
        mangle_dump=$(iptables -t mangle -L OUTPUT -n 2>/dev/null || true)
        dscp_streaming=$(echo "$mangle_dump" | { grep -cE "tcp +spt:1704 +DSCP +set 0x2e" || true; })
        dscp_rpc=$(echo "$mangle_dump" | { grep -cE "tcp +spt:${rpc_port} +DSCP +set 0x2e" || true; })

        if [[ "$dscp_streaming" -ge 1 ]]; then
            pass_check "DSCP EF marking on Snapcast streaming port 1704"
        else
            fail_check "No DSCP EF mangle rule on tcp sport 1704 — bufferbloat will desync rooms"
        fi
        if [[ "$dscp_rpc" -ge 1 ]]; then
            pass_check "DSCP EF marking on Snapcast RPC port $rpc_port"
        else
            fail_check "No DSCP EF mangle rule on tcp sport $rpc_port"
        fi
    else
        warn "iptables not installed — DSCP marking check skipped"
    fi

    # 3. Persistence hook in NetworkManager dispatcher. Pi OS uses NM, not
    # systemd-networkd, so the hook lives under /etc/NetworkManager/
    # dispatcher.d/. Without it CAKE vanishes on every NM up/dhcp event.
    # We also check that the legacy networkd-dispatcher path is NOT present
    # (it was the original install location pre-v0.7.8.11 and never fired
    # on Pi OS — flag it so operators reflash to clean it up).
    if [[ -x /etc/NetworkManager/dispatcher.d/50-cake-qos ]]; then
        pass_check "CAKE persistence hook installed (/etc/NetworkManager/dispatcher.d/50-cake-qos)"
    else
        warn "CAKE persistence hook missing — qdisc will be lost on next iface restart"
    fi
    if [[ -e /etc/networkd-dispatcher/routable.d/50-cake-qos ]]; then
        warn "Legacy CAKE hook still present in networkd-dispatcher (never fires on NM hosts) — re-run deploy.sh or reflash to remove"
    fi
}
