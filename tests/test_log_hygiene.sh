#!/usr/bin/env bash
# Static checks for log-hygiene fixes:
#   - Compose security_opt uses `=` (not deprecated `:`) for no-new-privileges + apparmor
#   - udev USB autosuspend rule scoped to DEVTYPE==usb_device (interfaces don't expose power/autosuspend)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR/.."

pass=0
fail=0

assert() {
    local cond="$1" desc="$2"
    if eval "$cond"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

echo "## Compose security_opt — equals syntax (Docker Compose deprecation)"

for f in "$ROOT/docker-compose.yml" "$ROOT/client/common/docker-compose.yml"; do
    name="${f#"$ROOT/"}"
    assert "! grep -qE 'no-new-privileges:|apparmor:' '$f'" \
        "$name: no deprecated colon separator in security_opt"
done

echo
echo "## udev USB autosuspend — scoped to usb_device"

TUNE="$ROOT/scripts/common/system-tune.sh"
assert "grep -q 'DEVTYPE==\"usb_device\"' '$TUNE'" \
    "system-tune.sh: rule filters DEVTYPE==usb_device"
assert "grep -q 'TEST==\"power/autosuspend\"' '$TUNE'" \
    "system-tune.sh: rule keeps TEST==power/autosuspend (belt+suspenders)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
