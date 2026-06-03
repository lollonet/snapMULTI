#!/usr/bin/env bash
# scripts/common/env-reader.sh — SSOT for runtime `.env`-style key/value reads.
#
# Why a helper:
#   Runtime .env parsing was duplicated across smoke modules + diagnostics with
#   subtle drift — `cut -d= -f2` (truncates values containing `=`),
#   `tr -d '\r[:space:]'` (aggressive), `tr -d '"' | sed 's/[[:space:]]*$//'`
#   (quote-trim), and one `grep | cut` raw form. The drift mostly cancelled
#   on simple values, but a password / token / base64 with `=` or CR would
#   silently corrupt depending on the caller. Centralising the read with
#   explicit strip modes makes the intent visible at every call site.
#
# This helper is RUNTIME ONLY — it parses values from already-deployed
# `.env` files on the device (`/opt/snapmulti/.env`, `/opt/snapclient/.env`).
# It is NOT a replacement for `install_conf_get` in
# scripts/common/install-conf-reader.sh, which parses `/boot/.../install.conf`
# during firstboot (different schema, different lifecycle).
#
# Contract:
#   env_get KEY FILE [STRIP_MODE]
#     KEY        — must match `^[A-Za-z_][A-Za-z0-9_]*$`; invalid → rc 1.
#     FILE       — path to a `.env`-style file; missing file → "" + rc 0.
#     STRIP_MODE — one of: none | cr | trim | all (default: trim).
#                  Unknown mode → rc 1.
#
# Strip modes:
#   none  — raw value after `KEY=`, preserves whitespace/CR/quotes verbatim
#   cr    — strip only trailing `\r` (handles CRLF-saved .env files)
#   trim  — strip surrounding double quotes + trailing CR/whitespace
#   all   — strip every whitespace + CR (legacy aggressive behaviour)
#
# Always uses `cut -d= -f2-` (NOT `-f2`) so values containing `=` survive —
# same convention as install_conf_get. First match wins (`grep -m1`); a
# `.env` with duplicate keys is malformed and the first occurrence has
# always been the de-facto value (matches what `bash -a; source file; echo
# $X` would yield).
#
# Sourced by: scripts/common/play-smoke-tone.sh, scripts/smoke/check_system.sh,
# scripts/smoke/check_mounts.sh, scripts/smoke/check_qos.sh,
# scripts/diagnostic.sh (post v0.8.x SSOT-extraction track).

# NB: `set -euo pipefail` intentionally omitted — this is a function library
# sourced into callers that already manage their own error mode. Every error
# path uses explicit `return 1` or `printf '' + return 0`.

env_get() {
    local key="$1" file="$2" strip_mode="${3:-trim}"

    # Input validation: key must be a POSIX-portable identifier. This forecloses
    # on regex injection at the grep boundary AND surfaces typos at the caller
    # rather than silently returning empty. Same shape as install_conf_get's
    # field validation in install-conf-reader.sh.
    if [[ ! "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "env_get: invalid key '$key' (must match [A-Za-z_][A-Za-z0-9_]*)" >&2
        return 1
    fi

    case "$strip_mode" in
        none|cr|trim|all) ;;
        *)
            echo "env_get: unknown strip mode '$strip_mode' (want none|cr|trim|all)" >&2
            return 1
            ;;
    esac

    # Missing file → empty value, rc 0. Callers test `if [[ -n "$x" ]]`; a
    # missing .env on a client-only install is normal, not a fault.
    if [[ ! -f "$file" ]]; then
        printf ''
        return 0
    fi

    local raw
    # `cut -d= -f2-` preserves values containing `=` (passwords, base64,
    # query strings). `|| true` keeps the assignment alive under `set -e`
    # in the caller when grep finds no match.
    raw=$(grep -m1 "^${key}=" "$file" 2>/dev/null | cut -d= -f2- || true)

    case "$strip_mode" in
        none)
            printf '%s' "$raw"
            ;;
        cr)
            # Strip trailing CR only — covers Windows-edited .env files
            # without touching legitimate inner whitespace or quotes.
            printf '%s' "$raw" | tr -d '\r'
            ;;
        trim)
            # Strip CR + surrounding double quotes + trailing whitespace.
            # Matches the pre-helper behaviour of `tr -d '"' | sed 's/
            # [[:space:]]*$//'` for the common case of clean values; values
            # with embedded `"` are NOT supported (malformed anyway under
            # POSIX shell .env semantics). bash 3.2 compatible — uses
            # parameter expansion + a single sed for the tail strip.
            local stripped="$raw"
            stripped="${stripped%$'\r'}"
            stripped="${stripped#\"}"
            stripped="${stripped%\"}"
            printf '%s' "$stripped" | sed 's/[[:space:]]*$//'
            ;;
        all)
            # Aggressive: strip every whitespace + CR. tr DOES recognise
            # `[:space:]` as a character class even when concatenated
            # with literal characters in the SET — pre-helper code in
            # play-smoke-tone.sh relied on this and we preserve the
            # behaviour exactly. Use for opt-out flags / numeric values
            # where any whitespace is a bug.
            printf '%s' "$raw" | tr -d '\r[:space:]'
            ;;
    esac
}
