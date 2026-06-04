#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SH="$SCRIPT_DIR/../scripts/fleet-smoke.sh"

pass=0
fail=0

assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

# Read the whole file: there is no reason for a portability guard to
# skip lines, and the 1,340 window left a regression window in the
# final exit block (claude-review PR #400).
src="$(cat "$FLEET_SH")"

echo "Testing fleet-smoke.sh static portability and rendering guards..."

assert_not_contains "$src" "mapfile" "does not require Bash 4 mapfile (macOS /bin/bash safe)"
assert_contains "$src" "non_snapmulti" "tracks reachable non-snapMULTI peers explicitly"
assert_contains "$src" '"SKIP"' "renders non-snapMULTI peers as SKIP, not PASS"
assert_contains "$src" "version drift vs" "surfaces version drift in fleet table"
assert_contains "$src" "baseline_version" "computes a server baseline version for drift detection"
assert_contains "$src" "DISCONNECTED_CLIENTS_JSON" "tracks disconnected paired clients separately"
assert_contains "$src" "disconnected_clients" "exposes disconnected paired clients in JSON output"
assert_contains "$src" "Disconnected paired clients:" "lists disconnected paired clients in text output"
assert_contains "$src" "CONNECTED_NON_SNAPMULTI_JSON" "tracks connected non-snapMULTI Snapcast clients separately"
assert_contains "$src" "connected_non_snapmulti_clients" "exposes connected non-snapMULTI clients in JSON output"
assert_contains "$src" "Connected non-snapMULTI clients:" "lists connected non-snapMULTI clients in text output"
assert_contains "$src" "trap - EXIT" "parallel probe workers do not inherit tmpdir cleanup trap"
assert_contains "$src" "ServerAliveInterval=15" "SSH keepalive set (anti-hang when remote bash wedges)"
assert_contains "$src" "ServerAliveCountMax=3" "SSH gives up after 3 missed keepalives (~45 s ceiling)"
assert_contains "$src" '/^\{.*\}$/' "payload sanitiser strips MOTD/banner by picking the single JSON line"

# Release identity vs build id — pre-fix, fleet-smoke compared client
# `/opt/snapclient/VERSION` (build id, e.g. "v0.8.1-7-g68e102f" from
# `git describe --tags` baked at flash time) against server
# `/opt/snapmulti/VERSION` (same build id, but bare "v0.8.1" when the
# server was flashed from the tag exactly). Two devices on the same
# release line flashed from different post-tag commits then tripped a
# false "version drift" WARN on every fleet smoke. The fix reads
# SNAPMULTI_RELEASE from `.env` (and falls back to release-manifest.json
# on the boot partition for client-native devices that have no `.env`)
# as the release identity, and uses that for the drift check.
assert_contains "$src" "SNAPMULTI_RELEASE" "reads release identity from .env, not just VERSION file"
assert_contains "$src" "_read_release_from_env" "release-id helper extracted"
assert_contains "$src" "_read_release_from_manifest" "client-native fallback to release-manifest.json"
assert_contains "$src" "release_srv" "release identity surfaces in the JSON payload"
assert_contains "$src" "release_cli" "release identity surfaces for client role too"
assert_contains "$src" "release:{server:.release_srv, client:.release_cli}" \
    "per-host record exposes release identity alongside build versions"
assert_contains "$src" 'jq -r ' "baseline computation uses jq (already required)"
# The drift baseline now prefers .release over .versions; the original
# .versions fallback stays for legacy devices that did not bake
# SNAPMULTI_RELEASE in .env.
assert_contains "$src" "if   \$rsrv != \"\" then \$rsrv" "drift baseline prefers release-id over build-id"
assert_contains "$src" "elif \$vsrv != \"\" then \$vsrv" "legacy fallback to build-id when no release-id is baked"

# mDNS discovery hardening (macOS dns-sd path).
#   1. stdbuf -oL: dns-sd buffers stdout in a pipe, so `timeout 4 dns-sd … | awk`
#      killed the process before any line flushed. The line-buffer wrapper
#      makes the browsing output arrive immediately.
#   2. dns-sd -B returns the SERVICE INSTANCE name (e.g. "Snapcast"), not a
#      resolvable hostname. The previous code piped that into curl as if it
#      were a host, so discovery silently failed even when the server was
#      visible. The fix follows up each instance with `dns-sd -L <inst>` and
#      pulls the SRV Target via "can be reached at <host>.local.:<port>".
#   3. The probe step tries BOTH bare host and `.local` form, because mDNS
#      resolution paths vary by platform.
assert_contains "$src" "stdbuf" "dns-sd output is line-buffered to survive pipe + timeout"
assert_contains "$src" "run_with_timeout" "mDNS discovery uses timeout/gtimeout/fallback wrapper"
assert_not_contains "$src" "timeout 4 dns-sd" "mDNS discovery does not hardcode GNU timeout"
assert_contains "$src" "dns-sd -L" "instance name from -B is resolved to hostname via -L"
assert_contains "$src" "can be reached at" "SRV Target regex extracts hostname from -L response"
assert_contains "$src" '"http://${h}.local:1780/jsonrpc"' "probe tries both bare host and .local fallback"

# Regression guard against the historic "device-smoke exit 1 + valid
# JSON" concat bug. The previous `|| echo "{}"` form appended a second
# JSON document on failure, so a host with real failures got reported
# as having an empty smoke object (the python json.loads parser raised
# JSONDecodeError and fell back to {}). Two indicators of the fix.
assert_not_contains "$src" '|| echo "{}")' \
    'no `|| echo "{}"` concat on smoke JSON capture (would mask failures)'
assert_contains "$src" "raw_decode" \
    "python parser uses raw_decode (belt-and-suspenders against trailing garbage)"

# Functional: replay the exact parse logic against synthetic inputs.
python3 - <<'PY'
import json, sys

def parse(raw):
    raw = (raw or "").strip()
    if not raw:
        return {}
    try:
        smoke, _ = json.JSONDecoder().raw_decode(raw)
        return smoke
    except json.JSONDecodeError:
        return {}

cases = [
    # The exact historic bug: device-smoke exit 1 + valid JSON appended with {}
    ('{"records":[{"status":"fail","name":"snapserver"}]}\n{}',
     {"records":[{"status":"fail","name":"snapserver"}]},
     "concatenated JSON keeps the first (real) document"),
    # Normal pass
    ('{"records":[{"status":"pass","name":"x"}]}',
     {"records":[{"status":"pass","name":"x"}]},
     "valid single-document parse"),
    # Empty input
    ('', {}, "empty input -> {}"),
    # Garbage prefix -> {}
    ('not-json-at-all', {}, "non-JSON garbage -> {}"),
    # Whitespace before JSON
    ('   {"a":1}\n', {"a":1}, "leading whitespace tolerated"),
]
failed = 0
for raw, expected, desc in cases:
    got = parse(raw)
    if got == expected:
        print(f"  PASS: {desc}")
    else:
        print(f"  FAIL: {desc} (got {got!r}, expected {expected!r})")
        failed += 1
sys.exit(failed)
PY
rc=$?
if (( rc > 5 )); then
    echo "  FAIL: python helper crashed (rc=$rc) — all 5 subtests counted as failed"
    fail=$((fail + 5))
elif (( rc == 0 )); then
    pass=$((pass + 5))
else
    fail=$((fail + rc))
    pass=$((pass + 5 - rc))
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
