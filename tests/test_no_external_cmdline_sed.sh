#!/usr/bin/env bash
# Anti-drift gate — Bundle B1 step s10.
#
# scripts/common/cmdline-manager.sh is the SINGLE authority for
# /boot/firmware/cmdline.txt mutations. Direct `sed -i ... cmdline.txt`
# (or `sed -i ... $CMDLINE` / $CMDLINE_FILE / etc.) outside the manager
# bypasses idempotency, validation, and the source-of-truth contract.
#
# Allowlist:
#   - scripts/common/cmdline-manager.sh (canonical owner)
#   - tests/ (test fixtures may construct cmdline strings + run sed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

pass=0
fail=0

echo "=== Gate: sed against cmdline.txt outside cmdline-manager.sh ==="
violators=$(
    cd "$REPO_DIR"
    # Match: `sed ...arg...` where `arg` contains cmdline.txt / CMDLINE /
    # CMDLINE_FILE — covers literal paths and variable references.
    git grep -nE 'sed [^|]*(cmdline\.txt|CMDLINE|CMDLINE_FILE)' scripts/ client/ 2>/dev/null \
        | grep -v 'scripts/common/cmdline-manager.sh' \
        | grep -v 'tests/' \
        || true
)
if [[ -z "$violators" ]]; then
    echo "  PASS: no direct sed cmdline.txt mutations outside cmdline-manager.sh"
    pass=$((pass + 1))
else
    echo "  FAIL: external sed cmdline.txt mutations found — route through"
    echo "        cmdline_add_token / cmdline_remove_token / cmdline_remove_pattern:"
    echo "$violators" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
