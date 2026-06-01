#!/usr/bin/env bash
# Static checks for prepare-sd.sh wiring of scripts/common/install-profile.sh
# (v0.8 PR3). Pure additive PRs landed the helper (PR1) and migrated
# firstboot.sh (PR2). This PR3 migrates prepare-sd.sh's 7 occurrences
# of the `INSTALL_TYPE == "server" || == "both"` / `"client" || == "both"`
# patterns to install_profile_needs_server_stack / _needs_client_stack.
#
# Unlike firstboot.sh, prepare-sd.sh runs on the HOST (Mac/Linux/Windows
# WSL) — install_profile_resolve falls through unchanged because
# is_pi_zero_2w is not defined here. Pi Zero promotion happens at first
# boot, not at SD-prep time. The is_valid gate IS still asserted because
# the advanced menu can override INSTALL_TYPE via MANIFEST_DEFAULT_*.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP="$SCRIPT_DIR/../scripts/prepare-sd.sh"

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

echo "=== Static checks ==="
assert '[[ -f "$PREP" ]]' "prepare-sd.sh exists"
assert 'bash -n "$PREP"' "prepare-sd.sh: bash -n clean"

assert 'grep -qE "source \"\\\$SCRIPT_DIR/common/install-profile\\.sh\"" "$PREP"' \
       "prepare-sd.sh sources install-profile.sh"

echo
echo "=== Migration completeness ==="
# After v0.8 PR3 there must be ZERO occurrences of the literal
# `INSTALL_TYPE == "server" || == "both"` / `== "client" || == "both"`
# patterns in prepare-sd.sh — all such gates route through the
# install_profile_needs_*_stack predicates.
residual_server_both=$(grep -cE '"\$INSTALL_TYPE" == "server" \|\| "\$INSTALL_TYPE" == "both"' "$PREP" || true)
residual_client_both=$(grep -cE '"\$INSTALL_TYPE" == "client" \|\| "\$INSTALL_TYPE" == "both"' "$PREP" || true)

# Case statements with the same `server|both` / `client|both` branch
# pattern are functionally equivalent to the `||` form and must also be
# migrated. The remaining `case "$INSTALL_TYPE"` block at L822 is the
# real 3-way copy_server / copy_client / copy_both dispatch and is OK.
case_server_both=$(awk '/case "\$INSTALL_TYPE"/{f=NR; next} f && NR<=f+4 && /server\|both\)/ {print; f=0}' "$PREP" | wc -l | awk '{print $1}')
case_client_both=$(awk '/case "\$INSTALL_TYPE"/{f=NR; next} f && NR<=f+4 && /client\|both\)/ {print; f=0}' "$PREP" | wc -l | awk '{print $1}')
if [[ "$case_server_both" -eq 0 ]]; then
    echo "  PASS: zero residual case \"server|both\" branches"
    pass=$((pass + 1))
else
    echo "  FAIL: $case_server_both residual case \"server|both\" branches still present"
    fail=$((fail + 1))
fi
if [[ "$case_client_both" -eq 0 ]]; then
    echo "  PASS: zero residual case \"client|both\" branches"
    pass=$((pass + 1))
else
    echo "  FAIL: $case_client_both residual case \"client|both\" branches still present"
    fail=$((fail + 1))
fi
if [[ "$residual_server_both" -eq 0 ]]; then
    echo "  PASS: zero residual \"server || both\" literal gates"
    pass=$((pass + 1))
else
    echo "  FAIL: $residual_server_both residual \"server || both\" gates still present"
    fail=$((fail + 1))
fi
if [[ "$residual_client_both" -eq 0 ]]; then
    echo "  PASS: zero residual \"client || both\" literal gates"
    pass=$((pass + 1))
else
    echo "  FAIL: $residual_client_both residual \"client || both\" gates still present"
    fail=$((fail + 1))
fi

# The 7 originally-migrated sites now use the predicates. Count both
# directions (server_stack + client_stack) ≥ 7.
predicate_uses=$(grep -cE 'install_profile_needs_(server|client)_stack' "$PREP" || true)
if [[ "$predicate_uses" -ge 7 ]]; then
    echo "  PASS: install_profile_needs_*_stack used $predicate_uses times (>= 7 migrated sites)"
    pass=$((pass + 1))
else
    echo "  FAIL: only $predicate_uses uses of needs_*_stack predicate (expected >= 7)"
    fail=$((fail + 1))
fi

echo
echo "=== Validation contract ==="
# install_profile_is_valid gate must run AFTER get_install_type call
# AND BEFORE any predicate call.
get_type_line=$(grep -nE "INSTALL_TYPE=\\\$\(get_install_type\)" "$PREP" | head -1 | cut -d: -f1)
gate_line=$(grep -nE "install_profile_is_valid" "$PREP" | head -1 | cut -d: -f1)
# Skip comment lines so the comment block introducing the source helper
# isn't mistaken for a usage call.
first_predicate_line=$(grep -nE "install_profile_needs_(server|client)_stack" "$PREP" | grep -vE '^[0-9]+:\s*#' | head -1 | cut -d: -f1)

if [[ -n "$get_type_line" && -n "$gate_line" && "$get_type_line" -lt "$gate_line" ]]; then
    echo "  PASS: get_install_type (line $get_type_line) runs BEFORE is_valid gate (line $gate_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: get_install_type must precede is_valid gate (get=$get_type_line, gate=$gate_line)"
    fail=$((fail + 1))
fi

if [[ -n "$gate_line" && -n "$first_predicate_line" && "$gate_line" -lt "$first_predicate_line" ]]; then
    echo "  PASS: is_valid gate (line $gate_line) runs BEFORE first predicate use (line $first_predicate_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: is_valid gate must precede first predicate use (gate=$gate_line, predicate=$first_predicate_line)"
    fail=$((fail + 1))
fi

# Gate must explicitly reject `client-native` — install_profile_is_valid
# alone accepts it (the predicate is shared with firstboot.sh's runtime
# gate). prepare-sd.sh only accepts user-selectable types from the menu.
assert 'grep -qE "client-native" "$PREP" | head -1' \
       "gate has explicit client-native rejection (prevents drift from runtime-only profile name)"
gate_body=$(sed -n "${gate_line},$((gate_line + 5))p" "$PREP" 2>/dev/null)
if grep -qE 'client-native' <<<"$gate_body"; then
    echo "  PASS: gate explicitly rejects client-native (runtime-only derivation)"
    pass=$((pass + 1))
else
    echo "  FAIL: gate does not reject client-native — drift risk if future paths set it"
    fail=$((fail + 1))
fi

echo
echo "=== Summary ==="
echo "  Passed: $pass"
echo "  Failed: $fail"
(( fail == 0 ))
