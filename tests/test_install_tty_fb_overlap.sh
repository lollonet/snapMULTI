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
echo "=== firstboot.sh — TUI on tty3, fb-display deferred to post-reboot ==="

assert 'grep -qE "export PROGRESS_TTY=/dev/tty3" "$FIRSTBOOT"' \
       'firstboot.sh exports PROGRESS_TTY=/dev/tty3'

assert 'grep -qE "chvt 3" "$FIRSTBOOT"' \
       'firstboot.sh switches to VT 3 for the install TUI'

# fb-display must NOT start during install — install TUI on tty3
# stays visible all the way through the final banner. Verify the
# legacy `chvt 8` workaround is gone (no executable line, only
# rationale in comments).
assert '! grep -qE "^[[:space:]]+chvt 8" "$FIRSTBOOT"' \
       'no executable `chvt 8` line (fb-display deferred to post-reboot)'

# Client start path: docker compose up with COMPOSE_PROFILES="" so
# only the unprofiled `snapclient` service comes up; fb-display and
# audio-visualizer (both `profiles: framebuffer`) are deferred.
assert 'grep -qE "COMPOSE_PROFILES=\"\".*docker compose up" "$FIRSTBOOT"' \
       'firstboot starts snapclient with COMPOSE_PROFILES="" (no framebuffer)'

assert 'grep -qE "COMPOSE_PROFILES=\"\".*verify_compose_stack" "$FIRSTBOOT"' \
       'verify_compose_stack runs with COMPOSE_PROFILES="" (only counts unprofiled services)'

echo
echo "=== firstboot.sh — quiet boot flags for fb-display (client/both only) ==="

# Cmdline patcher now lives INSIDE the existing client/both setup block
# (gated on INSTALL_TYPE at line ~672). Awk between the section header
# and the next blank line OR `# Run setup.sh` boundary.
quiet_block=$(awk '
    /Quiet boot for fb-display/ {in_block=1}
    in_block && /^[[:space:]]*# Run setup\.sh/ {in_block=0}
    in_block {print}
' "$FIRSTBOOT")

assert 'echo "$quiet_block" | grep -qE "\\[\\[ -c /dev/fb0 \\]\\]"' \
       'quiet boot block gated on /dev/fb0 presence'

for flag in quiet loglevel=3 systemd.show_status=false vt.global_cursor_default=0 logo.nologo; do
    # here-string avoids `echo | grep -q` SIGPIPE race under `set -o pipefail`:
    # grep -q exits at first match → echo gets SIGPIPE → pipefail propagates
    # non-zero → false FAIL even when the flag is present. Flaky on CI when
    # the block fits the pipe buffer in some runs but not others.
    if grep -qF "$flag" <<< "$quiet_block"; then
        echo "  PASS: cmdline flag '$flag' is appended"
        pass=$((pass + 1))
    else
        echo "  FAIL: cmdline flag '$flag' missing"
        fail=$((fail + 1))
    fi
done

# Idempotency: each append routes through cmdline_add_token (from
# scripts/common/cmdline-manager.sh) which is itself idempotent —
# its internal field-loop returns 0 with no write when the token is
# already present. The previous explicit `grep -qE` guard around each
# `sed -i` call is gone because the helper subsumes it. Verifying
# idempotency now means verifying the helper is called.
assert 'echo "$quiet_block" | grep -qE "cmdline_add_token"' \
       'each cmdline flag append routes through idempotent cmdline_add_token helper'

# CRITICAL ORDERING #1: the quiet-boot block MUST run BEFORE
# `bash scripts/setup.sh`. setup.sh itself runs `raspi-config nonint
# do_overlayfs 0` (around setup.sh:1369) which remounts /boot/firmware
# READ-ONLY immediately. Verified live on pi-server (post-PR-#320
# reflash): patcher logged `cmdline: failed to add '<flag>'` × 5 with
# /boot/firmware already ro because setup.sh had run first.
quiet_line=$(grep -nE "^[[:space:]]*for flag in .*systemd\\.show_status" "$FIRSTBOOT" | head -1 | cut -d: -f1)
# After PR #355 the dispatcher resolved a `$setup_script` variable
# (Pi Zero 2W → setup-zero2w.sh, others → setup.sh) — accept either
# `bash scripts/setup.sh` or `bash "$setup_script"` as the call site.
setup_line=$(grep -nE "^[[:space:]]*bash (scripts/setup\\.sh|\"\\\$setup_script\")" "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$quiet_line" && -n "$setup_line" && "$quiet_line" -lt "$setup_line" ]]; then
    echo "  PASS: quiet-boot block (line $quiet_line) runs BEFORE bash scripts/setup.sh (line $setup_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: quiet-boot block NOT before setup.sh call (quiet=$quiet_line, setup=$setup_line)"
    fail=$((fail + 1))
fi

# CRITICAL ORDERING #2: still BEFORE setup_readonly_fs (PR #320 invariant
# preserved transitively, since setup.sh runs before setup_readonly_fs).
ro_line=$(grep -nE "^[[:space:]]*setup_readonly_fs " "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$quiet_line" && -n "$ro_line" && "$quiet_line" -lt "$ro_line" ]]; then
    echo "  PASS: quiet-boot block (line $quiet_line) runs BEFORE setup_readonly_fs (line $ro_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: quiet-boot block AFTER setup_readonly_fs (quiet=$quiet_line, ro=$ro_line)"
    fail=$((fail + 1))
fi

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
