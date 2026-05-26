#!/usr/bin/env bash
# Regression test for firstboot.sh's release-identity precedence.
#
# As of fix/release-identity-ssot, release-manifest.json on the SD is the
# only source for SNAPMULTI_RELEASE + SNAPMULTI_IMAGE_SET. install.conf no
# longer carries those keys. IMAGE_TAG keeps install.conf as its operator-
# override channel (e.g. pin to :dev while the manifest stays on a release
# tag); when unset, it falls back to manifest image_set, then 'latest'.
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
# cases stay one-liner / readable. Mirrors firstboot.sh post fix/release-
# identity-ssot: release identity from manifest only; install.conf carries
# only the IMAGE_TAG operator override.
derive_for_test() {
    local boot="$1"
    parse_release_manifest "$boot/release-manifest.json"
    local _explicit_image_tag
    _explicit_image_tag=$(read_install_conf_key "$boot/install.conf" IMAGE_TAG)
    SNAPMULTI_RELEASE="$MANIFEST_RELEASE"
    SNAPMULTI_IMAGE_SET="$MANIFEST_IMAGE_SET"
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

# Case (c) — install.conf SNAPMULTI_IMAGE_SET is now IGNORED (key dropped
# from install.conf SSOT cleanup). With no manifest, IMAGE_TAG falls back
# to 'latest'.
mkdir -p "$TMP/c"
cat > "$TMP/c/install.conf" <<'EOF'
INSTALL_TYPE=server
SNAPMULTI_IMAGE_SET=0.7.5
EOF
derive_for_test "$TMP/c"
assert "[[ '$IMAGE_TAG' == 'latest' ]]" "(c) install.conf SNAPMULTI_IMAGE_SET ignored → IMAGE_TAG=latest (no manifest)"
assert "[[ -z '$SNAPMULTI_IMAGE_SET' ]]" "(c) install.conf SNAPMULTI_IMAGE_SET ignored → empty (manifest is SSOT)"

# Case (d): install.conf IMAGE_TAG=dev — operator override wins. SNAPMULTI_
# IMAGE_SET still from manifest (here absent → empty).
mkdir -p "$TMP/d"
cat > "$TMP/d/install.conf" <<'EOF'
INSTALL_TYPE=server
IMAGE_TAG=dev
EOF
derive_for_test "$TMP/d"
assert "[[ '$IMAGE_TAG' == 'dev' ]]" "(d) IMAGE_TAG=dev (operator override) preserved"
assert "[[ -z '$SNAPMULTI_IMAGE_SET' ]]" "(d) no manifest → SNAPMULTI_IMAGE_SET empty"

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
assert "[[ '$IMAGE_TAG' == '0.7.7' ]]" "(f) manifest only → IMAGE_TAG=0.7.7"
assert "[[ '$SNAPMULTI_RELEASE' == 'v0.7.7' ]]" "(f) manifest only → SNAPMULTI_RELEASE=v0.7.7"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.7' ]]" "(f) manifest only → SNAPMULTI_IMAGE_SET=0.7.7"

# Case (g) — manifest is the SSOT; install.conf SNAPMULTI_RELEASE is NO
# LONGER a shadow override. Manifest always wins.
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
assert "[[ '$SNAPMULTI_RELEASE' == 'v0.7.7' ]]" "(g) manifest wins — install.conf SNAPMULTI_RELEASE ignored (SSOT)"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.7' ]]" "(g) manifest wins for SNAPMULTI_IMAGE_SET too"

# Case (h): IMAGE_TAG override on top of manifest — operator pins to :dev
# while server keeps the manifest release identity. Common workflow.
mkdir -p "$TMP/h"
cat > "$TMP/h/install.conf" <<'EOF'
INSTALL_TYPE=server
IMAGE_TAG=dev
EOF
cat > "$TMP/h/release-manifest.json" <<'EOF'
{
  "snapmulti_release": "v0.7.9",
  "image_set": "0.7.9",
  "requires_image_rebuild": false
}
EOF
derive_for_test "$TMP/h"
assert "[[ '$IMAGE_TAG' == 'dev' ]]" "(h) IMAGE_TAG=dev override preserved with manifest present"
assert "[[ '$SNAPMULTI_RELEASE' == 'v0.7.9' ]]" "(h) SNAPMULTI_RELEASE still from manifest"
assert "[[ '$SNAPMULTI_IMAGE_SET' == '0.7.9' ]]" "(h) SNAPMULTI_IMAGE_SET still from manifest"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
