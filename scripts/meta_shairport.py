#!/usr/bin/env python3
"""
Shairport-sync metadata reader for Snapcast.

Reads metadata from shairport-sync pipe and forwards to snapserver via JSON-RPC.
Uses single-threaded event loop with select() - no daemon threads.
"""

import base64
import json
import os
import re
import select
import socket
import struct
import sys
import time
import urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler
from threading import Thread
from typing import Any

METADATA_PIPE = os.environ.get("METADATA_PIPE", "/audio/shairport-metadata")
COVER_ART_PORT = int(os.environ.get("COVER_ART_PORT", "5858"))

metadata: dict[str, str | list[str] | float] = {
    "artist": [],
    "album": "",
    "title": "",
    "artUrl": "",
    "duration": 0.0,
    "genre": [],
    "composer": [],
}
cover_art_path = "/tmp/cover.jpg"

# Per-track cover state. shairport-sync sends a track's text metadata as a
# bundle (mdst ... mden) and its picture separately (pcst / PICT / pcen),
# usually right after. The cover URL used to be the same /cover.jpg for every
# track and was only cleared on `pend`, so the metadata-service fetched the
# PREVIOUS track's picture under the new track's key. Now:
#   - a new track (different title/artist/album at mden) clears artUrl
#     unless its PICT already arrived inside this bundle;
#   - each PICT bumps cover_version and publishes /cover.jpg?v=<n>, so every
#     picture has a distinct URL (no cache aliasing downstream);
#   - the HTTP server only serves the current version (stale ?v= -> 404).
cover_version = 0
cover_data: tuple[int, bytes] | None = None  # (version, bytes), swapped atomically
_in_bundle = False
_pict_in_bundle = False
_last_track_id: tuple | None = None


def send(msg: dict) -> None:
    """Send JSON-RPC message to snapserver via stdout."""
    try:
        print(json.dumps(msg), flush=True)
    except BrokenPipeError:
        pass  # stdout closed, ignore


def log(level: str, msg: str) -> None:
    """Log to stderr and send to snapserver."""
    sys.stderr.write(f"[{level.upper()}] meta_shairport: {msg}\n")
    sys.stderr.flush()
    send(
        {
            "jsonrpc": "2.0",
            "method": "Plugin.Stream.Log",
            "params": {"severity": level, "message": f"meta_shairport: {msg}"},
        }
    )


def send_metadata() -> None:
    """Send current metadata to snapserver."""
    props: dict[str, str | list[str] | float] = {}
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
    if metadata["genre"]:
        props["genre"] = metadata["genre"]
    if metadata["composer"]:
        props["composer"] = metadata["composer"]
    if props:
        artist = props.get("artist", ["?"])
        artist_str = artist[0] if isinstance(artist, list) and artist else "?"
        log("info", f"Metadata: {artist_str} - {props.get('title', '?')}")
    else:
        # Clear: send empty metadata so clients don't show stale info (e.g. after playback end)
        log("info", "Metadata cleared")
    # Always send — empty props clears stale metadata on clients
    send(
        {
            "jsonrpc": "2.0",
            "method": "Plugin.Stream.Player.Properties",
            "params": {"metadata": props},
        }
    )


def hex_to_str(h: str) -> str:
    """Convert hex string to ASCII."""
    try:
        return bytes.fromhex(h).decode("ascii")
    except (ValueError, UnicodeDecodeError):
        return h


def get_host_ip() -> str | None:
    """Get host IP address for cover art URL (reachable from clients).

    Returns None if no reachable host can be determined — caller should
    not publish an artUrl in that case.
    """
    # First check explicit environment variable
    explicit_ip = os.environ.get("COVER_ART_HOST")
    if explicit_ip:
        return explicit_ip

    # Try to get actual IP by connecting to a known address
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        pass

    # No reachable IP found — don't fall back to localhost/hostname.local
    # (unreachable from other devices on the network)
    return None


def parse_item(item_data: bytes) -> None:
    """Parse a single metadata item from shairport-sync XML."""
    try:
        item_xml = item_data.decode("utf-8", errors="replace")
    except Exception:
        return

    code_m = re.search(r"<code>([^<]+)</code>", item_xml)
    data_m = re.search(r"<data[^>]*>([^<]*)</data>", item_xml, re.DOTALL)

    if not code_m:
        return

    code = hex_to_str(code_m.group(1))
    data: str | bytes = ""

    if data_m and data_m.group(1):
        raw = data_m.group(1).replace("\n", "").replace("\r", "").strip()
        if raw:
            try:
                raw_bytes = base64.b64decode(raw)
                # Keep as bytes for binary codes (PICT, astm)
                if code in ("PICT", "astm"):
                    data = raw_bytes
                else:
                    data = raw_bytes.decode("utf-8", errors="replace")
            except Exception:
                pass

    if code == "asal" and isinstance(data, str):
        metadata["album"] = data
    elif code == "asar" and isinstance(data, str) and data:
        metadata["artist"] = [data]
    elif code == "minm" and isinstance(data, str):
        metadata["title"] = data
    elif code == "asgn" and isinstance(data, str) and data:
        metadata["genre"] = [data]
    elif code == "ascp" and isinstance(data, str) and data:
        metadata["composer"] = [data]
    elif code == "PICT":
        handle_picture(data if isinstance(data, bytes) else b"")
    elif code == "astm" and isinstance(data, bytes) and len(data) >= 4:
        # Song time in milliseconds (32-bit big-endian unsigned int)
        try:
            ms = struct.unpack(">I", data[:4])[0]
            metadata["duration"] = ms / 1000.0  # Convert to seconds
        except Exception:
            pass
    elif code == "mdst":
        start_bundle()
    elif code == "mden":
        end_bundle()
    elif code == "pend":
        reset_track_state()
        metadata["artist"], metadata["album"] = [], ""
        metadata["title"], metadata["artUrl"], metadata["duration"] = "", "", 0.0
        metadata["genre"], metadata["composer"] = [], []
        send_metadata()


def _track_id() -> tuple:
    artist = metadata["artist"]
    return (
        metadata["title"],
        tuple(artist) if isinstance(artist, list) else artist,
        metadata["album"],
    )


def reset_track_state() -> None:
    """Forget per-track cover state (playback ended)."""
    global cover_data, _in_bundle, _pict_in_bundle, _last_track_id
    cover_data = None
    _in_bundle = False
    _pict_in_bundle = False
    _last_track_id = None


def start_bundle() -> None:
    """mdst: a new metadata bundle begins.

    Track-specific fields a sender may omit (no astm, no genre) must not
    carry over from the previous track.
    """
    global _in_bundle, _pict_in_bundle
    _in_bundle = True
    _pict_in_bundle = False
    metadata["duration"] = 0.0
    metadata["genre"], metadata["composer"] = [], []


def end_bundle() -> None:
    """mden: publish the track; drop the old cover if the track changed."""
    global _in_bundle, _pict_in_bundle, _last_track_id, cover_data
    track = _track_id()
    if track != _last_track_id and not _pict_in_bundle:
        # New track and its picture hasn't arrived yet: publish text now,
        # the PICT (if any) follows and re-publishes with its own URL.
        metadata["artUrl"] = ""
        cover_data = None
    _last_track_id = track
    _in_bundle = False
    _pict_in_bundle = False
    send_metadata()


def handle_picture(data: bytes) -> None:
    """PICT: store the cover under a fresh version and publish its URL.

    An empty PICT means "this track has no artwork" and clears the URL.
    Outside a metadata bundle the update is sent immediately; inside one it
    goes out with the bundle's mden.
    """
    global cover_version, cover_data, _pict_in_bundle
    if _in_bundle:
        _pict_in_bundle = True
    if not data:
        cover_data = None
        metadata["artUrl"] = ""
    else:
        cover_version += 1
        cover_data = (cover_version, data)
        try:
            # On-disk copy kept for debugging / older tooling.
            tmp_path = str(cover_art_path) + ".tmp"
            with open(tmp_path, "wb") as f:
                f.write(data)
            os.replace(tmp_path, cover_art_path)
        except Exception as e:
            log("warning", f"Cover art error: {e}")
        host = get_host_ip()
        if host:
            metadata["artUrl"] = (
                f"http://{host}:{COVER_ART_PORT}/cover.jpg?v={cover_version}"
            )
        else:
            log(
                "warning",
                "Cannot determine reachable host IP — cover art URL omitted",
            )
            metadata["artUrl"] = ""
    if not _in_bundle:
        send_metadata()


def handle_stdin_line(line: str) -> None:
    """Process a JSON-RPC request from snapserver."""
    try:
        req = json.loads(line)
        rid = req.get("id")
        method = req.get("method", "")

        if method == "Plugin.Stream.GetMetadata":
            send({"jsonrpc": "2.0", "id": rid, "result": metadata})
        elif method == "Plugin.Stream.GetProperties":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": rid,
                    "result": {
                        "canControl": False,
                        "canGoNext": False,
                        "canGoPrevious": False,
                        "canPause": False,
                        "canPlay": False,
                        "canSeek": False,
                    },
                }
            )
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": "ok"})
    except json.JSONDecodeError:
        pass
    except Exception as e:
        log("error", f"stdin error: {e}")


def cover_bytes_for_path(path: str) -> bytes | None:
    """Bytes to serve for an HTTP path, or None for 404.

    `/cover.jpg?v=N` is served only while N is the current picture, so a
    late fetch of an old track's URL can never return the new track's
    picture. Bare `/cover.jpg` returns the current picture (compatibility).
    """
    parsed = urllib.parse.urlsplit(path)
    if parsed.path != "/cover.jpg":
        return None
    current = cover_data  # single read: (version, bytes) swapped atomically
    if current is None:
        return None
    version, body = current
    requested = urllib.parse.parse_qs(parsed.query).get("v")
    if requested and requested[0] != str(version):
        return None
    return body


class CoverHandler(SimpleHTTPRequestHandler):
    """Simple HTTP handler to serve cover art."""

    def do_GET(self) -> None:
        body = cover_bytes_for_path(self.path)
        if body is not None:
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args: object) -> None:
        pass  # Suppress HTTP logs


def start_cover_server() -> None:
    """Start cover art HTTP server in background thread."""
    try:
        server = HTTPServer(("0.0.0.0", COVER_ART_PORT), CoverHandler)
        server.serve_forever()
    except Exception as e:
        log("error", f"Cover server error: {e}")


def extract_items(pipe_buffer: bytearray) -> tuple[list[bytes], bytearray]:
    """Split every complete <item>...</item> off pipe_buffer.

    Returns (items, remaining buffer). A bytearray is used so a multi-MB
    PICT arriving in 8 KB reads isn't re-copied on every read.
    """
    items: list[bytes] = []
    while b"<item>" in pipe_buffer and b"</item>" in pipe_buffer:
        start = pipe_buffer.find(b"<item>")
        end = pipe_buffer.find(b"</item>") + 7
        if 0 <= start < end:
            items.append(bytes(pipe_buffer[start:end]))
            del pipe_buffer[:end]
        else:
            # Orphan </item> appears BEFORE <item> (corrupt
            # pipe / mid-stream startup). Without this slice
            # the buffer kept the orphan forever, growing
            # to MAX_PIPE_BUFFER (10 MB) before reset and
            # losing all metadata in between. Drop the
            # prefix up to the next <item> and keep going: complete
            # items behind it must not wait for the next pipe read.
            pipe_buffer = pipe_buffer[start:]
            continue
    return items, pipe_buffer


def open_metadata_pipe() -> int | None:
    """Open metadata pipe, return file descriptor or None."""
    if not os.path.exists(METADATA_PIPE):
        return None
    try:
        # Open non-blocking
        fd = os.open(METADATA_PIPE, os.O_RDONLY | os.O_NONBLOCK)
        return fd
    except OSError as e:
        log("warning", f"Cannot open pipe: {e}")
        return None


def main() -> None:
    """Main event loop using select() on stdin and metadata pipe."""
    log("info", "Starting meta_shairport...")

    # Signal ready to snapserver
    send({"jsonrpc": "2.0", "method": "Plugin.Stream.Ready"})

    # Start cover art server in background (this one can be a daemon thread)
    cover_thread = Thread(target=start_cover_server, daemon=True)
    cover_thread.start()
    log("info", f"Cover server started on port {COVER_ART_PORT}")

    # Buffers with safety caps to prevent unbounded growth
    stdin_buffer = ""
    pipe_buffer = bytearray()
    MAX_STDIN_BUFFER = 65536  # 64 KB — snapserver sends small JSON-RPC messages
    MAX_PIPE_BUFFER = 10485760  # 10 MB — high-res ALAC embedded art can exceed 1 MB
    pipe_fd: int | None = None
    last_pipe_check = 0.0

    # Make stdin non-blocking
    import fcntl

    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    log("info", "Entering main loop")

    # Track whether stdin has been closed so we don't re-include it in the
    # select watch list — otherwise select.select() on a closed FD raises
    # OSError(EBADF) immediately, the except clause swallows it, and the
    # outer while-True loop spins at 100% CPU. The plugin must keep running
    # after stdin closes (snapserver may have restarted) to continue
    # forwarding pipe metadata.
    stdin_closed = False

    while True:
        # Build list of file descriptors to watch
        read_fds: list[Any] = []
        if not stdin_closed:
            read_fds.append(sys.stdin)

        # Try to open pipe if not open, but not too frequently
        now = time.time()
        if pipe_fd is None and (now - last_pipe_check) > 2.0:
            last_pipe_check = now
            pipe_fd = open_metadata_pipe()
            if pipe_fd is not None:
                log("info", f"Opened metadata pipe: {METADATA_PIPE}")

        if pipe_fd is not None:
            read_fds.append(pipe_fd)

        # Nothing to watch (stdin closed AND pipe not open yet) — sleep so
        # the loop doesn't spin while we wait for the pipe to come back.
        if not read_fds:
            time.sleep(1.0)
            continue

        try:
            readable, _, _ = select.select(read_fds, [], [], 1.0)
        except (ValueError, OSError):
            # stdin closed or other error
            readable = []

        for fd in readable:
            # Handle stdin
            if fd == sys.stdin or (
                hasattr(fd, "fileno") and fd.fileno() == sys.stdin.fileno()
            ):
                try:
                    chunk = sys.stdin.read(4096)
                    # On a non-blocking TextIOWrapper, read() returns:
                    #   - None when no complete data is ready (would-block,
                    #     e.g. partial UTF-8 sequence in the buffer)
                    #   - "" only on TRUE EOF (writer closed)
                    # `if not chunk:` matched both, prematurely closing stdin
                    # on a transient would-block. Distinguish the two now.
                    if chunk is None:
                        # Would-block — leave stdin open, retry next select
                        continue
                    if not chunk:
                        # stdin EOF - snapserver closed connection.
                        # Set the flag so the next iteration's read_fds
                        # build skips stdin entirely — otherwise select
                        # on the closed FD raises EBADF and the loop
                        # busy-spins at 100% CPU.
                        log("info", "stdin EOF, continuing...")
                        stdin_closed = True
                        try:
                            sys.stdin.close()
                        except Exception:
                            pass
                        continue
                    stdin_buffer += chunk
                    if len(stdin_buffer) > MAX_STDIN_BUFFER:
                        log("warning", "stdin buffer overflow, discarding")
                        stdin_buffer = ""
                    while "\n" in stdin_buffer:
                        line, stdin_buffer = stdin_buffer.split("\n", 1)
                        if line.strip():
                            handle_stdin_line(line)
                except (IOError, OSError):
                    pass

            # Handle metadata pipe
            elif fd == pipe_fd:
                try:
                    chunk = os.read(pipe_fd, 8192)
                    if not chunk:
                        # Pipe EOF - writer closed, reopen
                        log("info", "Pipe EOF, will reopen...")
                        os.close(pipe_fd)
                        pipe_fd = None
                        pipe_buffer = bytearray()
                        continue

                    pipe_buffer += chunk
                    if len(pipe_buffer) > MAX_PIPE_BUFFER:
                        log("warning", "pipe buffer overflow, discarding")
                        pipe_buffer = bytearray()

                    items, pipe_buffer = extract_items(pipe_buffer)
                    for item_data in items:
                        try:
                            parse_item(item_data)
                        except Exception as e:
                            log("warning", f"Parse error: {e}")
                except OSError as e:
                    log("warning", f"Pipe read error: {e}")
                    if pipe_fd is not None:
                        try:
                            os.close(pipe_fd)
                        except Exception:
                            pass
                    pipe_fd = None
                    pipe_buffer = bytearray()


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
