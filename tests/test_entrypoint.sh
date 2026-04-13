#!/usr/bin/env bash
set -euo pipefail

# Test MIXER validation logic from entrypoint.sh
# Runs the validation block in isolation without exec'ing snapclient.

pass=0
fail=0

# Write the validation logic to a temp file (avoids quoting issues)
VALIDATOR=$(mktemp)
trap 'rm -f "$VALIDATOR"' EXIT

cat > "$VALIDATOR" << 'VALIDATION'
#!/bin/sh
MIXER="${MIXER:-software}"
validate_string() {
    case "$1" in
        *[\'\"\\$\`\;\&\|\>\<\(\)\{\}\[\]]*)
            echo "REJECTED"
            exit 1
            ;;
    esac
}
MIXER_MODE="${MIXER%%:*}"
case "${MIXER_MODE}" in
    software|hardware|none) ;;
    *) MIXER=software ;;
esac
validate_string "${MIXER}" "MIXER"
echo "$MIXER"
VALIDATION

assert_mixer() {
    local input="$1" expected="$2" desc="$3"
    actual=$(MIXER="$input" sh "$VALIDATOR" 2>/dev/null) || actual="REJECTED"

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc (${input} -> ${actual})"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (${input} -> ${actual}, expected ${expected})"
        fail=$((fail + 1))
    fi
}

echo "Testing MIXER validation..."

# Valid modes (pass through unchanged)
assert_mixer "software"          "software"          "bare software"
assert_mixer "hardware"          "hardware"          "bare hardware"
assert_mixer "none"              "none"              "bare none"
assert_mixer "hardware:Digital"  "hardware:Digital"  "hardware with element"
assert_mixer "hardware:PCM"      "hardware:PCM"      "hardware with PCM element"

# Invalid modes (fallback to software)
assert_mixer "invalid"           "software"           "invalid mode falls back"
assert_mixer "script"            "software"           "script mode rejected"

# Empty MIXER uses default (software)
assert_mixer ""                  "software"           "empty falls back to default"

# Invalid mode with metacharacters (neutralized by mode fallback)
assert_mixer 'hardware;rm'       "software"          "semicolon in mode falls back"
assert_mixer 'bad$(cmd)'         "software"          "cmd subst in mode falls back"

# Valid mode prefix with metacharacters in element (caught by validate_string)
assert_mixer 'hardware:x;rm'     "REJECTED"          "semicolon in element rejected"
assert_mixer 'hardware:$(cmd)'   "REJECTED"          "cmd subst in element rejected"
assert_mixer 'hardware:x&bg'     "REJECTED"          "ampersand in element rejected"

# ── ALSA_BUFFER_TIME validation ──

ALSA_VALIDATOR=$(mktemp)
trap 'rm -f "$VALIDATOR" "$ALSA_VALIDATOR"' EXIT

cat > "$ALSA_VALIDATOR" << 'ALSA_VALIDATION'
#!/bin/sh
ALSA_BUFFER_TIME="${ALSA_BUFFER_TIME:-150}"
ALSA_FRAGMENTS="${ALSA_FRAGMENTS:-4}"

case "${ALSA_BUFFER_TIME}" in
    ''|*[!0-9]*) ALSA_BUFFER_TIME=150 ;;
esac
if [ "${ALSA_BUFFER_TIME}" -lt 50 ] || [ "${ALSA_BUFFER_TIME}" -gt 2000 ]; then
    ALSA_BUFFER_TIME=150
fi

case "${ALSA_FRAGMENTS}" in
    ''|*[!0-9]*) ALSA_FRAGMENTS=4 ;;
esac
if [ "${ALSA_FRAGMENTS}" -lt 2 ] || [ "${ALSA_FRAGMENTS}" -gt 16 ]; then
    ALSA_FRAGMENTS=4
fi

echo "${ALSA_BUFFER_TIME}/${ALSA_FRAGMENTS}"
ALSA_VALIDATION

assert_alsa() {
    local buf="$1" frag="$2" expected="$3" desc="$4"
    actual=$(ALSA_BUFFER_TIME="$buf" ALSA_FRAGMENTS="$frag" sh "$ALSA_VALIDATOR" 2>/dev/null) || actual="ERROR"

    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc (${buf}/${frag} -> ${actual})"
        pass=$((pass + 1))
    else
        echo "  FAIL: $desc (${buf}/${frag} -> ${actual}, expected ${expected})"
        fail=$((fail + 1))
    fi
}

echo ""
echo "Testing ALSA buffer validation..."

# Valid values (pass through unchanged)
assert_alsa "150" "4"  "150/4"   "ethernet defaults"
assert_alsa "250" "8"  "250/8"   "wifi defaults"
assert_alsa "50"  "2"  "50/2"    "minimum values"
assert_alsa "2000" "16" "2000/16" "maximum values"

# Out of range (fallback to defaults)
assert_alsa "49"   "4"  "150/4"   "buffer below minimum"
assert_alsa "2001" "4"  "150/4"   "buffer above maximum"
assert_alsa "150"  "1"  "150/4"   "fragments below minimum"
assert_alsa "150"  "17" "150/4"   "fragments above maximum"

# Non-numeric (fallback to defaults)
assert_alsa "abc"  "4"  "150/4"   "non-numeric buffer"
assert_alsa "150"  "x"  "150/4"   "non-numeric fragments"
assert_alsa ""     ""   "150/4"   "empty values use defaults"

echo ""
if [[ "$fail" -gt 0 ]]; then
    echo "FAILED: $fail tests failed, $pass passed"
    exit 1
fi
echo "All $pass tests passed!"
