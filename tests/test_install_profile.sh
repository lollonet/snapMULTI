#!/usr/bin/env bash
# Unit tests for scripts/common/install-profile.sh — the SSOT for
# install-type derived decisions (is_client, needs_docker,
# needs_server_stack, needs_client_stack, needs_music_source,
# hardware_ok, resolve).
#
# Tests run on any host (no Pi-specific paths required). The
# `is_pi_zero_2w` dependency is stubbed in each "Pi Zero" scenario so
# we exercise the hardware-aware paths deterministically.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/common/install-profile.sh"

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
assert '[[ -f "$LIB" ]]' "install-profile.sh exists"
assert 'bash -n "$LIB"' "install-profile.sh: bash -n clean"

# Each predicate must be defined (the library is pure additive — every
# function listed below is referenced from a planned wiring PR).
for fn in install_profile_is_valid \
          install_profile_resolve \
          install_profile_is_client \
          install_profile_needs_server_stack \
          install_profile_needs_client_stack \
          install_profile_needs_docker \
          install_profile_configures_music_source \
          install_profile_hardware_ok; do
    assert "grep -qE '^${fn}\\(\\) \\{' \"\$LIB\"" \
           "defines $fn"
done

echo
echo "=== install_profile_is_valid ==="
# shellcheck source=../scripts/common/install-profile.sh
source "$LIB"

for t in client client-native server both; do
    assert "install_profile_is_valid $t" "valid: $t"
done
for t in "" foo CLIENT bothx native; do
    assert "! install_profile_is_valid '$t'" "invalid: '$t'"
done

echo
echo "=== install_profile_is_client ==="
for t in client client-native both; do
    assert "install_profile_is_client $t" "client: $t -> true"
done
for t in server foo ""; do
    assert "! install_profile_is_client '$t'" "client: $t -> false"
done

echo
echo "=== install_profile_needs_server_stack ==="
for t in server both; do
    assert "install_profile_needs_server_stack $t" "server stack: $t -> true"
done
for t in client client-native foo ""; do
    assert "! install_profile_needs_server_stack '$t'" "server stack: $t -> false"
done

echo
echo "=== install_profile_needs_client_stack ==="
for t in client client-native both; do
    assert "install_profile_needs_client_stack $t" "client stack: $t -> true"
done
for t in server foo ""; do
    assert "! install_profile_needs_client_stack '$t'" "client stack: $t -> false"
done

echo
echo "=== install_profile_needs_docker ==="
for t in client server both; do
    assert "install_profile_needs_docker $t" "docker: $t -> true"
done
for t in client-native foo ""; do
    assert "! install_profile_needs_docker '$t'" "docker: $t -> false"
done

echo
echo "=== install_profile_configures_music_source ==="
for t in server both; do
    assert "install_profile_configures_music_source $t" "configures music: $t -> true"
done
for t in client client-native foo ""; do
    assert "! install_profile_configures_music_source '$t'" "configures music: $t -> false"
done

echo
echo "=== install_profile_hardware_ok (no is_pi_zero_2w available) ==="
# Without is_pi_zero_2w defined, every valid type returns OK.
for t in client client-native server both; do
    assert "install_profile_hardware_ok $t" "hardware OK (no probe): $t"
done
assert "! install_profile_hardware_ok ''" "hardware OK: invalid type rejected"

echo
echo "=== install_profile_hardware_ok (is_pi_zero_2w = true) ==="
# Stub the dependency to force Pi Zero detection.
is_pi_zero_2w() { return 0; }
assert "install_profile_hardware_ok client" "Pi Zero + client -> OK"
assert "install_profile_hardware_ok client-native" "Pi Zero + client-native -> OK"
assert "! install_profile_hardware_ok server" "Pi Zero + server -> REJECT"
assert "! install_profile_hardware_ok both" "Pi Zero + both -> REJECT"

echo
echo "=== install_profile_hardware_ok (is_pi_zero_2w = false) ==="
is_pi_zero_2w() { return 1; }
for t in client client-native server both; do
    assert "install_profile_hardware_ok $t" "non-Zero + $t -> OK"
done

echo
echo "=== install_profile_resolve ==="
# is_pi_zero_2w currently returns 1 (false).
assert '[[ "$(install_profile_resolve client)" == "client" ]]' \
       "resolve(client, non-Zero) -> client"
assert '[[ "$(install_profile_resolve server)" == "server" ]]' \
       "resolve(server) -> server (no promotion)"
assert '[[ "$(install_profile_resolve client-native)" == "client-native" ]]' \
       "resolve(client-native) -> client-native (idempotent)"

# Force Pi Zero detection: client should promote.
is_pi_zero_2w() { return 0; }
assert '[[ "$(install_profile_resolve client)" == "client-native" ]]' \
       "resolve(client, Pi Zero) -> client-native"
# Other types are never promoted, even on Pi Zero (server/both already
# rejected upstream by hardware_ok; client-native is the destination).
assert '[[ "$(install_profile_resolve server)" == "server" ]]' \
       "resolve(server, Pi Zero) -> server (no promotion)"
assert '[[ "$(install_profile_resolve both)" == "both" ]]' \
       "resolve(both, Pi Zero) -> both (no promotion)"
assert '[[ "$(install_profile_resolve client-native)" == "client-native" ]]' \
       "resolve(client-native, Pi Zero) -> client-native"

# Invalid input: echoes the input, returns 1.
unset -f is_pi_zero_2w
out=$(install_profile_resolve "foo" 2>/dev/null) || rc=$?
assert "[[ '${out}' == 'foo' ]]" "resolve(foo) echoes input verbatim"
assert "[[ '${rc:-0}' == '1' ]]" "resolve(foo) returns 1"

echo
echo "=== Summary ==="
echo "  Passed: $pass"
echo "  Failed: $fail"

(( fail == 0 ))
