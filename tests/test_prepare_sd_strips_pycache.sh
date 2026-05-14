#!/usr/bin/env bash
# shellcheck disable=SC2034  # PREP_PS1 is referenced inside eval'd assertions.
# Verifies prepare-sd.sh strips host-side junk from the staged SD tree
# after the mode-specific copies. The recursive
# `cp -r` calls in copy_server_files / copy_client_files don't
# filter; the strip pass at the bottom of the script is the only
# guard. Regressing the strip would ship `__pycache__/` to every
# SD card.
#
# Static-only checks (no SD card mock): grep for the find/rm
# invocations and confirm they appear AFTER the mode-specific
# dispatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
PREP_PS1="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

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

echo "== prepare-sd.sh: host-junk strip =="

assert 'grep -qE "find .* -type d -name .__pycache__. -exec rm -rf" "$PREP_SH"' \
    "find ... -name __pycache__ -exec rm -rf present"

assert 'grep -qE "find .* -type f -name .\\*\\.pyc. -delete" "$PREP_SH"' \
    "find ... -name '*.pyc' -delete present"

assert 'grep -qF "._*" "$PREP_SH"' \
    "find ... -name '._*' -delete present (macOS AppleDouble)"

assert 'grep -qF ".DS_Store" "$PREP_SH"' \
    "find ... -name '.DS_Store' -delete present"

assert 'grep -qF "__MACOSX" "$PREP_SH"' \
    "find ... -name '__MACOSX' -exec rm -rf present"

# Strip MUST run after the case "$INSTALL_TYPE" dispatch, so that
# both server and client copy paths are cleaned. If it ran before,
# subsequent copies could reintroduce __pycache__.
case_line=$(grep -nE '^case "\$INSTALL_TYPE"' "$PREP_SH" | head -1 | cut -d: -f1)
strip_line=$(grep -nE 'find .* -name .__pycache__' "$PREP_SH" | head -1 | cut -d: -f1)
if [[ -n "$case_line" && -n "$strip_line" && "$strip_line" -gt "$case_line" ]]; then
    echo "  PASS: strip (line $strip_line) runs AFTER case dispatch (line $case_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: strip ordering broken (case=$case_line strip=$strip_line)"
    fail=$((fail + 1))
fi

echo
echo "== prepare-sd.sh: first-boot swap masks =="

for unit in \
    "rpi-resize-swap-file.service" \
    "rpi-setup-loop@var-swap.service" \
    "dev-zram0.swap" \
    "systemd-zram-setup@zram0.service" \
    "rpi-zram-writeback.service" \
    "rpi-zram-writeback.timer"; do
    assert "grep -qF \"${unit}\" \"$PREP_SH\"" \
        "cmdline masks $unit before first boot"
done

assert 'grep -qF "cmdline_add_token \"systemd.mask=\${_swap_unit}\"" "$PREP_SH"' \
    "prepare-sd uses cmdline-manager to add swap masks"

echo
echo "== prepare-sd.ps1: __pycache__ strip (parity) =="

assert 'grep -qE "Name -eq .__pycache__." "$PREP_PS1"' \
    "PowerShell strips __pycache__ directories"

assert 'grep -qE "Filter .\\*\\.pyc." "$PREP_PS1"' \
    "PowerShell strips *.pyc files"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
