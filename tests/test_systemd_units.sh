#!/usr/bin/env bash
# Static drift checks for scripts/common/systemd-units.sh.
#
# Three invariants enforced:
#   1. Every base in SYSTEMD_UNITS_{SERVER,CLIENT} has at least one
#      matching file ($base.{service,timer,path}) under the unit dir.
#   2. Every `install -m 0644 ... .service|.timer|.path` line in
#      firstboot.sh + setup.sh references a base declared in the
#      matching manifest.
#   3. Every static unit file (scripts/common/snapmulti-*.{service,
#      timer,path}, client/common/systemd/*.service) is declared in
#      the manifest under its base name.
#
# Out of scope (intentionally not flagged):
#   - snapclient.service, snapclient-discover.{service,timer},
#     snapmulti-server.service: generated at runtime, not from static
#     files. See systemd-units.sh header comment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/scripts/common/systemd-units.sh"
FIRSTBOOT="$REPO_ROOT/scripts/firstboot.sh"
SETUP="$REPO_ROOT/client/common/scripts/setup.sh"

# Source the manifest in a context that defines the unified-log
# functions it doesn't use (manifest is data-only).
# shellcheck source=/dev/null
source "$MANIFEST"

pass=0
fail=0

note_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
note_fail() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# ─── Invariant 1: every base has at least one file ─────────────────
echo "=== Invariant 1: every manifest base has matching unit file(s) ==="
check_base_has_files() {
    local base="$1" dir_rel="$2" expected_in="$3"
    local dir_abs="$REPO_ROOT/$dir_rel"
    local found=0
    for ext in service timer path; do
        if [[ -f "$dir_abs/$base.$ext" ]]; then
            found=$((found + 1))
        fi
    done
    if (( found > 0 )); then
        note_pass "$expected_in/$base.* ($found file(s))"
    else
        note_fail "$expected_in/$base.{service,timer,path} — none exist"
    fi
}
for base in "${SYSTEMD_UNITS_SERVER[@]}"; do
    check_base_has_files "$base" "$SYSTEMD_UNITS_SERVER_DIR" "server"
done
for base in "${SYSTEMD_UNITS_CLIENT[@]}"; do
    check_base_has_files "$base" "$SYSTEMD_UNITS_CLIENT_DIR" "client"
done

# ─── Invariant 2: every inline install references a declared base ──
echo
echo "=== Invariant 2: every inline install references a declared base ==="
# Extract the unit filename from each `install -m 0644 ... unit.ext`
# line in firstboot.sh + setup.sh. Strip path + extension to get the
# base; assert the base is in the appropriate manifest array.

check_install_lines() {
    local source_file="$1" name="$2" manifest_name="$3"
    declare -n manifest_ref="$manifest_name"

    # grep for the install lines, extract the unit basename
    local install_lines unit_path unit_file base ext
    install_lines=$(grep -nE "install -m 0644 .+\.(service|timer|path)" "$source_file" || true)
    if [[ -z "$install_lines" ]]; then
        note_pass "$name: no static-unit install lines (vacuously satisfied)"
        return
    fi

    local line_num missing=0 total=0
    while IFS= read -r line; do
        line_num="${line%%:*}"
        # Extract the second arg (source path) — match the .service/.timer/.path
        # `|| true` defensively guards against an install line with a
        # quoting style the inner pattern doesn't match — `pipefail`
        # would otherwise abort the test before the empty-guard below
        # can demote to `continue`.
        unit_path=$(echo "$line" | grep -oE "[^[:space:]\"]+\.(service|timer|path)" | head -1 || true)
        [[ -z "$unit_path" ]] && continue
        unit_file="${unit_path##*/}"
        ext="${unit_file##*.}"
        base="${unit_file%.*}"
        total=$((total + 1))

        local found=0
        local m
        for m in "${manifest_ref[@]}"; do
            if [[ "$m" == "$base" ]]; then
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            note_fail "$name:$line_num references '$unit_file' but base '$base' is not in $manifest_name"
            missing=$((missing + 1))
        fi
    done <<< "$install_lines"
    if (( missing == 0 && total > 0 )); then
        note_pass "$name: all $total install lines reference declared bases"
    fi
}
check_install_lines "$FIRSTBOOT" "firstboot.sh" "SYSTEMD_UNITS_SERVER"
check_install_lines "$SETUP"     "setup.sh"     "SYSTEMD_UNITS_CLIENT"

# ─── Invariant 2b: helper is called for every manifest base ────────
# After PR8 migration, every base in the manifest must be reachable
# from at least one `install_systemd_unit_files "BASE" ...` call in
# the appropriate script. Pins the migration so a future refactor
# can't silently drop a base.
check_helper_usage() {
    local script="$1" name="$2" manifest_name="$3"
    declare -n manifest_ref="$manifest_name"
    local body
    body=$(cat "$script")
    local base
    for base in "${manifest_ref[@]}"; do
        if grep -qE "install_systemd_unit_files\\b.+\"$base\"" <<< "$body"; then
            note_pass "$name: install_systemd_unit_files called for '$base'"
        else
            note_fail "$name: NO install_systemd_unit_files call references '$base'"
        fi
    done
}
echo
echo "=== Invariant 2b: helper called for every manifest base (post-PR8) ==="
check_helper_usage "$FIRSTBOOT" "firstboot.sh" "SYSTEMD_UNITS_SERVER"
check_helper_usage "$SETUP"     "setup.sh"     "SYSTEMD_UNITS_CLIENT"

# ─── Invariant 2c: state-backup keeps the all-or-nothing guard ─────
# snapmulti-state-backup is the only 3-unit group; the helper's
# "install whatever you find, return success if anything installed"
# is too permissive — a missing .path or .timer would let the caller
# proceed to `enable --now snapmulti-state-backup.path` which fails.
# Caller MUST gate the helper call on all three source files existing.
echo
echo "=== Invariant 2c: state-backup keeps all-or-nothing source guard ==="
sb_guard=$(awk '/STATE_BACKUP_SCRIPT/,/install_systemd_unit_files .+snapmulti-state-backup/' "$FIRSTBOOT")
if grep -qE 'snapmulti-state-backup\.service.* &&' <<<"$sb_guard" && \
   grep -qE 'snapmulti-state-backup\.path.* &&'    <<<"$sb_guard" && \
   grep -qE 'snapmulti-state-backup\.timer'        <<<"$sb_guard"; then
    note_pass "firstboot.sh keeps all-or-nothing .service && .path && .timer guard for snapmulti-state-backup"
else
    note_fail "firstboot.sh missing 3-file source guard for snapmulti-state-backup — helper alone could let .path/.timer enable fire on a partial bundle"
fi

# ─── Invariant 3: no orphan unit files in the unit dirs ────────────
echo
echo "=== Invariant 3: no orphan unit files (every static file is declared) ==="
check_orphans() {
    local dir_rel="$1" prefix="$2" manifest_name="$3" name="$4"
    declare -n manifest_ref="$manifest_name"
    local dir_abs="$REPO_ROOT/$dir_rel"
    [[ -d "$dir_abs" ]] || { note_fail "$name unit dir missing: $dir_rel"; return; }

    local f base orphan_count=0 checked=0
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        checked=$((checked + 1))
        base="${f##*/}"
        base="${base%.service}"
        base="${base%.timer}"
        base="${base%.path}"

        local found=0
        local m
        for m in "${manifest_ref[@]}"; do
            if [[ "$m" == "$base" ]]; then
                found=1
                break
            fi
        done
        if (( found == 0 )); then
            note_fail "$name orphan: $dir_rel/$(basename "$f") (base '$base' not in $manifest_name)"
            orphan_count=$((orphan_count + 1))
        fi
    done < <(find "$dir_abs" -maxdepth 1 -name "${prefix}*.service" -o -name "${prefix}*.timer" -o -name "${prefix}*.path" 2>/dev/null)

    if (( orphan_count == 0 && checked > 0 )); then
        note_pass "$name: all $checked files declared (no orphans under $dir_rel)"
    elif (( checked == 0 )); then
        note_fail "$name: no files found under $dir_rel matching ${prefix}*"
    fi
}
check_orphans "$SYSTEMD_UNITS_SERVER_DIR" "snapmulti-" "SYSTEMD_UNITS_SERVER" "server"
check_orphans "$SYSTEMD_UNITS_CLIENT_DIR" ""           "SYSTEMD_UNITS_CLIENT" "client"

echo
echo "Results: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
