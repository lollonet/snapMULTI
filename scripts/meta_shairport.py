#!/usr/bin/env python3
"""
Shairport-sync metadata reader for Snapcast.

Reads metadata from shairport-sync pipe and forwards to snapserver via JSON-RPC.
Based on the snapcast meta plugin protocol.

Metadata format from shairport-sync:
<item><type>xxxx</type><code>yyyy</code><length>n</length>
<data encoding="base64">...</data></item>

Common codes:
- core/asal: album
- core/asar: artist
- core/minm: title (item name)
- ssnc/PICT: cover art (JPEG/PNG)
- ssnc/pbeg: playback begin
- ssnc/pend: playback end
"""

import base64
import json
import os
import re
import select
import sys
import tempfile
import threading
from http.server import HTTPServer, SimpleHTTPRequestHandler

# Metadata pipe path (shared volume with shairport-sync container)
METADATA_PIPE = os.environ.get("METADATA_PIPE", "/audio/shairport-metadata")

# Cover art server port
COVER_ART_PORT = int(os.environ.get("COVER_ART_PORT", "5858"))

# Current metadata state
metadata = {
    "artist": [],
    "album": "",
    "title": "",
    "artUrl": "",
}

# Cover art storage
cover_art_data = None
cover_art_path = "/tmp/cover.jpg"


def send(json_msg):
    """Send JSON-RPC message to snapserver via stdout."""
    print(json.dumps(json_msg), flush=True)


def log(level, message):
    """Send log message to snapserver."""
    send({
        "jsonrpc": "2.0",
        "method": "Plugin.Stream.Log",
        "params": {"severity": level, "message": f"meta_shairport: {message}"}
    })


def send_metadata():
    """Send current metadata to snapserver."""
    props = {}

    if metadata["title"]:
        props["title"] = metadata["title"]
    if metadata["artist"]:
        props["artist"] = metadata["artist"]
    if metadata["album"]:
        props["album"] = metadata["album"]
    if metadata["artUrl"]:
        props["artUrl"] = metadata["artUrl"]

    if props:
        send({
            "jsonrpc": "2.0",
            "method": "Plugin.Stream.SetMetadata",
            "params": {"metadata": props}
        })


def hex_to_str(hex_str):
    """Convert hex string to ASCII."""
    try:
        return bytes.fromhex(hex_str).decode('ascii')
    except Exception:
        return hex_str


def parse_metadata_item(item_xml):
    """Parse a single metadata item from XML."""
    global cover_art_data

    # Extract type, code, and data using regex
    type_match = re.search(r'<type>([^<]+)</type>', item_xml)
    code_match = re.search(r'<code>([^<]+)</code>', item_xml)
    data_match = re.search(r'<data[^>]*>([^<]*)</data>', item_xml)

    if not type_match or not code_match:
        return

    # Type and code are hex-encoded ASCII
    item_type = hex_to_str(type_match.group(1))
    item_code = hex_to_str(code_match.group(1))
    item_data = ""

    if data_match and data_match.group(1):
        try:
            item_data = base64.b64decode(data_match.group(1)).decode('utf-8', errors='replace')
        except Exception:
            # Binary data (like cover art)
            if data_match.group(1):
                try:
                    item_data = base64.b64decode(data_match.group(1))
                except Exception:
                    pass

    # Process based on code
    if item_code == "asal":  # Album
        metadata["album"] = item_data if isinstance(item_data, str) else ""
    elif item_code == "asar":  # Artist
        if isinstance(item_data, str) and item_data:
            metadata["artist"] = [item_data]
    elif item_code == "minm":  # Title (item name)
        metadata["title"] = item_data if isinstance(item_data, str) else ""
    elif item_code == "PICT":  # Cover art
        if isinstance(item_data, bytes) and len(item_data) > 0:
            cover_art_data = item_data
            # Write to file for HTTP serving
            try:
                with open(cover_art_path, 'wb') as f:
                    f.write(item_data)
                # Set artUrl to local HTTP server
                hostname = os.environ.get("HOSTNAME", "localhost")
                metadata["artUrl"] = f"http://{hostname}:{COVER_ART_PORT}/cover.jpg"
            except Exception as e:
                log("warning", f"Failed to write cover art: {e}")
    elif item_code == "pbeg":  # Playback begin
        log("info", "Playback started")
    elif item_code == "pend":  # Playback end
        log("info", "Playback ended")
        # Clear metadata
        metadata["artist"] = []
        metadata["album"] = ""
        metadata["title"] = ""
        metadata["artUrl"] = ""
        send_metadata()
    elif item_code == "prsm":  # Playback resume
        pass
    elif item_code == "pffr":  # Playback flush (track change)
        send_metadata()


def read_metadata_pipe():
    """Read and parse metadata from shairport-sync pipe."""
    log("info", f"Opening metadata pipe: {METADATA_PIPE}")

    # Wait for pipe to exist
    while not os.path.exists(METADATA_PIPE):
        import time
        time.sleep(1)

    buffer = ""

    while True:
        try:
            with open(METADATA_PIPE, 'r', encoding='utf-8', errors='replace') as pipe:
                while True:
                    chunk = pipe.read(4096)
                    if not chunk:
                        break

                    buffer += chunk

                    # Process complete items
                    while '<item>' in buffer and '</item>' in buffer:
                        start = buffer.find('<item>')
                        end = buffer.find('</item>') + len('</item>')

                        if start >= 0 and end > start:
                            item_xml = buffer[start:end]
                            buffer = buffer[end:]

                            try:
                                parse_metadata_item(item_xml)
                            except Exception as e:
                                log("warning", f"Error parsing metadata: {e}")
                        else:
                            break

                    # Send metadata after processing
                    if metadata["title"] or metadata["artist"]:
                        send_metadata()

        except FileNotFoundError:
            import time
            time.sleep(1)
        except Exception as e:
            log("error", f"Pipe read error: {e}")
            import time
            time.sleep(1)


class CoverArtHandler(SimpleHTTPRequestHandler):
    """Simple HTTP handler for serving cover art."""

    def do_GET(self):
        if self.path == "/cover.jpg" and os.path.exists(cover_art_path):
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            with open(cover_art_path, 'rb') as f:
                self.wfile.write(f.read())
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress HTTP logs


def start_cover_art_server():
    """Start HTTP server for cover art."""
    try:
        server = HTTPServer(('0.0.0.0', COVER_ART_PORT), CoverArtHandler)
        log("info", f"Cover art server started on port {COVER_ART_PORT}")
        server.serve_forever()
    except Exception as e:
        log("error", f"Cover art server failed: {e}")


def handle_stdin():
    """Handle JSON-RPC commands from snapserver."""
    while True:
        if select.select([sys.stdin], [], [], 0.1)[0]:
            try:
                line = sys.stdin.readline()
                if not line:
                    break

                request = json.loads(line)
                method = request.get("method", "")
                req_id = request.get("id")

                if method == "Plugin.Stream.GetMetadata":
                    send({"jsonrpc": "2.0", "id": req_id, "result": metadata})
                elif method == "Plugin.Stream.GetProperties":
                    send({"jsonrpc": "2.0", "id": req_id, "result": {
                        "canControl": False,
                        "canGoNext": False,
                        "canGoPrevious": False,
                        "canPause": False,
                        "canPlay": False,
                        "canSeek": False,
                    }})
                else:
                    send({"jsonrpc": "2.0", "id": req_id, "result": "ok"})

            except json.JSONDecodeError:
                pass
            except Exception as e:
                log("error", f"stdin error: {e}")


def main():
    """Main entry point."""
    # Signal ready to snapserver
    send({"jsonrpc": "2.0", "method": "Plugin.Stream.Ready"})

    # Start cover art HTTP server in background
    cover_thread = threading.Thread(target=start_cover_art_server, daemon=True)
    cover_thread.start()

    # Start metadata pipe reader in background
    pipe_thread = threading.Thread(target=read_metadata_pipe, daemon=True)
    pipe_thread.start()

    # Handle stdin commands from snapserver
    handle_stdin()


if __name__ == "__main__":
    main()
