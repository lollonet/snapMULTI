#!/usr/bin/env bash
# Monitor snapserver IP and (re)point snapclient at a healthy one.
#
# Boot mode:  ExecStartPre (no args) — picks initial server (or 127.0.0.1 in both mode).
# Watch mode: timer (--watch) — only acts when the current server is unreachable,
#             then prefers an mDNS-discovered server *different* from the dead one
#             so flapping back to the original is impossible.
#
# Failover semantics:
#   1. If current SNAPSERVER_HOST answers TCP on 1704 → no-op (cheap probe ~5ms).
#   2. If current is unreachable → mDNS scan; pick any IPv4 different from current.
#   3. Update .env and `docker compose up -d` so the new SNAPSERVER_HOST is
#      actually re-read into the container (compose restart does NOT re-read .env).
#
# "Both" mode: SNAPSERVER_HOST=127.0.0.1 (local server always wins).
set -euo pipefail

ENV_FILE="/opt/snapclient/.env"
LAST_IP_FILE="/run/snapclient-server-ip"
SNAPSERVER_PORT="${SNAPSERVER_PORT:-1704}"
WATCH_MODE=false
[[ "${1:-}" == "--watch" ]] && WATCH_MODE=true

# Single tagged logger so journalctl -u snapclient-discover.service is greppable
# without losing the boot-mode output to stderr. Lines: "[discover] <message>".
_log() { echo "[discover] $*"; }

# "Both" mode: local snapserver always wins. Detect via install.conf
# (single source of truth — set by prepare-sd.sh).
_is_both_mode() {
    local conf
    for conf in /boot/firmware/snapmulti/install.conf /boot/snapmulti/install.conf; do
        if grep -q '^INSTALL_TYPE=both' "$conf" 2>/dev/null; then return 0; fi
    done
    return 1
}

# Read current SNAPSERVER_HOST from .env.
_current_host() {
    grep "^SNAPSERVER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true
}

# TCP probe of host:port with 3s deadline. Bash /dev/tcp is enough — no
# need for nc/curl in the host. Returns 0 if reachable, 1 otherwise.
_tcp_alive() {
    local host="$1" port="$2"
    [[ -n "$host" && -n "$port" ]] || return 1
    timeout 3 bash -c ">/dev/tcp/$host/$port" 2>/dev/null
}

# Apply SNAPSERVER_HOST=$1 to .env and recreate snapclient so the new value
# takes effect. `docker compose restart` does NOT re-read .env — the container
# would come back up with the previous SNAPSERVER_HOST, so failover would
# silently fail. `up -d` re-evaluates compose+env and recreates only when the
# effective config differs.
_apply_server() {
    local new_ip="$1"
    local current
    current=$(_current_host)
    if [[ "$new_ip" == "$current" ]]; then
        return 1  # no change
    fi
    sed -i "s|^SNAPSERVER_HOST=.*|SNAPSERVER_HOST=$new_ip|" "$ENV_FILE" 2>/dev/null \
        || echo "SNAPSERVER_HOST=$new_ip" >> "$ENV_FILE"
    _log "server at $new_ip (was: ${current:-empty})"
    echo "$new_ip" > "$LAST_IP_FILE"
    if $WATCH_MODE; then
        cd /opt/snapclient && docker compose up -d 2>/dev/null || \
            _log "docker compose up -d failed, will retry next cycle"
    fi
    return 0
}

# Both-mode shortcut: pin to 127.0.0.1 and exit.
if _is_both_mode; then
    if _apply_server "127.0.0.1"; then
        _log "local snapserver pinned (both mode)"
    else
        _log "local snapserver, using 127.0.0.1"
    fi
    exit 0
fi

# Discover IPv4 advertisers on _snapcast._tcp via avahi-browse.
# Snapclient's built-in Avahi can pick IPv6 link-local addresses which
# don't work inside Docker containers (scope ID mismatch), so we run
# discovery on the host and pass the IPv4 result to the container.
_discover_all_ipv4() {
    if command -v avahi-browse &>/dev/null; then
        timeout 10 avahi-browse -rpt _snapcast._tcp 2>/dev/null \
            | awk -F';' '/^=/ && $3=="IPv4" {print $8}' \
            | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
            | sort -u
    fi
}

# Pick an IPv4 different from $1 if any. Falls back to the first IPv4 seen
# (covers the case where we're scanning during initial boot — current=empty).
_pick_failover_ipv4() {
    local current="$1"
    local all
    all=$(_discover_all_ipv4)
    if [[ -z "$all" ]]; then
        _log "mDNS returned no servers"
        return 1
    fi
    _log "mDNS results: $(echo "$all" | tr '\n' ',' | sed 's/,$//')"
    local ip
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" == "$current" ]] && continue
        _log "selecting $ip (different from current $current)"
        echo "$ip"
        return 0
    done <<< "$all"
    # No different IP — return whatever single IP was discovered (initial boot path).
    local first
    first=$(echo "$all" | head -1)
    _log "no alternative to $current — returning $first"
    echo "$first"
}

# Watch mode: short-circuit when the current server is healthy. This avoids
# the flapping seen when avahi happens to return a different server first
# during a routine timer fire — we should only switch when the current is
# actually broken.
if $WATCH_MODE; then
    current=$(_current_host)
    if [[ -n "$current" ]] && _tcp_alive "$current" "$SNAPSERVER_PORT"; then
        _log "$current:$SNAPSERVER_PORT alive, no scan"
        exit 0
    fi
    _log "$current unreachable, scanning mDNS for alternative..."
fi

# Boot mode (or watch mode with current dead): scan and pick.
current=$(_current_host)
host=$(_pick_failover_ipv4 "$current") || true
if [[ -n "$host" && "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if _apply_server "$host"; then
        $WATCH_MODE && _log "failover applied, snapclient recreated on $host"
    fi
else
    _log "no snapserver found via mDNS"
fi
