#!/usr/bin/env bash
# Anti-drift gate — Bundle B1 step s10.
#
# scripts/common/unified-log.sh is the SINGLE authority for
# info/warn/error/ok/step/debug/log_info/log_warn/log_error/log_ok.
# scripts/common/logging.sh is a thin shim that re-sources it. Other
# scripts must NOT redefine these functions — doing so:
#   - bypasses the install-chain / interactive auto-detection
#   - drifts the output format from the rest of the install log
#   - silently breaks PROGRESS_TTY mirroring on ERROR/WARN
#
# Allowlist:
#   - scripts/common/unified-log.sh (canonical owner)
#   - scripts/common/logging.sh (shim that re-sources unified-log.sh)
#   - tests/ (test fixtures may define local logger stubs)
#   - inside `if ! declare -F` guard blocks (fallback definitions that
#     only run when unified-log.sh is unreachable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
fail=0

echo "=== Gate: log function redefinitions outside unified-log.sh ==="
violators=$(
    cd "$REPO_DIR"
    git grep -nE '^(info|ok|warn|error|step|debug|log_info|log_warn|log_error|log_ok)\(\) \{' \
        scripts/ client/ 2>/dev/null \
        | grep -v 'scripts/common/unified-log.sh' \
        | grep -v 'scripts/common/logging.sh' \
        | grep -v 'tests/' \
        || true
)
if [[ -z "$violators" ]]; then
    echo "  PASS: no log function redefinitions outside unified-log.sh / logging.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: log function redefinitions found — source unified-log.sh instead:"
    echo "$violators" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
