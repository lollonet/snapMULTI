#!/usr/bin/env bash
# release-manifest.sh — single source of truth for release vs image-set
# resolution. Pure-bash, no jq dependency at runtime (Pi Zero 2W lean
# installs may not ship jq).
#
# Canonical manifest shape (release-manifest.json, repo root):
#   {
#     "snapmulti_release": "v0.7.7",
#     "image_set": "0.7.7",
#     "requires_image_rebuild": true
#   }
#
# The parser handles canonical pretty-printed multi-line JSON ONLY (one
# key per line). Compact JSON breaks the line-oriented regex matcher;
# this is enforced by tests/test_release_manifest_canonical.sh.
#
# Precedence chains — the SINGLE source of truth for every consumer:
#
#   (A) IMAGE_TAG     = install.conf IMAGE_TAG
#                     > install.conf SNAPMULTI_IMAGE_SET
#                     > manifest image_set
#                     > "latest"
#   (B) SNAPMULTI_RELEASE   = install.conf SNAPMULTI_RELEASE
#                           > manifest snapmulti_release
#                           > ""
#   (C) SNAPMULTI_IMAGE_SET = install.conf SNAPMULTI_IMAGE_SET
#                           > manifest image_set
#                           > ""
#
# Every consumer (prepare-sd, firstboot, deploy, setup) implements
# precedence (A) via derive_image_tag().
#
# All three functions return 0 ALWAYS so they're safe under `set -euo
# pipefail`. Missing inputs yield empty strings.

# parse_release_manifest <path>
#   Populates MANIFEST_RELEASE, MANIFEST_IMAGE_SET, MANIFEST_REQUIRES_IMAGE_REBUILD
#   from the named JSON file. Empty on missing file or missing keys.
#   requires_image_rebuild is normalised to literal "true" / "false";
#   any other value yields empty.
parse_release_manifest() {
    local path="${1:-}"
    # shellcheck disable=SC2034 # consumed by callers (firstboot, prepare-sd, deploy)
    MANIFEST_RELEASE=""
    # shellcheck disable=SC2034
    MANIFEST_IMAGE_SET=""
    # shellcheck disable=SC2034
    MANIFEST_REQUIRES_IMAGE_REBUILD=""

    [[ -n "$path" && -f "$path" ]] || return 0

    # Per-key regex anchored on line start with `"<key>"` so confusable
    # keys (image_set vs image_set_override) cannot collide. Use ERE
    # (`-E`) for portability — BSD sed (macOS dev / CI) does not support
    # `\|` alternation; GNU sed (Pi runtime) supports both.
    # shellcheck disable=SC2034 # globals consumed by firstboot/prepare-sd/deploy/setup
    MANIFEST_RELEASE=$(sed -nE 's/^[[:space:]]*"snapmulti_release"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$path" | head -n1)
    # shellcheck disable=SC2034
    MANIFEST_IMAGE_SET=$(sed -nE 's/^[[:space:]]*"image_set"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$path" | head -n1)

    local raw_rebuild
    raw_rebuild=$(sed -nE 's/^[[:space:]]*"requires_image_rebuild"[[:space:]]*:[[:space:]]*(true|false)[[:space:]]*,?[[:space:]]*$/\1/p' "$path" | head -n1)
    # shellcheck disable=SC2034
    case "$raw_rebuild" in
        true|false) MANIFEST_REQUIRES_IMAGE_REBUILD="$raw_rebuild" ;;
        *)          MANIFEST_REQUIRES_IMAGE_REBUILD="" ;;
    esac

    return 0
}

# derive_image_tag <explicit> <fallback>
#   Echoes the first non-empty argument (whitespace-trimmed), or
#   "latest" if both are empty / whitespace-only.
derive_image_tag() {
    local explicit="${1:-}"
    local fallback="${2:-}"

    # Trim leading/trailing whitespace.
    explicit="${explicit#"${explicit%%[![:space:]]*}"}"
    explicit="${explicit%"${explicit##*[![:space:]]}"}"
    fallback="${fallback#"${fallback%%[![:space:]]*}"}"
    fallback="${fallback%"${fallback##*[![:space:]]}"}"

    if [[ -n "$explicit" ]]; then
        printf '%s\n' "$explicit"
    elif [[ -n "$fallback" ]]; then
        printf '%s\n' "$fallback"
    else
        printf 'latest\n'
    fi
    return 0
}

# read_install_conf_key <path> <key>
#   Echoes the value of <key>=<value> from install.conf, FIRST match
#   wins (matches `grep -m1` convention in firstboot.sh:70 and
#   elsewhere — the operator-canonical value is the top of the file).
#   Trims whitespace and trailing CR. Empty on missing file / key.
read_install_conf_key() {
    local path="${1:-}"
    local key="${2:-}"
    [[ -n "$path" && -f "$path" && -n "$key" ]] || { printf ''; return 0; }

    local value
    value=$(grep -m1 "^${key}=" "$path" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)
    # Trim leading/trailing whitespace.
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    printf '%s\n' "$value"
    return 0
}
