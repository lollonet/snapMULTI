#!/usr/bin/env bash
# shellcheck disable=SC2016  # assert() conditions are intentionally
#                              passed as single-quoted strings and eval'd
#                              with the file paths in scope.
# Static checks for the install TUI / fb-display overlap fix.
#
# Three coordinated changes:
#   1. progress.sh + unified-log.sh use $PROGRESS_TTY (default /dev/tty1),
#      not a hardcoded path — so firstboot.sh can redirect the install
#      TUI to /dev/tty3 without touching the libraries.
#   2. firstboot.sh:
#        - exports PROGRESS_TTY=/dev/tty3 + chvt 3 at start,
#        - chvt 8 (blank VT outside logind autovt range) right before
#          systemctl start snapclient.service so fb-display owns /dev/fb0.
#   3. client setup.sh masks getty@tty1.service when HAS_DISPLAY=true
#      so the post-reboot login prompt doesn't redraw on top of fb-display.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROGRESS_SH="$SCRIPT_DIR/../scripts/common/progress.sh"
UNIFIED_LOG_SH="$SCRIPT_DIR/../scripts/common/unified-log.sh"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

echo "=== progress.sh — env-driven PROGRESS_TTY ==="

assert 'grep -qE "^PROGRESS_TTY=\"\\\$\\{PROGRESS_TTY:-/dev/tty1\\}\"" "$PROGRESS_SH"' \
       'progress.sh declares PROGRESS_TTY with /dev/tty1 default'

# No hardcoded `/dev/tty1` in progress.sh active code (comments and the
# default value are OK). awk strips inline comments before checking.
hardcoded=$(awk -F'#' '
    {code=$1; if (code ~ /\/dev\/tty1/ && code !~ /PROGRESS_TTY:-/) print NR": "$0}
' "$PROGRESS_SH" || true)
if [[ -z "$hardcoded" ]]; then
    echo "  PASS: progress.sh has no hardcoded /dev/tty1 in active code"
    pass=$((pass + 1))
else
    echo "  FAIL: progress.sh still has hardcoded /dev/tty1:"
    echo "$hardcoded" | sed 's/^/    /'
    fail=$((fail + 1))
fi

assert 'grep -qE "render_progress|^[[:space:]]*\\}.*> *\"\\\$PROGRESS_TTY\"" "$PROGRESS_SH"' \
       'progress.sh writes render output to "$PROGRESS_TTY"'

assert 'grep -qE "stty -F \"\\\$PROGRESS_TTY\"" "$PROGRESS_SH"' \
       'progress.sh queries stty on "$PROGRESS_TTY"'

assert 'grep -qE "setfont .* -C \"\\\$PROGRESS_TTY\"" "$PROGRESS_SH"' \
       'progress.sh runs setfont on "$PROGRESS_TTY"'

echo
echo "=== unified-log.sh — env-driven PROGRESS_TTY ==="

assert 'grep -qE "^PROGRESS_TTY=\"\\\$\\{PROGRESS_TTY:-/dev/tty1\\}\"" "$UNIFIED_LOG_SH"' \
       'unified-log.sh declares PROGRESS_TTY with /dev/tty1 default'

assert 'grep -qE "ERROR\\] \\[\\\$source\\] \\\$msg\" *> *\"\\\$PROGRESS_TTY\"" "$UNIFIED_LOG_SH"' \
       'unified-log.sh writes ERROR to "$PROGRESS_TTY"'

assert 'grep -qE "WARN\\] *\\[\\\$source\\] \\\$msg\" *> *\"\\\$PROGRESS_TTY\"" "$UNIFIED_LOG_SH"' \
       'unified-log.sh writes WARN to "$PROGRESS_TTY"'

assert 'grep -qE "log_and_tty\\(\\)" "$UNIFIED_LOG_SH" && \
        awk "/^log_and_tty\\(\\)/,/^\\}/" "$UNIFIED_LOG_SH" | grep -qE "> *\"\\\$PROGRESS_TTY\""' \
       'log_and_tty() targets "$PROGRESS_TTY"'

echo
echo "=== firstboot.sh — chvt 3 at start, chvt 8 before fb-display ==="

assert 'grep -qE "export PROGRESS_TTY=/dev/tty3" "$FIRSTBOOT"' \
       'firstboot.sh exports PROGRESS_TTY=/dev/tty3'

assert 'grep -qE "chvt 3" "$FIRSTBOOT"' \
       'firstboot.sh switches to VT 3 for the install TUI'

# The chvt 8 must precede `systemctl start snapclient.service`.
chvt8_line=$(grep -nE 'chvt 8' "$FIRSTBOOT" | head -1 | cut -d: -f1)
snap_start_line=$(grep -nE 'systemctl start snapclient\.service' "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$chvt8_line" && -n "$snap_start_line" && "$chvt8_line" -lt "$snap_start_line" ]]; then
    echo "  PASS: chvt 8 (line $chvt8_line) runs BEFORE systemctl start snapclient (line $snap_start_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: chvt 8 missing or AFTER snapclient start (chvt8=$chvt8_line, start=$snap_start_line)"
    fail=$((fail + 1))
fi

# chvt 8 path must be guarded on /dev/fb0 + chvt presence: scan a small
# window of lines preceding chvt 8 for the conditional.
chvt8_ln=$(grep -nE 'chvt 8' "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$chvt8_ln" ]]; then
    start_ln=$((chvt8_ln - 5))
    (( start_ln < 1 )) && start_ln=1
    guard_window=$(sed -n "${start_ln},${chvt8_ln}p" "$FIRSTBOOT")
    if echo "$guard_window" | grep -qE 'if \[\[ -c /dev/fb0' \
       && echo "$guard_window" | grep -q 'command -v chvt'; then
        echo "  PASS: chvt 8 block guarded on /dev/fb0 + chvt presence"
        pass=$((pass + 1))
    else
        echo "  FAIL: chvt 8 missing fb0/chvt guard (window:"
        echo "$guard_window" | sed 's/^/    /'
        echo "    )"
        fail=$((fail + 1))
    fi
else
    echo "  FAIL: chvt 8 not found in firstboot.sh"
    fail=$((fail + 1))
fi

# setterm clears blanker/cursor on tty8.
assert 'grep -qE "setterm.*-blank 0.*tty8|setterm.*tty8.*-blank 0" "$FIRSTBOOT"' \
       'setterm disables blanker on /dev/tty8'

echo
echo "=== client setup.sh — mask getty@tty1 when HAS_DISPLAY ==="

# setup.sh has MULTIPLE `if [[ "$HAS_DISPLAY" == true ]]` blocks
# (audio loopback at line ~590, COMPOSE_PROFILES at line ~990, getty
# mask at line ~1105). The simple awk-range pattern stops at the FIRST
# `^fi$` in the file, which is the audio block — the getty mask is never
# in scope. Use a depth-tracked walk so grep sees content from ANY
# HAS_DISPLAY block, regardless of nesting.
hd_blocks=$(awk '
    /^if \[\[ "\$HAS_DISPLAY" == true \]\]; then$/ {depth=1; print; next}
    depth>0 && /^[[:space:]]*if / {depth++}
    depth>0 && /^[[:space:]]*fi$/ {print; depth--; next}
    depth>0 {print}
' "$SETUP_SH")

if echo "$hd_blocks" | grep -qE 'systemctl mask getty@tty1\.service'; then
    echo "  PASS: setup.sh masks getty@tty1.service inside a HAS_DISPLAY block"
    pass=$((pass + 1))
else
    echo "  FAIL: setup.sh missing systemctl mask getty@tty1 inside HAS_DISPLAY"
    fail=$((fail + 1))
fi

if echo "$hd_blocks" | grep -qE 'systemctl stop getty@tty1\.service'; then
    echo "  PASS: setup.sh stops getty@tty1.service before mask (to drop running prompt)"
    pass=$((pass + 1))
else
    echo "  FAIL: setup.sh missing systemctl stop getty@tty1 inside HAS_DISPLAY"
    fail=$((fail + 1))
fi

# Must NOT mask getty unconditionally — headless installs need tty1
# free, and forcibly masking would surprise diagnostics-only runs.
mask_outside_block=$(awk '
    /^if \[\[ "\$HAS_DISPLAY" == true \]\]; then$/ {depth=1; next}
    depth>0 && /^[[:space:]]*if / {depth++; next}
    depth>0 && /^[[:space:]]*fi$/ {depth--; next}
    depth==0 && /systemctl mask getty@tty1/ {print NR": "$0}
' "$SETUP_SH" || true)
if [[ -z "$mask_outside_block" ]]; then
    echo "  PASS: getty@tty1 mask is gated on HAS_DISPLAY (not unconditional)"
    pass=$((pass + 1))
else
    echo "  FAIL: stray getty@tty1 mask outside HAS_DISPLAY block:"
    echo "$mask_outside_block" | sed 's/^/    /'
    fail=$((fail + 1))
fi

echo
echo "=== Bash syntax ==="
for f in "$PROGRESS_SH" "$UNIFIED_LOG_SH" "$FIRSTBOOT" "$SETUP_SH"; do
    if bash -n "$f"; then
        echo "  PASS: bash -n $(basename "$f")"
        pass=$((pass + 1))
    else
        echo "  FAIL: bash -n $(basename "$f")"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Pass: $pass"
echo "  Fail: $fail"

[[ "$fail" -eq 0 ]]
