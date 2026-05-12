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
CHECK_SYSTEM="$SCRIPT_DIR/../scripts/smoke/check_system.sh"
CHECK_TIMERS="$SCRIPT_DIR/../scripts/smoke/check_timers.sh"

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
echo "== device-smoke.sh: Host / Compose / Systemd gates on native client =="

# 1. Host section: Docker driver / overlay-fuse check is skipped when
# native client (no Docker on the device).
assert 'awk "/section .Host./{f=1} f&&/INSTALL_TYPE_NATIVE_CLIENT.*==.*true/{print; exit}" "$SMOKE" >/dev/null' \
    "Host section guards Docker driver check on INSTALL_TYPE_NATIVE_CLIENT"
assert 'grep -qF "Native client install (no Docker)" "$SMOKE"' \
    "Host section emits an info line when skipping Docker driver"

# 2. Systemd section: snapclient-discover.timer is not expected on
# native client (snapclient uses libavahi-client directly).
assert 'awk "/section .Systemd./{f=1} f&&/snapclient-discover.timer/{n++} f&&/esac/{print n; exit}" "$SMOKE" | awk "{exit !(\$1>=1)}"' \
    "Systemd section still references snapclient-discover.timer (gated)"
assert 'awk "/snapclient-discover.timer/{prev=p} /INSTALL_TYPE_NATIVE_CLIENT.*!=.*true/{p=NR} END{exit !prev}" "$SMOKE"' \
    "snapclient-discover.timer check is preceded by INSTALL_TYPE_NATIVE_CLIENT gate"

# 3. Compose section: client compose stack is skipped on native client
# (compose file is pruned by setup-zero2w.sh).
assert 'awk "/section .Compose./{f=1} f&&/INSTALL_TYPE_NATIVE_CLIENT.*==.*true/{print; exit}" "$SMOKE" >/dev/null' \
    "Compose section guards the client stack check on INSTALL_TYPE_NATIVE_CLIENT"
assert 'grep -qF "Native client install — Docker Compose stack check skipped" "$SMOKE"' \
    "Compose section emits an info line when skipping the compose stack"

echo
echo "== check_system.sh: cgroup memory downgraded on native client =="

assert 'grep -qF "INSTALL_TYPE_NATIVE_CLIENT" "$CHECK_SYSTEM"' \
    "check_system reads INSTALL_TYPE_NATIVE_CLIENT"
assert 'awk "/Cgroup memory/{prev=p} /INSTALL_TYPE_NATIVE_CLIENT.*==.*true/{p=NR} END{exit !prev}" "$CHECK_SYSTEM"' \
    "cgroup-memory fail/info branch is gated by INSTALL_TYPE_NATIVE_CLIENT"

echo
echo "== check_timers.sh: snapclient-discover.timer skipped on native client =="

assert 'grep -qF "INSTALL_TYPE_NATIVE_CLIENT" "$CHECK_TIMERS"' \
    "check_timers reads INSTALL_TYPE_NATIVE_CLIENT"
assert 'awk "/INSTALL_TYPE_NATIVE_CLIENT.*==.*true/{f=1} f&&/snapclient-discover.timer/{print; exit}" "$CHECK_TIMERS" >/dev/null' \
    "snapclient-discover.timer skip is inside the INSTALL_TYPE_NATIVE_CLIENT branch"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
