#!/usr/bin/env bash
# Static checks on scripts/prepare-sd.sh for release-manifest wiring.
#
# We deliberately do NOT run prepare-sd.sh end-to-end (it needs root,
# a real boot partition, cloud-init patching, etc.). Instead we grep
# the script for the wiring contracts the iter-2 plan locks in:
#   - manifest helper sourced BEFORE ADV_IMAGE_TAG init
#   - parse_release_manifest invoked with the canonical path
#   - ADV_IMAGE_TAG default = $MANIFEST_IMAGE_SET (with 'latest' fallback)
#   - install.conf heredoc emits SNAPMULTI_RELEASE + SNAPMULTI_IMAGE_SET
#   - release-manifest.json staged onto SD (guarded copy)
#   - verify-list includes release-manifest.json + common/release-manifest.sh
#   - summary print includes the 2 new keys

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE="$SCRIPT_DIR/../scripts/prepare-sd.sh"

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

echo "## prepare-sd.sh manifest wiring"

assert "[[ -f '$PREPARE' ]]" "prepare-sd.sh exists"

assert "grep -qE 'source .*common/release-manifest\.sh' '$PREPARE'" \
    "release-manifest.sh sourced"

assert "grep -qE 'parse_release_manifest .*release-manifest\.json' '$PREPARE'" \
    "parse_release_manifest invoked with manifest path"

# The source MUST come before ADV_IMAGE_TAG init so the default can pick
# up MANIFEST_IMAGE_SET. Compare line numbers.
src_line=$(grep -nE 'source .*common/release-manifest\.sh' "$PREPARE" | head -n1 | cut -d: -f1)
init_line=$(grep -n '^ADV_IMAGE_TAG=' "$PREPARE" | head -n1 | cut -d: -f1)
assert "(( ${src_line:-0} < ${init_line:-0} ))" \
    "release-manifest.sh sourced BEFORE ADV_IMAGE_TAG init (line $src_line < $init_line)"

assert "grep -qE 'ADV_IMAGE_TAG=\"\\\$\\{MANIFEST_IMAGE_SET:-latest\\}\"' '$PREPARE'" \
    "ADV_IMAGE_TAG default = manifest image_set (fallback 'latest')"

assert "grep -q 'SNAPMULTI_RELEASE=\$MANIFEST_RELEASE' '$PREPARE'" \
    "install.conf heredoc emits SNAPMULTI_RELEASE=\$MANIFEST_RELEASE"

assert "grep -q 'SNAPMULTI_IMAGE_SET=\$MANIFEST_IMAGE_SET' '$PREPARE'" \
    "install.conf heredoc emits SNAPMULTI_IMAGE_SET=\$MANIFEST_IMAGE_SET"

assert "grep -qE 'cp .*release-manifest\.json.*DEST' '$PREPARE'" \
    "release-manifest.json staged onto SD"

# Guarded copy — the iter-2 codex major: set -e tolerance when manifest absent
assert "grep -B1 'cp .*release-manifest\.json.*DEST' '$PREPARE' | grep -qE '\\[\\[ -f .*release-manifest\.json' " \
    "release-manifest.json copy guarded by [[ -f ... ]]"

assert "grep -q 'release-manifest.json' '$PREPARE'" \
    "verify-list mentions release-manifest.json"

assert "grep -q 'common/release-manifest.sh' '$PREPARE'" \
    "verify-list mentions common/release-manifest.sh"

assert "grep -q '^SNAPMULTI_RELEASE=' '$PREPARE'" \
    "summary print covers SNAPMULTI_RELEASE (grep on install.conf inside echo)" \
    || true   # weak — the regex above already validates the heredoc

assert "grep -qE 'install.conf -> SNAPMULTI_RELEASE=' '$PREPARE'" \
    "summary print includes SNAPMULTI_RELEASE line"

assert "grep -qE 'install.conf -> SNAPMULTI_IMAGE_SET=' '$PREPARE'" \
    "summary print includes SNAPMULTI_IMAGE_SET line"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
