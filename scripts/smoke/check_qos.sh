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

# Source the env_get helper for the SNAPSERVER_RPC_PORT .env read below.
# Guarded so re-sourcing across smoke modules is idempotent.
if ! declare -F env_get >/dev/null 2>&1; then
    _CQ_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$_CQ_DIR/../common/env-reader.sh" ]]; then
        # shellcheck source=../common/env-reader.sh
        source "$_CQ_DIR/../common/env-reader.sh"
    fi
    unset _CQ_DIR
fi

# The DSCP rules are applied by the NetworkManager dispatcher hook only on
# the first NM up/dhcp event, which lands ~60-120s after boot. A smoke run
# inside that window sees them missing on a perfectly-configured device, so
# demote to INFO there (same boot-race tolerance as elsewhere). After the
# window a genuine absence is still a real FAIL.
_CQ_BOOT_GRACE_S=120

_cq_uptime_s() {
    local u
    u=$(cut -d. -f1 /proc/uptime 2>/dev/null) || u=""
    printf '%s' "${u:-0}"
}

# _cq_dscp_verdict <present 0|1+> <uptime_s> -> pass|boot|fail
_cq_dscp_verdict() {
    local present="$1" uptime_s="$2"
    if (( present >= 1 )); then printf 'pass'; return; fi
    if (( uptime_s < _CQ_BOOT_GRACE_S )); then printf 'boot'; return; fi
    printf 'fail'
}

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
                pass_check "Network egress queue (CAKE smart queueing): active on $egress_iface"
                ;;
            "")
                fail_check "Network egress queue: unreadable on $egress_iface (tc command produced no output)"
                ;;
            *)
                warn "Network egress queue on $egress_iface is '$qdisc_root', expected 'cake' (kernel may lack the sch_cake module — Snapcast still works but bufferbloat can desync rooms)"
                ;;
        esac
    else
        warn "Network egress queue check skipped (missing dep: iproute2 — install for traffic shaping inspection)"
    fi

    # 2. DSCP EF (0x2e) marking on Snapcast streaming + RPC. The actual
    # ports are configurable via .env (SNAPSERVER_RPC_PORT defaults to
    # 1705); read the .env to honour overrides, fall back to defaults.
    local server_env rpc_port
    server_env="${SERVER_DIR:-/opt/snapmulti}/.env"
    rpc_port=1705
    if [[ -f "$server_env" ]]; then
        local override
        # env_get strip=trim matches the pre-helper quote-and-trailing-
        # space strip behaviour. Inline fallback for stripped bundles.
        if declare -F env_get >/dev/null 2>&1; then
            override=$(env_get SNAPSERVER_RPC_PORT "$server_env" trim)
        else
            override=$(grep '^SNAPSERVER_RPC_PORT=' "$server_env" 2>/dev/null | cut -d= -f2- | tr -d '"' | sed 's/[[:space:]]*$//' || true)
        fi
        [[ -n "$override" ]] && rpc_port="$override"
    fi

    if command -v iptables >/dev/null 2>&1; then
        local mangle_dump dscp_streaming dscp_rpc
        mangle_dump=$(iptables -t mangle -L OUTPUT -n 2>/dev/null || true)
        dscp_streaming=$(echo "$mangle_dump" | { grep -cE "tcp +spt:1704 +DSCP +set 0x2e" || true; })
        dscp_rpc=$(echo "$mangle_dump" | { grep -cE "tcp +spt:${rpc_port} +DSCP +set 0x2e" || true; })

        local uptime_s
        uptime_s=$(_cq_uptime_s)
        case "$(_cq_dscp_verdict "$dscp_streaming" "$uptime_s")" in
            pass) pass_check "Snapcast streaming priority tag (DSCP EF): set on port 1704" ;;
            boot) info "Snapcast streaming priority tag: not applied yet (uptime ${uptime_s}s < ${_CQ_BOOT_GRACE_S}s — NM dispatcher applies it on the first up/dhcp event)" ;;
            fail) fail_check "Snapcast streaming priority tag: missing on port 1704 — bufferbloat will desync rooms when LAN is busy" ;;
        esac
        case "$(_cq_dscp_verdict "$dscp_rpc" "$uptime_s")" in
            pass) pass_check "Snapcast RPC priority tag (DSCP EF): set on port $rpc_port" ;;
            boot) info "Snapcast RPC priority tag: not applied yet (uptime ${uptime_s}s < ${_CQ_BOOT_GRACE_S}s — NM dispatcher applies it on the first up/dhcp event)" ;;
            fail) fail_check "Snapcast RPC priority tag: missing on port $rpc_port" ;;
        esac
    else
        warn "Priority tag (DSCP) check skipped (missing dep: iptables — install for QoS inspection)"
    fi

    # 3. Persistence hook in NetworkManager dispatcher. Pi OS uses NM, not
    # systemd-networkd, so the hook lives under /etc/NetworkManager/
    # dispatcher.d/. Without it CAKE vanishes on every NM up/dhcp event.
    # We also check that the legacy networkd-dispatcher path is NOT present
    # (it was the original install location pre-v0.7.8.11 and never fired
    # on Pi OS — flag it so operators re-run deploy.sh or reflash to remove it).
    if [[ -x /etc/NetworkManager/dispatcher.d/50-cake-qos ]]; then
        pass_check "Network egress queue persistence hook: installed (will re-apply on every NetworkManager event)"
    else
        warn "Network egress queue persistence hook: missing — CAKE will be lost on next network restart"
    fi
    if [[ -e /etc/networkd-dispatcher/routable.d/50-cake-qos ]]; then
        warn "Legacy egress-queue hook from older snapMULTI still present (no effect on Pi OS) — re-run deploy.sh or reflash to remove"
    fi
}
