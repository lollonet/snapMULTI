#!/usr/bin/env bash
# Static + integration tests for the post-patch YAML sanity check in
# prepare-sd.sh and prepare-sd.ps1.
#
# Why this exists: the patch_user_data_runcmd function appends a `runcmd:`
# block at end-of-file when no existing runcmd is matched. If the regex
# missed an existing runcmd block (e.g. with non-standard whitespace), the
# result is two runcmd: blocks → cloud-init refuses to parse user-data at
# first boot → Pi comes up without network or SSH → operator only learns
# at first-boot reflash time.
#
# The check is a sanity gate AFTER the patch: verify exactly one
# `runcmd:` line is present, and (if python+yaml available) verify the
# whole document still parses. Adds nothing to the happy path; catches
# the silent-corruption case loudly on the operator's laptop instead of
# 20 minutes later on the Pi.

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

echo "== prepare-sd.sh: post-patch YAML sanity =="

assert 'grep -qE "_runcmd_count=\\\$\\(grep -cE \"\\^\\[\\[:space:\\]\\]\\*runcmd:\" \"\\\$USERDATA\"" "$PREP_SH"' \
       'sh: counts runcmd: occurrences post-patch'

assert 'grep -qF "ERROR: user-data has \${_runcmd_count} runcmd: blocks after patch (expected 1)" "$PREP_SH"' \
       'sh: errors loudly on double runcmd block'

assert 'grep -qE "command -v python3 .* python3 -c \"import yaml\"" "$PREP_SH"' \
       'sh: tries python+yaml validation when available'

assert 'grep -qF "yaml.safe_load(open(sys.argv[1]))" "$PREP_SH"' \
       'sh: full YAML parse via yaml.safe_load'

assert 'grep -qF "First boot will fail with cloud-init unable to parse user-data." "$PREP_SH"' \
       'sh: error message names the actual downstream failure'

# Pin the placement: validation must come AFTER the grep that verifies the
# hook string is present (otherwise we error out before knowing the patch
# even attempted) and BEFORE the meta-data refresh block.
_check_line=$(grep -nE "_runcmd_count=\\\$\\(grep" "$PREP_SH" | head -1 | cut -d: -f1)
_patched_line=$(grep -nF '  user-data patched.' "$PREP_SH" | head -1 | cut -d: -f1)
_metadata_line=$(grep -nF "Refresh cloud-init meta-data" "$PREP_SH" | head -1 | cut -d: -f1)
assert '[[ -n "$_check_line" && -n "$_patched_line" && -n "$_metadata_line" && \
        "$_check_line" -gt "$_patched_line" && "$_check_line" -lt "$_metadata_line" ]]' \
       'sh: validation block sits between "patched." print and meta-data refresh'

echo
echo "== prepare-sd.ps1: post-patch YAML sanity (Windows mirror) =="

assert 'grep -qF "runcmdMatches = \[regex\]::Matches(\$udContent, \"(?m)^[\\s]*runcmd:\")" "$PREP_PS1" || \
        grep -qF "runcmdMatches = [regex]::Matches(\$udContent, '"'"'(?m)^[\s]*runcmd:'"'"')" "$PREP_PS1"' \
       'ps1: counts runcmd: matches via [regex]::Matches'

assert 'grep -qF "runcmd: blocks after patch (expected 1)" "$PREP_PS1"' \
       'ps1: error message mirrors bash version'

assert 'grep -qF "Inspect '"'"'\$userData'"'"' for a malformed YAML structure." "$PREP_PS1"' \
       'ps1: error message names the file to inspect'

# Both scripts must agree on what counts as "correct" — exactly 1 runcmd block.
assert 'grep -qE "runcmd_count.* -ne 1" "$PREP_SH" && grep -qF "runcmdMatches.Count -ne 1" "$PREP_PS1"' \
       'bash + ps1 agree on the expected runcmd block count (1)'

echo
echo "== integration: simulate double-runcmd corruption =="

# Build a tiny YAML fixture that has TWO runcmd: blocks and verify the
# count regex catches it. This is what would happen if the awk patch's
# END branch fired against an already-populated user-data file.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/userdata-corrupt.yaml" <<'YAML'
#cloud-config
hostname: snapmulti
runcmd:
  - echo existing
runcmd:
  - [bash, /boot/firmware/snapmulti/firstboot.sh]
YAML

corrupt_count=$(grep -cE "^[[:space:]]*runcmd:" "$TMP/userdata-corrupt.yaml" || true)
assert '[[ "$corrupt_count" -eq 2 ]]' \
       'integration: a double-runcmd fixture yields count=2 with the same regex used by prepare-sd.sh'

# And a healthy fixture (post-correct-patch shape) yields count=1.
cat > "$TMP/userdata-ok.yaml" <<'YAML'
#cloud-config
hostname: snapmulti
runcmd:
  - [bash, /boot/firmware/snapmulti/firstboot.sh]
  - echo existing
YAML

ok_count=$(grep -cE "^[[:space:]]*runcmd:" "$TMP/userdata-ok.yaml" || true)
assert '[[ "$ok_count" -eq 1 ]]' \
       'integration: a correctly-patched fixture yields count=1'

# If pyyaml available, also verify the corrupt fixture fails parse and the
# OK fixture passes. Best-effort — runner may not have pyyaml.
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    if python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$TMP/userdata-ok.yaml" 2>/dev/null; then
        echo "  PASS: integration: yaml.safe_load accepts healthy fixture"
        pass=$((pass + 1))
    else
        echo "  FAIL: integration: yaml.safe_load rejected healthy fixture"
        fail=$((fail + 1))
    fi
    # The corrupt fixture has two duplicate top-level `runcmd:` keys —
    # yaml.safe_load tolerates this (last-wins) so the parser does NOT
    # error on it. The strict count check above is what actually catches
    # the bug; pyyaml is the secondary belt-and-braces guard against
    # OTHER corruptions (bad indentation, unbalanced brackets, etc.).
    # This pin documents that the chain is: count first, parse second.
    if python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$TMP/userdata-corrupt.yaml" 2>/dev/null; then
        echo "  PASS: integration: yaml.safe_load tolerates dup-key corrupt fixture (count check is the real catcher)"
        pass=$((pass + 1))
    else
        echo "  PASS: integration: yaml.safe_load also rejected dup-key corrupt fixture (bonus)"
        pass=$((pass + 1))
    fi
else
    echo "  SKIP: pyyaml not installed on this runner — yaml-parse leg of the test skipped"
fi

echo
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
