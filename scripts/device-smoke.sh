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
    shift
    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
        return 0
    fi
    local candidate
    for candidate in "$@"; do
        if [[ -d "$candidate" && -f "$candidate/docker-compose.yml" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

SERVER_DIR="$(detect_dir "$SERVER_DIR" /opt/snapmulti "${SCRIPT_DIR}/.." || true)"
CLIENT_DIR="$(detect_dir "$CLIENT_DIR" /opt/snapclient "${SCRIPT_DIR}/../client/common" || true)"

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
