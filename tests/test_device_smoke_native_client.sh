#!/usr/bin/env bash
# Static checks for device-smoke.sh native-client detection.
#
# Pi Zero 2W native install lacks /opt/snapclient/docker-compose.yml
# and /opt/snapclient/.env (snapclient is a plain apt package). The
# detect_dir guard would skip it and the smoke would refuse with
# "No snapMULTI installation found". A separate detect_native_client_dir()
# reads install.conf (INSTALL_TYPE=client-native) and exports
# INSTALL_TYPE_NATIVE_CLIENT for the smoke modules.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE="$SCRIPT_DIR/../scripts/device-smoke.sh"
CHECK_CONTAINERS="$SCRIPT_DIR/../scripts/smoke/check_containers.sh"

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

echo "== device-smoke.sh: native client install detection =="

assert 'grep -qE "detect_native_client_dir\\(\\)" "$SMOKE"' \
    "detect_native_client_dir() defined"
assert 'grep -qE "INSTALL_TYPE=client-native" "$SMOKE"' \
    "matches INSTALL_TYPE=client-native from install.conf"
assert 'grep -qF "export INSTALL_TYPE_NATIVE_CLIENT" "$SMOKE"' \
    "exports INSTALL_TYPE_NATIVE_CLIENT for downstream smoke modules"

# require_cmd docker MUST NOT fire on a native-only client; the gate
# is `if [[ ... != "true" || ... != client ]]`.
assert 'awk "/require_cmd docker/{f=1} f&&/^fi/{print NR; exit}" "$SMOKE" >/dev/null && grep -qE "INSTALL_TYPE_NATIVE_CLIENT.*!=.*true" "$SMOKE"' \
    "require_cmd docker is gated on INSTALL_TYPE_NATIVE_CLIENT"

# Detection mode selection still works for native client.
assert 'awk "/auto/{f=1} f&&/MODE=\"client\"/{print; exit}" "$SMOKE" >/dev/null' \
    "auto-detect promotes mode to client when only native client is present"

echo
echo "== check_containers.sh: respects INSTALL_TYPE_NATIVE_CLIENT =="

assert 'grep -qF "INSTALL_TYPE_NATIVE_CLIENT" "$CHECK_CONTAINERS"' \
    "check_containers checks INSTALL_TYPE_NATIVE_CLIENT env var"

# The fallback model-detection idiom is still present (defense in
# depth for standalone invocation when the env var is unset).
assert 'grep -qF "_is_pi_zero_2w_smoke" "$CHECK_CONTAINERS"' \
    "model-based fallback still present"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
