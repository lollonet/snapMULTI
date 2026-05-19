#!/usr/bin/env bash
# Static + functional checks for scripts/diagnostic.sh.
#
# Invariants we guard:
#   1. The script exists, parses, and passes shellcheck.
#   2. CLI contract: --reason / --out-dir / --compose / --help.
#   3. Bundle naming: snapmulti-diag-<reason>-<UTC-ts>.tar.gz.
#   4. Bundle contents always include meta.txt + hw.txt at minimum;
#      install.conf appears when source file present; smoke.json
#      requires jq + a callable device-smoke.sh.
#   5. Anonymisation: SMB_PASS / SMB_USER / *_TOKEN / *_SECRET /
#      *_PASSWORD / *_PASSPHRASE / wpa_supplicant ssid+psk / Bearer
#      tokens / MAC addresses / RFC1918 IPs all redacted.
#   6. Firstboot trap integration: firstboot.sh invokes diagnostic.sh
#      with --reason install-failed and surfaces the bundle path on
#      the failure TUI.
#   7. prepare-sd.sh ships diagnostic.sh to both server and client paths
#      so the firstboot trap can find it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIAG="$SCRIPT_DIR/../scripts/diagnostic.sh"
FIRSTBOOT="$SCRIPT_DIR/../scripts/firstboot.sh"
# shellcheck disable=SC2034  # consumed inside single-quoted eval'd asserts
PREPARE_SD="$SCRIPT_DIR/../scripts/prepare-sd.sh"

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
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (unexpected '$needle' still present)"
        fail=$((fail + 1))
    fi
}

echo "=== Static checks ==="
assert '[[ -f "$DIAG" && -x "$DIAG" ]]' "diagnostic.sh exists and is executable"
assert 'bash -n "$DIAG"' "diagnostic.sh: bash -n clean"
if command -v shellcheck >/dev/null 2>&1; then
    assert 'shellcheck -S warning "$DIAG"' "diagnostic.sh: shellcheck -S warning clean"
fi

echo
echo "=== CLI contract ==="
help_out=$("$DIAG" --help 2>&1 || true)
assert_contains "$help_out" "--reason" "--help mentions --reason"
assert_contains "$help_out" "--out-dir" "--help mentions --out-dir"
assert_contains "$help_out" "/boot/firmware" "--help documents default boot-partition output"

unknown_exit=0
"$DIAG" --bogus 2>/dev/null || unknown_exit=$?
assert "[[ \"$unknown_exit\" -ne 0 ]]" "unknown argument exits non-zero"

echo
echo "=== Functional: bundle creation against a mock host ==="
OUT_DIR=$(mktemp -d /tmp/diag-test-out-XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '$OUT_DIR'" EXIT

# Run diagnostic.sh against a writable tmp dir. On macOS /proc is
# absent so most collectors will be no-ops; that's fine, we're
# validating the bundle skeleton, not the host inventory.
bundle_path=$("$DIAG" --reason unit-test --out-dir "$OUT_DIR" 2>/dev/null || true)
assert "[[ -f \"$bundle_path\" ]]" "bundle file created at advertised path"

bundle_basename=$(basename "$bundle_path" 2>/dev/null || echo "")
assert "[[ \"$bundle_basename\" =~ ^snapmulti-diag-unit-test- ]]" \
    "bundle filename carries the --reason tag"
assert "[[ \"$bundle_basename\" =~ Z\\.tar\\.gz$ ]]" \
    "bundle filename ends with UTC timestamp Z + .tar.gz"

bundle_list=$(tar tzf "$bundle_path" 2>/dev/null || true)
assert_contains "$bundle_list" "meta.txt" "bundle includes meta.txt"
assert_contains "$bundle_list" "hw.txt" "bundle includes hw.txt"

echo
echo "=== Functional: anonymisation ==="
# Drive the anonymise function directly by extracting it with awk —
# sourcing diagnostic.sh would run its top-level collection body
# (which assumes a Pi rootfs). Extracting only the `anonymise`
# function body lets us unit-test the redaction logic in isolation
# regardless of the script's set options.
ANON_EXTRACT=$(mktemp /tmp/diag-anon-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -rf '$OUT_DIR' '$ANON_EXTRACT'" EXIT

awk '
    /^anonymise\(\) \{/ {f=1}
    f {print}
    f && /^\}/ {exit}
' "$DIAG" > "$ANON_EXTRACT"

# shellcheck disable=SC1090
source "$ANON_EXTRACT"

# NOTE: token-shaped strings below are synthetic fixtures (NOT real
# credentials). They use placeholder words like "fake" / "synthetic" to
# avoid tripping the gitleaks "generic-api-key" entropy heuristic in CI.
scrubbed=$(anonymise <<'EOF'
INSTALL_TYPE=client
SMB_USER=alice
SMB_PASS=hunter2
SPOTIFY_TOKEN=fake-synthetic-token-not-real
DATABASE_PASSWORD=correct horse battery staple
NETWORK_SECRET=foo
GH_PASSPHRASE=p@ssw0rd
ssid="MyHomeWifi"
psk="reallybadpassword"
Authorization: Bearer fake-synthetic-bearer-not-real-token
mac aa:bb:cc:dd:ee:ff seen
peer 192.168.1.42 reached
nas 10.0.0.5 mounted
docker bridge 172.17.0.1 active
container 172.20.5.8 active
high-end 172.30.250.99 reached
high-end 172.31.0.4 reached
EOF
)

assert_contains "$scrubbed" "SMB_PASS=[REDACTED]" "SMB_PASS redacted"
assert_contains "$scrubbed" "SMB_USER=[REDACTED]" "SMB_USER redacted"
assert_contains "$scrubbed" "SPOTIFY_TOKEN=[REDACTED]" "*_TOKEN redacted"
assert_contains "$scrubbed" "DATABASE_PASSWORD=[REDACTED]" "*_PASSWORD redacted"
assert_contains "$scrubbed" "NETWORK_SECRET=[REDACTED]" "*_SECRET redacted"
assert_contains "$scrubbed" "GH_PASSPHRASE=[REDACTED]" "*_PASSPHRASE redacted"
assert_contains "$scrubbed" 'ssid="[SSID]"' "wpa_supplicant ssid redacted"
assert_contains "$scrubbed" 'psk="[REDACTED]"' "wpa_supplicant psk redacted"
assert_contains "$scrubbed" "Bearer [REDACTED]" "Bearer token redacted"
assert_contains "$scrubbed" "xx:xx:xx:xx:xx:xx" "MAC address redacted"
assert_contains "$scrubbed" "x.x.x.x" "RFC1918 IP redacted"

# Sanity: original sensitive strings must NOT survive
assert_not_contains "$scrubbed" "hunter2" "raw SMB password gone"
assert_not_contains "$scrubbed" "reallybadpassword" "raw WiFi PSK gone"
assert_not_contains "$scrubbed" "aa:bb:cc:dd:ee:ff" "raw MAC gone"
assert_not_contains "$scrubbed" "192.168.1.42" "raw 192.168 IP gone"
assert_not_contains "$scrubbed" "10.0.0.5" "raw 10.x IP gone"
assert_not_contains "$scrubbed" "172.17.0.1" "raw 172.16/12 IP gone (low end)"
assert_not_contains "$scrubbed" "172.20.5.8" "raw 172.16/12 IP gone (mid end)"
assert_not_contains "$scrubbed" "172.30.250.99" "raw 172.16/12 IP gone (172.30.x.x)"
assert_not_contains "$scrubbed" "172.31.0.4" "raw 172.16/12 IP gone (172.31.x.x)"

# install_type is structural metadata, not credential — must survive
assert_contains "$scrubbed" "INSTALL_TYPE=client" "INSTALL_TYPE preserved (not a credential)"

echo
echo "=== firstboot.sh integration ==="
assert 'grep -qF "diagnostic.sh" "$FIRSTBOOT"' \
    "firstboot.sh references diagnostic.sh"
assert 'grep -qF "install-failed" "$FIRSTBOOT"' \
    "firstboot.sh invokes diagnostic.sh with --reason install-failed"
assert 'grep -qE "Diagnostic bundle saved" "$FIRSTBOOT"' \
    "firstboot.sh logs the bundle path on failure"
assert 'grep -qE "GitHub issue|/issues/new" "$FIRSTBOOT"' \
    "firstboot.sh tells the user where to attach the bundle"

# The diag invocation MUST live inside cleanup_on_failure so it only
# fires when exit_code != 0 — verify by line ordering.
cleanup_line=$(grep -nE "^cleanup_on_failure\\(\\) \\{" "$FIRSTBOOT" | head -1 | cut -d: -f1 || true)
diag_invoke_line=$(grep -nE 'diagnostic\.sh' "$FIRSTBOOT" | head -1 | cut -d: -f1 || true)
if [[ -n "$cleanup_line" && -n "$diag_invoke_line" && "$diag_invoke_line" -gt "$cleanup_line" ]]; then
    echo "  PASS: diagnostic.sh invocation lives inside cleanup_on_failure() (line $diag_invoke_line > $cleanup_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: diagnostic.sh invoked outside cleanup_on_failure (cleanup=$cleanup_line, diag=$diag_invoke_line)"
    fail=$((fail + 1))
fi

echo
echo "=== prepare-sd.sh ships diagnostic.sh ==="
# copy_server_files copies into "$dest/" where $dest=$1/server, so the
# literal line is `cp "$SCRIPT_DIR/diagnostic.sh" "$dest/"`.
assert 'grep -qE "diagnostic\\.sh.*dest/" <<<"$(grep -A50 "^copy_server_files" "$PREPARE_SD")"' \
    "copy_server_files() copies diagnostic.sh"
assert 'grep -qE "diagnostic\\.sh.*dest/scripts" <<<"$(grep -A60 "^copy_client_files" "$PREPARE_SD")"' \
    "copy_client_files() copies diagnostic.sh"

echo
echo "=== firstboot.sh path discovery covers prepare-sd.sh write targets ==="
# Regression gate: prepare-sd.sh copies diagnostic.sh to two SD-card
# paths (server/diagnostic.sh and client/scripts/diagnostic.sh). On an
# early install failure (before deploy.sh / setup.sh have copied files
# to /opt), these SD paths are the ONLY sources for the bundle.
# firstboot.sh must include both in its lookup loop or the feature is
# silently defeated. This test caught a real bug where the original
# lookup tried `$SNAP_BOOT/scripts/diagnostic.sh` (never populated).
assert 'grep -qF "\$SNAP_BOOT/server/diagnostic.sh" "$FIRSTBOOT"' \
    "firstboot.sh lookup includes \$SNAP_BOOT/server/diagnostic.sh (server SD path)"
assert 'grep -qF "\$SNAP_BOOT/client/scripts/diagnostic.sh" "$FIRSTBOOT"' \
    "firstboot.sh lookup includes \$SNAP_BOOT/client/scripts/diagnostic.sh (client SD path)"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
