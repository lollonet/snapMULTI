#!/usr/bin/env bash
# Static checks on scripts/prepare-sd.sh for release-manifest wiring.
#
# We deliberately do NOT run prepare-sd.sh end-to-end (it needs root,
# a real boot partition, cloud-init patching, etc.). Instead we grep
# the script for the wiring contracts:
#   - manifest helper sourced BEFORE ADV_IMAGE_TAG init
#   - parse_release_manifest invoked with the canonical path
#   - ADV_IMAGE_TAG default = $MANIFEST_IMAGE_SET (with 'latest' fallback)
#   - install.conf heredoc does NOT emit SNAPMULTI_RELEASE / SNAPMULTI_IMAGE_SET
#     (SSOT is release-manifest.json on the SD — see fix/release-identity-ssot)
#   - release-manifest.json staged onto SD (guarded copy)
#   - verify-list includes release-manifest.json + common/release-manifest.sh
#   - summary print sources release identity from manifest, not install.conf

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

# SSOT contract — install.conf heredoc MUST NOT carry the manifest values.
# Duplicating them would let a stale install.conf shadow a fresh manifest
# the next time prepare-sd.sh runs against the same SD (the bug fix/release-
# identity-ssot closes). The heredoc lives between the install.conf opener
# and its `EOF` terminator; we scope the search to that block.
heredoc_block=$(awk '/cat > "\$DEST\/install\.conf" <<EOF/,/^EOF$/' "$PREPARE")
assert "! grep -q '^SNAPMULTI_RELEASE=' <<<\"\$heredoc_block\"" \
    "install.conf heredoc does NOT emit SNAPMULTI_RELEASE (SSOT is release-manifest.json)"

assert "! grep -q '^SNAPMULTI_IMAGE_SET=' <<<\"\$heredoc_block\"" \
    "install.conf heredoc does NOT emit SNAPMULTI_IMAGE_SET (SSOT is release-manifest.json)"

assert "grep -qE 'cp .*release-manifest\.json.*DEST' '$PREPARE'" \
    "release-manifest.json staged onto SD"

# Guarded copy — set -e tolerance when manifest absent
assert "grep -B1 'cp .*release-manifest\.json.*DEST' '$PREPARE' | grep -qE '\\[\\[ -f .*release-manifest\.json' " \
    "release-manifest.json copy guarded by [[ -f ... ]]"

assert "grep -q 'release-manifest.json' '$PREPARE'" \
    "verify-list mentions release-manifest.json"

assert "grep -q 'common/release-manifest.sh' '$PREPARE'" \
    "verify-list mentions common/release-manifest.sh"

assert "grep -qE 'release-manifest -> SNAPMULTI_RELEASE=' '$PREPARE'" \
    "summary print sources SNAPMULTI_RELEASE from manifest (not install.conf)"

assert "grep -qE 'release-manifest -> SNAPMULTI_IMAGE_SET=' '$PREPARE'" \
    "summary print sources SNAPMULTI_IMAGE_SET from manifest (not install.conf)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
