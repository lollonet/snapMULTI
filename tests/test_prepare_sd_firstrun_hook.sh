#!/usr/bin/env bash
# firstrun.sh hook must find firstboot.sh on Bookworm+ (/boot/firmware)
# as well as Bullseye (/boot). Older Imager releases write firstrun.sh
# even for Bookworm images, where the old hard-coded
# `bash /boot/snapmulti/firstboot.sh` pointed at a non-existent file.
#
# Covers prepare-sd.sh (functional: the sed insertion + the hook itself)
# and prepare-sd.ps1 (static: same probe order).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
PREP_PS1="$SCRIPT_DIR/../scripts/prepare-sd.ps1"

pass=0
fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

echo "== prepare-sd.sh firstrun hook =="

hook_line=$(grep -E "^HOOK_FIRSTRUN='" "$PREP_SH" || true)
if [[ -n "$hook_line" ]]; then ok "HOOK_FIRSTRUN defined"; else bad "HOOK_FIRSTRUN missing"; fi
HOOK_FIRSTRUN=""
eval "$hook_line"

if grep -qE '^    HOOK="\$HOOK_FIRSTRUN"' "$PREP_SH"; then
    ok "firstrun.sh branch uses HOOK_FIRSTRUN"
else
    bad "firstrun.sh branch does not use HOOK_FIRSTRUN"
fi
if grep -qF "HOOK_BULLSEYE='bash /boot/snapmulti/firstboot.sh'" "$PREP_SH"; then
    bad "hard-coded Bullseye-only hook still present"
else
    ok "no hard-coded Bullseye-only hook"
fi

# Probe order: /boot/firmware before /boot.
if [[ "$HOOK_FIRSTRUN" == *"in /boot/firmware /boot;"* ]]; then
    ok "hook probes /boot/firmware first, then /boot"
else
    bad "hook probe order wrong: $HOOK_FIRSTRUN"
fi
# The verify / already-patched greps key on this substring.
if [[ "$HOOK_FIRSTRUN" == *"snapmulti/firstboot.sh"* ]]; then
    ok "hook contains the snapmulti/firstboot.sh marker substring"
else
    bad "hook lacks snapmulti/firstboot.sh marker"
fi

# Insert it exactly the way prepare-sd.sh does (sed i\ before `rm -f ...firstrun.sh`).
cat > "$TMPD/firstrun.sh" <<'EOF'
#!/bin/bash
set +e
echo configuring
rm -f /boot/firstrun.sh
sed -i 's| systemd.run.*||g' /boot/cmdline.txt
exit 0
EOF
HOOK="$HOOK_FIRSTRUN"
sed -i.bak '/^rm -f.*firstrun\.sh/i\
# snapMULTI auto-install\
'"$HOOK"'
' "$TMPD/firstrun.sh"
rm -f "$TMPD/firstrun.sh.bak"
if bash -n "$TMPD/firstrun.sh"; then ok "patched firstrun.sh is valid bash"; else bad "patched firstrun.sh has a syntax error"; fi
if grep -qxF -- "$HOOK_FIRSTRUN" "$TMPD/firstrun.sh"; then
    ok "hook inserted verbatim by the sed i\\ command"
else
    bad "hook mangled by sed insertion"
fi

# Functional: run the hook with the two mount points remapped into TMPD.
run_hook() {
    local fw="$1" legacy="$2"
    local h="${HOOK_FIRSTRUN//\/boot\/firmware \/boot;/$fw $legacy;}"
    (cd "$TMPD" && bash -c "$h")
}
mkdir -p "$TMPD/fw/snapmulti" "$TMPD/legacy/snapmulti"
echo 'echo ran-fw' > "$TMPD/fw/snapmulti/firstboot.sh"
echo 'echo ran-legacy' > "$TMPD/legacy/snapmulti/firstboot.sh"
out=$(run_hook "$TMPD/fw" "$TMPD/legacy")
if [[ "$out" == "ran-fw" ]]; then ok "Bookworm layout: runs /boot/firmware copy only"; else bad "Bookworm layout: got '$out'"; fi
rm -f "$TMPD/fw/snapmulti/firstboot.sh"
out=$(run_hook "$TMPD/fw" "$TMPD/legacy")
if [[ "$out" == "ran-legacy" ]]; then ok "Bullseye layout: falls back to /boot copy"; else bad "Bullseye layout: got '$out'"; fi

echo
echo "== prepare-sd.ps1 firstrun hook (static) =="
ps1=$(tr -d '\r' < "$PREP_PS1")
if grep -qF 'for _sm_boot in /boot/firmware /boot; do' <<<"$ps1"; then
    ok "ps1: firstrun hook probes /boot/firmware then /boot"
else
    bad "ps1: firstrun hook does not probe both mount points"
fi
if grep -qF "hookBullseye = 'bash /boot/snapmulti/firstboot.sh'" <<<"$ps1"; then
    bad "ps1: hard-coded Bullseye-only hook still present"
else
    ok "ps1: no hard-coded Bullseye-only hook"
fi

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
