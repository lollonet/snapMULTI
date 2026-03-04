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
            value="${value%%xx*}"       # strip from first 'xx' onward
            value="${value%% x}"        # strip trailing ' x'
            value="${value%"${value##*[! ]}"}"  # rtrim whitespace
            printf '%s' "$value"
            return
        fi
    done <<< "$output"
}

# Escape a string for safe JSON embedding.
# Bash handles backslash/quote escaping; tr strips control chars (U+0000-U+001F).
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s" | tr -d '\000-\037'
}

wait_for_tmux

while true; do
    # Capture last 50 lines from speaker controller TUI
    OUTPUT=$(tmux capture-pane -t "$TMUX_SESSION" -pS -50 2>/dev/null) || {
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

    # Parse position (e.g., "38 / 227") — bash only
    POSITION=0
    while IFS= read -r line; do
        # Match lines like "  38 / 227"
        line="${line#"${line%%[! ]*}"}"  # ltrim spaces
        if [[ "$line" =~ ^[0-9]+' '*/' '*[0-9]+$ ]]; then
            POSITION="${line%%[/ ]*}"
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
