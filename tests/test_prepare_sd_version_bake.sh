#!/usr/bin/env bash
# Pin the VERSION-file bake invocation in prepare-sd.{sh,ps1}.
#
# The version stamp written into `server/.version` + `client/VERSION` on the
# SD boot partition is the ONLY way the device knows which release it was
# flashed from (no git repo on the appliance). When prepare-sd used
# `git describe --tags --abbrev=0`, a flash from a main HEAD that was N
# commits past the latest tag baked the BARE tag — every diagnostic and the
# /status page reported the device as "v0.8.0" even though it actually ran
# code with N additional commits.
#
# This test pins the corrected invocation (without `--abbrev=0`) on both
# the bash and PowerShell installers, and asserts the rationale comment
# stays close enough to the call that a future drift will be obvious.
#
# Static-only — no real SD card or git repo manipulation.

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

echo "== prepare-sd.sh: VERSION bake without --abbrev=0 =="

# The correct invocation: `git describe --tags 2>/dev/null` — the lack of
# `--abbrev=0` is the WHOLE point of the fix.
assert 'grep -qE "git -C .* describe --tags 2>/dev/null" "$PREP_SH"' \
    "describe call present without --abbrev=0 (bash)"

assert '! grep -qE "git -C .* describe --tags --abbrev=0" "$PREP_SH"' \
    "no residual --abbrev=0 anywhere in prepare-sd.sh"

# Rationale comment must live within 12 lines of the call so a future
# editor sees it without scrolling.
describe_line=$(grep -n "git -C .* describe --tags" "$PREP_SH" | head -1 | cut -d: -f1)
comment_line=$(grep -n "NO .--abbrev=0." "$PREP_SH" | head -1 | cut -d: -f1)
if [[ -n "$describe_line" && -n "$comment_line" ]] \
    && (( describe_line - comment_line >= 0 )) \
    && (( describe_line - comment_line <= 12 )); then
    echo "  PASS: rationale comment within 12 lines of describe call (bash)"
    pass=$((pass + 1))
else
    echo "  FAIL: rationale comment missing or too far from describe call (bash)"
    fail=$((fail + 1))
fi

echo
echo "== prepare-sd.ps1: VERSION bake without --abbrev=0 =="

assert 'grep -qE "git -C .ProjectDir describe --tags 2>" "$PREP_PS1"' \
    "describe call present without --abbrev=0 (ps1)"

assert '! grep -qE "describe --tags --abbrev=0" "$PREP_PS1"' \
    "no residual --abbrev=0 anywhere in prepare-sd.ps1"

assert 'grep -qE "NO .--abbrev=0." "$PREP_PS1"' \
    "rationale comment present (ps1)"

# The two installers must stay in sync — if one bakes a distance-suffix
# format and the other bakes a bare tag, the same release tag would appear
# differently on Mac/Linux-flashed vs Windows-flashed devices.
sh_form=$(grep -oE "describe --tags[^|]*\| true|describe --tags[^)]*\)" "$PREP_SH" | head -1)
ps1_form=$(grep -oE "describe --tags[^|]*" "$PREP_PS1" | head -1)
if [[ -n "$sh_form" && -n "$ps1_form" ]]; then
    echo "  PASS: both installers call describe --tags (cross-platform parity)"
    pass=$((pass + 1))
else
    echo "  FAIL: describe call shape mismatch (sh=$sh_form, ps1=$ps1_form)"
    fail=$((fail + 1))
fi

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
