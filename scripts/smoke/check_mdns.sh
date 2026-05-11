#!/usr/bin/env bash
# scripts/smoke/check_mdns.sh — Snapcast mDNS publish + discovery
#
# Sourced by device-smoke.sh. Relies on helpers from the main script.
#
# What this catches:
#   - Snapcast server up but NOT publishing _snapcast._tcp on mDNS.
#     PR #290 fixed an Avahi socket bind-mount race that left the
#     server running and reachable by IP but invisible to clients
#     doing discovery. The container "healthcheck" still passes
#     (RPC port open), and snapclient on the SAME host even works
#     via discover-server.sh's localhost fallback — but other Pis
#     on the LAN never see the server. The fail mode is "music
#     plays on the server but not on remote players" and is
#     undebuggable without an mDNS-aware tool.
#   - Client-mode device has no servers on the LAN. Either there's
#     no server running, or the network blocks multicast (corporate
#     WiFi, some VLAN setups). Distinct from "server is up but
#     unreachable" but the user-visible symptom is identical, so
#     surfacing it explicitly helps diagnostics.
#
# Tool choice: avahi-browse with `-t -r` (terminate after one pass,
# resolve) and a 5s wall-clock cap via timeout — without the cap a
# slow/failing avahi-daemon hangs the whole smoke. Falls back to
# `dns-sd` if installed (rare on Pi).

# shellcheck disable=SC2154

_mdns_run_browse() {
    # 5s timeout, resolve, terminate. Returns 0 even on empty result
    # because that's a valid mDNS state (no peers), distinct from
    # "tool failed".
    if command -v avahi-browse >/dev/null 2>&1; then
        timeout 5 avahi-browse -t -r -p _snapcast._tcp 2>/dev/null || true
        return 0
    fi
    if command -v dns-sd >/dev/null 2>&1; then
        timeout 5 dns-sd -B _snapcast._tcp 2>/dev/null || true
        return 0
    fi
    return 1
}

check_mdns() {
    section "mDNS Publish"

    if ! _mdns_run_browse >/dev/null 2>&1; then
        warn "Neither avahi-browse nor dns-sd installed — mDNS check skipped"
        return
    fi

    local browse_output
    browse_output=$(_mdns_run_browse)

    # Avahi parseable lines start with one of:
    #   = ... → resolved record (interface, proto, name, type, domain, host, ipv, addr, port, txt)
    #   + ... → service seen but not resolved
    # We need at least one `=` row for _snapcast._tcp.
    local resolved
    resolved=$(grep -cE "^=" <<<"$browse_output" || true)
    resolved=${resolved:-0}

    # Extract the unique hostnames advertising _snapcast._tcp from
    # resolved rows. avahi-browse's parseable output has fields
    # separated by `;`; field 7 is the target host. Defensive parsing
    # in case the row format shifts (dns-sd fallback uses a different
    # layout) — accept anything that survives the awk.
    local advertised_hosts
    advertised_hosts=$(grep "^=" <<<"$browse_output" 2>/dev/null \
        | awk -F';' '{print $7}' \
        | sort -u | tr '\n' ' ' \
        || true)

    local our_hostname
    our_hostname=$(hostname 2>/dev/null || echo "")

    # Mode-aware verdict.
    case "$MODE" in
        server|both)
            if (( resolved == 0 )); then
                fail_check "_snapcast._tcp NOT advertised on mDNS — clients will not find this server (avahi socket race? port collision?)"
            elif [[ "$advertised_hosts" == *"$our_hostname"* ]] \
                || [[ "$advertised_hosts" == *"${our_hostname}.local"* ]]; then
                pass_check "_snapcast._tcp advertised by self ($our_hostname) — visible on LAN"
            else
                warn "_snapcast._tcp advertised (hosts: ${advertised_hosts:-unknown}) but not by self ($our_hostname) — name mismatch or self-resolve race"
            fi
            ;;
        client)
            if (( resolved == 0 )); then
                fail_check "_snapcast._tcp: no servers seen on LAN (no peer publishing, or multicast blocked)"
            else
                # Show how many servers we can see and which.
                local server_count
                server_count=$(grep "^=" <<<"$browse_output" \
                    | awk -F';' '{print $7}' \
                    | sort -u | wc -l | tr -cd '0-9')
                server_count=${server_count:-0}
                pass_check "_snapcast._tcp visible: $server_count server(s) on LAN (${advertised_hosts:-unknown})"
            fi
            ;;
        *)
            info "_snapcast._tcp resolved-rows count: $resolved (MODE=$MODE)"
            ;;
    esac
}
