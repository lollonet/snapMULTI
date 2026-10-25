#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREPARE_SD_SH="$SCRIPT_DIR/../scripts/prepare-sd.sh"
HOOK="/boot/firmware/snapmulti/firstboot.sh"

pass=0
fail=0

assert_contains() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (missing '$needle')"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local file="$1" needle="$2" desc="$3"
    if grep -qF -- "$needle" "$file"; then
        echo "  FAIL: $desc (found '$needle')"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

assert_line() {
    local file="$1" line="$2" desc="$3"
    if grep -qxF -- "$line" "$file"; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (no exact line '$line')"
        fail=$((fail + 1))
    fi
}

assert_valid() {
    local file="$1" desc="$2"
    if validate_user_data "$file" >/dev/null 2>&1; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        validate_user_data "$file" 2>&1 | sed 's/^/        /' || true
        fail=$((fail + 1))
    fi
}

assert_invalid() {
    local file="$1" desc="$2"
    if validate_user_data "$file" >/dev/null 2>&1; then
        echo "  FAIL: $desc (accepted)"
        fail=$((fail + 1))
    else
        echo "  PASS: $desc"
        pass=$((pass + 1))
    fi
}

eval "$(sed -n '/^patch_user_data_runcmd()/,/^}/p' "$PREPARE_SD_SH")"
eval "$(sed -n '/^validate_user_data()/,/^}/p' "$PREPARE_SD_SH")"

HAVE_PYYAML=false
if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" 2>/dev/null; then
    HAVE_PYYAML=true
fi

# Full YAML check, independent of validate_user_data (which skips the
# parse when PyYAML is missing).
assert_yaml_ok() {
    local file="$1" desc="$2"
    if [[ "$HAVE_PYYAML" != true ]]; then
        echo "  SKIP: $desc (PyYAML not installed)"
        return 0
    fi
    if python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert isinstance(d['runcmd'], list)
assert d['runcmd'][0] == ['bash', sys.argv[2]], d['runcmd']
" "$file" "$HOOK" 2>/dev/null; then
        echo "  PASS: $desc"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc"
        fail=$((fail + 1))
    fi
}

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

run_case() {
    local name="$1" content="$2"
    printf '%s\n' "$content" > "$TMPD/$name"
    patch_user_data_runcmd "$TMPD/$name" "$HOOK"
    echo "$TMPD/$name"
}

echo "Testing prepare-sd user-data patching..."

tmp1=$(run_case "plain-runcmd" $'#cloud-config\nruncmd:\n  - [ sh, -c, echo first ]')
assert_line "$tmp1" "  - [bash, $HOOK]" "plain runcmd gets hook at the existing item indent"
assert_valid "$tmp1" "plain runcmd: validates"
assert_yaml_ok "$tmp1" "plain runcmd: parses, hook is first runcmd entry"

tmp2=$(run_case "inline-empty" $'#cloud-config\nruncmd: []')
assert_line "$tmp2" 'runcmd:' "inline [] converted to block key"
assert_line "$tmp2" "  - [bash, $HOOK]" "inline [] gets hook"
assert_not_contains "$tmp2" 'runcmd: []' "inline [] removed"
assert_valid "$tmp2" "inline []: validates"
assert_yaml_ok "$tmp2" "inline []: parses"

tmp3=$(run_case "inline-null" $'#cloud-config\nruncmd: null')
assert_line "$tmp3" 'runcmd:' "inline null converted to block key"
assert_line "$tmp3" "  - [bash, $HOOK]" "inline null gets hook"
assert_not_contains "$tmp3" 'runcmd: null' "inline null removed"
assert_yaml_ok "$tmp3" "inline null: parses"

tmp4=$(run_case "indented" $'#cloud-config\n  runcmd:\n    - [ sh, -c, echo first ]')
assert_line "$tmp4" '  runcmd:' "indented runcmd preserved"
assert_line "$tmp4" "    - [bash, $HOOK]" "indented hook matches indentation"

# Raspberry Pi Imager writes runcmd items at column 0. The old patch
# inserted a two-space item above them -> mixed indents -> invalid YAML.
tmp5=$(run_case "imager-col0" $'#cloud-config\nhostname: snapmulti\nruncmd:\n- localectl set-x11-keymap "it" pc105\n- setupcon -k --force || true\nusers:\n- name: pi')
assert_line "$tmp5" "- [bash, $HOOK]" "column-0 runcmd list: hook inserted at column 0"
assert_not_contains "$tmp5" "  - [bash, $HOOK]" "column-0 runcmd list: no two-space hook"
assert_valid "$tmp5" "column-0 runcmd list: validates"
assert_yaml_ok "$tmp5" "column-0 runcmd list: parses, hook is first runcmd entry"

tmp6=$(run_case "comment-between" $'#cloud-config\nruncmd:\n  # Imager comment\n\n    - echo deep')
assert_line "$tmp6" "    - [bash, $HOOK]" "blank/comment lines skipped when inheriting item indent"
assert_yaml_ok "$tmp6" "comment between key and items: parses"

tmp7=$(run_case "missing" $'#cloud-config\nhostname: snapmulti')
assert_line "$tmp7" 'runcmd:' "missing runcmd appended"
assert_line "$tmp7" "  - [bash, $HOOK]" "missing runcmd: hook appended"
assert_valid "$tmp7" "missing runcmd: validates"
assert_yaml_ok "$tmp7" "missing runcmd: parses"

tmp8=$(run_case "empty-file" '')
assert_valid "$tmp8" "empty user-data: patched file validates"

tmp9=$(run_case "null-key-then-key" $'#cloud-config\nruncmd:\nhostname: snapmulti')
assert_line "$tmp9" "  - [bash, $HOOK]" "runcmd: followed by another key gets default indent"
assert_yaml_ok "$tmp9" "runcmd: followed by another key: parses"

tmp10=$(run_case "trailing-comment" $'#cloud-config\nruncmd: [] # none yet')
assert_line "$tmp10" "  - [bash, $HOOK]" "inline [] with trailing comment patched (no second runcmd block)"
assert_valid "$tmp10" "inline [] with trailing comment: validates"

echo ""
echo "Testing validate_user_data..."

printf '%s\n' '#cloud-config' 'runcmd:' "  - [bash, $HOOK]" '- localectl set-x11-keymap "it" pc105' > "$TMPD/mixed"
assert_invalid "$TMPD/mixed" "mixed runcmd indentation (old patch output) rejected"

printf '%s\n' '#cloud-config' 'runcmd:' '  - echo a' 'runcmd:' "  - [bash, $HOOK]" > "$TMPD/double"
assert_invalid "$TMPD/double" "two runcmd: blocks rejected"

printf '%s\n' '#cloud-config' 'runcmd:' '  - echo a' > "$TMPD/nohook"
assert_invalid "$TMPD/nohook" "runcmd without the firstboot hook rejected"

printf '%s\n' '#cloud-config' 'runcmd:' "  - [bash, $HOOK]" '  - |' '    - not an item' '    echo nested' > "$TMPD/blockscalar"
assert_valid "$TMPD/blockscalar" "dash lines inside a nested block scalar are not flagged"

if [[ "$HAVE_PYYAML" == true ]]; then
    printf '%s\n' '#cloud-config' 'write_files: [unclosed' 'runcmd:' "  - [bash, $HOOK]" > "$TMPD/badyaml"
    assert_invalid "$TMPD/badyaml" "unparseable YAML elsewhere in the file rejected (PyYAML leg)"
else
    echo "  SKIP: PyYAML leg (not installed)"
fi

# Re-running the patch on an already-patched file must stay valid when the
# caller skips the patch (grep guard) — and the gate must still run.
echo ""
echo "Testing prepare-sd.sh main-flow wiring..."
main_flow=$(sed -n '/^elif \[\[ -f "\$USERDATA" \]\]; then/,/^else$/p' "$PREPARE_SD_SH")
# No credential-bearing copy of user-data may be left on the FAT partition.
if ! grep -qF 'snapmulti.bak' "$PREPARE_SD_SH"; then
    echo "  PASS: no user-data backup copy (it would duplicate credentials)"
    pass=$((pass + 1))
else
    echo "  FAIL: prepare-sd.sh leaves a user-data backup copy on the boot partition"
    fail=$((fail + 1))
fi
# The validation must run on BOTH paths (fresh patch and already-patched).
validate_calls=$(grep -cE '^\s*if ! validate_user_data ' <<<"$main_flow" || true)
if [[ "$validate_calls" -ge 2 ]]; then
    echo "  PASS: validate_user_data runs on both the patch and the already-patched paths"
    pass=$((pass + 1))
else
    echo "  FAIL: validate_user_data must run on both paths (found $validate_calls call(s))"
    fail=$((fail + 1))
fi
# The patch must land in a temp file and only replace user-data after validation.
patch_line=$(grep -nE 'patch_user_data_runcmd "\$USERDATA_TMP"' <<<"$main_flow" | head -1 | cut -d: -f1)
validate_tmp_line=$(grep -nE 'validate_user_data "\$USERDATA_TMP"' <<<"$main_flow" | head -1 | cut -d: -f1)
replace_line=$(grep -nE 'mv -f "\$USERDATA_TMP" "\$USERDATA"' <<<"$main_flow" | head -1 | cut -d: -f1)
if [[ -n "$patch_line" && -n "$validate_tmp_line" && -n "$replace_line" ]] \
   && (( patch_line < validate_tmp_line && validate_tmp_line < replace_line )); then
    echo "  PASS: patch -> validate temp file -> replace user-data (in that order)"
    pass=$((pass + 1))
else
    echo "  FAIL: expected patch(tmp) < validate(tmp) < mv(tmp->user-data) (got $patch_line/$validate_tmp_line/$replace_line)"
    fail=$((fail + 1))
fi

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
