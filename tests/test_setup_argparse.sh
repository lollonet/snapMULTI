#!/usr/bin/env bash
# Verify setup.sh argument parsing and CLI readonly precedence.
#
# Bug history (regressions to prevent):
#   - firstboot calls `setup.sh --auto --no-readonly /boot/firmware/install.conf`
#     and the config path used to be silently dropped because the parser
#     only captured AUTO_CONFIG when it followed --auto immediately AND
#     was not a flag.
#   - With install.conf containing ENABLE_READONLY=true, a CLI
#     --no-readonly was undone after the source.
#
# Approach: extract the parser block and execute it in a sandbox shell,
# bypassing the realpath validation block that requires real files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SH="$SCRIPT_DIR/../client/common/scripts/setup.sh"

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

# Static checks first — verify the parser has the structural shape that
# implements the contract.

echo "=== static checks ==="

if grep -q "^CLI_READONLY_OVERRIDE=\"\"" "$SETUP_SH"; then
    echo "  PASS: CLI_READONLY_OVERRIDE variable declared"
    pass=$((pass + 1))
else
    echo "  FAIL: CLI_READONLY_OVERRIDE not declared (precedence cannot be tracked)"
    fail=$((fail + 1))
fi

if grep -q "CLI_READONLY_OVERRIDE=true" "$SETUP_SH" \
   && grep -q "CLI_READONLY_OVERRIDE=false" "$SETUP_SH"; then
    echo "  PASS: --read-only and --no-readonly write CLI_READONLY_OVERRIDE"
    pass=$((pass + 1))
else
    echo "  FAIL: --read-only / --no-readonly do not record into CLI_READONLY_OVERRIDE"
    fail=$((fail + 1))
fi

if grep -q 'ENABLE_READONLY="$CLI_READONLY_OVERRIDE"' "$SETUP_SH"; then
    echo "  PASS: CLI override applied to ENABLE_READONLY"
    pass=$((pass + 1))
else
    echo "  FAIL: ENABLE_READONLY does not pick up CLI_READONLY_OVERRIDE"
    fail=$((fail + 1))
fi

# The override application MUST come AFTER the source of AUTO_CONFIG.
override_line=$(grep -n 'ENABLE_READONLY="$CLI_READONLY_OVERRIDE"' "$SETUP_SH" | head -1 | cut -d: -f1)
source_line=$(grep -n 'source "\$AUTO_CONFIG_REAL"' "$SETUP_SH" | head -1 | cut -d: -f1)
if [[ -n "$override_line" && -n "$source_line" && "$override_line" -gt "$source_line" ]]; then
    echo "  PASS: CLI override application follows config sourcing (line $override_line > $source_line)"
    pass=$((pass + 1))
else
    echo "  FAIL: CLI override must come AFTER source (override=$override_line, source=$source_line)"
    fail=$((fail + 1))
fi

# The new parser must accept positional ANYWHERE — not glued to --auto.
if grep -q 'First non-flag positional' "$SETUP_SH"; then
    echo "  PASS: parser accepts positional config independently of flag order"
    pass=$((pass + 1))
else
    echo "  FAIL: parser still ties AUTO_CONFIG capture to --auto adjacency"
    fail=$((fail + 1))
fi

# Functional check: extract the parser only (no realpath / source) and
# exec it with synthetic argv.

echo
echo "=== functional checks ==="

PARSER_TMP=$(mktemp /tmp/setup-parser-XXXXXX.sh)
trap 'rm -f "$PARSER_TMP"' EXIT

# Build a runnable harness: the parser block, then echo the captured vars.
# We deliberately stop BEFORE the AUTO_CONFIG-source/realpath block (it
# needs real files). The CLI override application follows the source, so
# we have to run that part inline against fake config-set values.
awk '
    BEGIN { capture=0 }
    /^AUTO_MODE=false$/ { capture=1 }
    capture { print }
    /^done$/ && capture { print "exit_after_parse=1"; print "echo PARSED"; capture=0 }
' "$SETUP_SH" > "$PARSER_TMP"

cat <<'EOF' >> "$PARSER_TMP"
echo "AUTO_MODE=$AUTO_MODE"
echo "AUTO_CONFIG=$AUTO_CONFIG"
echo "ENABLE_READONLY=$ENABLE_READONLY"
echo "CLI_READONLY_OVERRIDE=$CLI_READONLY_OVERRIDE"
EOF

run_parse() {
    bash "$PARSER_TMP" "$@" 2>&1
}

# Test 1: positional after --no-readonly
out=$(run_parse --auto --no-readonly /tmp/foo.conf)
ac=$(echo "$out" | grep -E '^AUTO_CONFIG=' | cut -d= -f2-)
ro=$(echo "$out" | grep -E '^CLI_READONLY_OVERRIDE=' | cut -d= -f2-)
assert_eq "$ac" "/tmp/foo.conf" "AUTO_CONFIG captured after --no-readonly"
assert_eq "$ro" "false"         "CLI_READONLY_OVERRIDE recorded as false"

# Test 2: positional before flags
out=$(run_parse --auto /tmp/bar.conf --no-readonly)
ac=$(echo "$out" | grep -E '^AUTO_CONFIG=' | cut -d= -f2-)
assert_eq "$ac" "/tmp/bar.conf" "AUTO_CONFIG captured when before flags"

# Test 3: --auto only, no positional
out=$(run_parse --auto)
ac=$(echo "$out" | grep -E '^AUTO_CONFIG=' | cut -d= -f2-)
assert_eq "$ac" "" "AUTO_CONFIG empty when no positional given"

# Test 4: --read-only flag
out=$(run_parse --auto --read-only /tmp/baz.conf)
ro=$(echo "$out" | grep -E '^CLI_READONLY_OVERRIDE=' | cut -d= -f2-)
ac=$(echo "$out" | grep -E '^AUTO_CONFIG=' | cut -d= -f2-)
assert_eq "$ro" "true" "--read-only sets CLI_READONLY_OVERRIDE=true"
assert_eq "$ac" "/tmp/baz.conf" "positional after --read-only is captured"

echo
if (( fail > 0 )); then
    echo "FAILED: $fail / $((pass + fail))"
    exit 1
fi
echo "All $pass tests passed!"
