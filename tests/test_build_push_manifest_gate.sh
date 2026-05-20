#!/usr/bin/env bash
# Static checks on .github/workflows/build-push.yml for the
# release-manifest gate introduced in #433.
#
# Contracts asserted:
#   - workflow_dispatch input `force_rebuild` present
#   - top-level `gate` job exists, reads release-manifest.json, validates
#     image_set shape + requires_image_rebuild literal
#   - gate produces should_rebuild + image_set + release outputs
#   - gate's verify_hub step runs ONLY when should_rebuild=false and uses
#     `docker manifest inspect` against all 5 production images
#   - `build` job has `needs: gate` AND
#     `if: needs.gate.outputs.should_rebuild == 'true'`
#   - `build` job's image-tag computation reads gate.outputs.image_set
#     (NOT github.ref_name) so script-only releases publish the
#     manifest's image_set, not the just-cut tag

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$SCRIPT_DIR/../.github/workflows/build-push.yml"

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

echo "## build-push.yml manifest gate"

assert "[[ -f '$WF' ]]" "workflow file exists"

assert "grep -qE '^      force_rebuild:' '$WF'" \
    "workflow_dispatch input force_rebuild present"

assert "grep -qE '^  gate:' '$WF'" \
    "top-level gate job exists"

# gate must come BEFORE build in the file (so needs: gate resolves)
gate_line=$(grep -n '^  gate:' "$WF" | head -n1 | cut -d: -f1)
build_line=$(grep -n '^  build:' "$WF" | head -n1 | cut -d: -f1)
assert "(( ${gate_line:-9999} < ${build_line:-0} ))" \
    "gate job declared before build job (line $gate_line < $build_line)"

assert "grep -qE \"jq -r .'?\\\\.image_set'? release-manifest.json\" '$WF'" \
    "gate reads image_set from release-manifest.json"

assert "grep -qE \"jq -r .'?\\\\.requires_image_rebuild'? release-manifest.json\" '$WF'" \
    "gate reads requires_image_rebuild from release-manifest.json"

# Codex iter-2 major: validate shape BEFORE using
assert "grep -qE '\\[\\[ ! \"\\\$IMAGE_SET\" =~ \\^\\[0-9\\]\\+' '$WF'" \
    "gate validates image_set regex (X.Y.Z) before use"

assert "grep -qE '\\\$REBUILD\" != \"true\" && \"\\\$REBUILD\" != \"false\"' '$WF'" \
    "gate validates requires_image_rebuild is literal true/false"

assert "grep -qE 'should_rebuild=\\\$SHOULD_REBUILD' '$WF'" \
    "gate emits should_rebuild output"

# Docker Hub existence check — iter-1 blocker fix
assert "grep -q 'docker manifest inspect' '$WF'" \
    "gate verifies images via docker manifest inspect (closes iter-1 blocker)"

assert "grep -q 'lollonet/snapmulti-server' '$WF'" \
    "gate verifies snapmulti-server image"
assert "grep -q 'lollonet/snapmulti-airplay' '$WF'" \
    "gate verifies snapmulti-airplay image"
assert "grep -q 'lollonet/snapmulti-mpd' '$WF'" \
    "gate verifies snapmulti-mpd image"
assert "grep -q 'lollonet/snapmulti-metadata' '$WF'" \
    "gate verifies snapmulti-metadata image"
assert "grep -q 'lollonet/snapmulti-tidal' '$WF'" \
    "gate verifies snapmulti-tidal image"

# verify_hub runs ONLY when should_rebuild=false (the if: line lives a
# few lines above the docker manifest inspect command — grep the full
# Verify-Hub step body for the conditional).
assert "awk '/name: Verify image set on Docker Hub/,/docker manifest inspect/' '$WF' | grep -qE \"should_rebuild == 'false'\"" \
    "gate verify_hub conditioned on should_rebuild=='false'"

# Error message pointing operator to force_rebuild
assert "grep -q 'force_rebuild=true' '$WF'" \
    "gate error message documents the force_rebuild bypass"

# build job wired to gate
assert "grep -qE '^    needs: gate' '$WF'" \
    "build job has needs: gate"

assert "grep -qE \"needs.gate.outputs.should_rebuild == 'true'\" '$WF'" \
    "build job conditioned on gate.outputs.should_rebuild=='true'"

# image_set, not GITHUB_REF, for tagged-release tag derivation
assert "grep -qE 'GATE_IMAGE_SET.*needs.gate.outputs.image_set' '$WF'" \
    "build derives image tag from gate.outputs.image_set (not github.ref_name)"

# Tagged-release branch uses GATE_IMAGE_SET, not the stripped GITHUB_REF
assert "grep -qE 'tag=\\\$GATE_IMAGE_SET' '$WF'" \
    "tagged-release branch uses GATE_IMAGE_SET for the published tag"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"

[[ $fail -eq 0 ]]
