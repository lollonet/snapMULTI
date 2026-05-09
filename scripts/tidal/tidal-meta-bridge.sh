#!/usr/bin/env bash
# Metadata bridge for Tidal Connect.
# Scrapes tmux output from speaker_controller_application and writes
# track metadata as JSON to a shared file that meta_tidal.py reads.
#
# Adapted from TonyTromp/tidal-connect-docker volume-bridge.sh.
set -euo pipefail
trap 'echo "tidal-meta-bridge: exiting (code $?)" >&2' EXIT

METADATA_FILE="${TIDAL_METADATA_FILE:-/audio/tidal-metadata.json}"
TMUX_SESSION="speaker"
POLL_INTERVAL="${TIDAL_META_POLL:-1}"
PREV_HASH=""

echo "tidal-meta-bridge: writing to $METADATA_FILE (poll=${POLL_INTERVAL}s)"

# Wait for speaker_controller_application tmux session
wait_for_tmux() {
    local attempts=0
    while ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ $((attempts % 30)) -eq 0 ]; then
            echo "tidal-meta-bridge: waiting for tmux session '$TMUX_SESSION'..."
        fi
        sleep 2
    done
}

# Extract a metadata field from TUI output using bash builtins.
# speaker_controller_application renders a curses TUI where the vertical
# bar character appears as 'x' in tmux captures. Fields appear as:
#   xartists: Artist Name   xx
#   xtitle: Track Title     xx
# The 'xx' at the end is where two adjacent panels meet.
extract_field() {
    local prefix="$1" output="$2" line value
    while IFS= read -r line; do
        if [[ "$line" == "${prefix}"* ]]; then
            value="${line#"$prefix"}"   # strip prefix
            # Strip the trailing TUI panel marker. The TUI renders
            #   "<field-content>  ...padding...  xx"
            # where the panel-end "xx" is preceded by AT LEAST 2 spaces
            # of column padding. Artist names like "Jamie xx" or song
            # titles containing "xx" have at most one space inside, so
            # the 2-space discriminator distinguishes panel marker from
            # content. The previous `${value%%xx*}` matched the FIRST
            # "xx" anywhere and truncated names like "Jamie xx" → "Jamie ".
            if [[ "$value" =~ ^(.*[^[:space:]])[[:space:]]{2,}xx[[:space:]]*$ ]]; then
                value="${BASH_REMATCH[1]}"
            fi
            value="${value% x}"          # also strip trailing ' x' (half-panel)
            value="${value%"${value##*[! ]}"}"  # rtrim whitespace
            printf '%s' "$value"
            return
        fi
    done <<< "$output"
}

# Strip ANSI/VT100 escape sequences and tmux 8-bit C1 representations.
# speaker_controller_application sets the terminal to 8-bit mode; tmux encodes
# C1 control chars (U+0080–U+009F) as ~@~X in 7-bit captures where X = char - 0x40,
# so the X character ranges from @ (0x40) to _ (0x5F), matched by [@-_].
strip_escapes() {
    sed \
        -e 's/\x1b\[[0-9;]*[A-Za-z]//g' \
        -e 's/\x1b[()][AB01]//g' \
        -e 's/\x1b.//g' \
        -e 's/~@~[@-_]//g'
}

# Escape a string for safe JSON embedding.
# Bash handles backslash/quote escaping; tr strips C0 control chars (U+0000-U+001F).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s" | tr -d '\000-\037'
}

wait_for_tmux

while true; do
    # Capture last 50 lines from speaker controller TUI
    OUTPUT=$(tmux capture-pane -t "$TMUX_SESSION" -pS -50 2>/dev/null | strip_escapes) || {
        echo "tidal-meta-bridge: tmux capture failed, waiting for session..."
        wait_for_tmux
        continue
    }

    if [[ -z "$OUTPUT" ]]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Parse playback state (PLAYING, PAUSED, IDLE, BUFFERING)
    STATE="IDLE"
    while IFS= read -r line; do
        if [[ "$line" == *PlaybackState::* ]]; then
            # Extract state name after last '::'
            STATE="${line##*PlaybackState::}"
            # Take only uppercase letters (trim trailing junk)
            STATE="${STATE%%[^A-Z]*}"
            break
        fi
    done <<< "$OUTPUT"

    # Parse metadata fields
    ARTIST=$(extract_field "xartists: " "$OUTPUT") || true
    TITLE=$(extract_field "xtitle: " "$OUTPUT") || true
    ALBUM=$(extract_field "xalbum name: " "$OUTPUT") || true
    DURATION=$(extract_field "xduration: " "$OUTPUT") || true

    # Parse position (e.g., "38 / 227") — bash only.
    # The TUI panel border is rendered as a literal "x" by speaker_controller_
    # application, so position lines come through tmux capture as
    # `x  38 / 227                          xx` (NOT `  38 / 227`).
    # `strip_escapes` only handles ANSI/C1 control sequences — the `x` is a
    # plain ASCII char and survives. The original anchored regex
    # `^[0-9]+...` could never match a line starting with `x`, so POSITION
    # stayed 0 forever and the progress bar never advanced on Tidal.
    # Use an anchorless regex with BASH_REMATCH capture so the position
    # pattern is found anywhere in the line, regardless of the leading
    # panel char or padding spaces. Other TUI lines (xduration:, xartists:)
    # do NOT contain a `<digits> / <digits>` pattern, so they don't match.
    POSITION=0
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+)[[:space:]]*/[[:space:]]*([0-9]+) ]]; then
            POSITION="${BASH_REMATCH[1]}"
            break
        fi
    done <<< "$OUTPUT"

    # Convert duration from milliseconds to seconds
    if [[ -n "$DURATION" ]] && [[ "$DURATION" -gt 0 ]] 2>/dev/null; then
        DURATION_SEC=$((DURATION / 1000))
    else
        DURATION_SEC=0
    fi

    # Only write on track/state change (position excluded — it increments
    # every second during playback and meta_tidal.py doesn't forward it)
    STATUS_HASH="${STATE}|${ARTIST}|${TITLE}|${ALBUM}"
    if [[ "$STATUS_HASH" != "$PREV_HASH" ]]; then
        TIMESTAMP=$(printf '%(%s)T' -1)

        ARTIST_JSON=$(json_escape "$ARTIST")
        TITLE_JSON=$(json_escape "$TITLE")
        ALBUM_JSON=$(json_escape "$ALBUM")

        # Atomic write via temp file
        cat > "${METADATA_FILE}.tmp" <<EOF
{"state":"$STATE","artist":"$ARTIST_JSON","title":"$TITLE_JSON","album":"$ALBUM_JSON","duration":$DURATION_SEC,"position":${POSITION:-0},"timestamp":$TIMESTAMP}
EOF
        mv "${METADATA_FILE}.tmp" "$METADATA_FILE"

        if [[ -n "$TITLE" ]]; then
            echo "tidal-meta-bridge: $STATE — $ARTIST — $TITLE"
        fi
        PREV_HASH="$STATUS_HASH"
    fi

    sleep "$POLL_INTERVAL"
done
