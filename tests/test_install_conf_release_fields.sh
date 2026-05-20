#!/usr/bin/env bash
# Static + behavioural checks on deploy.sh and client setup.sh for the
# 3-key release-identity persistence block (SNAPMULTI_RELEASE,
# SNAPMULTI_IMAGE_SET, IMAGE_TAG) introduced in #433.
#
# Contracts asserted:
#   - both files source scripts/common/release-manifest.sh (guarded)
#   - both have a derive_image_tag call to coerce IMAGE_TAG
#   - both persist SNAPMULTI_RELEASE + SNAPMULTI_IMAGE_SET as REAL keys
#     (not comments) in the deployed .env
#   - deploy.sh has an inline fallback shim for derive_image_tag when
#     the helper is absent (iter-2 codex major)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY="$SCRIPT_DIR/../scripts/deploy.sh"
SETUP="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

echo "## deploy.sh release-identity wiring"

assert "[[ -f '$DEPLOY' ]]" "deploy.sh exists"

assert "grep -qE 'source .*common/release-manifest\.sh' '$DEPLOY'" \
    "deploy.sh sources release-manifest.sh"

# Guarded source (iter-2 codex major)
assert "grep -B3 'source .*common/release-manifest\.sh' '$DEPLOY' | grep -qE '\\[\\[ -f' " \
    "deploy.sh source guarded by [[ -f ... ]]"

# Inline fallback for derive_image_tag (iter-2 codex major)
assert "grep -A20 'common/release-manifest\.sh' '$DEPLOY' | grep -qE 'derive_image_tag\\(\\)' " \
    "deploy.sh has inline derive_image_tag fallback shim"

assert "grep -q 'derive_image_tag' '$DEPLOY'" \
    "deploy.sh calls derive_image_tag"

assert "grep -qE 'persist_env_kv .*SNAPMULTI_RELEASE' '$DEPLOY'" \
    "deploy.sh persists SNAPMULTI_RELEASE as a real .env key"

assert "grep -qE 'persist_env_kv .*SNAPMULTI_IMAGE_SET' '$DEPLOY'" \
    "deploy.sh persists SNAPMULTI_IMAGE_SET as a real .env key"

assert "grep -qE 'persist_env_kv .*IMAGE_TAG' '$DEPLOY'" \
    "deploy.sh persists IMAGE_TAG via the same helper"

echo
echo "## client/common/scripts/setup.sh release-identity wiring"

assert "[[ -f '$SETUP' ]]" "client setup.sh exists"

assert "grep -qE 'source .*release-manifest\.sh' '$SETUP'" \
    "setup.sh sources release-manifest.sh"

# Guarded source via the existing COMMON_MODULE_DIR pattern
assert "grep -B1 'source.*release-manifest\.sh' '$SETUP' | grep -qE '\\[\\[ -f' " \
    "setup.sh source guarded by [[ -f ... ]]"

assert "grep -qE '\\[\"SNAPMULTI_RELEASE\"\\]=' '$SETUP'" \
    "setup.sh env_vars array includes SNAPMULTI_RELEASE"

assert "grep -qE '\\[\"SNAPMULTI_IMAGE_SET\"\\]=' '$SETUP'" \
    "setup.sh env_vars array includes SNAPMULTI_IMAGE_SET"

assert "grep -q 'derive_image_tag' '$SETUP'" \
    "setup.sh uses derive_image_tag for IMAGE_TAG coherence"

# Fall-through to legacy ${IMAGE_TAG:-latest} when helper absent
assert "grep -qE 'declare -F derive_image_tag' '$SETUP'" \
    "setup.sh has runtime fallback when derive_image_tag missing"

echo
echo "## End-to-end env-write simulation"

# Stage a synthetic deploy.sh persist_env_kv invocation in a tmp dir.
# deploy.sh uses GNU sed -i syntax (no extension arg) which is the
# production target (Linux/Pi). BSD sed (macOS dev box) needs `sed -i ''`
# — skip the runtime simulation on macOS with an info line; the static
# contracts above already validated the function shape on every platform.
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "  INFO: skipping runtime simulation on macOS (deploy.sh uses GNU sed -i)"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    ENV_FILE="$TMP/.env"
    touch "$ENV_FILE"

    # Extract persist_env_kv definition from deploy.sh and source it in
    # isolation (bash function definition fits in a few lines, no other
    # globals required).
    persist_def=$(awk '/persist_env_kv\(\) \{/,/^    \}$/' "$DEPLOY")
    eval "$persist_def"

    persist_env_kv "SNAPMULTI_RELEASE" "v0.7.7"
    persist_env_kv "SNAPMULTI_IMAGE_SET" "0.7.7"
    persist_env_kv "IMAGE_TAG" "0.7.7"

    assert "grep -q '^SNAPMULTI_RELEASE=v0.7.7$' '$ENV_FILE'" \
        "persist_env_kv writes SNAPMULTI_RELEASE on first call"
    assert "grep -q '^SNAPMULTI_IMAGE_SET=0.7.7$' '$ENV_FILE'" \
        "persist_env_kv writes SNAPMULTI_IMAGE_SET on first call"
    assert "grep -q '^IMAGE_TAG=0.7.7$' '$ENV_FILE'" \
        "persist_env_kv writes IMAGE_TAG on first call"

    # Idempotence — second call with different value updates in place.
    persist_env_kv "IMAGE_TAG" "dev"
    count=$(grep -c '^IMAGE_TAG=' "$ENV_FILE")
    assert "[[ '$count' -eq 1 ]]" \
        "persist_env_kv idempotent — IMAGE_TAG line not duplicated"
    assert "grep -q '^IMAGE_TAG=dev$' '$ENV_FILE'" \
        "persist_env_kv overwrites in place — IMAGE_TAG=dev"
fi

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
