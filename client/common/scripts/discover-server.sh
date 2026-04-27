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

# Single tagged logger. MUST write to stderr — functions like
# _pick_failover_ipv4 are invoked in command substitution (`host=$(...)`),
# which captures stdout. Logging on stdout would pollute the captured value
# with [discover] lines and break the IP regex match. systemd captures both
# streams into journald, so the [discover] tag is still grep-able via
# `journalctl -u snapclient-discover.service`.
_log() { echo "[discover] $*" >&2; }

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

# Run `docker compose up -d`, capture every output line into journald,
# return docker's rc. `|| compose_rc=$?` MUST be outside the pipe: bash's
# left-pipe runs in a subshell, so any assignment there does not propagate
# to the parent scope. With `set -o pipefail` (already active) the
# pipeline's exit code is the rightmost non-zero, so docker's failure
# makes the whole pipeline fail and the assignment captures it correctly.
_compose_up() {
    local reason="${1:-up -d}"
    _log "$reason — running up -d"
    local compose_rc=0
    if cd /opt/snapclient; then
        docker compose up -d 2>&1 | while IFS= read -r _line; do
            _log "compose: $_line"
        done || compose_rc=$?
        [[ "$compose_rc" -ne 0 ]] && _log "up -d failed (rc=$compose_rc), will retry next cycle"
    else
        _log "cd /opt/snapclient failed, cannot run up -d"
        compose_rc=1
    fi
    return "$compose_rc"
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
        _compose_up "applying new server $new_ip"
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

# Pick an IPv4 different from $1 if any. On initial boot $current is empty,
# so the loop's "$ip == $current" check is never true and the first discovered
# IP is selected by the loop itself. The fallback below is only reached when
# all discovered IPs equal the (presumed dead) current — i.e. Avahi cache
# stale entry is the only result. We return that single IP so the caller
# can log a "no failover available" situation rather than failing silently.
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
        _log "selecting $ip (different from current ${current:-<none>})"
        echo "$ip"
        return 0
    done <<< "$all"
    # All discovered IPs match the (dead) current — only stale cache entry
    # remains visible. Return it so caller's _apply_server short-circuits
    # with no-change and we log the situation.
    local first
    first=$(echo "$all" | head -1)
    _log "no alternative to ${current:-<none>} — only stale entry returned: $first"
    echo "$first"
}

# Reconcile container state with .env. Two failure modes covered:
#   1. Env drift — container.Config.Env SNAPSERVER_HOST != .env SNAPSERVER_HOST
#      (legacy `docker compose restart` bug, manual .env edit, out-of-band).
#      Trust .env, recreate via up -d.
#   2. Container exists but not running — e.g. previous up -d created the
#      container then failed at start (transient docker glitch). Without this
#      retry, the device is silently audio-dead while subsequent cycles see
#      no env drift and exit early.
# In both cases, trigger up -d and signal caller to skip remaining checks.
_reconcile_container_env() {
    local env_host container_host container_running
    env_host=$(_current_host)
    [[ -n "$env_host" ]] || return 0

    container_running=$(docker inspect snapclient \
        --format '{{.State.Running}}' 2>/dev/null)
    if [[ "$container_running" == "false" ]]; then
        _compose_up "container not running (state=$(docker inspect snapclient --format '{{.State.Status}}' 2>/dev/null))"
        return 1
    fi
    [[ "$container_running" == "true" ]] || return 0  # missing entirely — caller will discover

    container_host=$(docker inspect snapclient \
        --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | awk -F= '/^SNAPSERVER_HOST=/{print $2; exit}')
    [[ -n "$container_host" ]] || return 0
    if [[ "$env_host" != "$container_host" ]]; then
        _compose_up "drift: container=$container_host, .env=$env_host"
        return 1
    fi
    return 0
}

# Watch mode: short-circuit when the current server is healthy. This avoids
# the flapping seen when avahi happens to return a different server first
# during a routine timer fire — we should only switch when the current is
# actually broken.
if $WATCH_MODE; then
    if ! _reconcile_container_env; then
        exit 0  # reconcile already acted — let next cycle do the rest
    fi
    current=$(_current_host)
    if [[ -n "$current" ]] && _tcp_alive "$current" "$SNAPSERVER_PORT"; then
        _log "$current:$SNAPSERVER_PORT alive, no scan"
        exit 0
    fi
    _log "${current:-<none>} unreachable, scanning mDNS for alternative..."
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
