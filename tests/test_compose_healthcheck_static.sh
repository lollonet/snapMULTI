#!/usr/bin/env bash
# Static checks for healthchecks and start-up wiring in docker-compose.yml:
#   - no CMD-SHELL healthcheck uses `pgrep -f <literal>`: the check runs as
#     `/bin/sh -c "<test>"`, whose own cmdline contains the literal, so
#     pgrep -f always finds the shell and the check can never fail. A
#     bracketed first character (`[t]idal...`) or `pgrep -x` avoids that.
#   - tidal-connect is checked on the main Connect binary, not on the
#     speaker_controller metadata helper
#   - snapserver probes fast during start-up (start_interval)
#   - mpd receives MUSIC_SOURCE (streaming installs skip the music wait)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$SCRIPT_DIR/../docker-compose.yml"

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

# Print the lines of one service block.
service_block() {
    awk -v start="  $1:" '
        $0 == start { on = 1; next }
        on && /^  [a-z][a-z0-9_-]*:$/ { exit }
        on && /^[^[:space:]#]/ { exit }
        on { print }
    ' "$COMPOSE"
}

# Return 0 when the given CMD-SHELL test string has a self-matching
# `pgrep -f <pattern>` (pattern without any regex bracket expression).
self_matching_pgrep() {
    local test_str="$1" pat
    # Every `pgrep [opts] -f [opts] <pattern>` occurrence; pattern may be quoted.
    while read -r pat; do
        [[ -n "$pat" ]] || continue
        pat="${pat#\'}"; pat="${pat%\'}"
        pat="${pat#\\\"}"; pat="${pat%\\\"}"
        [[ "$pat" == *"["*"]"* ]] || return 0
    done < <(printf '%s\n' "$test_str" \
        | grep -oE "pgrep( -[a-zA-Z]+)* -f( -[a-zA-Z]+)* ('[^']*'|\\\\\"[^\"]*\\\\\"|[^ |;&]+)" \
        | sed -E 's/^pgrep( -[a-zA-Z]+)* -f( -[a-zA-Z]+)* //')
    return 1
}

echo "## self-matching pgrep -f detector (unit)"
assert "self_matching_pgrep 'pgrep -f speaker_controller || exit 1'" \
    "flags bare literal: pgrep -f speaker_controller"
assert "self_matching_pgrep \"pgrep -f 'tidal_connect_application' >/dev/null || exit 1\"" \
    "flags quoted literal: pgrep -f 'tidal_connect_application'"
assert "! self_matching_pgrep \"pgrep -f '[t]idal_connect_application' >/dev/null || exit 1\"" \
    "accepts bracket trick: pgrep -f '[t]idal_connect_application'"
assert "! self_matching_pgrep 'pgrep -x shairport-sync && test -p /audio/airplay_fifo || exit 1'" \
    "accepts pgrep -x (matches comm, not cmdline)"

echo
echo "## docker-compose.yml healthchecks"
checked=0
while IFS= read -r line; do
    checked=$((checked + 1))
    if self_matching_pgrep "$line"; then
        assert "false" "self-matching pgrep -f in healthcheck: ${line#"${line%%[![:space:]]*}"}"
    fi
done < <(grep -E '^[[:space:]]+test: \["CMD-SHELL",' "$COMPOSE")
assert "(( checked >= 5 ))" "scanned all CMD-SHELL healthchecks ($checked found)"
assert "(( fail == 0 ))" "no CMD-SHELL healthcheck uses a self-matching pgrep -f literal"

# shellcheck disable=SC2034  # read inside assert's eval
tidal="$(service_block tidal-connect)"
assert "[[ -n \"\$tidal\" ]]" "tidal-connect service block found"
assert "printf '%s\n' \"\$tidal\" | grep -E 'test: \\[\"CMD-SHELL\"' | grep -q 'idal_connect_application'" \
    "tidal-connect healthcheck checks tidal_connect_application (main binary)"
assert "! printf '%s\n' \"\$tidal\" | grep -E 'test: \\[\"CMD-SHELL\"' | grep -q 'speaker_controller'" \
    "tidal-connect healthcheck no longer checks the speaker_controller helper"

echo
echo "## snapserver start-up probe"
# shellcheck disable=SC2034
snapserver="$(service_block snapserver)"
assert "printf '%s\n' \"\$snapserver\" | grep -qE '^      start_interval: [0-9]+s$'" \
    "snapserver healthcheck has start_interval"
assert "printf '%s\n' \"\$snapserver\" | grep -qE '^      start_period: [0-9]+s$'" \
    "snapserver healthcheck has start_period (start_interval only applies inside it)"

echo
echo "## mpd music wait"
# shellcheck disable=SC2034
mpd="$(service_block mpd)"
assert "printf '%s\n' \"\$mpd\" | grep -qF -- '- MUSIC_SOURCE=\${MUSIC_SOURCE:-}'" \
    "mpd gets MUSIC_SOURCE from .env (empty default keeps the wait)"

echo
echo "## Summary"
echo "  Passed: $pass"
echo "  Failed: $fail"
[[ $fail -eq 0 ]]
