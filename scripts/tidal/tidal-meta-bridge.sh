#!/usr/bin/env bash
# Metadata bridge for Tidal Connect.
# Scrapes tmux output from speaker_controller_application and writes
# track metadata as JSON to a shared file that meta_tidal.py reads.
#
# Adapted from TonyTromp/tidal-connect-docker volume-bridge.sh.
set -euo pipefail

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

wait_for_tmux

while true; do
    # Capture last 50 lines from speaker controller TUI
    OUTPUT=$(tmux capture-pane -t "$TMUX_SESSION" -pS -50 2>/dev/null) || {
        echo "tidal-meta-bridge: tmux capture failed, waiting for session..."
        wait_for_tmux
        continue
    }

    if [ -z "$OUTPUT" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Parse playback state (PLAYING, PAUSED, IDLE, BUFFERING)
    STATE=$(echo "$OUTPUT" | grep -o 'PlaybackState::[A-Z]*' | head -1 | cut -d: -f3) || true
    [ -z "$STATE" ] && STATE="IDLE"

    # Parse metadata from TUI panel text.
    # speaker_controller_application renders a curses TUI where the vertical
    # bar character appears as 'x' in tmux captures. Fields appear as:
    #   xartists: Artist Name   xx
    #   xtitle: Track Title     xx
    # The 'xx' at the end is where two adjacent panels meet.
    ARTIST=$(echo "$OUTPUT" | grep '^xartists:' | sed 's/^xartists: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//') || true
    TITLE=$(echo "$OUTPUT" | grep '^xtitle:' | sed 's/^xtitle: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//') || true
    ALBUM=$(echo "$OUTPUT" | grep '^xalbum name:' | sed 's/^xalbum name: //' | sed 's/xx.*$//' | sed 's/ *x*$//' | sed 's/[[:space:]]*$//') || true
    DURATION=$(echo "$OUTPUT" | grep '^xduration:' | sed 's/^xduration: //' | sed 's/xx.*$//' | sed 's/[[:space:]]*$//') || true

    # Parse position (e.g., "38 / 227")
    POSITION=$(echo "$OUTPUT" | grep -E '^ *[0-9]+ */ *[0-9]+$' | tr -d ' ' | cut -d'/' -f1) || true
    [ -z "$POSITION" ] && POSITION=0

    # Convert duration from milliseconds to seconds
    if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
        DURATION_SEC=$((DURATION / 1000))
    else
        DURATION_SEC=0
    fi

    # Only write on change
    STATUS_HASH="${STATE}|${ARTIST}|${TITLE}|${ALBUM}|${POSITION}"
    if [ "$STATUS_HASH" != "$PREV_HASH" ]; then
        TIMESTAMP=$(date +%s)

        # Escape backslashes first, then double quotes for valid JSON
        ARTIST_JSON=$(printf '%s' "$ARTIST" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
        TITLE_JSON=$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
        ALBUM_JSON=$(printf '%s' "$ALBUM" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')

        # Atomic write via temp file
        cat > "${METADATA_FILE}.tmp" <<EOF
{"state":"$STATE","artist":"$ARTIST_JSON","title":"$TITLE_JSON","album":"$ALBUM_JSON","duration":$DURATION_SEC,"position":${POSITION:-0},"timestamp":$TIMESTAMP}
EOF
        mv "${METADATA_FILE}.tmp" "$METADATA_FILE"

        if [ -n "$TITLE" ]; then
            echo "tidal-meta-bridge: $STATE — $ARTIST — $TITLE"
        fi
        PREV_HASH="$STATUS_HASH"
    fi

    sleep "$POLL_INTERVAL"
done
