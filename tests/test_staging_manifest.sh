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
for arr in STAGING_SERVER_REQUIRED STAGING_SERVER_OPTIONAL \
           STAGING_CLIENT_REQUIRED STAGING_CLIENT_OPTIONAL \
           STAGING_COMMON_SHARED_MODULES \
           STAGING_TOPLEVEL_REQUIRED STAGING_TOPLEVEL_OPTIONAL; do
    eval "len=\${#${arr}[@]}"
    if [[ "$len" -gt 0 ]]; then
        echo "  PASS: $arr non-empty ($len entries)"
        pass=$((pass + 1))
    else
        echo "  FAIL: $arr is empty"
        fail=$((fail + 1))
    fi
done

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

# Extract the source path of every `cp ` / `cp -r ` invocation inside
# a function body. Source path is the first quoted argument; strip the
# trailing `/.` used in the `cp -r src/. dst/` idempotent idiom.
#
# Also expands `for VAR in A B C; do ... cp "$BASE/$VAR" ...; done`
# patterns: synthesizes one source per loop element so the manifest
# check catches every iterable target, not just the literal `$VAR`.
extract_cp_sources() {
    local func_name="$1"
    local body
    body=$(awk -v fn="^$func_name\\(\\)" '
        $0 ~ fn {f=1; next}
        f && /^\}/ {exit}
        f
    ' "$PREP")

    # Literal cp sources.
    echo "$body" | grep -oE 'cp -r? "[^"]+"' | \
        sed -E 's|cp -r? "||; s|"$||; s|/\.$||' | \
        grep -v '\$[a-z_]*$'

    # for VAR in A B C ... ; do ... cp "$BASE/$VAR" ...
    # Match the for line + the cp line in the same block to recover BASE.
    local for_items cp_base for_var
    for_var=$(echo "$body" | grep -oE 'for [a-z_]+ in ' | head -1 | awk '{print $2}')
    if [[ -n "$for_var" ]]; then
        for_items=$(echo "$body" | sed -nE "s|^[[:space:]]*for ${for_var} in (.*); do.*|\\1|p" | head -1)
        cp_base=$(echo "$body" | grep -oE "cp -r? \"\\\$[A-Z_]+(/[a-zA-Z_./-]*)?/\\\$${for_var}\"" | \
            sed -E "s|cp -r? \"||; s|/\\\$${for_var}\"||" | head -1)
        if [[ -n "$for_items" && -n "$cp_base" ]]; then
            for item in $for_items; do
                echo "$cp_base/$item"
            done
        fi
    fi
}

echo
echo "=== copy_server_files: every cp source is in the manifest ==="
mapfile -t server_sources < <(extract_cp_sources copy_server_files | sort -u)
# Normalize $SCRIPT_DIR -> scripts/, $PROJECT_DIR -> "", $CLIENT_DIR -> client/.
normalize_path() {
    sed -E 's|^\$SCRIPT_DIR/|scripts/|; s|^\$PROJECT_DIR/||; s|^\$CLIENT_DIR/|client/|'
}
all_server_entries=("${STAGING_SERVER_REQUIRED[@]}" "${STAGING_SERVER_OPTIONAL[@]}")
for src in "${server_sources[@]}"; do
    norm=$(echo "$src" | normalize_path)
    found=0
    for entry in "${all_server_entries[@]}"; do
        if [[ "$norm" == "$entry" || "$norm" == "$entry/"* ]]; then
            found=1; break
        fi
    done
    if (( found )); then
        echo "  PASS: declared in manifest: $norm"
        pass=$((pass + 1))
    else
        echo "  FAIL: undeclared cp source: $norm  (raw: $src)"
        fail=$((fail + 1))
    fi
done

echo
echo "=== copy_client_files: every cp source is in the manifest ==="
mapfile -t client_sources < <(extract_cp_sources copy_client_files | sort -u)
all_client_entries=("${STAGING_CLIENT_REQUIRED[@]}" "${STAGING_CLIENT_OPTIONAL[@]}" "${STAGING_COMMON_SHARED_MODULES[@]}")
for src in "${client_sources[@]}"; do
    norm=$(echo "$src" | normalize_path)
    found=0
    for entry in "${all_client_entries[@]}"; do
        if [[ "$norm" == "$entry" || "$norm" == "$entry/"* ]]; then
            found=1; break
        fi
    done
    if (( found )); then
        echo "  PASS: declared in manifest: $norm"
        pass=$((pass + 1))
    else
        echo "  FAIL: undeclared cp source: $norm  (raw: $src)"
        fail=$((fail + 1))
    fi
done

echo
echo "=== copy_server_files references every required server entry ==="
copy_server_body=$(awk '/^copy_server_files\(\)/{f=1; next} f && /^\}/{exit} f' "$PREP")
for entry in "${STAGING_SERVER_REQUIRED[@]}"; do
    # Convert the entry (relative path) back to a $VAR-prefixed form for grep.
    case "$entry" in
        scripts/*) pattern="\\\$SCRIPT_DIR/${entry#scripts/}" ;;
        client/*)  pattern="\\\$CLIENT_DIR/${entry#client/}" ;;
        *)         pattern="\\\$PROJECT_DIR/$entry" ;;
    esac
    if grep -qE "$pattern" <<<"$copy_server_body"; then
        echo "  PASS: copy_server_files references required: $entry"
        pass=$((pass + 1))
    else
        echo "  FAIL: copy_server_files does NOT reference required: $entry"
        fail=$((fail + 1))
    fi
done

echo
echo "=== copy_client_files references every required client entry ==="
copy_client_body=$(awk '/^copy_client_files\(\)/{f=1; next} f && /^\}/{exit} f' "$PREP")
for entry in "${STAGING_CLIENT_REQUIRED[@]}"; do
    case "$entry" in
        scripts/*) pattern="\\\$SCRIPT_DIR/${entry#scripts/}" ;;
        client/*)  pattern="\\\$CLIENT_DIR/${entry#client/}" ;;
        *)         pattern="\\\$PROJECT_DIR/$entry" ;;
    esac
    # Match literal cp source, OR the basename in a `for item in ...`
    # line (the `for item in docker-compose.yml ...` loop covers the
    # CLIENT_DIR/common/* top-level files).
    basename="${entry##*/}"
    if grep -qE "$pattern" <<<"$copy_client_body" || \
       grep -qE "for [a-z_]+ in [^;]*${basename}" <<<"$copy_client_body"; then
        echo "  PASS: copy_client_files references required: $entry"
        pass=$((pass + 1))
    else
        echo "  FAIL: copy_client_files does NOT reference required: $entry"
        fail=$((fail + 1))
    fi
done

echo
echo "=== Summary ==="
echo "  Passed: $pass"
echo "  Failed: $fail"
(( fail == 0 ))
