#!/usr/bin/env bash
# Sourced as a helper library; `set -euo pipefail` intentionally omitted.
#
# path-resolve.sh — SSOT for the "first existing candidate path" pattern
# that repeats across firstboot.sh + setup.sh.
#
# Why this exists (v0.8 hardening track, PR9):
#   Both firstboot.sh and setup.sh repeat the same 5-line loop for every
#   helper script / module / unit file the installer needs to locate
#   under one of several possible directories (the SD bundle root, the
#   /opt install dir, the in-repo dev path, etc.):
#
#     SCRIPT=""
#     for _candidate in \
#         "$PATH1/script.sh" \
#         "$PATH2/script.sh" \
#         "$PATH3/script.sh"; do
#         [[ -f "$_candidate" ]] && SCRIPT="$_candidate" && break
#     done
#
#   16 occurrences in the two scripts: 9 in firstboot.sh, 7 in setup.sh.
#   Each adds 5 LOC of noise around the actual install logic the caller
#   cares about. The bug class the inline form hides:
#     - typo in the candidate list (silently falls through to next entry)
#     - candidate order matters for "prefer SD over /opt" semantics but
#       is invisible in a 5-line block
#     - a new candidate path added in one block but not another
#       (drift across install/upgrade paths)
#
# The helpers below collapse the loop to a single call:
#
#     resolve_first_existing_file SCRIPT "script.sh" \
#         "$PATH1" \
#         "$PATH2" \
#         "$PATH3" || true
#
# Bash 3.2 compatible (printf -v has worked since bash 3.1). No
# namerefs, no mapfile — same constraint as tests/*.sh per
# feedback_bash32_no_namerefs in MEMORY.md.

# resolve_first_existing_file VAR_NAME FILENAME CANDIDATE_DIR [CANDIDATE_DIR...]
#
# Sets VAR_NAME (via printf -v) to the first $CANDIDATE_DIR/$FILENAME
# that exists on disk; sets VAR_NAME="" and returns 1 if no candidate
# matches. Returns 0 on first match.
#
# The caller passes DIRECTORIES (not full paths) so the filename
# appears once instead of N times — typos in the filename are caught
# at first call. Order matters: first match wins; later candidates
# are intentionally fallback paths.
resolve_first_existing_file() {
    local var_name="$1" filename="$2"
    shift 2
    local dir
    for dir in "$@"; do
        if [[ -f "$dir/$filename" ]]; then
            printf -v "$var_name" '%s' "$dir/$filename"
            return 0
        fi
    done
    printf -v "$var_name" '%s' ''
    return 1
}

# resolve_first_existing_dir VAR_NAME CANDIDATE_DIR [CANDIDATE_DIR...]
#
# Sets VAR_NAME to the first candidate that is an existing directory;
# sets VAR_NAME="" and returns 1 if none. Used by callers that need a
# DIR (e.g. COMMON_MODULE_DIR lookup) rather than a file path.
resolve_first_existing_dir() {
    local var_name="$1"
    shift
    local dir
    for dir in "$@"; do
        if [[ -d "$dir" ]]; then
            printf -v "$var_name" '%s' "$dir"
            return 0
        fi
    done
    printf -v "$var_name" '%s' ''
    return 1
}
