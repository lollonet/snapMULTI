#!/usr/bin/env python3
"""
Tidal Connect metadata reader for Snapcast.

Watches a JSON file written by tidal-meta-bridge.sh (which scrapes metadata
from speaker_controller_application's tmux TUI) and forwards track metadata
to snapserver via JSON-RPC over stdin/stdout.

Environment variables:
    TIDAL_METADATA_FILE  Path to metadata JSON file (default: /audio/tidal-metadata.json)
"""

import fcntl
import json
import os
import select
import sys
import time
from threading import Lock, Thread

METADATA_FILE = os.environ.get("TIDAL_METADATA_FILE", "/audio/tidal-metadata.json")
POLL_INTERVAL = 1.0

debug_mode = "--debug" in sys.argv

# Lock guards metadata/playback_status reads+writes and all stdout sends,
# preventing partial-update reads and interleaved JSON-RPC output between
# the main thread (stdin handler) and the file-watcher background thread.
_lock = Lock()

metadata: dict[str, str | list[str] | float] = {
    "title": "",
    "artist": [],
    "album": "",
    "artUrl": "",
    "duration": 0.0,
}

playback_status = "unknown"


def send(msg: dict) -> None:
    """Send JSON-RPC message to snapserver via stdout (must hold _lock)."""
    try:
        print(json.dumps(msg), flush=True)
    except BrokenPipeError:
        pass


def log(level: str, msg: str) -> None:
    """Log to stderr and send to snapserver."""
    sys.stderr.write(f"[{level.upper()}] meta_tidal: {msg}\n")
    sys.stderr.flush()
    with _lock:
        send({"jsonrpc": "2.0", "method": "Plugin.Stream.Log",
              "params": {"severity": level, "message": f"meta_tidal: {msg}"}})


def send_properties() -> None:
    """Send current metadata and playback status to snapserver.

    Must be called with _lock held.
    """
    props: dict = {}
    if metadata["title"]:
        props["title"] = metadata["title"]
    if metadata["artist"]:
        props["artist"] = metadata["artist"]
    if metadata["album"]:
        props["album"] = metadata["album"]
    if metadata["artUrl"]:
        props["artUrl"] = metadata["artUrl"]
    if metadata["duration"]:
        props["duration"] = metadata["duration"]

    params: dict = {}
    if props:
        params["metadata"] = props
    if playback_status != "unknown":
        params["playbackStatus"] = playback_status

    if params:
        artist = props.get("artist", ["?"])
        artist_str = artist[0] if isinstance(artist, list) and artist else "?"
        sys.stderr.write(f"[INFO] meta_tidal: {playback_status}: {artist_str} - {props.get('title', '?')}\n")
        sys.stderr.flush()
        send({"jsonrpc": "2.0", "method": "Plugin.Stream.Player.Properties",
              "params": params})


def apply_metadata(data: dict) -> bool:
    """Apply metadata from the bridge JSON file.

    Expected format (written by tidal-meta-bridge.sh):
        {"state":"PLAYING","artist":"Name","title":"Track","album":"Album",
         "duration":227,"position":38,"timestamp":1234567890}

    Returns True if metadata changed and should be sent to snapserver.
    """
    global playback_status
    changed = False

    if debug_mode:
        sys.stderr.write(f"[DEBUG] meta_tidal: File data: {json.dumps(data)[:500]}\n")
        sys.stderr.flush()

    title = str(data.get("title", ""))
    if title and title != metadata["title"]:
        metadata["title"] = title
        changed = True

    # Artist clears to [] when empty (unlike title/album which preserve previous
    # values). This is intentional: the bridge's STATUS_HASH includes ARTIST, so
    # an empty artist only arrives on a genuine state transition, not mid-render.
    artist = data.get("artist", "")
    artist_list = [artist] if isinstance(artist, str) and artist else []
    if artist_list != metadata["artist"]:
        metadata["artist"] = artist_list
        changed = True

    album = str(data.get("album", ""))
    if album and album != metadata["album"]:
        metadata["album"] = album
        changed = True

    duration = data.get("duration", 0)
    if duration:
        dur_f = float(duration)
        if dur_f != metadata["duration"]:
            metadata["duration"] = dur_f
            changed = True

    # Map speaker_controller states to Snapcast states
    state_raw = str(data.get("state", "")).upper()
    state_map = {
        "PLAYING": "playing",
        "PAUSED": "paused",
        "IDLE": "stopped",
        "STOPPED": "stopped",
        "BUFFERING": "playing",
    }
    state = state_map.get(state_raw)
    if state and state != playback_status:
        playback_status = state
        changed = True

    return changed


def file_watch_thread() -> None:
    """Background thread: poll metadata JSON file for changes.

    On x86_64 deployments (no tidal-connect), the file never appears.
    Backs off to 5-minute retries to avoid log noise.
    """
    last_mtime = 0.0
    delay = POLL_INTERVAL
    ever_found = False

    while True:
        try:
            stat = os.stat(METADATA_FILE)
        except FileNotFoundError:
            if not ever_found and delay < 300:
                delay = min(delay * 2, 300)
            time.sleep(delay)
            continue

        if not ever_found:
            log("info", f"Metadata file found: {METADATA_FILE}")
            ever_found = True
            delay = POLL_INTERVAL

        if stat.st_mtime <= last_mtime:
            time.sleep(POLL_INTERVAL)
            continue

        last_mtime = stat.st_mtime

        try:
            with open(METADATA_FILE) as f:
                data = json.load(f)
            with _lock:
                if apply_metadata(data):
                    send_properties()
        except (json.JSONDecodeError, OSError, TypeError, AttributeError) as e:
            last_mtime = 0.0  # retry next poll
            if debug_mode:
                sys.stderr.write(f"[DEBUG] meta_tidal: File read error: {e}\n")
                sys.stderr.flush()

        time.sleep(POLL_INTERVAL)


def _filtered_metadata() -> dict:
    """Return metadata dict with empty/zero values removed."""
    return {k: v for k, v in metadata.items() if v}


def handle_stdin_line(line: str) -> None:
    """Process a JSON-RPC request from snapserver."""
    try:
        req = json.loads(line)
        rid = req.get("id")
        method = req.get("method", "")

        with _lock:
            if method == "Plugin.Stream.GetMetadata":
                send({"jsonrpc": "2.0", "id": rid, "result": _filtered_metadata()})
            elif method == "Plugin.Stream.GetProperties":
                send({"jsonrpc": "2.0", "id": rid, "result": {
                    "playbackStatus": playback_status,
                    "canControl": False,
                    "canGoNext": False,
                    "canGoPrevious": False,
                    "canPause": False,
                    "canPlay": False,
                    "canSeek": False,
                }})
            elif method == "Plugin.Stream.Player.Control":
                send({"jsonrpc": "2.0", "id": rid, "error": {
                    "code": -32601,
                    "message": "Tidal Connect does not support remote control"}})
            else:
                send({"jsonrpc": "2.0", "id": rid, "result": "ok"})
    except json.JSONDecodeError:
        pass
    except Exception as e:
        log("error", f"stdin error: {e}")


def main() -> None:
    """Main event loop: select() on stdin + file watcher in background thread."""
    log("info", "Starting meta_tidal...")
    log("info", f"Watching metadata file: {METADATA_FILE}")
    if debug_mode:
        log("info", "Debug mode enabled")

    # Signal ready to snapserver
    with _lock:
        send({"jsonrpc": "2.0", "method": "Plugin.Stream.Ready"})

    # Start file watcher in background
    thread = Thread(target=file_watch_thread, daemon=True)
    thread.start()

    # Make stdin non-blocking
    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    stdin_buffer = ""
    MAX_BUFFER = 65536  # 64 KB safety cap — snapserver sends small JSON-RPC messages

    while True:
        try:
            readable, _, _ = select.select([sys.stdin], [], [], 1.0)
        except (ValueError, OSError):
            readable = []

        for fd in readable:
            try:
                chunk = fd.read(4096)
                if not chunk:
                    log("info", "stdin EOF, continuing...")
                    try:
                        sys.stdin.close()
                    except Exception:
                        pass
                    # Keep running for file watcher thread
                    while True:
                        time.sleep(60)
                stdin_buffer += chunk
                if len(stdin_buffer) > MAX_BUFFER:
                    log("warning", "stdin buffer overflow, discarding")
                    stdin_buffer = ""
                while "\n" in stdin_buffer:
                    line, stdin_buffer = stdin_buffer.split("\n", 1)
                    if line.strip():
                        handle_stdin_line(line)
            except (IOError, OSError):
                pass


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("info", "Interrupted, exiting")
    except Exception as e:
        log("error", f"Fatal error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
