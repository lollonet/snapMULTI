#!/usr/bin/env bash
# Sourced as a helper library; `set -euo pipefail` intentionally omitted.
#
# install-conf-reader.sh — SSOT for the install.conf field-read pattern
# that repeats 12 times in firstboot.sh.
#
# Why this exists (v0.8 hardening track, PR10):
#   firstboot.sh parses install.conf with this exact shape:
#
#     VAR=$(grep -m1 '^VAR=' "$SNAP_BOOT/install.conf" \
#               | cut -d= -f2 | tr -d '[:space:]' || true)
#
#   12 occurrences with two minor variants:
#     - 10 use `cut -d= -f2 | tr -d '[:space:]'` (strip-all)
#     - 2 use `cut -d= -f2- | tr -d '\r'` (preserve `=` in value,
#       strip only \r — required for SMB_PASS and SMB_USER which can
#       contain whitespace + special chars)
#   Plus an inline `_rc()` local function at firstboot.sh:156 that
#   wraps the same idiom for the ENABLE_READONLY / SKIP_UPGRADE /
#   VERBOSE_INSTALL trio.
#
#   Drift classes the inline form hides:
#     1. A new field added to install.conf.template but the
#        firstboot.sh read never lands → operator picks the value in
#        prepare-sd's menu but firstboot silently uses the hardcoded
#        default.
#     2. A field is read with the wrong strip mode → a SMB password
#        containing trailing whitespace or an `=` survives prepare-sd
#        but gets corrupted at firstboot.
#     3. Per-field grep/cut/tr expressions drift apart (one uses
#        `cut -d= -f2`, another uses `-f2-`) — silently stripping data
#        from values that contain `=`.
#
# Always use `cut -d= -f2-` so values containing `=` (passwords,
# base64-style tokens) survive. The simple case `VAR=value` returns
# `value` identically under `-f2` and `-f2-`.

# install_conf_get FIELD CONF_FILE [STRIP_MODE]
#
#   FIELD       Name on the left of `=` in the config file.
#   CONF_FILE   Path to install.conf (or compatible KEY=VALUE file).
#   STRIP_MODE  Optional, default "all":
#                 all  → tr -d '[:space:]'  (spaces, tabs, \r, \n)
#                 cr   → tr -d '\r'         (only carriage returns,
#                                            for password-style fields
#                                            where whitespace is data)
#                 none → preserve the cut output verbatim
#
# Echoes the value on stdout. Echoes empty when the field is absent
# or the file does not exist. Returns 0 in both cases (the empty
# string IS a valid result — callers default-fall through with
# `[[ -n "$x" ]] && X=$x` or with parameter expansion `${X:-default}`).
# Returns 1 only on an unknown STRIP_MODE argument (programming error).
install_conf_get() {
    local field="$1" conf="$2" strip="${3:-all}"
    # Defensive: the FIELD name is interpolated into a `grep` regex.
    # We CANNOT use `grep -F` because it would also treat the leading
    # `^` as literal (verified: `grep -F "^FOO=" file` matches the
    # literal-caret line, NOT the start-of-line). So instead we
    # constrain FIELD to a shell-style identifier — the same shape
    # every legitimate caller already uses. This forecloses on regex
    # injection via crafted field names while preserving the start-of-
    # line anchor. PR #585 review caught the latent regex risk.
    if [[ ! "$field" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "install_conf_get: invalid field name '$field' (must match [A-Za-z_][A-Za-z0-9_]*)" >&2
        return 1
    fi
    local raw
    raw=$(grep -m1 "^${field}=" "$conf" 2>/dev/null | cut -d= -f2- || true)
    case "$strip" in
        all)  tr -d '[:space:]' <<< "$raw" ;;
        cr)   tr -d '\r'        <<< "$raw" ;;
        none) printf '%s' "$raw" ;;
        *)
            echo "install_conf_get: unknown strip mode '$strip' (want all|cr|none)" >&2
            return 1
            ;;
    esac
}
