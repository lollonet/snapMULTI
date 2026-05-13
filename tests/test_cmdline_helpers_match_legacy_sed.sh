#!/usr/bin/env bash
# Behavioral-equivalence test — Bundle B1 step s2.
#
# This test runs the four legacy `sed -i` patterns that USED to live
# inline in firstboot.sh and setup.sh, then runs the equivalent new
# cmdline-manager.sh helper sequence on the same input, and asserts
# byte-identical output. The intent: lock in the semantics of the
# refactor BEFORE swapping call sites, so any post-refactor regression
# in cmdline.txt content surfaces immediately in CI.
#
# Coverage matches the four pre-refactor call sites:
#   1. firstboot.sh:421 — remove `quiet`, `splash`, `fbcon=map:9`
#   2. firstboot.sh:877 — append `<flag>` (called in a loop)
#   3. setup.sh:732     — remove parametric `video=HDMI-A-1:[^ ]*`
#   4. setup.sh:842     — remove `fbcon=map:9`

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMDLINE_MGR="$SCRIPT_DIR/../scripts/common/cmdline-manager.sh"

pass=0
fail=0

# Skip the legacy-sed leg of every test on Darwin without gsed: BSD
# sed has different `-i` semantics that corrupt the test.
USE_SED="sed"
if [[ "$(uname -s)" == "Darwin" ]]; then
    if command -v gsed >/dev/null 2>&1; then
        USE_SED="gsed"
    else
        echo "SKIP: BSD sed on macOS — behavioral-equivalence test runs on Linux CI only"
        echo
        echo "Results: 0 passed, 0 failed (skipped)"
        exit 0
    fi
fi

# shellcheck source=../scripts/common/cmdline-manager.sh
source "$CMDLINE_MGR"

LEGACY=$(mktemp /tmp/cmdline-legacy.XXXXXX)
NEW=$(mktemp /tmp/cmdline-new.XXXXXX)
trap 'rm -f "$LEGACY" "$NEW"' EXIT

# Monkey-patch cmdline_path so the helpers operate on $NEW.
cmdline_path() {
    printf '%s\n' "$NEW"
}

assert_equiv() {
    local desc="$1"
    local legacy new
    legacy=$(cat "$LEGACY")
    new=$(cat "$NEW")
    if [[ "$legacy" == "$new" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        echo "    LEGACY: '$legacy'"
        echo "    NEW   : '$new'"
        fail=$((fail + 1))
    fi
}

# ── Case 1: firstboot.sh:421 — remove quiet, splash, fbcon=map:9 ──
INPUT='coherent_pool=1M 8250.nr_uarts=1 console=serial0,115200 console=tty1 quiet splash fbcon=map:9 root=PARTUUID=abc-02 rootwait'
echo "$INPUT" > "$LEGACY"
echo "$INPUT" > "$NEW"

# Legacy sed (verified line 421 of firstboot.sh pre-refactor).
$USE_SED -i 's/ quiet//; s/ splash//; s/ fbcon=map:9//' "$LEGACY"

# New helper sequence.
cmdline_remove_token quiet
cmdline_remove_token splash
cmdline_remove_token 'fbcon=map:9'

assert_equiv "case 1 — firstboot.sh:421 (remove quiet+splash+fbcon=map:9)"

# ── Case 2: firstboot.sh:877 — append <flag> ──
INPUT='console=tty1 root=PARTUUID=abc-02 rootwait'
echo "$INPUT" > "$LEGACY"
echo "$INPUT" > "$NEW"
flag='cgroup_enable=memory'

# Legacy sed (line 877: `sed -i "1s/\$/ ${flag}/"`).
$USE_SED -i "1s/\$/ ${flag}/" "$LEGACY"

# New helper.
cmdline_add_token "$flag"

assert_equiv "case 2 — firstboot.sh:877 (append cgroup_enable=memory)"

# ── Case 3: setup.sh:732 — remove parametric video=HDMI-A-1:* ──
INPUT='console=tty1 video=HDMI-A-1:1920M@60 fbcon=map:9 rootwait'
echo "$INPUT" > "$LEGACY"
echo "$INPUT" > "$NEW"

# Legacy sed.
$USE_SED -i 's/ video=HDMI-A-1:[^ ]*//' "$LEGACY"

# New helper — pattern matches the entire field.
cmdline_remove_pattern 'video=HDMI-A-1:[^[:space:]]*'

assert_equiv "case 3 — setup.sh:732 (remove parametric video=HDMI-A-1:*)"

# ── Case 4: setup.sh:842 — remove fbcon=map:9 ──
INPUT='console=tty1 fbcon=map:9 rootwait'
echo "$INPUT" > "$LEGACY"
echo "$INPUT" > "$NEW"

# Legacy sed.
$USE_SED -i 's/ fbcon=map:9//' "$LEGACY"

# New helper.
cmdline_remove_token 'fbcon=map:9'

assert_equiv "case 4 — setup.sh:842 (remove fbcon=map:9)"

# ── Edge: multi-call sequence equivalent to firstboot.sh:877 loop ──
INPUT='console=tty1 rootwait'
echo "$INPUT" > "$LEGACY"
echo "$INPUT" > "$NEW"
for flag in cgroup_enable=memory cgroup_memory=1; do
    $USE_SED -i "1s/\$/ ${flag}/" "$LEGACY"
    cmdline_add_token "$flag"
done
assert_equiv "case 5 — loop append (cgroup_enable=memory + cgroup_memory=1)"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
