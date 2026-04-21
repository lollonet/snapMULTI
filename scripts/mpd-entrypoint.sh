#!/bin/sh
# MPD entrypoint: start MPD, wait for initial library scan to complete, then stay alive.
# This ensures the container is only healthy after the full scan — not mid-scan.
set -e

# Wait for music files to be accessible (NFS/SMB may mount after Docker starts).
# Check for actual files, not just directories — overlayroot upper layer can show
# empty directory structure before NFS lower layer is fully mounted.
wait=0
while [ "$(find /music -maxdepth 3 -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.wav' -o -name '*.aac' -o -name '*.opus' -o -name '*.wma' \) 2>/dev/null | head -1 | wc -l)" -eq 0 ] && [ "$wait" -lt 120 ]; do
    echo "Waiting for music files to be accessible... (${wait}s)"
    sleep 5
    wait=$((wait + 5))
done
if [ "$(find /music -maxdepth 3 -type f \( -name '*.mp3' -o -name '*.flac' -o -name '*.m4a' -o -name '*.ogg' -o -name '*.wav' -o -name '*.aac' -o -name '*.opus' -o -name '*.wma' \) 2>/dev/null | head -1 | wc -l)" -eq 0 ]; then
    echo "WARNING: no music files found after 120s — MPD may do a full rescan later"
fi

mpd --no-daemon /etc/mpd.conf &
MPD_PID=$!

# Register signal forwarding immediately — before any blocking calls.
# Without this, Docker SIGTERM during the initial library scan is silently
# ignored (default PID-1 behaviour), causing Docker to wait the full stop
# timeout before sending SIGKILL and forcing an ungraceful MPD shutdown.
trap 'kill -TERM "$MPD_PID"' TERM INT

# Wait for MPD to accept connections (check PID is still alive)
until echo 'ping' | nc -w 1 127.0.0.1 6600 2>/dev/null | grep -q OK; do
    if ! kill -0 "$MPD_PID" 2>/dev/null; then
        echo "ERROR: MPD process died during startup"
        exit 1
    fi
    sleep 1
done

# Only force a scan if the database is empty or missing.
# A pre-built database (from prepare-sd.sh) gets a fast incremental update
# via auto_update in mpd.conf — no need to force a full rescan.
song_count=$(mpc -p 6600 stats 2>/dev/null | awk '/Songs:/{print $2}') || true
if [ "${song_count:-0}" -eq 0 ]; then
    echo "Empty database — triggering full library scan..."
    mpc -p 6600 update --wait 2>/dev/null || echo "WARNING: library scan failed or incomplete"
else
    echo "Database has $song_count songs — auto_update handles incremental scan"
fi
wait $MPD_PID
rc=$?
# Signal termination (128+N) is normal during Docker stop — exit 0
if [ "$rc" -gt 128 ]; then
    exit 0
fi
exit $rc
