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
MOCK_BIN_DIR=$(dirname "$0")
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
    # Determine which format is requested. The --format flag's argument
    # tells us if we're being asked for Health.Status or RestartCount.
    fmt=""
    for ((i=2; i<=$#; i++)); do
        if [[ "${!i}" == "--format" ]]; then
            j=$((i+1))
            fmt="${!j}"
            break
        fi
    done
    case "$fmt" in
        *RestartCount*)
            # Walk MOCK_RC_SEQUENCE (comma-separated, one value per
            # attempt loop) using a counter file scoped to this case.
            counter_file="$MOCK_BIN_DIR/.rc_attempt"
            attempt=0
            [[ -f "$counter_file" ]] && attempt=$(cat "$counter_file")
            sequence="${MOCK_RC_SEQUENCE:-0,0,0,0,0,0,0,0}"
            rc=$(echo "$sequence" | awk -F, -v i="$((attempt + 1))" '{print ($i == "") ? 0 : $i}')
            echo $((attempt + 1)) > "$counter_file"
            # Return the RC value once per container id in args.
            for arg in "${@:2}"; do
                [[ "$arg" == --format || "$arg" == "$fmt" || "$arg" == --* ]] && continue
                echo "$rc"
            done
            ;;
        *)
            # Default: Health.Status format → all containers healthy.
            for arg in "${@:2}"; do
                [[ "$arg" == --format || "$arg" == "$fmt" || "$arg" == --* ]] && continue
                echo "healthy"
            done
            ;;
    esac
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
    local rc_seq="${7:-0,0,0,0,0,0,0,0}"
    local attempts="${8:-2}"
    export MOCK_TOTAL="$total"
    export MOCK_HC_TOTAL="$hc_total"
    export MOCK_RUNNING="$running"
    export MOCK_HEALTHY="$healthy"
    export MOCK_RC_SEQUENCE="$rc_seq"
    # Reset the mock's per-case attempt counter so each case starts at
    # sequence index 0.
    rm -f "$MOCK_BIN/.rc_attempt"

    local rc=0
    verify_compose_stack /tmp/stack.yml stack "$attempts" 0 || rc=$?
    assert_eq "$rc" "$expect_rc" "$desc"
}

echo "Testing verify_compose_stack()..."
run_case 0 0 0 0 1 "zero services fails"
run_case 2 1 2 1 0 "healthy stack passes"
run_case 2 1 1 0 1 "incomplete stack fails"
run_case 2 1 2 1 0 "health count via docker inspect passes"

# RestartCount-based restart-loop detection (PR #348+: catch the bug
# class where a container crashes faster than `delay` and verify sees
# it `healthy` between crashes).
echo ""
echo "Testing RestartCount restart-loop detection..."
# Stable stack: RC=0 across all attempts → passes
run_case 2 1 2 1 0 "stable stack (RC=0,0) passes" "0,0" 2
# Restart loop: RC increments every attempt → fails (never stabilises)
run_case 2 1 2 1 1 "restart loop (RC=0,1,2,3) fails" "0,1,2,3" 3
# Transient restart: RC jumps once then stabilises → passes once stable
run_case 2 1 2 1 0 "transient restart (RC=0,1,1) passes once stable" "0,1,1" 3
# Healthy + running but RC growing on EVERY sample → fails (would have
# been a false-positive success under the old logic).
run_case 2 1 2 1 1 "perpetual crash-loop (RC=0,1) attempts=2 fails" "0,1" 2

# Regression guard for attempts=0: the loop body never runs and rc_current
# is never assigned by the loop. The local rc_current=0 initialisation
# above prevents `set -u` from killing the post-loop diagnostic
# `[[ "$rc_current" -gt 0 ]]`.
run_case 2 1 2 1 1 "attempts=0 fails cleanly (rc_current pre-initialised)" "0,0" 0

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
