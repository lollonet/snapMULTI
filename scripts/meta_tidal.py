#!/usr/bin/env python3
"""Tidal Connect → Snapserver metadata bridge.

Controlscript that watches /tmp/tidal-status.json and sends metadata to Snapserver.
Communicates with Snapserver via stdin/stdout JSON-RPC (Plugin.Stream protocol).
"""

import json
import os
import sys
import hashlib
import select
from pathlib import Path
from typing import Any

# Configuration
STATUS_FILE = Path(os.environ.get("TIDAL_STATUS_FILE", "/tmp/tidal-status.json"))
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "1.0"))

# Current state
metadata: dict[str, Any] = {}
playback_status = "stopped"
last_hash = ""


def log(msg: str) -> None:
    """Log to stderr (stdout is reserved for JSON-RPC)."""
    print(f"[meta_tidal] {msg}", file=sys.stderr, flush=True)


def send(obj: dict) -> None:
    """Send JSON-RPC message to Snapserver via stdout."""
    print(json.dumps(obj), flush=True)


def send_properties() -> None:
    """Send current playback properties to Snapserver."""
    send({
        "jsonrpc": "2.0",
        "method": "Plugin.Stream.Player.Properties",
        "params": {
            "playbackStatus": playback_status,
            "metadata": metadata,
        }
    })


def map_state(state: str) -> str:
    """Map Tidal state to Snapcast playbackStatus."""
    return {
        "PLAYING": "playing",
        "PAUSED": "paused",
    }.get(state, "stopped")


def read_status() -> bool:
    """Read status file and update metadata. Returns True if changed."""
    global metadata, playback_status, last_hash

    if not STATUS_FILE.exists():
        return False

    try:
        content = STATUS_FILE.read_text()
        current_hash = hashlib.md5(content.encode()).hexdigest()

        if current_hash == last_hash:
            return False
        last_hash = current_hash

        data = json.loads(content)

        # Map state
        new_status = map_state(data.get("state", "IDLE"))

        # Build metadata (Snapcast MPRIS format)
        new_metadata = {}
        if title := data.get("title"):
            new_metadata["title"] = title
        if artist := data.get("artist"):
            new_metadata["artist"] = [artist]  # Array format
        if album := data.get("album"):
            new_metadata["album"] = album
        if duration := data.get("duration"):
            new_metadata["duration"] = float(duration)
        if art_url := data.get("artUrl"):
            new_metadata["artUrl"] = art_url

        # Check if anything changed
        if new_status != playback_status or new_metadata != metadata:
            playback_status = new_status
            metadata = new_metadata
            log(f"{playback_status}: {metadata.get('artist', ['?'])[0]} - {metadata.get('title', '?')}")
            return True
        return False

    except (json.JSONDecodeError, IOError) as e:
        log(f"Error reading status: {e}")
        return False


def handle_request(line: str) -> None:
    """Handle incoming JSON-RPC request from Snapserver."""
    try:
        req = json.loads(line)
        method = req.get("method", "")
        rid = req.get("id")

        if method == "Plugin.Stream.GetProperties":
            send({
                "jsonrpc": "2.0",
                "id": rid,
                "result": {
                    "playbackStatus": playback_status,
                    "canControl": False,
                    "canGoNext": False,
                    "canGoPrevious": False,
                    "canPause": False,
                    "canPlay": False,
                    "canSeek": False,
                    "metadata": metadata,
                }
            })
        elif method == "Plugin.Stream.GetMetadata":
            send({"jsonrpc": "2.0", "id": rid, "result": metadata})
        else:
            # Unknown method - respond with ok
            send({"jsonrpc": "2.0", "id": rid, "result": "ok"})

    except json.JSONDecodeError as e:
        log(f"Invalid JSON request: {e}")


def main() -> None:
    """Main event loop."""
    log(f"Starting, watching {STATUS_FILE}")

    # Signal ready to Snapserver
    send({"jsonrpc": "2.0", "method": "Plugin.Stream.Ready"})

    # Initial read
    if read_status():
        send_properties()

    while True:
        # Check for input from Snapserver (with timeout for polling)
        readable, _, _ = select.select([sys.stdin], [], [], POLL_INTERVAL)

        if readable:
            line = sys.stdin.readline()
            if not line:
                log("stdin closed, exiting")
                break
            handle_request(line.strip())

        # Poll status file
        if read_status():
            send_properties()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("Interrupted")
    except Exception as e:
        log(f"Fatal error: {e}")
        sys.exit(1)
