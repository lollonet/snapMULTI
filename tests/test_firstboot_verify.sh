#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIRSTBOOT_SH="$SCRIPT_DIR/../scripts/firstboot.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

verify_compose_stack() {
    local compose_file="$1"
    local stack_name="$2"
    local attempts="$3"
    local delay="$4"
    local compose_args=(-f "$compose_file")
    local total hc_total running healthy attempt

    total=$(docker compose "${compose_args[@]}" config --services 2>/dev/null | wc -l)
    if [[ "$total" -eq 0 ]]; then
        log_error "Could not determine ${stack_name} service count"
        return 1
    fi

    hc_total=$(docker compose "${compose_args[@]}" config --format json 2>/dev/null \
        | python3 -c "import sys,json; c=json.load(sys.stdin)['services']; print(sum(1 for s in c.values() if 'healthcheck' in s))" 2>/dev/null) || hc_total=0

    for attempt in $(seq 1 "$attempts"); do
        running=$(docker compose "${compose_args[@]}" ps --status running -q 2>/dev/null | wc -l)
        healthy=$(
            docker compose "${compose_args[@]}" ps -q 2>/dev/null \
                | xargs docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null \
                | grep -c '^healthy$' || true
        )

        if [[ "$running" -ge "$total" ]] && { [[ "$hc_total" -eq 0 ]] || [[ "$healthy" -ge "$hc_total" ]]; }; then
            return 0
        fi

        [[ "$attempt" -lt "$attempts" ]] && sleep "$delay"
    done

    docker compose "${compose_args[@]}" ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null >/dev/null
    return 1
}

run_case() {
    local total="$1" hc_total="$2" running="$3" healthy="$4" expect_rc="$5" desc="$6"
    MOCK_TOTAL="$total"
    MOCK_HC_TOTAL="$hc_total"
    MOCK_RUNNING="$running"
    MOCK_HEALTHY="$healthy"

    log_info() { :; }
    log_error() { :; }
    sleep() { :; }
    docker() {
        local args="$*"
        if [[ "$args" == "compose -f /tmp/stack.yml config --services" ]]; then
            if [[ "${MOCK_TOTAL:-0}" -gt 0 ]]; then
                seq 1 "${MOCK_TOTAL:-0}" | sed 's/.*/svc&/'
            fi
            return 0
        fi
        if [[ "$args" == "compose -f /tmp/stack.yml config --format json" ]]; then
            python3 - <<'PY'
import json, os
hc = int(os.environ.get('MOCK_HC_TOTAL', '0'))
services = {}
for i in range(max(hc, 1)):
    services[f'svc{i}'] = {'healthcheck': {'test': ['CMD', 'true']}} if i < hc else {}
print(json.dumps({'services': services}))
PY
            return 0
        fi
        if [[ "$args" == "compose -f /tmp/stack.yml ps --status running -q" ]]; then
            seq 1 "${MOCK_RUNNING:-0}" | sed 's/.*/id&/'
            return 0
        fi
        if [[ "$args" == "compose -f /tmp/stack.yml ps -q" ]]; then
            seq 1 "${MOCK_HEALTHY:-0}" | sed 's/.*/id&/'
            return 0
        fi
        if [[ "$1" == "inspect" ]]; then
            seq 1 "${MOCK_HEALTHY:-0}" | sed 's/.*/healthy/'
            return 0
        fi
        return 0
    }

    local rc=0
    verify_compose_stack /tmp/stack.yml stack 2 0 || rc=$?
    assert_eq "$rc" "$expect_rc" "$desc"
}

echo "Testing verify_compose_stack()..."
run_case 0 0 0 0 1 "zero services fails"
run_case 2 1 2 1 0 "healthy stack passes"
run_case 2 1 1 0 1 "incomplete stack fails"
run_case 2 1 2 1 0 "health count via docker inspect passes"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
