#!/usr/bin/env bash
# Unit tests for derive_image_tag() — pure precedence-chain logic.
#
# Truth table:
#   explicit non-empty   → explicit
#   explicit empty/ws    → fallback
#   both empty           → "latest"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/common/release-manifest.sh"

# shellcheck source=../scripts/common/release-manifest.sh
source "$LIB"

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

echo "## derive_image_tag"

# (a) explicit non-empty + fallback non-empty → explicit wins
result=$(derive_image_tag "0.7.5" "0.7.6")
assert "[[ '$result' == '0.7.5' ]]" "(a) explicit='0.7.5' fallback='0.7.6' → '0.7.5'"

# (b) explicit empty + fallback non-empty → fallback
result=$(derive_image_tag "" "0.7.6")
assert "[[ '$result' == '0.7.6' ]]" "(b) explicit='' fallback='0.7.6' → '0.7.6'"

# (c) both empty → 'latest'
result=$(derive_image_tag "" "")
assert "[[ '$result' == 'latest' ]]" "(c) explicit='' fallback='' → 'latest'"

# (d) explicit='dev' (non-version string) + fallback='0.7.6' → 'dev'
result=$(derive_image_tag "dev" "0.7.6")
assert "[[ '$result' == 'dev' ]]" "(d) explicit='dev' fallback='0.7.6' → 'dev' (override wins)"

# (e) explicit whitespace-only + fallback non-empty → fallback
result=$(derive_image_tag "   " "0.7.6")
assert "[[ '$result' == '0.7.6' ]]" "(e) explicit='   ' fallback='0.7.6' → '0.7.6' (whitespace treated as empty)"

# Bonus: explicit with surrounding whitespace → trimmed
result=$(derive_image_tag "  v0.8.0  " "0.7.6")
assert "[[ '$result' == 'v0.8.0' ]]" "(bonus) explicit='  v0.8.0  ' → trimmed to 'v0.8.0'"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
