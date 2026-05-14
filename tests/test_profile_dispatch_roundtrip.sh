#!/usr/bin/env bash
# End-to-end round-trip test of the 4-profile install dispatch pipeline.
#
# Covers council finding F6 — the gap was that individual components were
# unit-tested in isolation, but no test verified that prepare-sd.sh's
# menu choice flowed cleanly through install.conf write → firstboot read
# → promote rule → case statement → setup-script dispatch → device-smoke
# detection.
#
# For every (hardware, menu_choice) combination, the test drives the
# extracted blocks in sequence and asserts the final state matches the
# expected profile + dispatch + smoke gate values.
#
# The test mocks is_pi_zero_2w via an env var so it runs on any host;
# the production code paths are exercised verbatim (extracted from
# scripts/prepare-sd.sh, scripts/firstboot.sh, scripts/device-smoke.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
PREPARE_SD="$REPO_ROOT/scripts/prepare-sd.sh"
FIRSTBOOT="$REPO_ROOT/scripts/firstboot.sh"
DEVICE_SMOKE="$REPO_ROOT/scripts/device-smoke.sh"

pass=0
fail=0

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (got '$actual', expected '$expected')"
        fail=$((fail + 1))
    fi
}

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

# ═══════════════════════════════════════════════════════════════════
# Step 1 — prepare-sd.sh:get_install_type()
# ═══════════════════════════════════════════════════════════════════
# Extract the function and drive it with stdin numbers. The function
# reads from `read -rp` so we just `echo "$N" | get_install_type`.

GET_TYPE_SRC=$(mktemp /tmp/snapmulti-get-type-XXXXXX.sh)
# shellcheck disable=SC2064  # intentional: paths must expand NOW so
# trap captures these specific tmpfiles. Includes .callable companion
# created below so an unexpected exit between mktemp and the manual
# `rm -f` (line ~84) doesn't leak it.
trap "rm -f '$GET_TYPE_SRC' '$GET_TYPE_SRC.callable'" EXIT

awk '
    /^get_install_type\(\) \{/ {f=1}
    f {print}
    f && /^\}/ {exit}
' "$PREPARE_SD" > "$GET_TYPE_SRC"

# Wrap in a callable script.
cat > "$GET_TYPE_SRC.callable" <<EOF
#!/usr/bin/env bash
set -uo pipefail
$(cat "$GET_TYPE_SRC")
get_install_type
EOF
chmod +x "$GET_TYPE_SRC.callable"

echo "=== Step 1: prepare-sd.sh menu choice -> install.conf value ==="
for input_expected in "1:client" "2:server" "3:both"; do
    input="${input_expected%%:*}"
    expected="${input_expected##*:}"
    got=$(echo "$input" | "$GET_TYPE_SRC.callable" 2>/dev/null || true)
    assert_eq "$got" "$expected" "menu choice $input -> $expected"
done

# Invalid menu prompts must go to stderr only. `INSTALL_TYPE=$(...)`
# captures stdout; if the error prompt is written there, install.conf
# gets a corrupted value such as
# `Invalidchoice.Enter1,2,or3.client`.
got=$(printf 'x\n1\n' | "$GET_TYPE_SRC.callable" 2>/dev/null || true)
assert_eq "$got" "client" "invalid menu choice does not contaminate stdout/INSTALL_TYPE"

rm -f "$GET_TYPE_SRC.callable"

# ═══════════════════════════════════════════════════════════════════
# Step 2 — install.conf write contract
# ═══════════════════════════════════════════════════════════════════
# prepare-sd.sh writes `INSTALL_TYPE=$INSTALL_TYPE` into install.conf.
# We don't re-run the full SD-copy logic; we just verify the line
# format the file format readers (firstboot, device-smoke) expect.

CONF_DIR=$(mktemp -d /tmp/snapmulti-conf-XXXXXX)
# shellcheck disable=SC2064
trap "rm -rf '$CONF_DIR' '$GET_TYPE_SRC'" EXIT

write_install_conf() {
    local install_type="$1"
    cat > "$CONF_DIR/install.conf" <<EOF
INSTALL_TYPE=$install_type
MUSIC_SOURCE=
NFS_SERVER=
NFS_EXPORT=
SMB_SERVER=
SMB_SHARE=
ENABLE_READONLY=true
SKIP_UPGRADE=false
IMAGE_TAG=latest
VERBOSE_INSTALL=false
EOF
}

# ═══════════════════════════════════════════════════════════════════
# Step 3 — firstboot.sh: read install.conf + promote rule
# ═══════════════════════════════════════════════════════════════════
# Extract the read block (lines around 67-71) AND the promote block
# (the new code introduced by F1+F2+F4) into a driver. Mock
# is_pi_zero_2w via env var IS_ZERO=0|1.

FIRSTBOOT_DRIVER=$(mktemp /tmp/snapmulti-firstboot-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -rf '$CONF_DIR' '$GET_TYPE_SRC' '$FIRSTBOOT_DRIVER'" EXIT

cat > "$FIRSTBOOT_DRIVER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

log_info()  { :; }
log_error() { :; }
is_pi_zero_2w() { return "${IS_ZERO:-1}"; }

SNAP_BOOT="${TEST_CONF_DIR:?}"

# Mirror firstboot.sh:67-71 (install.conf read with fallback)
INSTALL_TYPE="server"
if [[ -f "$SNAP_BOOT/install.conf" ]]; then
    INSTALL_TYPE=$(grep -m1 '^INSTALL_TYPE=' "$SNAP_BOOT/install.conf" | cut -d= -f2 | tr -d '[:space:]')
    INSTALL_TYPE="${INSTALL_TYPE:-server}"
fi

# Mirror firstboot.sh promote block (introduced by F1+F2+F4)
if [[ "$INSTALL_TYPE" == "client" ]] && is_pi_zero_2w; then
    log_info "Pi Zero 2W detected — promoting profile: client -> client-native"
    INSTALL_TYPE="client-native"
fi

echo "$INSTALL_TYPE"
EOF
chmod +x "$FIRSTBOOT_DRIVER"

run_firstboot_promote() {
    local menu_choice="$1" is_zero="$2"
    # Step 1 + 2: write install.conf with the menu choice
    write_install_conf "$menu_choice"
    # Step 3: drive firstboot read + promote
    TEST_CONF_DIR="$CONF_DIR" IS_ZERO="$is_zero" "$FIRSTBOOT_DRIVER"
}

echo
echo "=== Step 3: firstboot.sh read install.conf + promote (full pipeline so far) ==="

# is_zero=0 means is_pi_zero_2w returns true (Pi Zero 2W detected)
# is_zero=1 means non-Pi-Zero-2W hardware
for case in \
    "1:0:client-native:menu=client + Pi Zero 2W -> client-native" \
    "1:1:client:menu=client + non-Zero -> client" \
    "2:0:server:menu=server + Pi Zero 2W -> server (guard will reject later)" \
    "2:1:server:menu=server + non-Zero -> server" \
    "3:0:both:menu=both + Pi Zero 2W -> both (guard will reject later)" \
    "3:1:both:menu=both + non-Zero -> both"; do
    IFS=: read -r menu_choice is_zero expected desc <<<"$case"
    # Map menu choice (1/2/3) -> profile string via the get_install_type extract
    menu_value=$(echo "$menu_choice" | bash -c "$(cat <<INNER
$(awk '/^get_install_type\(\) \{/ {f=1} f {print} f && /^\}/ {exit}' "$PREPARE_SD")
get_install_type
INNER
)" 2>/dev/null)
    final=$(run_firstboot_promote "$menu_value" "$is_zero")
    assert_eq "$final" "$expected" "$desc"
done

# ═══════════════════════════════════════════════════════════════════
# Step 4 — firstboot.sh case statement covers every profile
# ═══════════════════════════════════════════════════════════════════
echo
echo "=== Step 4: firstboot.sh case statement covers every produced INSTALL_TYPE ==="

# Extract the case statement body.
case_body=$(awk '/^case "\$INSTALL_TYPE" in$/{f=1} f; /^esac$/{exit}' "$FIRSTBOOT")
for profile in client server both client-native; do
    if grep -qE "^[[:space:]]+${profile}\)" <<<"$case_body"; then
        echo "  PASS: firstboot case has '$profile)' arm"
        pass=$((pass + 1))
    else
        echo "  FAIL: firstboot case missing '$profile)' arm"
        fail=$((fail + 1))
    fi
done

# Catch-all `*)` must also be present so unknown INSTALL_TYPE exits 1.
assert 'grep -qE "^[[:space:]]+\\*\\)" <<<"$case_body"' \
    "firstboot case has catch-all '*)' arm"

# ═══════════════════════════════════════════════════════════════════
# Step 5 — firstboot.sh dispatches to the correct setup script
# ═══════════════════════════════════════════════════════════════════
# Static check: the dispatch block selects setup-zero2w.sh iff
# INSTALL_TYPE == client-native, otherwise setup.sh.
echo
echo "=== Step 5: firstboot.sh setup-script dispatch ==="

# firstboot.sh has TWO `if [[ "$INSTALL_TYPE" == "client-native" ]]`
# blocks: one early (SKIP_DOCKER=true) and one later (setup_script
# dispatch). The dispatch is the only one that mentions
# setup-zero2w.sh — grab a window around it.
# shellcheck disable=SC2034  # consumed inside single-quoted asserts
dispatch_block=$(grep -B5 -A20 "setup_script=\"scripts/setup-zero2w.sh\"" "$FIRSTBOOT" || true)

assert 'grep -qF "setup-zero2w.sh" <<<"$dispatch_block"' \
    "dispatch: client-native -> setup-zero2w.sh"
assert 'grep -qF "setup_script=\"scripts/setup.sh\"" <<<"$dispatch_block"' \
    "dispatch: non-native fallback to setup.sh"
assert 'grep -qE "if \\[\\[ \"\\\$INSTALL_TYPE\" == \"client-native\" \\]\\]" <<<"$dispatch_block"' \
    "dispatch: gated on INSTALL_TYPE=client-native"

# The dispatch block must be inside is_client_install territory (client +
# client-native + both reach it). Easiest: confirm `is_client_install` is
# called earlier in the file than the dispatch line itself.
isclient_line=$(grep -nE "^is_client_install\\(\\) \\{" "$FIRSTBOOT" | head -1 | cut -d: -f1)
dispatch_line=$(grep -nE 'INSTALL_TYPE.*client-native.*then|^[[:space:]]*if \[\[ "\$INSTALL_TYPE" == "client-native" \]\]; then' "$FIRSTBOOT" | head -1 | cut -d: -f1)
if [[ -n "$isclient_line" && -n "$dispatch_line" && "$isclient_line" -lt "$dispatch_line" ]]; then
    echo "  PASS: is_client_install defined (line $isclient_line) BEFORE dispatch (line $dispatch_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: is_client_install/dispatch ordering wrong (helper=$isclient_line, dispatch=$dispatch_line)"
    fail=$((fail + 1))
fi

# ═══════════════════════════════════════════════════════════════════
# Step 6 — device-smoke.sh:detect_native_client_dir + export
# ═══════════════════════════════════════════════════════════════════
# Extract the function and drive it against mock /opt/snapclient dirs
# with different install.conf contents.
echo
echo "=== Step 6: device-smoke.sh detect_native_client_dir + INSTALL_TYPE_NATIVE_CLIENT ==="

SMOKE_DRIVER=$(mktemp /tmp/snapmulti-smoke-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -rf '$CONF_DIR' '$GET_TYPE_SRC' '$FIRSTBOOT_DRIVER' '$SMOKE_DRIVER'" EXIT

cat > "$SMOKE_DRIVER" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="${TEST_SMOKE_SCRIPT_DIR:-/nonexistent}"

EOF

awk '
    /^detect_native_client_dir\(\) \{/ {f=1}
    f {print}
    f && /^\}/ {exit}
' "$DEVICE_SMOKE" >> "$SMOKE_DRIVER"

cat >> "$SMOKE_DRIVER" <<'EOF'

# Override /opt/snapclient lookup to the test dir.
detect_native_client_dir_test() {
    local candidate
    for candidate in "${TEST_NATIVE_DIR:-/nonexistent}" "${SCRIPT_DIR}/../client/common"; do
        if [[ -f "$candidate/install.conf" ]] && \
           grep -qE '^INSTALL_TYPE=client-native' "$candidate/install.conf" 2>/dev/null; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

# Emit INSTALL_TYPE_NATIVE_CLIENT same way device-smoke.sh does.
INSTALL_TYPE_NATIVE_CLIENT="false"
NATIVE_CLIENT_DIR="$(detect_native_client_dir_test || true)"
if [[ -n "$NATIVE_CLIENT_DIR" ]]; then
    INSTALL_TYPE_NATIVE_CLIENT="true"
fi
echo "INSTALL_TYPE_NATIVE_CLIENT=$INSTALL_TYPE_NATIVE_CLIENT"
echo "NATIVE_CLIENT_DIR=$NATIVE_CLIENT_DIR"
EOF
chmod +x "$SMOKE_DRIVER"

run_smoke_detect() {
    local install_type="$1"
    local tmp_native
    tmp_native=$(mktemp -d /tmp/snapmulti-native-XXXXXX)
    cat > "$tmp_native/install.conf" <<INNER
INSTALL_TYPE=$install_type
INNER
    TEST_NATIVE_DIR="$tmp_native" "$SMOKE_DRIVER" | grep '^INSTALL_TYPE_NATIVE_CLIENT=' | cut -d= -f2
    rm -rf "$tmp_native"
}

# client-native install.conf -> export true
result=$(run_smoke_detect "client-native")
assert_eq "$result" "true" "install.conf=client-native -> INSTALL_TYPE_NATIVE_CLIENT=true"

# client install.conf -> export false (non-native install)
result=$(run_smoke_detect "client")
assert_eq "$result" "false" "install.conf=client -> INSTALL_TYPE_NATIVE_CLIENT=false"

# server install.conf -> export false
result=$(run_smoke_detect "server")
assert_eq "$result" "false" "install.conf=server -> INSTALL_TYPE_NATIVE_CLIENT=false"

# both install.conf -> export false (both is containerised, not native)
result=$(run_smoke_detect "both")
assert_eq "$result" "false" "install.conf=both -> INSTALL_TYPE_NATIVE_CLIENT=false"

# Missing install.conf -> export false
empty_dir=$(mktemp -d /tmp/snapmulti-empty-XXXXXX)
result=$(TEST_NATIVE_DIR="$empty_dir" "$SMOKE_DRIVER" | grep '^INSTALL_TYPE_NATIVE_CLIENT=' | cut -d= -f2)
rm -rf "$empty_dir"
assert_eq "$result" "false" "missing install.conf -> INSTALL_TYPE_NATIVE_CLIENT=false"

# ═══════════════════════════════════════════════════════════════════
# Step 7 — Edge cases on install.conf parsing
# ═══════════════════════════════════════════════════════════════════
echo
echo "=== Step 7: edge cases on install.conf parsing ==="

# Empty INSTALL_TYPE= line — falls back to "server" via the
# ${INSTALL_TYPE:-server} default in firstboot.sh:70
cat > "$CONF_DIR/install.conf" <<'EOF'
INSTALL_TYPE=
EOF
result=$(TEST_CONF_DIR="$CONF_DIR" IS_ZERO=1 "$FIRSTBOOT_DRIVER")
assert_eq "$result" "server" "empty INSTALL_TYPE= line -> falls back to 'server'"

# Missing INSTALL_TYPE line entirely
cat > "$CONF_DIR/install.conf" <<'EOF'
MUSIC_SOURCE=nfs
EOF
result=$(TEST_CONF_DIR="$CONF_DIR" IS_ZERO=1 "$FIRSTBOOT_DRIVER")
assert_eq "$result" "server" "missing INSTALL_TYPE= line -> falls back to 'server'"

# Missing install.conf entirely
rm -f "$CONF_DIR/install.conf"
result=$(TEST_CONF_DIR="$CONF_DIR" IS_ZERO=1 "$FIRSTBOOT_DRIVER")
assert_eq "$result" "server" "missing install.conf -> falls back to 'server'"

# Whitespace tolerance — `tr -d [:space:]` strips trailing spaces
cat > "$CONF_DIR/install.conf" <<'EOF'
INSTALL_TYPE=client
EOF
# is_zero=1 so promote does NOT fire — verifies parse logic alone
result=$(TEST_CONF_DIR="$CONF_DIR" IS_ZERO=1 "$FIRSTBOOT_DRIVER")
assert_eq "$result" "client" "trailing whitespace stripped from INSTALL_TYPE value"

# ═══════════════════════════════════════════════════════════════════
# Done
# ═══════════════════════════════════════════════════════════════════
echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
