#!/usr/bin/env bash
# Unit tests for parse_release_manifest() in
# scripts/common/release-manifest.sh.
#
# Cases (per the iter-2 plan):
#   (a) valid 3-key → all set
#   (b) missing file → empty, return 0
#   (c) missing one key → others still set
#   (d) extra unrelated keys → 3 set, others ignored
#   (e) image_set_override only (no image_set) → MANIFEST_IMAGE_SET empty
#   (f) both image_set and image_set_override → image_set wins
#   (g) truncated JSON (missing closing brace) → regex still matches
#   (h-i-j) requires_image_rebuild = true / false / garbage → normalised

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

echo "## parse_release_manifest"

# Case (a): valid 3-key
cat > "$TMP/a.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "0.7.7",
  "requires_image_rebuild": true
}
EOF
parse_release_manifest "$TMP/a.json"
assert "[[ '$MANIFEST_RELEASE' == 'v0.7.7' ]]" "(a) snapmulti_release captured"
assert "[[ '$MANIFEST_IMAGE_SET' == '0.7.7' ]]" "(a) image_set captured"
assert "[[ '$MANIFEST_REQUIRES_IMAGE_REBUILD' == 'true' ]]" "(a) requires_image_rebuild=true normalised"

# Case (b): missing file
parse_release_manifest "$TMP/nonexistent.json"
assert "[[ -z '$MANIFEST_RELEASE' ]]" "(b) missing file → MANIFEST_RELEASE empty"
assert "[[ -z '$MANIFEST_IMAGE_SET' ]]" "(b) missing file → MANIFEST_IMAGE_SET empty"
assert "[[ -z '$MANIFEST_REQUIRES_IMAGE_REBUILD' ]]" "(b) missing file → REQUIRES_IMAGE_REBUILD empty"
# Verify return code is 0 even with missing file
parse_release_manifest "$TMP/nonexistent.json" && rc=0 || rc=$?
assert "[[ $rc -eq 0 ]]" "(b) missing file → return 0 (set -e safe)"

# Case (c): missing one key (no image_set)
cat > "$TMP/c.json" <<'EOF'
{
  "snapmulti_release": "v0.7.5",
  "requires_image_rebuild": false
}
EOF
parse_release_manifest "$TMP/c.json"
assert "[[ '$MANIFEST_RELEASE' == 'v0.7.5' ]]" "(c) snapmulti_release set despite missing image_set"
assert "[[ -z '$MANIFEST_IMAGE_SET' ]]" "(c) missing image_set → empty"
assert "[[ '$MANIFEST_REQUIRES_IMAGE_REBUILD' == 'false' ]]" "(c) requires_image_rebuild=false captured"

# Case (d): extra unrelated keys
cat > "$TMP/d.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "0.7.7",
  "requires_image_rebuild": true,
  "unrelated_key": "ignored",
  "another": 42
}
EOF
parse_release_manifest "$TMP/d.json"
assert "[[ '$MANIFEST_RELEASE' == 'v0.7.7' ]]" "(d) extra keys don't affect snapmulti_release"
assert "[[ '$MANIFEST_IMAGE_SET' == '0.7.7' ]]" "(d) extra keys don't affect image_set"

# Case (e): image_set_override only (no image_set) — must not cross-match
cat > "$TMP/e.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set_override": "fake-value",
  "requires_image_rebuild": true
}
EOF
parse_release_manifest "$TMP/e.json"
assert "[[ -z '$MANIFEST_IMAGE_SET' ]]" "(e) image_set_override does NOT cross-match into image_set"

# Case (f): both image_set AND image_set_override — image_set wins
cat > "$TMP/f.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "real-value",
  "image_set_override": "decoy",
  "requires_image_rebuild": true
}
EOF
parse_release_manifest "$TMP/f.json"
assert "[[ '$MANIFEST_IMAGE_SET' == 'real-value' ]]" "(f) image_set wins over image_set_override"

# Case (g): truncated JSON (missing closing brace) — parser still extracts
cat > "$TMP/g.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "0.7.7",
EOF
parse_release_manifest "$TMP/g.json" && rc=0 || rc=$?
assert "[[ $rc -eq 0 ]]" "(g) truncated JSON → parser returns 0 (no abort)"
assert "[[ '$MANIFEST_RELEASE' == 'v0.7.7' ]]" "(g) truncated JSON → release still extracted"
assert "[[ '$MANIFEST_IMAGE_SET' == '0.7.7' ]]" "(g) truncated JSON → image_set still extracted"

# Case (h): requires_image_rebuild=true
cat > "$TMP/h.json" <<'EOF'
{
  "requires_image_rebuild": true
}
EOF
parse_release_manifest "$TMP/h.json"
assert "[[ '$MANIFEST_REQUIRES_IMAGE_REBUILD' == 'true' ]]" "(h) requires_image_rebuild=true → 'true'"

# Case (i): requires_image_rebuild=false
cat > "$TMP/i.json" <<'EOF'
{
  "requires_image_rebuild": false
}
EOF
parse_release_manifest "$TMP/i.json"
assert "[[ '$MANIFEST_REQUIRES_IMAGE_REBUILD' == 'false' ]]" "(i) requires_image_rebuild=false → 'false'"

# Case (j): requires_image_rebuild=garbage (string instead of bool)
cat > "$TMP/j.json" <<'EOF'
{
  "requires_image_rebuild": "yes"
}
EOF
parse_release_manifest "$TMP/j.json"
assert "[[ -z '$MANIFEST_REQUIRES_IMAGE_REBUILD' ]]" "(j) requires_image_rebuild=\"yes\" → empty (not literal true/false)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
