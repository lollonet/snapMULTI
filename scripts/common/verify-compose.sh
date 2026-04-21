#!/usr/bin/env bash
# verify-compose.sh — shared compose stack verification policy
#
# Single contract: all expected services running, only healthcheck-enabled
# ones must be healthy. Retries with configurable attempts and delay.
#
# Usage:
#   source scripts/common/verify-compose.sh
#   verify_compose_stack <compose_file> <stack_name> <attempts> <delay_seconds>
#
# Returns 0 if all services healthy, 1 otherwise.
# Logging: uses log_info/log_error if available, falls back to echo.

# Ensure logging functions exist (callers should source their own logger first)
if ! declare -F log_info &>/dev/null; then
    if declare -F info &>/dev/null; then
        log_info()  { info "$@"; }
        log_error() { error "$@"; }
    else
        log_info()  { echo "[INFO] $*"; }
        log_error() { echo "[ERROR] $*" >&2; }
    fi
fi

# Count services with healthcheck defined in a compose file.
# Returns the count via stdout.
_compose_hc_total() {
    local compose_file="$1"
    docker compose -f "$compose_file" config --format json 2>/dev/null \
        | python3 -c "import sys,json; c=json.load(sys.stdin)['services']; print(sum(1 for s in c.values() if 'healthcheck' in s))" \
        2>/dev/null || echo 0
}

# Count healthy containers in a compose project.
_compose_healthy_count() {
    local compose_file="$1"
    docker compose -f "$compose_file" ps -q 2>/dev/null \
        | xargs -r docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
        | grep -c '^healthy$' || true
}

# Verify all services in a compose stack are running and healthy.
#
# Args:
#   $1  compose_file   Path to docker-compose.yml
#   $2  stack_name     Human label for log messages (e.g. "server", "client")
#   $3  attempts       Number of retry attempts
#   $4  delay          Seconds between attempts
#
# Returns 0 on success, 1 on failure.
verify_compose_stack() {
    local compose_file="$1"
    local stack_name="$2"
    local attempts="$3"
    local delay="$4"
    local total hc_total running healthy attempt

    total=$(docker compose -f "$compose_file" config --services 2>/dev/null | wc -l)
    if [[ "$total" -eq 0 ]]; then
        log_error "Could not determine ${stack_name} service count"
        return 1
    fi

    hc_total=$(_compose_hc_total "$compose_file")

    for attempt in $(seq 1 "$attempts"); do
        running=$(docker compose -f "$compose_file" ps --status running -q 2>/dev/null | wc -l)
        healthy=$(_compose_healthy_count "$compose_file")

        if [[ "$running" -ge "$total" ]] && { [[ "$hc_total" -eq 0 ]] || [[ "$healthy" -ge "$hc_total" ]]; }; then
            log_info "All $total ${stack_name} services running ($healthy/$hc_total healthy)"
            return 0
        fi

        log_info "Attempt $attempt/$attempts: $running/$total running, $healthy/$hc_total healthy..."
        [[ "$attempt" -lt "$attempts" ]] && sleep "$delay"
    done

    log_error "$stack_name services not all healthy after $(( attempts * delay ))s"
    docker compose -f "$compose_file" ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null | while read -r line; do
        log_error "  $line"
    done
    return 1
}
