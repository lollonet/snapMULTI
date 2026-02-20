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
from http.server import HTTPServer, SimpleHTTPRequestHandler
from threading import Thread

METADATA_PIPE = os.environ.get("METADATA_PIPE", "/audio/shairport-metadata")
COVER_ART_PORT = int(os.environ.get("COVER_ART_PORT", "5858"))

metadata: dict[str, str | list[str] | float] = {
    "artist": [], "album": "", "title": "", "artUrl": "", "duration": 0.0,
    "genre": [], "composer": [],
}
cover_art_path = "/tmp/cover.jpg"


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
    send({"jsonrpc": "2.0", "method": "Plugin.Stream.Log",
          "params": {"severity": level, "message": f"meta_shairport: {msg}"}})


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
        # Use Plugin.Stream.Player.Properties with metadata key (same as meta_mpd.py)
        send({"jsonrpc": "2.0", "method": "Plugin.Stream.Player.Properties",
              "params": {"metadata": props}})


def hex_to_str(h: str) -> str:
    """Convert hex string to ASCII."""
    try:
        return bytes.fromhex(h).decode("ascii")
    except (ValueError, UnicodeDecodeError):
        return h


def get_host_ip() -> str:
    """Get host IP address for cover art URL (reachable from clients)."""
    # First check explicit environment variable
    explicit_ip = os.environ.get("COVER_ART_HOST")
    if explicit_ip:
        return explicit_ip

    # Try to get actual IP by connecting to a known address
    try:
        # Connect to public DNS to determine which interface is used
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except Exception:
        pass

    # Fallback to hostname (works if mDNS is configured)
    hostname = os.environ.get("HOSTNAME", "localhost")
    if hostname != "localhost":
        return f"{hostname}.local"  # mDNS suffix
    return "localhost"


# Cache the host IP at startup
_host_ip: str | None = None


def parse_item(item_data: bytes) -> None:
    """Parse a single metadata item from shairport-sync XML."""
    global _host_ip

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
    elif code == "PICT" and isinstance(data, bytes) and len(data) > 0:
        try:
            with open(cover_art_path, "wb") as f:
                f.write(data)
            # Cache host IP on first use
            if _host_ip is None:
                _host_ip = get_host_ip()
            metadata["artUrl"] = f"http://{_host_ip}:{COVER_ART_PORT}/cover.jpg"
        except Exception as e:
            log("warning", f"Cover art error: {e}")
    elif code == "astm" and isinstance(data, bytes) and len(data) >= 4:
        # Song time in milliseconds (32-bit big-endian unsigned int)
        try:
            ms = struct.unpack(">I", data[:4])[0]
            metadata["duration"] = ms / 1000.0  # Convert to seconds
        except Exception:
            pass
    elif code == "mden":
        send_metadata()
    elif code == "pend":
        metadata["artist"], metadata["album"] = [], ""
        metadata["title"], metadata["artUrl"], metadata["duration"] = "", "", 0.0
        metadata["genre"], metadata["composer"] = [], []
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
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "canControl": False, "canGoNext": False, "canGoPrevious": False,
                "canPause": False, "canPlay": False, "canSeek": False}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "result": "ok"})
    except json.JSONDecodeError:
        pass
    except Exception as e:
        log("error", f"stdin error: {e}")


class CoverHandler(SimpleHTTPRequestHandler):
    """Simple HTTP handler to serve cover art."""

    def do_GET(self) -> None:
        if self.path == "/cover.jpg" and os.path.exists(cover_art_path):
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            with open(cover_art_path, "rb") as f:
                self.wfile.write(f.read())
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
    pipe_buffer = b""
    MAX_STDIN_BUFFER = 65536    # 64 KB — snapserver sends small JSON-RPC messages
    MAX_PIPE_BUFFER = 1048576   # 1 MB — cover art PICT items can be large
    pipe_fd: int | None = None
    last_pipe_check = 0.0

    # Make stdin non-blocking
    import fcntl
    flags = fcntl.fcntl(sys.stdin.fileno(), fcntl.F_GETFL)
    fcntl.fcntl(sys.stdin.fileno(), fcntl.F_SETFL, flags | os.O_NONBLOCK)

    log("info", "Entering main loop")

    while True:
        # Build list of file descriptors to watch
        read_fds = [sys.stdin]

        # Try to open pipe if not open, but not too frequently
        now = time.time()
        if pipe_fd is None and (now - last_pipe_check) > 2.0:
            last_pipe_check = now
            pipe_fd = open_metadata_pipe()
            if pipe_fd is not None:
                log("info", f"Opened metadata pipe: {METADATA_PIPE}")

        if pipe_fd is not None:
            read_fds.append(pipe_fd)

        try:
            readable, _, _ = select.select(read_fds, [], [], 1.0)
        except (ValueError, OSError):
            # stdin closed or other error
            readable = []

        for fd in readable:
            # Handle stdin
            if fd == sys.stdin or (hasattr(fd, "fileno") and fd.fileno() == sys.stdin.fileno()):
                try:
                    chunk = sys.stdin.read(4096)
                    if not chunk:
                        # stdin EOF - snapserver closed connection
                        # Keep running to continue reading metadata
                        log("info", "stdin EOF, continuing...")
                        # Remove stdin from future selects by making it invalid
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
                        pipe_buffer = b""
                        continue

                    pipe_buffer += chunk
                    if len(pipe_buffer) > MAX_PIPE_BUFFER:
                        log("warning", "pipe buffer overflow, discarding")
                        pipe_buffer = b""

                    # Process complete <item>...</item> tags
                    while b"<item>" in pipe_buffer and b"</item>" in pipe_buffer:
                        start = pipe_buffer.find(b"<item>")
                        end = pipe_buffer.find(b"</item>") + 7
                        if 0 <= start < end:
                            item_data = pipe_buffer[start:end]
                            pipe_buffer = pipe_buffer[end:]
                            try:
                                parse_item(item_data)
                            except Exception as e:
                                log("warning", f"Parse error: {e}")
                        else:
                            break
                except OSError as e:
                    log("warning", f"Pipe read error: {e}")
                    if pipe_fd is not None:
                        try:
                            os.close(pipe_fd)
                        except Exception:
                            pass
                    pipe_fd = None
                    pipe_buffer = b""


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
