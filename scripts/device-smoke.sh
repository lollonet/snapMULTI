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

# Modular check files — sourced after the helper functions are defined
# (see "Source modular checks" block further down). Each module exposes
# a single `check_<name>` function and reuses the helpers from this
# parent script (section, pass_check, fail_check, warn, info). Adding a
# new check is a matter of dropping a `scripts/smoke/check_*.sh` file
# and one source + invocation line below.
SMOKE_MODULES_DIR="$SCRIPT_DIR/smoke"

MODE="auto"
SERVER_DIR=""
CLIENT_DIR=""
FAILURES=0
WARNINGS=0
JSON_OUTPUT=false
NO_FAIL_ON_WARN=false
TONE=false

# JSON-mode buffers — populated by helpers when JSON_OUTPUT=true.
# Each is a JSON-encoded object string ready for jq to assemble.
declare -a JSON_RECORDS=()
JSON_CURRENT_SECTION="general"
SCHEMA_VERSION=1
RUN_STARTED_AT=""

usage() {
    cat <<'EOF'
Usage: device-smoke.sh [OPTIONS]

Mode selection:
  --server          Expect only server install
  --client          Expect only client install
  --both            Expect both server and client installs
  default           Auto-detect from installed directories

Overrides:
  --server-dir PATH Override server install directory
  --client-dir PATH Override client install directory

Output:
  --json            Emit a single JSON object on stdout instead of human
                    text on stderr. Suitable for the snapmulti-status
                    timer / metadata-service /status endpoint.
  --no-fail-on-warn Exit 0 when only warnings (not failures) occurred.
                    Default behaviour is exit 0 when 0 fails (warnings
                    don't fail anyway), so this is mainly for callers
                    that want a guaranteed-non-zero exit ONLY on hard
                    failures (the status timer wants this).
  --tone            Play an audible tone for the result (pass/warn/fail/skip)
                    via /usr/share/snapmulti/audio/. Useful for headless
                    server installs where the operator can hear but not
                    see the result. Suppressed by TEST_TONE=false in
                    install.conf or by an active Snapcast stream.
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
        --json)
            JSON_OUTPUT=true
            shift
            ;;
        --no-fail-on-warn)
            NO_FAIL_ON_WARN=true
            shift
            ;;
        --tone)
            TONE=true
            shift
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

# JSON requires jq for safe escaping of arbitrary message text.
if [[ "$JSON_OUTPUT" == "true" ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: --json requires jq (apt-get install jq)" >&2
        exit 2
    fi
    RUN_STARTED_AT=$(date -u +%FT%TZ)
fi

# Helper: append one record to JSON_RECORDS using jq for safe escaping.
# Args: status (pass|fail|warn|info), message
_json_record() {
    local status="$1" msg="$2"
    JSON_RECORDS+=("$(jq -nc \
        --arg sec "$JSON_CURRENT_SECTION" \
        --arg st  "$status" \
        --arg msg "$msg" \
        '{section: $sec, status: $st, msg: $msg}')")
}

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

# Pi Zero 2W native install path — install.conf marks the role but
# there's no docker-compose.yml / .env (snapclient runs as systemd unit
# directly from the distro apt package). detect_dir() would miss it
# because of the compose-file gate, so look for install.conf separately.
detect_native_client_dir() {
    local explicit="$1"
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    local candidate
    for candidate in /opt/snapclient "${SCRIPT_DIR}/../client/common"; do
        if [[ -f "$candidate/install.conf" ]] && \
           grep -qE '^INSTALL_TYPE=client-native' "$candidate/install.conf" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

SERVER_DIR="$(detect_dir "$SERVER_DIR" snapserver /opt/snapmulti "${SCRIPT_DIR}/.." || true)"
CLIENT_DIR="$(detect_dir "$CLIENT_DIR" snapclient /opt/snapclient "${SCRIPT_DIR}/../client/common" || true)"
NATIVE_CLIENT_DIR=""
INSTALL_TYPE_NATIVE_CLIENT="false"
if [[ -z "$CLIENT_DIR" ]]; then
    NATIVE_CLIENT_DIR="$(detect_native_client_dir "" || true)"
    if [[ -n "$NATIVE_CLIENT_DIR" ]]; then
        CLIENT_DIR="$NATIVE_CLIENT_DIR"
        INSTALL_TYPE_NATIVE_CLIENT="true"
    fi
fi
export INSTALL_TYPE_NATIVE_CLIENT  # consumed by smoke modules (check_containers etc.)

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
    JSON_CURRENT_SECTION="$*"
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        return  # section header is implicit in each record's `section` field
    fi
    printf '\n==> %s\n' "$*" >&2
}

pass_check() {
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        _json_record pass "$1"
    else
        ok "$1"
    fi
}

fail_check() {
    FAILURES=$((FAILURES + 1))
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        _json_record fail "$1"
    else
        error "$1"
    fi
}

# Override info/warn from logging.sh in JSON mode so they too end up
# in the structured output. We have to do this AFTER `source logging.sh`
# at the top of the file — the override happens here, well after that.
if [[ "$JSON_OUTPUT" == "true" ]]; then
    # shellcheck disable=SC2317  # called via dispatch table when JSON_OUTPUT
    info() { _json_record info "$*"; }
    # shellcheck disable=SC2317
    warn() { WARNINGS=$((WARNINGS + 1)); _json_record warn "$*"; }
    # `error` keeps writing to stderr — it's used by usage() / require_cmd
    # before any check has run, and we want those visible regardless.
fi

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

# Docker is mandatory for every install path EXCEPT the Pi Zero 2W
# native client (snapclient runs as a systemd unit; no daemon).
# Skip the docker require when only that path is present.
if [[ "$INSTALL_TYPE_NATIVE_CLIENT" != "true" || "$MODE" != "client" ]]; then
    require_cmd docker
fi
require_cmd python3
require_cmd systemctl
require_cmd mount

# ── Source modular checks ────────────────────────────────────────────
# Each file under $SMOKE_MODULES_DIR/check_<name>.sh exposes a single
# `check_<name>` function. Sourced unconditionally; mode-gating is done
# inside each module so the wiring here stays declarative.
if [[ -d "$SMOKE_MODULES_DIR" ]]; then
    for _smoke_mod in \
        check_boot_health.sh \
        check_mounts.sh \
        check_qos.sh \
        check_timers.sh \
        check_system.sh \
        check_thermal.sh \
        check_audio_modules.sh \
        check_containers.sh \
        check_env.sh \
        check_mdns.sh \
        check_snapcast.sh \
    ; do
        if [[ -f "$SMOKE_MODULES_DIR/$_smoke_mod" ]]; then
            # shellcheck source=/dev/null
            source "$SMOKE_MODULES_DIR/$_smoke_mod"
        fi
    done
    unset _smoke_mod
fi

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

# Native client install (Pi Zero 2W path) has no Docker — skip the
# driver / daemon.json / fuse-overlayfs checks entirely. fuse-overlayfs
# is only needed when Docker stacks live on an overlayroot tmpfs.
if [[ "$INSTALL_TYPE_NATIVE_CLIENT" == "true" ]]; then
    info "Native client install (no Docker) — Docker driver / overlay check skipped"
else
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
        # snapclient-discover.timer drives the Docker-based multi-server
        # failover mechanism (PR #285). Native client (Pi Zero 2W) uses
        # the libavahi-client mDNS discovery built into snapclient itself,
        # so the timer is not installed and not expected.
        if [[ "$INSTALL_TYPE_NATIVE_CLIENT" != "true" ]]; then
            check_unit "snapclient-discover.timer"
        fi
        ;;
    both)
        [[ -n "$SERVER_DIR" ]] || fail_check "server install directory missing"
        [[ -n "$CLIENT_DIR" ]] || fail_check "client install directory missing"
        check_unit "snapmulti-server.service"
        check_unit "snapclient.service"
        # See `client)` comment above. `both` mode is impossible on Pi
        # Zero 2W (server stack exceeds 512 MB RAM), so the guard is
        # belt-and-braces here.
        if [[ "$INSTALL_TYPE_NATIVE_CLIENT" != "true" ]]; then
            check_unit "snapclient-discover.timer"
        fi
        ;;
esac

section "Compose"
# Native client install has no docker-compose.yml — the file was pruned
# by setup-zero2w.sh — so `docker compose config` would return empty and
# fail the check. Skip the client compose stack on native client. Server
# checks still run when MODE=both (impossible combination on Pi Zero 2W
# but kept declarative).
case "$MODE" in
    server)
        [[ -n "$SERVER_DIR" ]] && check_compose_stack "$SERVER_DIR/docker-compose.yml" "server"
        ;;
    client)
        if [[ "$INSTALL_TYPE_NATIVE_CLIENT" == "true" ]]; then
            info "Native client install — Docker Compose stack check skipped"
        elif [[ -n "$CLIENT_DIR" ]]; then
            check_compose_stack "$CLIENT_DIR/docker-compose.yml" "client"
        fi
        ;;
    both)
        [[ -n "$SERVER_DIR" ]] && check_compose_stack "$SERVER_DIR/docker-compose.yml" "server"
        if [[ "$INSTALL_TYPE_NATIVE_CLIENT" == "true" ]]; then
            info "Native client install — Docker Compose stack check skipped (client)"
        elif [[ -n "$CLIENT_DIR" ]]; then
            check_compose_stack "$CLIENT_DIR/docker-compose.yml" "client"
        fi
        ;;
esac

# Avahi socket bind-mount verification — confirms PR #290 (snapserver
# avahi mount) and PR #298 (mpd already had it) deployed correctly.
# Without these mounts, libavahi-client cannot reach the host's
# avahi-daemon, mDNS publication degrades to PTR-only, and strict
# clients fail (the bug we spent 2026-05-07 hunting).
_check_avahi_mount() {
    local container="$1"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$container" || return 0
    if docker inspect "$container" --format '{{range .Mounts}}{{.Source}}|{{end}}' 2>/dev/null \
        | grep -q '/run/avahi-daemon/socket'; then
        pass_check "$container: avahi socket mounted"
    else
        fail_check "$container: avahi socket NOT mounted — mDNS publication will degrade. Re-deploy with current docker-compose.yml"
    fi
}
case "$MODE" in
    server) _check_avahi_mount snapserver; _check_avahi_mount mpd ;;
    client) _check_avahi_mount snapclient ;;
    both)   _check_avahi_mount snapserver; _check_avahi_mount mpd; _check_avahi_mount snapclient ;;
esac
unset -f _check_avahi_mount 2>/dev/null || true

section "Network"
# Network checks are independent (each issues one or more system probes
# and exits) — run them in parallel so the slowest one (DNS retry: up
# to 30 s on failure) doesn't serialise behind NTP / mDNS / arping. On
# a healthy LAN this saves ~5 s; on a misconfigured one (DNS timing out)
# the smoke section completes in ~30 s instead of ~45 s.
#
# Background subshells can't update FAILURES / JSON_RECORDS in the
# parent, so each check writes its results to a tmpfile as TSV lines
# `<status>\t<message>` and the parent replays them through
# pass_check / fail_check / warn / info in canonical order.
_NET_RESULTS_DIR=$(mktemp -d /tmp/snapmulti-smoke-net.XXXXXX)
# shellcheck disable=SC2064  # expand now, on EXIT the dir we created
trap "rm -rf '$_NET_RESULTS_DIR'" EXIT

# DNS resolution must work — catches the NM dns-rc empty-resolv.conf
# regression (see CHANGELOG entry for PR #287). 30s budget covers slow
# DHCP + DNS warmup on Pi Zero 2W. Two neutral targets tried in sequence
# so a single-vendor outage (or a network that blocks one of them) does
# not produce a false-negative for the smoke test.
_net_check_dns() {
    local out="$_NET_RESULTS_DIR/dns"
    local targets=("cloudflare.com" "dns.google") attempt target
    for attempt in 1 2 3; do
        # `attempt` is only the retry counter — used implicitly to bound the loop.
        : "$attempt"
        for target in "${targets[@]}"; do
            if getent hosts "$target" >/dev/null 2>&1; then
                printf 'pass\tDNS resolution working (%s)\n' "$target" > "$out"
                return
            fi
        done
        sleep 10
    done
    printf 'fail\tDNS resolution failing on all targets (%s) — check /etc/resolv.conf and "nmcli general status"\n' "${targets[*]}" > "$out"
}

# Time sync — Snapcast TimeProvider is NTP-immune, but log timestamps and
# metadata-service rely on a sane wall clock. Pi Zero 2W's RTC sits at
# epoch 0 until NTP completes, which can mask boot-time bugs in any
# component that uses absolute timestamps.
_net_check_ntp() {
    local out="$_NET_RESULTS_DIR/ntp"
    local synced
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo "unknown")
    case "$synced" in
        yes) printf 'pass\tTime synchronised (NTP)\n' > "$out" ;;
        no)  printf 'fail\tTime NOT synchronised — `timedatectl status` for details, often resolves itself within 60s of boot\n' > "$out" ;;
        *)   printf 'warn\tTime sync state unknown (timedatectl returned %q)\n' "$synced" > "$out" ;;
    esac
}

# Hostname mDNS round-trip — the host's own hostname.local must resolve
# to ONE OF the host's own IPs via avahi. On dual-homed hosts (eth0 +
# wlan0 active) avahi may advertise on a different interface than the
# arbitrary "first" one, so we accept any of the local addresses to
# avoid false-failing the mismatch path.
_net_check_mdns_self() {
    local out="$_NET_RESULTS_DIR/mdns_self"
    if ! command -v avahi-resolve >/dev/null 2>&1; then
        printf 'warn\tavahi-resolve not installed — skipping mDNS hostname check\n' > "$out"
        return
    fi
    local own_host own_ips resolved
    own_host="$(hostname).local"
    own_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    resolved=$(timeout 5 avahi-resolve -4 -n "$own_host" 2>/dev/null | awk '{print $2}' | head -1)
    if [[ -n "$resolved" ]] && echo "$own_ips" | grep -qF -- "$resolved"; then
        printf 'pass\tmDNS hostname round-trip (%s -> %s)\n' "$own_host" "$resolved" > "$out"
    elif [[ -n "$resolved" ]]; then
        local ips_csv
        ips_csv=$(echo "$own_ips" | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        printf 'fail\tmDNS hostname mismatch (%s -> %s, expected one of: %s) — restart avahi-daemon\n' "$own_host" "$resolved" "$ips_csv" > "$out"
    else
        printf 'fail\tmDNS hostname does NOT resolve (%s) — avahi-daemon publishing broken\n' "$own_host" > "$out"
    fi
}

# IP conflict detection — non-DAD ARP probe. The earlier
# implementation used `arping -D` (RFC 5227 Duplicate Address Detection)
# which sources the probe from 0.0.0.0 and asks the kernel to put the
# interface address into a tentative state. On hosts where
# NetworkManager has adopted Docker bridges (br-*, veth*) as "connected
# (externally)" — the default when running snapMULTI in both / client
# mode — that tentative transition makes avahi-daemon briefly withdraw
# its address record on eth0, re-register, and then see its own
# re-announce coming back through the NM-tracked bridge as a foreign
# claim of the hostname. Avahi resolves the apparent conflict by
# renaming the host to `<hostname>-2`; snapcast / AirPlay / MPD then
# publish via the -2 name and `<hostname>.local` lookups fail.
# Observed live on pi-server 2026-05-15 at 11:53:17.
#
# The non-DAD probe below sends a normal ARP request for our own IP
# from our own MAC, then inspects replies: if any reply comes from a
# DIFFERENT MAC than the local one, that's a real conflict. This does
# not flip the interface address into tentative state, so the avahi
# rename loop never arms.
_net_check_arping() {
    local out="$_NET_RESULTS_DIR/arping"
    if ! command -v arping >/dev/null 2>&1; then
        printf 'warn\tarping not installed — skipping IP conflict check (apt-get install iputils-arping)\n' > "$out"
        return
    fi
    local own_iface own_ip own_mac
    own_iface=$(ip -4 -o route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    own_ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    if [[ -z "$own_iface" ]] || [[ -z "$own_ip" ]]; then
        printf 'warn\tCould not determine own IP/iface for conflict check\n' > "$out"
        return
    fi
    own_mac=$(ip -o link show "$own_iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="link/ether"){print $(i+1); exit}}')
    if [[ -z "$own_mac" ]]; then
        printf 'warn\tCould not read MAC for %s — skipping IP conflict check\n' "$own_iface" > "$out"
        return
    fi

    # Non-DAD probe: regular ARP request for our own IP. -c sets count,
    # -w sets total deadline, -q would silence output (we want it).
    # Without -D the source IP is our own, so the kernel does not put
    # the address into tentative state.
    local arping_rc=0 arping_out
    if sudo -n true 2>/dev/null; then
        arping_out=$(sudo -n arping -c 3 -w 5 -I "$own_iface" "$own_ip" 2>&1) || arping_rc=$?
    else
        arping_out=$(arping -c 3 -w 5 -I "$own_iface" "$own_ip" 2>&1) || arping_rc=$?
    fi
    if echo "$arping_out" | grep -qiE 'permission|not permitted|capabilities|password is required'; then
        printf 'warn\tarping needs CAP_NET_RAW / sudo — IP-conflict check skipped (run as root, or "setcap cap_net_raw+ep $(command -v arping)")\n' > "$out"
        return
    fi
    # Without `-D`, arping returns rc=1 when no replies arrive within
    # the timeout. On a healthy LAN this is the COMMON case: managed
    # switches and Wi-Fi APs do not reflect broadcasts back to the
    # sender, so we never hear our own ARP request and the kernel
    # suppresses self-replies — yet that is exactly the "no foreign
    # host claims our IP" state we want to call `pass`. Reserve `warn`
    # for genuine probe errors (interface missing, network unreachable)
    # which produce distinct text on stderr.
    if [[ $arping_rc -ne 0 ]] && ! echo "$arping_out" | grep -qiE 'reply|bytes from'; then
        if echo "$arping_out" | grep -qiE 'unknown host|no such device|network is unreachable|interface .* not found'; then
            printf 'warn\tarping probe failed — check interface %s (%s)\n' "$own_iface" "$own_ip" > "$out"
        else
            printf 'pass\tNo IP conflict on %s (%s) — no other host replied\n' "$own_ip" "$own_iface" > "$out"
        fi
        return
    fi
    # Replies are formatted as `Unicast reply from <ip> [<MAC>] ...`.
    # Any reply MAC that is not OUR MAC means a different host on the
    # LAN responded as the authoritative owner of our IP — that is the
    # conflict signature. Compare case-insensitively.
    local own_mac_lc
    own_mac_lc=$(echo "$own_mac" | tr 'A-Z' 'a-z')
    local foreign_mac
    foreign_mac=$(echo "$arping_out" \
        | grep -oE '\[([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\]' \
        | tr -d '[]' \
        | tr 'A-Z' 'a-z' \
        | awk -v me="$own_mac_lc" '$0 != me {print; exit}')
    if [[ -n "$foreign_mac" ]]; then
        printf 'fail\tPossible IP conflict on %s — replied by foreign MAC %s (our MAC: %s)\n' "$own_ip" "$foreign_mac" "$own_mac" > "$out"
    else
        printf 'pass\tNo IP conflict on %s (%s) — only our MAC replied\n' "$own_ip" "$own_iface" > "$out"
    fi
}

# Dispatch a check's tmpfile result through the parent's pass_check /
# fail_check / warn / info helpers. Multi-line tmpfiles are supported
# (each line is `<status>\t<message>`); empty / missing files emit a
# warn so we never silently swallow a backgrounded check.
_net_emit_results() {
    local check="$1"
    local out="$_NET_RESULTS_DIR/$check"
    if [[ ! -s "$out" ]]; then
        warn "Network check '$check' produced no result — parallel job may have crashed"
        return
    fi
    local status message
    while IFS=$'\t' read -r status message; do
        case "$status" in
            pass) pass_check "$message" ;;
            fail) fail_check "$message" ;;
            warn) warn "$message" ;;
            info) info "$message" ;;
            *)    warn "Network check '$check' returned unknown status '$status': $message" ;;
        esac
    done < "$out"
}

# SMOKE_SKIP_NETWORK=1: local-gate escape hatch so tests stay deterministic without a real DNS/NTP/mDNS stack. Production paths (firstboot, fleet-smoke, ADR-005) leave it unset.
if [[ "${SMOKE_SKIP_NETWORK:-0}" != "1" ]]; then
    # Run all four checks in parallel — the slowest (DNS retry, up to 30 s)
    # now overlaps with NTP/mDNS/arping (all <= 5 s) instead of serialising
    # behind them.
    _net_check_dns &
    _net_check_ntp &
    _net_check_mdns_self &
    _net_check_arping &
    wait
    # Replay results in canonical order so the human + JSON output looks
    # identical to the pre-parallel layout.
    _net_emit_results dns
    _net_emit_results ntp
    _net_emit_results mdns_self
    _net_emit_results arping
else
    info "SMOKE_SKIP_NETWORK=1 — DNS / NTP / mDNS / arping checks skipped (local gate mode)"
fi

# mDNS strict-client publishing (server-only) — services must answer
# SRV+TXT, not just PTR. Strict clients (Python zeroconf, macOS
# dns-sd -L) reject PTR-only and report "no servers found". This was
# fixed in PR #290 (avahi socket bind-mount). The upstream Snapcast
# 0.35.0 bug still drops the registration if avahi-daemon restarts;
# tune_avahi_daemon now restarts snapmulti-server.service explicitly
# whenever it touches /etc/avahi/avahi-daemon.conf (PartOf= cascade
# was removed because it gave Avahi full lifecycle control over the
# audio stack), and the unit's ExecStartPost self-heal re-checks
# 12 s after start. avahi-browse itself is a strict client: a "+"
# line means PTR-only, "=" means fully resolved with SRV+TXT. Same
# logic for AirPlay + Spotify.
# Smoke is per-device validation: this device must publish its own
# Snapcast / AirPlay / Spotify records on the LAN. Peer servers
# publishing the same protocols are NOT a substitute — green smoke
# on pi-server must mean pi-server itself is up, not "some other
# snapMULTI server happens to be visible from here". Filter every
# protocol to entries whose mDNS hostname (field 7 of avahi-browse
# `-rpt` output) matches this host's `.local` name.
#
# Also closes the AirPlay / Spotify over-count from non-snapMULTI
# devices: macOS "AirPlay Receiver" on port 7000, Apple TVs, HomePods,
# AVRs, Echos, Sonos all publish those protocols and would inflate
# an unfiltered count.
_check_mdns_service() {
    local service="$1" label="$2" hint="$3" own_host="$4"
    local browse_out resolved_count ptr_count
    browse_out=$(timeout 8 avahi-browse -rpt "$service" 2>/dev/null | { grep '^=' || true; })
    # Keep only `=` lines whose field 7 (hostname, e.g. "pi-server.local")
    # equals this device's own .local name. avahi-browse output format:
    #   =;iface;family;name;type;domain;HOST;addr;port;txt...
    # Match is case-insensitive: avahi normally lowercases but a custom
    # hostname with uppercase chars could trip an exact-match filter.
    local kept="" line host own_lc
    own_lc=$(tr '[:upper:]' '[:lower:]' <<< "$own_host")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        host=$(awk -F';' '{print tolower($7)}' <<< "$line")
        [[ "$host" == "$own_lc" ]] && kept+="$line"$'\n'
    done <<< "$browse_out"
    resolved_count=$(printf '%s' "$kept" | { grep -c . || true; })
    if [[ "${resolved_count:-0}" -ge 1 ]]; then
        pass_check "$label mDNS fully resolves ($resolved_count entry/entries with SRV+TXT — own record)"
        return
    fi
    # Same filter on the PTR-only browse, so we don't surface a peer's
    # broken PTR-only state as a failure on this device.
    ptr_count=$(timeout 5 avahi-browse -pt "$service" 2>/dev/null \
        | awk -F';' -v h="$own_lc" '/^\+/ && tolower($7) == h' \
        | { grep -c . || true; })
    if [[ "${ptr_count:-0}" -ge 1 ]]; then
        fail_check "$label mDNS publishes PTR but NO SRV+TXT for $own_host — strict clients fail. Try \`$hint\`"
    else
        # AirPlay/Spotify can legitimately be invisible if the matching
        # source is disabled in compose-profiles or hasn't been reached
        # by a client yet — demote to warn (not fail) for those.
        if [[ "$service" == "_snapcast._tcp" ]]; then
            fail_check "$label mDNS not visible for $own_host — check snapserver container + avahi-daemon"
        else
            warn "$label mDNS not visible for $own_host — service may be disabled or no client has paired yet"
        fi
    fi
}
if [[ "$MODE" == "server" || "$MODE" == "both" ]] && [[ "${SMOKE_SKIP_NETWORK:-0}" != "1" ]]; then
    if command -v avahi-browse >/dev/null 2>&1; then
        _own_mdns_host="$(hostname).local"
        _check_mdns_service "_snapcast._tcp"        "Snapcast" "docker compose restart snapserver"     "$_own_mdns_host"
        _check_mdns_service "_raop._tcp"            "AirPlay"  "docker compose restart shairport-sync" "$_own_mdns_host"
        _check_mdns_service "_spotify-connect._tcp" "Spotify"  "docker compose restart librespot"      "$_own_mdns_host"
        unset _own_mdns_host
    else
        warn "avahi-browse not installed — skipping all mDNS strict-client checks"
    fi
fi
unset -f _check_mdns_service 2>/dev/null || true

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

# ──────────────────────────────────────────────────────────────────
# Tier-2 checks — added 2026-05-07
# ──────────────────────────────────────────────────────────────────

if [[ "$MODE" == "client" || "$MODE" == "both" ]]; then
    section "Audio"

    # HAT consistency — SOUNDCARD env in client .env should reference a
    # CARD that's actually present in \`aplay -l\`. Catches a stale or
    # mis-detected HAT config (where audio-hat-detect.sh said one thing
    # but the kernel exposes another).
    _client_env="${CLIENT_DIR:-/opt/snapclient}/.env"
    if [[ -f "$_client_env" ]]; then
        # `|| true`: pipefail + set -e would kill the script on grep no-match
        _soundcard=$(grep '^SOUNDCARD=' "$_client_env" 2>/dev/null | cut -d= -f2- || true)
        # Two paths to derive the expected ALSA card name:
        #  (a) SOUNDCARD=hw:CARD=NAME,DEV=0           — headless client with HAT (PR #282)
        #  (b) SOUNDCARD=default + /etc/asound.conf   — display+HAT setup; routing
        #      via `multi` plugin pumps audio to BOTH the HAT and a Loopback for
        #      audio-visualizer / fb-display. The asound.conf names the HAT card
        #      via `ctl.!default { card NAME }` and `pcm "hw:NAME,0"` references.
        _card_name=$(echo "$_soundcard" | sed -nE 's/.*CARD=([^,]+).*/\1/p')
        _card_source="SOUNDCARD"
        if [[ -z "$_card_name" ]] && [[ "$_soundcard" == "default" ]] && [[ -f /etc/asound.conf ]]; then
            # Prefer the explicit `ctl.!default { card NAME }` declaration
            _card_name=$(awk '/^ctl\.!default/,/^}/' /etc/asound.conf 2>/dev/null \
                | grep -oE 'card [A-Za-z0-9_-]+' | awk 'NR==1 {print $2}' || true)
            # Fallback: first `hw:NAME,...` reference (skip Loopback —
            # that's the visualizer tap, not the audio destination).
            # The pattern requires an ALPHABETIC lead character so we
            # don't pick up bare-numeric device indices like `hw:0` or
            # `hw:1` (USB-audio asound.confs commonly use those, and
            # capturing them as a "card name" would false-fail the
            # subsequent aplay -l grep).
            if [[ -z "$_card_name" ]]; then
                _card_name=$(grep -oE 'hw:[A-Za-z][A-Za-z0-9_-]*' /etc/asound.conf 2>/dev/null \
                    | sed 's/hw://' | grep -v -i '^Loopback$' | head -1 || true)
            fi
            [[ -n "$_card_name" ]] && _card_source="/etc/asound.conf"
        fi
        if [[ -n "$_card_name" ]]; then
            if command -v aplay >/dev/null 2>&1; then
                # `-F` (fixed-string) so card names with regex metachars
                # (e.g. `+` in HiFiBerry DAC+ long names) don't break the
                # match. The surrounding `": "` and trailing space anchor
                # the line format adequately without ERE.
                if aplay -l 2>/dev/null | grep -qF ": $_card_name "; then
                    pass_check "HAT consistency: card '$_card_name' present in ALSA (via $_card_source)"
                else
                    fail_check "HAT mismatch: $_card_source references card '$_card_name' but \`aplay -l\` does not show it — HAT removed / wrong DAC profile?"
                fi
            else
                warn "aplay not installed — HAT consistency check skipped"
            fi
        elif [[ "$_soundcard" == "default" ]] && [[ ! -f /etc/asound.conf ]]; then
            info "SOUNDCARD=default with no /etc/asound.conf — likely USB / HDMI audio (no HAT to verify)"
        elif [[ -n "$_soundcard" ]]; then
            info "SOUNDCARD='$_soundcard' has no CARD= and asound.conf yields no card name — HAT consistency check not applicable"
        else
            info "No SOUNDCARD in client .env — HAT consistency check skipped"
        fi
    else
        info "Client .env not found — HAT consistency check skipped"
    fi

    # Audio path active params — when audio is playing, the kernel
    # populates /proc/asound/.../hw_params. Empty / "closed" means no
    # stream is currently flowing (fine in a smoke test scenario; the
    # check is only meaningful as a pass when audio is actually in
    # progress). We INFO when idle, pass when active and well-formed,
    # fail only when a stream IS active but at the wrong format.
    _hw_params_files=()
    while IFS= read -r f; do
        _hw_params_files+=("$f")
    done < <(ls /proc/asound/card*/pcm0p/sub*/hw_params 2>/dev/null)
    _audio_active=false
    # Guard the array iteration so Bash 3.2 (macOS dev gates) does not abort with "unbound variable" when the glob produced no matches.
    for f in ${_hw_params_files[@]+"${_hw_params_files[@]}"}; do
        # \`closed\` (single line) = no stream. Any other content = active.
        if grep -q 'access:' "$f" 2>/dev/null; then
            _audio_active=true
            # `rate:` line in hw_params is "rate: 44100 (44100/1)" — fraction
            # annotation. `$2+0` forces numeric coercion in awk, stripping
            # the trailing " (44100/1)". format and channels are single-token
            # so the simple split on ': ' is fine for them.
            _rate=$(awk '/^rate:/ {print $2+0; exit}' "$f")
            _format=$(awk -F': ' '/^format:/ {print $2; exit}' "$f")
            _channels=$(awk -F': ' '/^channels:/ {print $2; exit}' "$f")
            # snapMULTI invariant: 44100 / S16_LE / 2 channels
            if [[ "$_rate" == "44100" ]] && [[ "$_format" == "S16_LE" ]] && [[ "$_channels" == "2" ]]; then
                pass_check "Audio path active and at expected format ($_rate/$_format/${_channels}ch on $(dirname "$f"))"
            else
                fail_check "Audio path active but wrong format: rate=$_rate format=$_format channels=$_channels (expected 44100/S16_LE/2)"
            fi
            break
        fi
    done
    if [[ "$_audio_active" == "false" ]]; then
        info "No audio currently playing — audio path check skipped (pass-through, not a fail)"
    fi
fi

section "Operations"

# Containerd Leases self-heal counter — set by the boot-tune.sh self-heal
# logic added in PR #292 + capped by PR #298 H5. Above 3 = structural
# problem (genuine ENOSPC, not transient false-ENOSPC family).
_heal_counter="/var/lib/snapmulti-installer/containerd-heal.count"
if [[ -s "$_heal_counter" ]]; then
    _heal_count_raw=$(tr -dc '0-9' < "$_heal_counter" 2>/dev/null || echo 0)
    _heal_count="${_heal_count_raw:-0}"
    if (( _heal_count >= 3 )); then
        fail_check "Containerd self-heal at limit ($_heal_count/3) — structural ENOSPC, manual intervention needed (check tmpfs / boot-tune.sh logs)"
    elif (( _heal_count >= 1 )); then
        warn "Containerd has self-healed ${_heal_count} time(s) since install — monitoring (3 = give up)"
    else
        pass_check "Containerd self-heal counter clean (0/3)"
    fi
else
    pass_check "Containerd self-heal not triggered (no event since install)"
fi

# Music library non-empty (server only, when network-backed). Local
# disks are skipped — they have many legitimate states (empty drive,
# fresh install, etc.) and the user wants the system up regardless.
if [[ "$MODE" == "server" || "$MODE" == "both" ]]; then
    _server_env="${SERVER_DIR:-/opt/snapmulti}/.env"
    if [[ -f "$_server_env" ]]; then
        # `|| true`: pipefail + set -e would kill the script when the key
        # is not present (servers without an explicit MUSIC_SOURCE).
        # Use `sed 's/[[:space:]]*$//'` instead of `tr -d '[:space:]'` —
        # the latter would also strip INTERNAL spaces from a path like
        # `/media/my music`, breaking the subsequent `[[ -d ... ]]` test.
        _music_source=$(grep '^MUSIC_SOURCE=' "$_server_env" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*$//' || true)
        _music_path=$(grep '^MUSIC_PATH=' "$_server_env" 2>/dev/null | cut -d= -f2 | sed 's/[[:space:]]*$//' || true)
        _music_path="${_music_path:-/media/music}"
        case "$_music_source" in
            nfs|smb|network)
                if [[ -d "$_music_path" ]] \
                    && [[ -n "$(find "$_music_path" -maxdepth 3 -type f \
                        \( -name '*.mp3' -o -name '*.flac' -o -name '*.ogg' -o -name '*.m4a' -o -name '*.wav' -o -name '*.aac' \) \
                        2>/dev/null | head -1)" ]]; then
                    pass_check "Music library non-empty ($_music_path, source=$_music_source)"
                else
                    fail_check "Music library appears EMPTY ($_music_path, source=$_music_source) — check NFS/SMB mount + remote share"
                fi
                ;;
            *)
                info "Music source not network-backed (MUSIC_SOURCE='${_music_source:-unset}') — library content check skipped"
                ;;
        esac
    fi

    # JSON-RPC API responsive — \`Server.GetStatus\` returns the full
    # server config + streams + groups. A 200 with valid JSON is the
    # smallest functional check that proves snapserver is not just
    # \`Up\` per docker but actually serving control requests.
    # SMOKE_SKIP_NETWORK also gates these live-service HTTP probes: a
    # macOS / container CI runner without a live snapserver/metadata
    # stack on 127.0.0.1 would always fail them. Production runs
    # (firstboot, fleet-smoke, ADR-005 release gate) leave the flag
    # unset so the probes execute and surface a real regression.
    if [[ "${SMOKE_SKIP_NETWORK:-0}" == "1" ]]; then
        info "SMOKE_SKIP_NETWORK=1 — Snapcast JSON-RPC / metadata /health / /status probes skipped"
    elif command -v curl >/dev/null 2>&1; then
        _rpc_response=$(curl -sS --max-time 5 \
            -X POST -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"Server.GetStatus","id":1}' \
            http://127.0.0.1:1780/jsonrpc 2>/dev/null || true)
        if echo "$_rpc_response" | grep -q '"result"'; then
            pass_check "Snapcast JSON-RPC API responsive (Server.GetStatus on :1780)"
        else
            fail_check "Snapcast JSON-RPC API not responding correctly — response: '$(echo "$_rpc_response" | head -c 100)'"
        fi

        # metadata-service /health — proves the container is bound to :8083
        # AND can talk to snapserver JSON-RPC. The hardened /health
        # returns 503 with snapserver_unreachable / snapserver_stale when
        # the back-end is silent — a stricter check than docker's
        # \`Up (healthy)\` heartbeat (which reuses the same endpoint but
        # accepts any 2xx).
        _meta_health=$(curl -sS --max-time 5 -w '\n%{http_code}' http://127.0.0.1:8083/health 2>/dev/null || true)
        _meta_code=$(echo "$_meta_health" | tail -n 1)
        _meta_body=$(echo "$_meta_health" | sed '$d')
        if [[ "$_meta_code" == "200" ]] && echo "$_meta_body" | grep -q '"status": "ok"'; then
            pass_check "metadata-service /health responsive (status:ok on :8083)"
        elif [[ "$_meta_code" == "503" ]]; then
            _meta_status=$(echo "$_meta_body" | grep -oE '"status": "[^"]+"' | head -n 1)
            fail_check "metadata-service /health degraded — HTTP 503 ${_meta_status:-(no status field)}"
        else
            fail_check "metadata-service /health unexpected — HTTP $_meta_code body='$(echo "$_meta_body" | head -c 100)'"
        fi

        # /status web page (issue #177) — probe the JSON variant
        # (?format=json) instead of the HTML one. The HTML always returns
        # 200 (even with a "no snapshot available" failure verdict in the
        # body, e.g. when the /audio volume is not mounted in the metadata
        # container). The JSON variant returns 503 when the snapshot is
        # missing, distinguishing "endpoint reachable" from "feature
        # actually working end-to-end".
        _status_code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' 'http://127.0.0.1:8083/status?format=json' 2>/dev/null || true)
        case "$_status_code" in
            200) pass_check "/status snapshot present and readable (issue #177 path)" ;;
            503) fail_check "/status reports no snapshot — check snapmulti-status.timer AND /audio bind-mount on metadata container" ;;
            *)   fail_check "/status not responding — HTTP ${_status_code:-no-response}" ;;
        esac
    else
        warn "curl not installed — skipping JSON-RPC + /health + /status checks"
    fi
fi

# ── Modular checks (boot health, mounts, QoS, timers, system, audio) ──
# Same SMOKE_SKIP_NETWORK gate as above — these read /proc, /sys, run journalctl/vcgencmd/lsmod/tc (all Linux-only), so they're skipped on portable test runners.
if [[ "${SMOKE_SKIP_NETWORK:-0}" != "1" ]]; then
    declare -F check_boot_health    >/dev/null && check_boot_health
    declare -F check_mounts         >/dev/null && check_mounts
    declare -F check_qos            >/dev/null && check_qos
    declare -F check_timers         >/dev/null && check_timers
    declare -F check_system         >/dev/null && check_system
    declare -F check_thermal        >/dev/null && check_thermal
    declare -F check_audio_modules  >/dev/null && check_audio_modules
    declare -F check_containers     >/dev/null && check_containers
    declare -F check_env            >/dev/null && check_env
    declare -F check_mdns           >/dev/null && check_mdns
    declare -F check_snapcast       >/dev/null && check_snapcast
else
    info "SMOKE_SKIP_NETWORK=1 — modular Linux-only checks (boot health, mounts, QoS, timers, system, thermal, audio, env, mDNS, snapcast) skipped"
fi

section "Recent Errors"
if [[ "${SMOKE_SKIP_NETWORK:-0}" == "1" ]]; then
    info "SMOKE_SKIP_NETWORK=1 — recent-errors journalctl scan skipped"
else
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
fi

# ── Final emit ──
if [[ "$JSON_OUTPUT" == "true" ]]; then
    # Compose final document. `jq -s '.'` slurps the per-record objects
    # into an array, then we wrap with metadata. All escaping is handled
    # by jq — no risk of malformed output from message text containing
    # quotes, newlines, or non-ASCII characters.
    overall_status="ok"
    if (( FAILURES > 0 )); then
        overall_status="fail"
    elif (( WARNINGS > 0 )); then
        overall_status="warn"
    fi
    if [[ ${#JSON_RECORDS[@]} -eq 0 ]]; then
        records_json="[]"
    else
        records_json=$(printf '%s\n' "${JSON_RECORDS[@]}" | jq -s '.')
    fi
    jq -nc \
        --argjson schema "$SCHEMA_VERSION" \
        --arg     status "$overall_status" \
        --arg     mode "$MODE" \
        --arg     hostname "$(hostname 2>/dev/null || echo unknown)" \
        --arg     started "$RUN_STARTED_AT" \
        --arg     finished "$(date -u +%FT%TZ)" \
        --argjson failures "$FAILURES" \
        --argjson warnings "$WARNINGS" \
        --argjson records "$records_json" \
        '{
            schema_version: $schema,
            status: $status,
            mode: $mode,
            hostname: $hostname,
            started_at: $started,
            finished_at: $finished,
            failures: $failures,
            warnings: $warnings,
            records: $records
        }'
    # Exit 0 when fail-on-warn mode is opt-out and only warnings present;
    # otherwise exit non-zero on real failures.
    if (( FAILURES > 0 )); then
        exit 1
    fi
    if [[ "$NO_FAIL_ON_WARN" == "true" ]] && (( WARNINGS > 0 )); then
        exit 0
    fi
    exit 0
fi

_play_tone() {
    if [[ "$TONE" != "true" ]]; then return 0; fi
    local result="$1"
    for tone_helper in /opt/snapmulti/scripts/common/play-smoke-tone.sh \
                       /opt/snapclient/scripts/common/play-smoke-tone.sh \
                       /usr/local/bin/snapmulti-play-smoke-tone; do
        if [[ -x "$tone_helper" ]]; then
            # Foreground: `Type=oneshot` kills the cgroup when ExecStart exits, so a backgrounded aplay gets SIGTERM before the WAV finishes. Tone is <1 s — no CLI latency cost.
            "$tone_helper" "$result" >/dev/null 2>&1
            return 0
        fi
    done
}

# Human (CLI) mode
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
    if (( WARNINGS > 0 )); then
        _play_tone warn
    else
        _play_tone pass
    fi
    ok "Smoke check passed"
    exit 0
fi

_play_tone fail
error "Smoke check failed with $FAILURES issue(s)"
exit 1
