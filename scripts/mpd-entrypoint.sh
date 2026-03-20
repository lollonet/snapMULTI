#!/bin/sh
# MPD entrypoint: start MPD, wait for initial library scan to complete, then stay alive.
# This ensures the container is only healthy after the full scan — not mid-scan.
set -e

mpd --no-daemon /etc/mpd.conf &
MPD_PID=$!

# Wait for MPD to accept connections
until echo 'ping' | nc -w 1 127.0.0.1 6600 2>/dev/null | grep -q OK; do
    sleep 1
done

# Trigger full library scan and wait for completion (blocks until MPD idle event)
mpc -p 6600 update --wait 2>/dev/null || true

# Forward SIGTERM/SIGINT to MPD, then wait for it to exit
trap 'kill -TERM "$MPD_PID"' TERM INT
wait $MPD_PID
exit $?
