#!/usr/bin/env bash
# Sourcing-invariant check for scripts/prepare-sd.sh.
#
# Why this exists: the other prepare-sd tests are static grep checks
# against the source text. They cannot catch a missing `source` line —
# the kind of bug where the manifest arrays (STAGING_*) are referenced
# by name but the file defining them is never sourced. At runtime,
# `set -euo pipefail` aborts on the first `${!ARR[@]}` expansion. PR
# #578 review (round 3) flagged this exact CRITICAL.
#
# Strategy: for every `${STAGING_*[...]}` or `${!STAGING_*[@]}` array
# reference in prepare-sd.sh, locate the defining file and assert that
# prepare-sd.sh sources it. Same for `install_profile_*` predicates and
# `stage_manifest_entry`.
#
# This is purely static (no bash sandbox needed) but catches the runtime
# class of bug that pure-text greps miss.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREPARE_SD="$REPO_ROOT/scripts/prepare-sd.sh"
COMMON_DIR="$REPO_ROOT/scripts/common"

pass=0
fail=0

note_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
note_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# Returns the list of common/*.sh files explicitly sourced by prepare-sd.sh
sourced_files() {
    grep -oE 'source "\$SCRIPT_DIR/common/[a-z0-9_-]+\.sh"' "$PREPARE_SD" \
        | sed -E 's|.*common/([a-z0-9_-]+\.sh).*|\1|' \
        | sort -u
}

# For a symbol (array name or function), find the common/*.sh file that
# defines it. Returns empty string if no defining file is found.
defining_file_for() {
    local symbol="$1" pattern="$2"
    local hit
    hit=$(grep -lE "$pattern" "$COMMON_DIR"/*.sh 2>/dev/null | head -1 || true)
    [[ -n "$hit" ]] && basename "$hit"
}

assert_sourced() {
    local symbol="$1" defining_file="$2" desc="$3"
    if sourced_files | grep -qFx "$defining_file"; then
        note_pass "$desc (defined in $defining_file, sourced ✓)"
    else
        note_fail "$desc — $symbol defined in $defining_file but prepare-sd.sh does not source it"
    fi
}

echo "=== Sourcing invariants — every STAGING_* array referenced is sourced ==="

# Arrays referenced by prepare-sd.sh:
for arr in STAGING_SERVER_REQUIRED STAGING_SERVER_REQUIRED_DESTS \
           STAGING_SERVER_OPTIONAL STAGING_SERVER_OPTIONAL_DESTS \
           STAGING_CLIENT_REQUIRED STAGING_CLIENT_REQUIRED_DESTS \
           STAGING_CLIENT_OPTIONAL STAGING_CLIENT_OPTIONAL_DESTS \
           STAGING_COMMON_SHARED_MODULES; do
    # Skip arrays not actually referenced — keeps the test honest if a
    # future refactor removes one of them.
    if ! grep -qE "\\\$\\{!?${arr}\\b|\\\$\\{${arr}\\b" "$PREPARE_SD"; then
        continue
    fi
    defining=$(defining_file_for "$arr" "^${arr}=\\(")
    if [[ -z "$defining" ]]; then
        note_fail "$arr is referenced but no defining file under common/ exposes it"
        continue
    fi
    assert_sourced "$arr" "$defining" "$arr"
done

# Scalar var
if grep -qE '\$\{?STAGING_COMMON_SHARED_MODULES_DEST\b' "$PREPARE_SD"; then
    defining=$(defining_file_for "STAGING_COMMON_SHARED_MODULES_DEST" \
        '^STAGING_COMMON_SHARED_MODULES_DEST=')
    if [[ -n "$defining" ]]; then
        assert_sourced "STAGING_COMMON_SHARED_MODULES_DEST" "$defining" \
            "STAGING_COMMON_SHARED_MODULES_DEST"
    fi
fi

echo
echo "=== Sourcing invariants — every helper function called is sourced ==="

for fn in stage_manifest_entry install_profile_is_valid install_profile_resolve \
          install_profile_is_client install_profile_needs_server_stack \
          install_profile_needs_client_stack install_profile_needs_docker \
          install_profile_configures_music_source install_profile_hardware_ok; do
    if ! grep -qE "(^|[^a-zA-Z_])${fn}\\b" "$PREPARE_SD"; then
        continue
    fi
    defining=$(defining_file_for "$fn" "^${fn}\\(\\)")
    if [[ -z "$defining" ]]; then
        note_fail "$fn is called but no defining file under common/ exposes it"
        continue
    fi
    assert_sourced "$fn" "$defining" "$fn"
done

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
