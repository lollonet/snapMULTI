#!/usr/bin/env bash
# device-smoke.sh — mode-aware acceptance smoke check for real snapMULTI devices.
#
# Verifies:
#   - root mount / overlayroot state
#   - Docker driver + daemon.json storage-driver consistency
#   - required systemd units
#   - docker compose expected/running/healthy counts
#
# Usage:
#   sudo bash scripts/device-smoke.sh [--server|--client|--both]
#   sudo bash scripts/device-smoke.sh --server-dir /opt/snapmulti --client-dir /opt/snapclient

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/logging.sh
source "$SCRIPT_DIR/common/logging.sh"

MODE="auto"
SERVER_DIR=""
CLIENT_DIR=""
FAILURES=0

usage() {
    cat <<'EOF'
Usage: device-smoke.sh [--server|--client|--both] [--server-dir PATH] [--client-dir PATH]

Mode selection:
  --server      Expect only server install
  --client      Expect only client install
  --both        Expect both server and client installs
  default       Auto-detect from installed directories

Overrides:
  --server-dir  Override server install directory
  --client-dir  Override client install directory
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server|--client|--both)
            MODE="${1#--}"
            shift
            ;;
        --server-dir)
            SERVER_DIR="${2:-}"
            [[ -n "$SERVER_DIR" ]] || { error "--server-dir requires a path"; exit 2; }
            shift 2
            ;;
        --client-dir)
            CLIENT_DIR="${2:-}"
            [[ -n "$CLIENT_DIR" ]] || { error "--client-dir requires a path"; exit 2; }
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

detect_dir() {
    local explicit="$1"
    local role_service="$2"  # "snapserver" or "snapclient" — distinguishes role
    shift 2
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    local candidate
    for candidate in "$@"; do
        if [[ -d "$candidate" && -f "$candidate/docker-compose.yml" && -f "$candidate/.env" ]]; then
            # Validate the compose actually defines the role's service.
            # Without this guard, on a client-only install the relative
            # fallback (${SCRIPT_DIR}/..) resolves to /opt/snapclient and
            # matches as both server and client → wrong "both" autodetect.
            if grep -qE "^  ${role_service}:" "$candidate/docker-compose.yml" 2>/dev/null; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done
    return 1
}

SERVER_DIR="$(detect_dir "$SERVER_DIR" snapserver /opt/snapmulti "${SCRIPT_DIR}/.." || true)"
CLIENT_DIR="$(detect_dir "$CLIENT_DIR" snapclient /opt/snapclient "${SCRIPT_DIR}/../client/common" || true)"

if [[ "$MODE" == "auto" ]]; then
    if [[ -n "$SERVER_DIR" && -n "$CLIENT_DIR" ]]; then
        MODE="both"
    elif [[ -n "$SERVER_DIR" ]]; then
        MODE="server"
    elif [[ -n "$CLIENT_DIR" ]]; then
        MODE="client"
    else
        error "No snapMULTI installation found"
        exit 1
    fi
fi

require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || {
        error "Missing required command: $cmd"
        exit 1
    }
}

section() {
    printf '\n%s%s==> %s%s\n' "$CYAN" "$BOLD" "$*" "$NC" >&2
}

pass_check() {
    ok "$1"
}

fail_check() {
    error "$1"
    FAILURES=$((FAILURES + 1))
}

check_unit() {
    local unit="$1"
    if systemctl is-enabled "$unit" >/dev/null 2>&1 && systemctl is-active "$unit" >/dev/null 2>&1; then
        pass_check "systemd: $unit enabled and active"
    else
        local enabled="disabled"
        local active="inactive"
        systemctl is-enabled "$unit" >/dev/null 2>&1 && enabled="enabled" || true
        systemctl is-active "$unit" >/dev/null 2>&1 && active="active" || true
        fail_check "systemd: $unit ${enabled}/${active}"
    fi
}

compose_hc_total() {
    local compose_file="$1"
    docker compose -f "$compose_file" config --format json 2>/dev/null \
        | python3 -c "import sys,json; c=json.load(sys.stdin)['services']; print(sum(1 for s in c.values() if 'healthcheck' in s))" \
        2>/dev/null || echo 0
}

check_compose_stack() {
    local compose_file="$1"
    local stack_name="$2"
    local expected=()
    local running healthy hc_total svc

    while IFS= read -r svc; do
        [[ -n "$svc" ]] && expected+=("$svc")
    done < <(docker compose -f "$compose_file" config --services 2>/dev/null || true)
    if [[ ${#expected[@]} -eq 0 ]]; then
        fail_check "$stack_name: no services returned by docker compose config"
        return
    fi

    running=$(docker compose -f "$compose_file" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')
    hc_total=$(compose_hc_total "$compose_file")
    healthy=$(
        docker compose -f "$compose_file" ps -q 2>/dev/null \
            | xargs -r docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
            | grep -c '^healthy$' || true
    )

    if [[ "$running" -ge "${#expected[@]}" ]] && { [[ "$hc_total" -eq 0 ]] || [[ "$healthy" -ge "$hc_total" ]]; }; then
        pass_check "$stack_name: ${#expected[@]}/${#expected[@]} running, $healthy/$hc_total healthy"
    else
        fail_check "$stack_name: $running/${#expected[@]} running, $healthy/$hc_total healthy"
    fi

    for svc in "${expected[@]}"; do
        local cid status
        cid=$(docker compose -f "$compose_file" ps -q "$svc" 2>/dev/null | head -1)
        if [[ -n "$cid" ]]; then
            status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cid" 2>/dev/null || echo "unknown")
        else
            status="missing"
        fi
        info "  $stack_name/$svc -> $status"
    done
}

require_cmd docker
require_cmd python3
require_cmd systemctl
require_cmd mount

section "Host"
info "Mode: $MODE"
info "Hostname: $(hostname 2>/dev/null || echo unknown)"
info "Uptime: $(uptime -p 2>/dev/null || echo unknown)"

root_mount="$(mount | awk '$3 == "/" {print; exit}')"
overlay_active=false
if mount | grep -q ' on / type overlay'; then
    overlay_active=true
fi
info "Root mount: ${root_mount:-unknown}"
info "Overlayroot active: $overlay_active"

docker_driver="$(docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)"
daemon_storage="default"
if [[ -f /etc/docker/daemon.json ]]; then
    daemon_storage=$(
        python3 -c "import json; import sys; cfg=json.load(open('/etc/docker/daemon.json')); print(cfg.get('storage-driver','default'))" \
            2>/dev/null || echo unreadable
    )
fi
info "Docker driver: $docker_driver"
info "daemon.json storage-driver: $daemon_storage"

if [[ "$overlay_active" == true ]]; then
    [[ "$docker_driver" == "fuse-overlayfs" ]] \
        && pass_check "overlayroot active -> Docker driver is fuse-overlayfs" \
        || fail_check "overlayroot active but Docker driver is $docker_driver"
else
    [[ "$docker_driver" != "fuse-overlayfs" ]] \
        && pass_check "writable root -> Docker driver is not fuse-overlayfs" \
        || fail_check "writable root but Docker driver is fuse-overlayfs"
fi

section "Systemd"
case "$MODE" in
    server)
        [[ -n "$SERVER_DIR" ]] || fail_check "server install directory missing"
        check_unit "snapmulti-server.service"
        ;;
    client)
        [[ -n "$CLIENT_DIR" ]] || fail_check "client install directory missing"
        check_unit "snapclient.service"
        check_unit "snapclient-discover.timer"
        ;;
    both)
        [[ -n "$SERVER_DIR" ]] || fail_check "server install directory missing"
        [[ -n "$CLIENT_DIR" ]] || fail_check "client install directory missing"
        check_unit "snapmulti-server.service"
        check_unit "snapclient.service"
        check_unit "snapclient-discover.timer"
        ;;
esac

section "Compose"
case "$MODE" in
    server)
        [[ -n "$SERVER_DIR" ]] && check_compose_stack "$SERVER_DIR/docker-compose.yml" "server"
        ;;
    client)
        [[ -n "$CLIENT_DIR" ]] && check_compose_stack "$CLIENT_DIR/docker-compose.yml" "client"
        ;;
    both)
        [[ -n "$SERVER_DIR" ]] && check_compose_stack "$SERVER_DIR/docker-compose.yml" "server"
        [[ -n "$CLIENT_DIR" ]] && check_compose_stack "$CLIENT_DIR/docker-compose.yml" "client"
        ;;
esac

section "Network"
# DNS resolution must work — catches the NM dns-rc empty-resolv.conf
# regression (see CHANGELOG entry for PR #287). 30s budget covers slow
# DHCP + DNS warmup on Pi Zero 2W. Two neutral targets tried in sequence
# so a single-vendor outage (or a network that blocks one of them) does
# not produce a false-negative for the smoke test.
_DNS_TARGETS=("cloudflare.com" "dns.google")
_dns_ok=false
for _dns_attempt in 1 2 3; do
    for _target in "${_DNS_TARGETS[@]}"; do
        if getent hosts "$_target" >/dev/null 2>&1; then
            _dns_ok=true
            _dns_target_ok="$_target"
            break 2
        fi
    done
    sleep 10
done
if [[ "$_dns_ok" == "true" ]]; then
    pass_check "DNS resolution working (${_dns_target_ok})"
else
    fail_check "DNS resolution failing on all targets (${_DNS_TARGETS[*]}) — check /etc/resolv.conf and 'nmcli general status'"
fi

# Time sync — Snapcast TimeProvider is NTP-immune, but log timestamps and
# metadata-service rely on a sane wall clock. Pi Zero 2W's RTC sits at
# epoch 0 until NTP completes, which can mask boot-time bugs in any
# component that uses absolute timestamps.
_ntp_synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
case "$_ntp_synced" in
    yes)
        pass_check "Time synchronised (NTP)"
        ;;
    no)
        fail_check "Time NOT synchronised — \`timedatectl status\` for details, often resolves itself within 60s of boot"
        ;;
    *)
        warn "Time sync state unknown (timedatectl returned '$_ntp_synced')"
        ;;
esac

# Hostname mDNS round-trip — the host's own hostname.local must resolve
# to the host's own IP via avahi. Catches DHCP/mDNS desync (e.g. IP
# changed via DHCP renew but avahi cache stale, or hostname mismatch).
if command -v avahi-resolve >/dev/null 2>&1; then
    _own_host="$(hostname).local"
    _own_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    _resolved=$(timeout 5 avahi-resolve -4 -n "$_own_host" 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$_resolved" ]] && [[ "$_resolved" == "$_own_ip" ]]; then
        pass_check "mDNS hostname round-trip ($_own_host -> $_resolved)"
    elif [[ -n "$_resolved" ]]; then
        fail_check "mDNS hostname mismatch ($_own_host -> $_resolved, expected $_own_ip) — restart avahi-daemon"
    else
        fail_check "mDNS hostname does NOT resolve ($_own_host) — avahi-daemon publishing broken"
    fi
else
    warn "avahi-resolve not installed — skipping mDNS hostname check"
fi

# IP conflict detection — duplicate-address probe. \`arping -D\` returns
# exit 0 if NO replies (good: nobody else claims our IP) and exit 1 if
# replies received (bad: another host on the LAN has our IP, will cause
# intermittent packet loss like the F8:17:2D historic .95 case from
# 2026-05-07). Requires \`iputils-arping\` (already installed by
# install-deps.sh on snapMULTI 0.6.4+).
if command -v arping >/dev/null 2>&1; then
    _own_iface=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    _own_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [[ -n "$_own_iface" ]] && [[ -n "$_own_ip" ]]; then
        # \`arping -D\` exits 0 if no replies (no conflict) and 1 if replies
        # received (conflict). It also fails with 1+stderr when missing
        # CAP_NET_RAW. We try \`sudo -n\` first; on permission failure we
        # fall back to unprivileged arping AND distinguish the permission
        # case from a real conflict by inspecting stderr — a permission
        # gap should NOT hard-fail the smoke gate (that turns a config
        # gap into a hard fail on every install without passwordless sudo).
        _arping_run() {
            "$@" -D -c 3 -w 5 -I "$_own_iface" "$_own_ip" 2>&1
        }
        _arping_out=$(_arping_run sudo -n arping)
        _arping_rc=$?
        if [[ $_arping_rc -ne 0 ]]; then
            # sudo -n likely lacked NOPASSWD or no sudo at all — retry plain
            _arping_out=$(_arping_run arping)
            _arping_rc=$?
        fi
        if [[ $_arping_rc -eq 0 ]]; then
            pass_check "No IP conflict on $_own_ip ($_own_iface)"
        elif echo "$_arping_out" | grep -qiE 'permission|not permitted|capabilities|password is required'; then
            warn "arping needs CAP_NET_RAW / sudo — IP-conflict check skipped (run as root, or 'setcap cap_net_raw+ep \$(command -v arping)')"
        else
            fail_check "Possible IP conflict on $_own_ip — another host replied to our ARP probe"
        fi
        unset -f _arping_run
    else
        warn "Could not determine own IP/iface for conflict check"
    fi
else
    warn "arping not installed — skipping IP conflict check (apt-get install iputils-arping)"
fi

# Snapcast mDNS publishing (server-only) — \`_snapcast._tcp\` SRV+TXT must
# be answered, not just PTR. Strict clients (Python zeroconf, macOS
# dns-sd -L) reject PTR-only and report "no servers found". This was
# fixed in PR #290 (avahi socket bind-mount) but the upstream Snapcast
# 0.35.0 bug still drops the registration if avahi-daemon restarts —
# PR #300 (PartOf=avahi-daemon.service) is our workaround. avahi-browse
# itself is a strict client: a "+" line means PTR-only, "=" means
# fully resolved with SRV+TXT.
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
    if command -v avahi-browse >/dev/null 2>&1; then
        _resolved_count=$(timeout 8 avahi-browse -rpt _snapcast._tcp 2>/dev/null \
            | grep -c '^=' || true)
        if [[ "$_resolved_count" -ge 1 ]]; then
            pass_check "Snapcast mDNS fully resolves ($_resolved_count entry/entries with SRV+TXT)"
        else
            _ptr_count=$(timeout 5 avahi-browse -pt _snapcast._tcp 2>/dev/null \
                | grep -c '^+' || true)
            if [[ "$_ptr_count" -ge 1 ]]; then
                fail_check "Snapcast mDNS publishes PTR but NO SRV+TXT — strict clients fail. Try \`docker compose restart snapserver\`"
            else
                fail_check "Snapcast mDNS not visible at all — check snapserver container + avahi-daemon"
            fi
        fi
    else
        warn "avahi-browse not installed — skipping Snapcast mDNS check"
    fi
fi

# Throttle / undervoltage — \`vcgencmd get_throttled\` reports a bitmask:
#   bit 0 (0x1)     — under-voltage detected NOW
#   bit 1 (0x2)     — arm freq capped NOW
#   bit 2 (0x4)     — currently throttled
#   bit 3 (0x8)     — soft temp limit active NOW
#   bits 16-19      — same conditions, occurred since boot (sticky)
# Bits 0/2 = currently in trouble → fail. Bits 16-19 = warn (history of
# trouble, often a marginal PSU/cable). vcgencmd only on Raspberry Pi.
if command -v vcgencmd >/dev/null 2>&1; then
    _throttled_raw=$(vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//')
    # Guard: empty / non-hex output (vcgencmd present but unable to read,
    # e.g. user not in `video` group, firmware mailbox hiccup) must NOT be
    # silently treated as 0x0 → "healthy". Empty $((…)) evaluates to 0 in
    # bash arithmetic, which would invert the diagnostic.
    if [[ -z "$_throttled_raw" ]] || [[ ! "$_throttled_raw" =~ ^0x[0-9a-fA-F]+$ ]]; then
        warn "vcgencmd returned no usable data ('$_throttled_raw') — throttle check skipped (permission issue? try \`sudo usermod -aG video \$USER\` and re-login)"
    else
        _throttled_dec=$((_throttled_raw))
        _now_bits=$(( _throttled_dec & 0xF ))
        _hist_bits=$(( _throttled_dec & 0xF0000 ))
        if (( _now_bits != 0 )); then
            fail_check "Hardware throttling RIGHT NOW (throttled=$_throttled_raw) — under-voltage / thermal / PSU issue"
        elif (( _hist_bits != 0 )); then
            # Historical only — not a hard fail but flag loudly
            _msg="hardware throttling occurred since boot (throttled=$_throttled_raw)"
            (( _hist_bits & 0x10000 )) && _msg="$_msg [under-voltage]"
            (( _hist_bits & 0x20000 )) && _msg="$_msg [arm-freq-capped]"
            (( _hist_bits & 0x40000 )) && _msg="$_msg [throttling]"
            (( _hist_bits & 0x80000 )) && _msg="$_msg [soft-temp-limit]"
            warn "$_msg — likely PSU/cable issue (5V/3A required)"
        else
            pass_check "Hardware healthy (throttled=0x0, no under-voltage / throttling)"
        fi
    fi
else
    info "vcgencmd not available — skipping throttle check (non-Raspberry-Pi host?)"
fi

section "Recent Errors"
_error_count=0
for log_src in "snapmulti-server" "snapclient" "docker"; do
    local_errors=$(journalctl -u "${log_src}.service" --since "10 min ago" --priority err --no-pager -q 2>/dev/null | wc -l | tr -d ' ') || local_errors=0
    if [[ "$local_errors" -gt 0 ]]; then
        warn "$log_src: $local_errors error(s) in last 10 min"
        journalctl -u "${log_src}.service" --since "10 min ago" --priority err --no-pager -q 2>/dev/null | tail -3 | while IFS= read -r line; do
            info "  $line"
        done
        _error_count=$((_error_count + local_errors))
    fi
done
if [[ "$_error_count" -eq 0 ]]; then
    pass_check "No errors in systemd logs (last 10 min)"
else
    warn "$_error_count total error(s) in recent logs (non-blocking)"
fi

echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    ok "Smoke check passed"
    exit 0
fi

error "Smoke check failed with $FAILURES issue(s)"
exit 1
