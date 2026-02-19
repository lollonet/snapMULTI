#!/usr/bin/env python3
"""
Tidal Connect metadata reader for Snapcast.

Connects to tidal-connect's WebSocket API and forwards track metadata
to snapserver via JSON-RPC over stdin/stdout.

Uses websocket-client (synchronous) in a background thread + select() on stdin.

Environment variables:
    TIDAL_WS_HOST   WebSocket host (default: 127.0.0.1)
    TIDAL_WS_PORT   WebSocket port (default: 8888)
"""

import fcntl
import json
import os
import select
import sys
import time
from threading import Lock, Thread

import websocket

WS_HOST = os.environ.get("TIDAL_WS_HOST", "127.0.0.1")
WS_PORT = int(os.environ.get("TIDAL_WS_PORT", "8888"))
RECONNECT_DELAY = 5
MAX_RECONNECT_DELAY = 60

debug_mode = "--debug" in sys.argv

# Lock guards metadata/playback_status reads+writes and all stdout sends,
# preventing partial-update reads and interleaved JSON-RPC output between
# the main thread (stdin handler) and the WebSocket background thread.
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


def parse_tidal_message(data: dict) -> bool:
    """Parse a WebSocket message from tidal-connect.

    Returns True if metadata was updated and should be sent.
    """
    global playback_status
    changed = False

    if debug_mode:
        # Log to stderr only (not via log() which acquires _lock — caller holds it)
        sys.stderr.write(f"[DEBUG] meta_tidal: Raw WS message: {json.dumps(data)[:500]}\n")
        sys.stderr.flush()

    # Try multiple known message formats from tidal-connect

    # Format 1: Direct fields (title, artist, album, etc.)
    if "title" in data:
        metadata["title"] = str(data.get("title", ""))
        changed = True
    if "artist" in data:
        artist = data["artist"]
        metadata["artist"] = [artist] if isinstance(artist, str) else list(artist)
        changed = True
    if "album" in data:
        metadata["album"] = str(data.get("album", ""))
        changed = True
    if "duration" in data:
        dur = data["duration"]
        # Could be seconds or milliseconds
        metadata["duration"] = float(dur) / 1000.0 if float(dur) > 10000 else float(dur)
        changed = True

    # Artwork URL — try several field names
    for art_key in ("artUrl", "artwork", "cover", "imageUrl", "image"):
        if art_key in data and data[art_key]:
            metadata["artUrl"] = str(data[art_key])
            changed = True
            break

    # Playback state
    state = None
    if "playing" in data:
        state = "playing" if data["playing"] else "paused"
    elif "state" in data:
        state_val = str(data["state"]).lower()
        if state_val in ("playing", "play"):
            state = "playing"
        elif state_val in ("paused", "pause"):
            state = "paused"
        elif state_val in ("stopped", "stop", "idle"):
            state = "stopped"
    elif "status" in data:
        status_val = str(data["status"]).lower()
        if "play" in status_val:
            state = "playing"
        elif "pause" in status_val:
            state = "paused"
        elif "stop" in status_val or "idle" in status_val:
            state = "stopped"

    if state and state != playback_status:
        playback_status = state
        changed = True

    # Format 2: Nested in "data" or "payload"
    if not changed:
        for wrapper_key in ("data", "payload", "track"):
            if wrapper_key in data and isinstance(data[wrapper_key], dict):
                return parse_tidal_message(data[wrapper_key])

    return changed


def ws_thread() -> None:
    """Background thread: connect to tidal-connect WebSocket and parse messages."""
    delay = RECONNECT_DELAY

    while True:
        url = f"ws://{WS_HOST}:{WS_PORT}"
        try:
            log("info", f"Connecting to {url}")
            ws = websocket.WebSocket()
            ws.connect(url, timeout=10)
            log("info", "Connected to tidal-connect WebSocket")
            delay = RECONNECT_DELAY  # Reset backoff on success

            while True:
                raw = ws.recv()
                if not raw:
                    break
                try:
                    data = json.loads(raw)
                    with _lock:
                        if parse_tidal_message(data):
                            send_properties()
                except json.JSONDecodeError:
                    if debug_mode:
                        log("debug", f"Non-JSON message: {raw[:200]}")
        except (ConnectionRefusedError, OSError) as e:
            log("warning", f"Connection failed: {e}")
        except websocket.WebSocketException as e:
            log("warning", f"WebSocket error: {e}")
        except Exception as e:
            log("error", f"Unexpected error: {e}")
        finally:
            try:
                ws.close()
            except Exception:
                pass

        log("info", f"Reconnecting in {delay}s...")
        time.sleep(delay)
        delay = min(delay * 2, MAX_RECONNECT_DELAY)


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
    """Main event loop: select() on stdin + WebSocket in background thread."""
    log("info", "Starting meta_tidal...")
    if debug_mode:
        log("info", "Debug mode enabled — logging raw WebSocket messages")

    # Signal ready to snapserver
    with _lock:
        send({"jsonrpc": "2.0", "method": "Plugin.Stream.Ready"})

    # Start WebSocket reader in background
    thread = Thread(target=ws_thread, daemon=True)
    thread.start()
    log("info", f"WebSocket thread started (target: {WS_HOST}:{WS_PORT})")

    # Make stdin non-blocking
    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    stdin_buffer = ""

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
                    # Keep running for WebSocket thread
                    while True:
                        time.sleep(60)
                stdin_buffer += chunk
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
