#!/usr/bin/env bash
# Static checks for scripts/common/auto-boot-smoke.sh + the systemd unit
# installed by install_boot_tune_service in scripts/common/system-tune.sh.

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

echo "## auto-boot-smoke wrapper"

WRAP="$ROOT/scripts/common/auto-boot-smoke.sh"
assert "[[ -f '$WRAP' ]]"                  "wrapper exists"
assert "[[ -x '$WRAP' ]]"                  "wrapper is executable"
assert "head -1 '$WRAP' | grep -q '^#!/usr/bin/env bash'"  "shebang env bash"
assert "grep -q 'set -uo pipefail' '$WRAP'" "set -uo pipefail (no -e — best-effort)"
assert "grep -q 'INSTALL_TYPE=' '$WRAP'"   "reads INSTALL_TYPE from install.conf"
assert "grep -qE 'server\\)|client\\)|both\\)' '$WRAP'" "dispatches on install role"
assert "grep -q '/opt/snapmulti/scripts/device-smoke.sh' '$WRAP'" "calls server smoke path"
assert "grep -q '/opt/snapclient/scripts/device-smoke.sh' '$WRAP'" "calls client smoke path"
assert "grep -q -- '--tone' '$WRAP'"       "invokes device-smoke.sh with --tone"
assert "grep -q 'docker compose ps' '$WRAP'" "waits for ALL compose containers healthy before firing (not just Snapcast — avoids self-degrade FAIL cascade)"
assert "grep -qE '\\|\\| true\\s*$|exit 0' '$WRAP'" "always exits 0 — tone is the signal, never fails the systemd unit"

echo
echo "## install_boot_tune_service installs the auto-boot-smoke unit"

TUNE="$ROOT/scripts/common/system-tune.sh"
assert "grep -q 'auto-boot-smoke.sh' '$TUNE'"                      "system-tune.sh references the wrapper"
assert "grep -q 'snapmulti-auto-boot-smoke.service' '$TUNE'"       "writes the systemd unit"
assert "grep -q 'snapmulti-auto-boot-smoke' '$TUNE'"               "installs helper to /usr/local/bin/snapmulti-auto-boot-smoke"
assert "grep -q 'systemctl enable snapmulti-auto-boot-smoke' '$TUNE'" "enables the unit"
assert "grep -A20 'snapmulti-auto-boot-smoke.service <<' '$TUNE' | grep -q 'After=multi-user.target'" "unit ordered After=multi-user.target"
assert "grep -A20 'snapmulti-auto-boot-smoke.service <<' '$TUNE' | grep -q 'Type=oneshot'"             "unit Type=oneshot"
assert "grep -A20 'snapmulti-auto-boot-smoke.service <<' '$TUNE' | grep -q 'WantedBy=multi-user.target'" "unit WantedBy=multi-user.target"

echo
echo "## SD-prep staging lists the wrapper"

assert "grep -q 'common/auto-boot-smoke.sh' '$ROOT/scripts/prepare-sd.sh'"  "prepare-sd.sh stages wrapper"
assert "grep -q 'common/auto-boot-smoke.sh' '$ROOT/scripts/prepare-sd.ps1'" "prepare-sd.ps1 stages wrapper"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
