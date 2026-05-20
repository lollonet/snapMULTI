#!/usr/bin/env bash
# Regression test for firstboot.sh's release-identity precedence chains.
# 6 scenarios from the iter-2 plan that protect the BLOCKER fix
# (install.conf SNAPMULTI_IMAGE_SET in the IMAGE_TAG chain) and the
# critical backward-compat invariant (legacy IMAGE_TAG-only installs
# continue to work unchanged).
#
# This test exercises the parser library directly with synthetic
# install.conf + release-manifest.json combinations, then asserts the
# exported IMAGE_TAG / SNAPMULTI_RELEASE / SNAPMULTI_IMAGE_SET match
# what firstboot.sh would produce. We do NOT spawn firstboot.sh itself
# (it runs systemctl, installs Docker, etc.) — the assertion is on the
# precedence chain logic.

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

# Reproduce firstboot.sh's chain logic in a single function so test
# cases stay one-liner / readable. Mirrors firstboot.sh:s7 exactly.
derive_for_test() {
    local boot="$1"
    parse_release_manifest "$boot/release-manifest.json"
    local _explicit_release _explicit_image_set _explicit_image_tag
    _explicit_release=$(read_install_conf_key "$boot/install.conf" SNAPMULTI_RELEASE)
    _explicit_image_set=$(read_install_conf_key "$boot/install.conf" SNAPMULTI_IMAGE_SET)
    _explicit_image_tag=$(read_install_conf_key "$boot/install.conf" IMAGE_TAG)
    SNAPMULTI_RELEASE="${_explicit_release:-$MANIFEST_RELEASE}"
    SNAPMULTI_IMAGE_SET="${_explicit_image_set:-$MANIFEST_IMAGE_SET}"
    IMAGE_TAG=$(derive_image_tag "$_explicit_image_tag" "$SNAPMULTI_IMAGE_SET")
}

echo "## firstboot.sh release-identity precedence (chains A/B/C)"

# Case (a): legacy install.conf with IMAGE_TAG only, no manifest
mkdir -p "$TMP/a"
cat > "$TMP/a/install.conf" <<'EOF'
INSTALL_TYPE=server
IMAGE_TAG=0.7.4
EOF
derive_for_test "$TMP/a"
assert "[[ '$IMAGE_TAG' == '0.7.4' ]]" "(a) legacy IMAGE_TAG=0.7.4 only → IMAGE_TAG=0.7.4"
assert "[[ -z '$SNAPMULTI_RELEASE' ]]" "(a) no manifest, no SNAPMULTI_RELEASE → empty"
assert "[[ -z '$SNAPMULTI_IMAGE_SET' ]]" "(a) no manifest, no SNAPMULTI_IMAGE_SET → empty"

# Case (b): legacy install.conf with IMAGE_TAG=latest, no manifest
mkdir -p "$TMP/b"
cat > "$TMP/b/install.conf" <<'EOF'
INSTALL_TYPE=server
IMAGE_TAG=latest
EOF
derive_for_test "$TMP/b"
assert "[[ '$IMAGE_TAG' == 'latest' ]]" "(b) legacy IMAGE_TAG=latest only → IMAGE_TAG=latest"

# Case (c) — BLOCKER FIX: install.conf SNAPMULTI_IMAGE_SET=0.7.5,
# no IMAGE_TAG, no manifest → IMAGE_TAG=0.7.5 (the new chain (A) step)
mkdir -p "$TMP/c"
cat > "$TMP/c/install.conf" <<'EOF'
INSTALL_TYPE=server
SNAPMULTI_IMAGE_SET=0.7.5
EOF
derive_for_test "$TMP/c"
assert "[[ '$IMAGE_TAG' == '0.7.5' ]]" "(c) BLOCKER: install.conf SNAPMULTI_IMAGE_SET=0.7.5 → IMAGE_TAG=0.7.5"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.5' ]]" "(c) install.conf SNAPMULTI_IMAGE_SET propagated"

# Case (d): install.conf SNAPMULTI_IMAGE_SET=0.7.5 + IMAGE_TAG=dev
# → IMAGE_TAG=dev (operator override wins over image_set)
mkdir -p "$TMP/d"
cat > "$TMP/d/install.conf" <<'EOF'
INSTALL_TYPE=server
SNAPMULTI_IMAGE_SET=0.7.5
IMAGE_TAG=dev
EOF
derive_for_test "$TMP/d"
assert "[[ '$IMAGE_TAG' == 'dev' ]]" "(d) IMAGE_TAG=dev wins over SNAPMULTI_IMAGE_SET=0.7.5"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.5' ]]" "(d) SNAPMULTI_IMAGE_SET=0.7.5 still surfaced separately"

# Case (e): install.conf absent, manifest absent → IMAGE_TAG=latest
mkdir -p "$TMP/e"
derive_for_test "$TMP/e"
assert "[[ '$IMAGE_TAG' == 'latest' ]]" "(e) all empty → IMAGE_TAG=latest"
assert "[[ -z '$SNAPMULTI_RELEASE' ]]" "(e) all empty → SNAPMULTI_RELEASE empty"

# Case (f): install.conf absent, manifest present → IMAGE_TAG from manifest
mkdir -p "$TMP/f"
cat > "$TMP/f/release-manifest.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "0.7.7",
  "requires_image_rebuild": true
}
EOF
derive_for_test "$TMP/f"
assert "[[ '$IMAGE_TAG' == '0.7.7' ]]" "(f) manifest only → IMAGE_TAG=0.7.7 (chain A fallback)"
assert "[[ '$SNAPMULTI_RELEASE' == 'v0.7.7' ]]" "(f) manifest only → SNAPMULTI_RELEASE=v0.7.7"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.7' ]]" "(f) manifest only → SNAPMULTI_IMAGE_SET=0.7.7"

# Bonus: install.conf SNAPMULTI_RELEASE override beats manifest
mkdir -p "$TMP/g"
cat > "$TMP/g/install.conf" <<'EOF'
INSTALL_TYPE=server
SNAPMULTI_RELEASE=v0.8.0-pre
EOF
cat > "$TMP/g/release-manifest.json" <<'EOF'
{
  "snapmulti_release": "v0.7.7",
  "image_set": "0.7.7",
  "requires_image_rebuild": true
}
EOF
derive_for_test "$TMP/g"
assert "[[ '$SNAPMULTI_RELEASE' == 'v0.8.0-pre' ]]" "(g) install.conf SNAPMULTI_RELEASE overrides manifest (chain B)"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.7' ]]" "(g) but SNAPMULTI_IMAGE_SET still from manifest (chain C separate)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
