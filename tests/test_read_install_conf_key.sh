#!/usr/bin/env bash
# Unit tests for read_install_conf_key() — first-match-wins reader
# matching firstboot.sh:70's existing grep -m1 convention.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/common/release-manifest.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

echo "## read_install_conf_key"

# (a) key present → value
cat > "$TMP/conf" <<'EOF'
INSTALL_TYPE=server
IMAGE_TAG=v0.7.7
SNAPMULTI_RELEASE=v0.7.7
SNAPMULTI_IMAGE_SET=0.7.7
EOF
value=$(read_install_conf_key "$TMP/conf" IMAGE_TAG)
assert "[[ '$value' == 'v0.7.7' ]]" "(a) IMAGE_TAG=v0.7.7 → 'v0.7.7'"

value=$(read_install_conf_key "$TMP/conf" SNAPMULTI_IMAGE_SET)
assert "[[ '$value' == '0.7.7' ]]" "(a) SNAPMULTI_IMAGE_SET=0.7.7 → '0.7.7'"

# (b) key absent
value=$(read_install_conf_key "$TMP/conf" NONEXISTENT_KEY)
assert "[[ -z '$value' ]]" "(b) absent key → empty"

# (c) file absent → empty, return 0
value=$(read_install_conf_key "$TMP/nonexistent" IMAGE_TAG && echo 'rc0' || echo "rc$?")
assert "[[ '$value' == 'rc0' ]]" "(c) absent file → empty + return 0 (set -e safe)"

# (d) duplicate key → FIRST occurrence wins (grep -m1 convention)
cat > "$TMP/dup" <<'EOF'
IMAGE_TAG=first-value
INSTALL_TYPE=server
IMAGE_TAG=second-value
EOF
value=$(read_install_conf_key "$TMP/dup" IMAGE_TAG)
assert "[[ '$value' == 'first-value' ]]" "(d) duplicate IMAGE_TAG → first match wins"

# (e) key with comments above + surrounding whitespace
cat > "$TMP/ws" <<'EOF'
# This is a comment
# Another comment about IMAGE_TAG
IMAGE_TAG=clean-value
EOF
value=$(read_install_conf_key "$TMP/ws" IMAGE_TAG)
assert "[[ '$value' == 'clean-value' ]]" "(e) key with comments above → value extracted cleanly"

# Bonus: trailing CR (DOS line endings) stripped
printf 'IMAGE_TAG=cr-value\r\n' > "$TMP/cr"
value=$(read_install_conf_key "$TMP/cr" IMAGE_TAG)
assert "[[ '$value' == 'cr-value' ]]" "(bonus) trailing CR (\\r) stripped"

# Bonus: value with = inside it (e.g. SMB_PASS=foo=bar) — full value captured
echo 'PASSWORD=foo=bar=baz' > "$TMP/equals"
value=$(read_install_conf_key "$TMP/equals" PASSWORD)
assert "[[ '$value' == 'foo=bar=baz' ]]" "(bonus) value with embedded '=' fully captured"

# Bonus: empty path
value=$(read_install_conf_key "" IMAGE_TAG && echo 'rc0' || echo "rc$?")
assert "[[ '$value' == 'rc0' ]]" "(bonus) empty path → empty + return 0"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
