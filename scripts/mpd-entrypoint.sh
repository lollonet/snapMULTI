#!/bin/sh
# MPD entrypoint: start MPD, wait for initial library scan to complete, then stay alive.
# This ensures the container is only healthy after the full scan — not mid-scan.
set -e

# Signal handling, registered before anything that can block (music wait,
# startup ping loop, initial scan). Before MPD exists, SIGTERM just exits.
# Once MPD runs, the signal is forwarded and the main path below keeps
# waiting until MPD has actually finished its shutdown (state file + db
# flush) — exiting PID 1 earlier makes the kernel SIGKILL MPD mid-shutdown.
MPD_PID=""
STOPPING=0
on_term() {
    STOPPING=1
    if [ -z "$MPD_PID" ]; then
        exit 0
    fi
    kill -TERM "$MPD_PID" 2>/dev/null || true
}
trap on_term TERM INT

# Wait for music files to be accessible (NFS/SMB may mount after Docker starts).
# Check for actual files, not just directories — overlayroot upper layer can show
# empty directory structure before NFS lower layer is fully mounted.
# Streaming-only installs have no library to wait for: skip the 120 s delay.
has_music() {
    [ "$(find /music -maxdepth 3 -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.wav' -o -name '*.aac' -o -name '*.opus' -o -name '*.wma' \) 2>/dev/null | head -1 | wc -l)" -ne 0 ]
}
case "${MUSIC_SOURCE:-}" in
    streaming|streaming-only)
        echo "Streaming-only install (MUSIC_SOURCE=$MUSIC_SOURCE) — not waiting for music files"
        ;;
    *)
        wait=0
        while ! has_music && [ "$wait" -lt 120 ]; do
            echo "Waiting for music files to be accessible... (${wait}s)"
            # Background + wait: `wait` returns as soon as a trapped signal
            # arrives, a foreground sleep would delay SIGTERM by up to 5 s.
            sleep 5 &
            wait $! || true
            wait=$((wait + 5))
        done
        if ! has_music; then
            echo "WARNING: no music files found after 120s — MPD may do a full rescan later"
        fi
        ;;
esac

mpd --no-daemon /etc/mpd.conf &
MPD_PID=$!
# A SIGTERM that landed between the music wait and the fork above only set
# STOPPING; forward it now that MPD exists.
if [ "$STOPPING" -eq 1 ]; then
    kill -TERM "$MPD_PID" 2>/dev/null || true
fi

# Wait for MPD to accept connections (check PID is still alive)
until [ "$STOPPING" -eq 1 ] || echo 'ping' | nc -w 1 127.0.0.1 6600 2>/dev/null | grep -q OK; do
    if ! kill -0 "$MPD_PID" 2>/dev/null; then
        [ "$STOPPING" -eq 1 ] && break
        echo "ERROR: MPD process died during startup"
        exit 1
    fi
    sleep 1
done

# Only force a scan if the database is empty or missing.
# A pre-built database (from prepare-sd.sh) gets a fast incremental update
# via auto_update in mpd.conf — no need to force a full rescan.
if [ "$STOPPING" -eq 0 ]; then
    song_count=$(mpc -p 6600 stats 2>/dev/null | awk '/Songs:/{print $2}') || true
    if [ "${song_count:-0}" -eq 0 ]; then
        echo "Empty database — triggering full library scan..."
        # Background + wait so SIGTERM during a long first scan is handled
        # immediately instead of after `mpc update --wait` returns.
        mpc -p 6600 update --wait 2>/dev/null &
        if ! wait $!; then
            [ "$STOPPING" -eq 1 ] || echo "WARNING: library scan failed or incomplete"
        fi
    else
        echo "Database has $song_count songs — auto_update handles incremental scan"
    fi
fi

# Wait for MPD to exit. A trapped signal interrupts `wait` (status > 128)
# while MPD is still shutting down, so loop until the PID is really gone;
# the final `wait` then reaps MPD and returns its own exit status.
set +e
while :; do
    wait "$MPD_PID"
    rc=$?
    kill -0 "$MPD_PID" 2>/dev/null || break
done
set -e
# SIGTERM (143) and SIGKILL (137) are normal during Docker stop — exit clean.
# Other signals (SIGSEGV=139, etc.) should propagate as failure.
if [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; then
    exit 0
fi
exit "$rc"
