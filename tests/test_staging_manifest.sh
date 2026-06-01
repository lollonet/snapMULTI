#!/usr/bin/env bash
# Validates scripts/common/staging-manifest.sh against the actual
# source tree + scripts/prepare-sd.sh's copy_server_files and
# copy_client_files. Three invariants:
#
#   1. Every REQUIRED entry exists in the repo at SD-prep time.
#   2. Every `cp ` / `cp -r ` source in copy_* functions corresponds
#      to a manifest entry (catches "added a cp but forgot to declare").
#   3. Every manifest entry is referenced by at least one cp in the
#      matching copy_* function (catches drift to dead data).
#
# Runs on any host — no Pi-specific paths. Uses bash arrays + grep,
# no JSON parser required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$PROJECT_DIR/scripts/common/staging-manifest.sh"
PREP="$PROJECT_DIR/scripts/prepare-sd.sh"

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
assert '[[ -f "$MANIFEST" ]]' "staging-manifest.sh exists"
assert 'bash -n "$MANIFEST"' "staging-manifest.sh: bash -n clean"
assert '[[ -f "$PREP" ]]' "prepare-sd.sh exists"

# shellcheck source=../scripts/common/staging-manifest.sh
source "$MANIFEST"

# Verify each declared array is non-empty (catches accidental deletion).
# Explicit case instead of `eval "len=\${#$arr[@]}"` so shellcheck sees
# every dereference (was SC2154 on `len`).
check_array_non_empty() {
    local name="$1" len="$2"
    if (( len > 0 )); then
        echo "  PASS: $name non-empty ($len entries)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name is empty"
        fail=$((fail + 1))
    fi
}
check_array_non_empty STAGING_SERVER_REQUIRED        "${#STAGING_SERVER_REQUIRED[@]}"
check_array_non_empty STAGING_SERVER_OPTIONAL        "${#STAGING_SERVER_OPTIONAL[@]}"
check_array_non_empty STAGING_CLIENT_REQUIRED        "${#STAGING_CLIENT_REQUIRED[@]}"
check_array_non_empty STAGING_CLIENT_OPTIONAL        "${#STAGING_CLIENT_OPTIONAL[@]}"
check_array_non_empty STAGING_COMMON_SHARED_MODULES  "${#STAGING_COMMON_SHARED_MODULES[@]}"
check_array_non_empty STAGING_TOPLEVEL_REQUIRED      "${#STAGING_TOPLEVEL_REQUIRED[@]}"
check_array_non_empty STAGING_TOPLEVEL_OPTIONAL      "${#STAGING_TOPLEVEL_OPTIONAL[@]}"

echo
echo "=== Required entries exist in source tree ==="
for entry in "${STAGING_SERVER_REQUIRED[@]}" \
             "${STAGING_CLIENT_REQUIRED[@]}" \
             "${STAGING_TOPLEVEL_REQUIRED[@]}"; do
    if [[ -e "$PROJECT_DIR/$entry" ]]; then
        echo "  PASS: required exists: $entry"
        pass=$((pass + 1))
    else
        echo "  FAIL: required MISSING: $entry"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Shared modules exist in source tree ==="
for entry in "${STAGING_COMMON_SHARED_MODULES[@]}"; do
    if [[ -e "$PROJECT_DIR/$entry" ]]; then
        echo "  PASS: shared module exists: $entry"
        pass=$((pass + 1))
    else
        echo "  FAIL: shared module MISSING: $entry"
        fail=$((fail + 1))
    fi
done

# Extract the source path of every staging copy inside a function body.
# Four flavours of cp source must be recovered, all live in the
# v0.7-era copy_server_files / copy_client_files:
#
#   1. Plain `cp "<src>" "<dst>"` and `cp -r "<src>" "<dst>"` —
#      the regex must accept both `cp` and `cp -r` (earlier draft only
#      matched `cp -r`, silently skipping ~half the manifest).
#   2. `for VAR in A B C; do ... cp "$BASE/$VAR" ...; done` — every
#      loop iterable becomes a synthesized source.
#   3. `for _shared in install-deps.sh install-docker.sh ...; do
#      cp "$SCRIPT_DIR/common/$_shared" ...` — same as (2) with a
#      different base path (covers STAGING_COMMON_SHARED_MODULES).
#   4. `_hooks=("$SCRIPT_DIR/common/initramfs-hooks/"*); cp
#      "${_hooks[@]}" ...` — the glob expands at runtime, so the
#      manifest entry is the directory itself.
extract_cp_sources() {
    local func_name="$1"
    local body
    body=$(awk -v fn="^$func_name\\(\\)" '
        $0 ~ fn {f=1; next}
        f && /^\}/ {exit}
        f
    ' "$PREP")

    # (1) Plain `cp ` and `cp -r ` — first quoted argument is the source.
    echo "$body" | grep -oE 'cp (-r )?"[^"]+"' | \
        sed -E 's|cp (-r )?"||; s|"$||; s|/\.$||' | \
        grep -v '\$[a-z_]*$' | \
        grep -v '\${[a-z_]*\[@\]}'

    # (2)+(3) for-loop expansion: scan EVERY `for VAR in ...; do` line
    # and synthesize one source per loop element. The base path is the
    # cp command that consumes `$VAR` — recovered from the same function
    # body. Handles both `for item in ...` (CLIENT_DIR/common/) and
    # `for _shared in ...` (SCRIPT_DIR/common/) loops without
    # hardcoding the var names.
    while IFS= read -r for_line; do
        local for_var for_items cp_base
        for_var=$(echo "$for_line" | sed -E 's|^[[:space:]]*for ([a-z_]+) in .*|\1|')
        for_items=$(echo "$for_line" | sed -E "s|^[[:space:]]*for ${for_var} in (.*); do.*|\\1|")
        cp_base=$(echo "$body" | grep -oE "cp (-r )?\"\\\$[A-Z_]+(/[a-zA-Z_./-]*)?/\\\$${for_var}\"" | \
            head -1 | sed -E "s|cp (-r )?\"||; s|/\\\$${for_var}\"||")
        if [[ -n "$for_items" && -n "$cp_base" ]]; then
            for item in $for_items; do
                echo "$cp_base/$item"
            done
        fi
    done < <(echo "$body" | grep -E '^[[:space:]]+for [a-z_]+ in [^;]*; do')

    # (4) `_VAR=(...); cp "${_VAR[@]}" "$dest/..."` — emit the
    # assignment's source directory so the manifest can declare it.
    # Today only `_hooks=("$SCRIPT_DIR/common/initramfs-hooks/"*)` uses
    # this idiom; the test stays generic by matching any `_VAR=(...)` with
    # a glob source.
    while IFS= read -r line; do
        echo "$line" | sed -E 's|.*=\("([^"]+)"\*\).*|\1|; s|/$||'
    done < <(echo "$body" | grep -E '^[[:space:]]+(local +)?_[a-z]+=\("\$[A-Z_]+(/[a-zA-Z_./-]*)+/?"\*\)')
}

echo
echo "=== Parallel _DESTS arrays match _REQUIRED / _OPTIONAL ==="
# Each entry array MUST have a matching _DESTS array of the same length.
# A mismatch silently mis-routes the cp dest to the wrong subdir.
check_lockstep() {
    local name1="$1" name2="$2" len1="$3" len2="$4"
    if [[ "$len1" -eq "$len2" ]]; then
        echo "  PASS: $name1 ($len1) and $name2 ($len2) parallel"
        pass=$((pass + 1))
    else
        echo "  FAIL: $name1 ($len1) and $name2 ($len2) length mismatch"
        fail=$((fail + 1))
    fi
}
check_lockstep STAGING_SERVER_REQUIRED STAGING_SERVER_REQUIRED_DESTS \
    "${#STAGING_SERVER_REQUIRED[@]}" "${#STAGING_SERVER_REQUIRED_DESTS[@]}"
check_lockstep STAGING_SERVER_OPTIONAL STAGING_SERVER_OPTIONAL_DESTS \
    "${#STAGING_SERVER_OPTIONAL[@]}" "${#STAGING_SERVER_OPTIONAL_DESTS[@]}"
check_lockstep STAGING_CLIENT_REQUIRED STAGING_CLIENT_REQUIRED_DESTS \
    "${#STAGING_CLIENT_REQUIRED[@]}" "${#STAGING_CLIENT_REQUIRED_DESTS[@]}"
check_lockstep STAGING_CLIENT_OPTIONAL STAGING_CLIENT_OPTIONAL_DESTS \
    "${#STAGING_CLIENT_OPTIONAL[@]}" "${#STAGING_CLIENT_OPTIONAL_DESTS[@]}"

echo
echo "=== Wiring: copy_*_files iterate the manifest ==="
# v0.8 PR6 — copy_server_files / copy_client_files iterate the manifest
# via stage_manifest_entry instead of inline cp lines. Replaced the
# previous `cp source in manifest` check (now there are no literal cp
# sources in the loop body) with checks on the loop structure.
copy_server_body=$(awk '/^copy_server_files\(\)/{f=1; next} f && /^\}/{exit} f' "$PREP")
copy_client_body=$(awk '/^copy_client_files\(\)/{f=1; next} f && /^\}/{exit} f' "$PREP")

assert_iterates() {
    local fn_body_var="$1" arr_name="$2"
    local body="${!fn_body_var}"
    if grep -qE "for [a-zA-Z_]+ in \"\\\$\\{!${arr_name}\\[@\\]\\}\"" <<<"$body"; then
        echo "  PASS: $fn_body_var iterates $arr_name via \${!$arr_name[@]}"
        pass=$((pass + 1))
    else
        echo "  FAIL: $fn_body_var does NOT iterate $arr_name"
        fail=$((fail + 1))
    fi
}
assert_iterates copy_server_body STAGING_SERVER_REQUIRED
assert_iterates copy_server_body STAGING_SERVER_OPTIONAL
assert_iterates copy_client_body STAGING_CLIENT_REQUIRED
assert_iterates copy_client_body STAGING_CLIENT_OPTIONAL

# stage_manifest_entry called by both copy_*_files.
for fn in server client; do
    body_var="copy_${fn}_body"
    body="${!body_var}"
    if grep -qE "stage_manifest_entry " <<<"$body"; then
        echo "  PASS: copy_${fn}_files calls stage_manifest_entry"
        pass=$((pass + 1))
    else
        echo "  FAIL: copy_${fn}_files does NOT call stage_manifest_entry"
        fail=$((fail + 1))
    fi
done

# Shared common modules wired in copy_client_files (server has its
# scripts/common/ shipped via the recursive top-level copy at L811).
if grep -qE 'for [a-z_]+ in "\$\{STAGING_COMMON_SHARED_MODULES\[@\]\}"' <<<"$copy_client_body"; then
    echo "  PASS: copy_client_files iterates STAGING_COMMON_SHARED_MODULES"
    pass=$((pass + 1))
else
    echo "  FAIL: copy_client_files does NOT iterate STAGING_COMMON_SHARED_MODULES"
    fail=$((fail + 1))
fi

echo
echo "=== Special-case inline copies still present and declared ==="
# Items in STAGING_*_SPECIAL_INLINE are kept inline because they have
# conditional logic stage_manifest_entry doesn't model (mpd.db
# MUSIC_SOURCE gate, tidal/ subdir copy, docker/ idempotent idiom,
# initramfs-hooks/ nullglob).
for entry in "${STAGING_SERVER_SPECIAL_INLINE[@]}"; do
    case "$entry" in
        scripts/*) pattern="\\\$SCRIPT_DIR/${entry#scripts/}" ;;
        *)         pattern="\\\$PROJECT_DIR/$entry" ;;
    esac
    if grep -qE "$pattern" <<<"$copy_server_body"; then
        echo "  PASS: server special-case '$entry' has inline cp"
        pass=$((pass + 1))
    else
        echo "  FAIL: server special-case '$entry' has NO inline cp"
        fail=$((fail + 1))
    fi
done
for entry in "${STAGING_CLIENT_SPECIAL_INLINE[@]}"; do
    case "$entry" in
        scripts/*) pattern="\\\$SCRIPT_DIR/${entry#scripts/}" ;;
        *)         pattern="\\\$PROJECT_DIR/$entry" ;;
    esac
    if grep -qE "$pattern" <<<"$copy_client_body"; then
        echo "  PASS: client special-case '$entry' has inline cp"
        pass=$((pass + 1))
    else
        echo "  FAIL: client special-case '$entry' has NO inline cp"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Passed: $pass"
echo "  Failed: $fail"
(( fail == 0 ))
