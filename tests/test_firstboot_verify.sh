#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SH="$SCRIPT_DIR/../scripts/common/verify-compose.sh"

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

# Source the shared verify module directly
# shellcheck source=../scripts/common/verify-compose.sh
source "$VERIFY_SH"

# Create mock docker script on PATH so xargs can invoke it
MOCK_BIN=$(mktemp -d)
cat > "$MOCK_BIN/docker" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "compose" ]]; then
    shift  # consume "compose"
    # Skip flags like -f <file>
    while [[ "${1:-}" == "-f" ]]; do shift 2; done
    case "${1:-} ${2:-} ${3:-}" in
        "config --services "*|"config --services ")
            if [[ "${MOCK_TOTAL:-0}" -gt 0 ]]; then
                seq 1 "${MOCK_TOTAL:-0}" | sed 's/.*/svc&/'
            fi
            ;;
        "config --format json")
            python3 -c "
import json, os
hc = int(os.environ.get('MOCK_HC_TOTAL', '0'))
services = {}
for i in range(max(hc, 1)):
    services[f'svc{i}'] = {'healthcheck': {'test': ['CMD', 'true']}} if i < hc else {}
print(json.dumps({'services': services}))
"
            ;;
        "ps --status running")
            seq 1 "${MOCK_RUNNING:-0}" | sed 's/.*/id&/'
            ;;
        "ps -q "*)
            seq 1 "${MOCK_HEALTHY:-0}" | sed 's/.*/id&/'
            ;;
    esac
elif [[ "$1" == "inspect" ]]; then
    # Called by xargs with container IDs as trailing args
    for arg in "${@:2}"; do
        [[ "$arg" == --* ]] && continue
        echo "healthy"
    done
fi
MOCK
chmod +x "$MOCK_BIN/docker"
# Also create a mock sleep to avoid delays
cat > "$MOCK_BIN/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$MOCK_BIN/sleep"
export PATH="$MOCK_BIN:$PATH"
trap 'rm -rf "$MOCK_BIN"' EXIT

log_info() { :; }
log_error() { :; }

run_case() {
    local total="$1" hc_total="$2" running="$3" healthy="$4" expect_rc="$5" desc="$6"
    export MOCK_TOTAL="$total"
    export MOCK_HC_TOTAL="$hc_total"
    export MOCK_RUNNING="$running"
    export MOCK_HEALTHY="$healthy"

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
