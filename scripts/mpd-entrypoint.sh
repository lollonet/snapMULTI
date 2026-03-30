#!/bin/sh
# MPD entrypoint: start MPD, wait for initial library scan to complete, then stay alive.
# This ensures the container is only healthy after the full scan — not mid-scan.
set -e

# Wait for music directory to have content (NFS/SMB may mount after Docker starts).
# Without this, MPD scans an empty /music and purges the pre-built database.
wait=0
while [ -z "$(ls -A /music 2>/dev/null)" ] && [ "$wait" -lt 120 ]; do
    echo "Waiting for /music to be mounted... (${wait}s)"
    sleep 5
    wait=$((wait + 5))
done
if [ -z "$(ls -A /music 2>/dev/null)" ]; then
    echo "WARNING: /music still empty after 120s — MPD will do a full rescan when it appears"
fi

mpd --no-daemon /etc/mpd.conf &
MPD_PID=$!

# Register signal forwarding immediately — before any blocking calls.
# Without this, Docker SIGTERM during the initial library scan is silently
# ignored (default PID-1 behaviour), causing Docker to wait the full stop
# timeout before sending SIGKILL and forcing an ungraceful MPD shutdown.
trap 'kill -TERM "$MPD_PID"' TERM INT

# Wait for MPD to accept connections
until echo 'ping' | nc -w 1 127.0.0.1 6600 2>/dev/null | grep -q OK; do
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
exit $?
