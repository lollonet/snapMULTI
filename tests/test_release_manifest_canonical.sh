#!/usr/bin/env bash
# Asserts release-manifest.json is committed in canonical pretty-printed
# multi-line JSON format. The parser at scripts/common/release-manifest.sh
# is line-oriented by design and would break on compact JSON; this test
# catches future edits that reformat the manifest into a single line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../release-manifest.json"

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

echo "## release-manifest.json canonical format"

assert "[[ -f '$MANIFEST' ]]" \
    "release-manifest.json exists at repo root"

assert "command -v jq >/dev/null" \
    "jq available for canonical-format check"

# jq --indent 2 emits canonical multi-line; we DELIBERATELY do not use
# `-S` (sort keys) here because the manifest is committed in reading
# order (release first, image_set second, rebuild flag last) — that
# matches the mental model and the precedence-chain documentation. The
# parser is regex-based and key-order-independent, so this is a
# stylistic invariant, not a correctness one.
assert "diff <(jq --indent 2 . '$MANIFEST') '$MANIFEST' >/dev/null" \
    "manifest matches jq --indent 2 . output (canonical multi-line)"

assert "[[ \$(wc -l < '$MANIFEST') -ge 4 ]]" \
    "manifest has at least 4 lines (opening brace + 3 keys + closing brace)"

assert "jq -e 'has(\"snapmulti_release\")' '$MANIFEST' >/dev/null" \
    "manifest has snapmulti_release key"

assert "jq -e 'has(\"image_set\")' '$MANIFEST' >/dev/null" \
    "manifest has image_set key"

assert "jq -e 'has(\"requires_image_rebuild\")' '$MANIFEST' >/dev/null" \
    "manifest has requires_image_rebuild key"

assert "[[ \$(jq -r .snapmulti_release '$MANIFEST') =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]" \
    "snapmulti_release matches vX.Y.Z"

assert "[[ \$(jq -r .image_set '$MANIFEST') =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]" \
    "image_set matches X.Y.Z (no v prefix — Docker tag format)"

assert "[[ \$(jq -r '.requires_image_rebuild | type' '$MANIFEST') == 'boolean' ]]" \
    "requires_image_rebuild is JSON boolean (not string)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
