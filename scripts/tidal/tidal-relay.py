#!/usr/bin/env python3
"""
Tidal Connect relay: run Tidal on an ARM Pi, play it through any server.

The Tidal Connect binary only exists for ARM. On a non-ARM server (x86_64)
a Pi "satellite" runs the tidal-connect container and this relay in `send`
mode; the server runs it in `receive` mode. The receiver feeds the server's
existing Tidal source: PCM goes into /audio/tidal_fifo (read by snapserver's
pipe source) and the bridge's JSON lands in /audio/tidal-metadata.json (read
by meta_tidal.py). snapserver.conf is unchanged; the stream is still "Tidal".

  send     satellite: /audio/tidal_fifo -> tcp://SERVER:4954 (PCM)
                      /audio/tidal-metadata.json -> tcp://SERVER:4955 (JSON)
  receive  server:    :4954 -> /audio/tidal_fifo, :4955 -> tidal-metadata.json

Audio is raw 44100:16:2 (what config/tidal-asound.conf writes); nothing is
re-encoded. Real-time semantics: while the server is unreachable the sender
discards PCM instead of stalling the Tidal app.

Environment variables:
    TIDAL_RELAY_SERVER      send: server host name or IP (required)
    TIDAL_RELAY_AUDIO_PORT  PCM port (default 4954)
    TIDAL_RELAY_META_PORT   metadata port (default 4955)
    TIDAL_RELAY_ALLOW       receive: comma-separated IPs/CIDRs allowed to
                            connect (default: private, loopback, link-local)
    TIDAL_RELAY_FIFO        default /audio/tidal_fifo
    TIDAL_RELAY_META_FILE   default /audio/tidal-metadata.json
"""

import ipaddress
import json
import os
import select
import socket
import stat
import sys
import threading
import time

AUDIO_PORT = int(os.environ.get("TIDAL_RELAY_AUDIO_PORT", "4954"))
META_PORT = int(os.environ.get("TIDAL_RELAY_META_PORT", "4955"))
FIFO_PATH = os.environ.get("TIDAL_RELAY_FIFO", "/audio/tidal_fifo")
META_PATH = os.environ.get("TIDAL_RELAY_META_FILE", "/audio/tidal-metadata.json")
HEARTBEAT_PATH = "/tmp/tidal-relay.alive"

CHUNK = 4096  # ~23 ms of 44100:16:2
META_MAX_BYTES = 64 * 1024
CONNECT_TIMEOUT = 3.0
RETRY_SECONDS = 2.0
META_POLL_SECONDS = 1.0
META_RESEND_SECONDS = 60.0  # re-push unchanged metadata after a server restart
HEARTBEAT_SECONDS = 15.0


def log(msg: str) -> None:
    print(f"tidal-relay: {msg}", file=sys.stderr, flush=True)


def heartbeat() -> None:
    """Touch the healthcheck file so a wedged process turns unhealthy."""
    while True:
        try:
            with open(HEARTBEAT_PATH, "w") as f:
                f.write(str(int(time.time())))
        except OSError:
            pass
        time.sleep(HEARTBEAT_SECONDS)


def ensure_fifo(path: str) -> None:
    """Create the FIFO; replace a regular file left by ALSA's file plugin.

    If tidal-connect ever starts before the FIFO exists, ALSA's `file` PCM
    creates a regular file and fills the disk with PCM.
    """
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        st = None
    if st is not None and stat.S_ISFIFO(st.st_mode):
        return
    if st is not None:
        log(f"{path} is not a FIFO, replacing it")
        os.unlink(path)
    os.mkfifo(path)
    os.chmod(path, 0o666)


# --- receive (server) -------------------------------------------------------


def parse_allow(spec: str) -> list:
    nets = []
    for item in spec.split(","):
        item = item.strip()
        if item:
            nets.append(ipaddress.ip_network(item, strict=False))
    return nets


def peer_allowed(addr: str, allow: list) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if allow:
        return any(ip in net for net in allow)
    return ip.is_private or ip.is_loopback or ip.is_link_local


def listen(port: int) -> socket.socket:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(4)
    return srv


class AudioReceiver:
    """One sender at a time; a new connection replaces the old one.

    Newest-wins matters when the satellite reboots: its old TCP connection
    can linger half-open and would otherwise block the new one forever.
    """

    def __init__(self, fifo_path: str):
        self.fifo_path = fifo_path
        self.lock = threading.Lock()
        self.current = None

    def take_over(self, conn: socket.socket) -> None:
        with self.lock:
            old, self.current = self.current, conn
        if old is not None:
            try:
                old.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def is_current(self, conn: socket.socket) -> bool:
        with self.lock:
            return self.current is conn

    def serve(self, conn: socket.socket, peer: str) -> None:
        log(f"audio sender connected: {peer}")
        fd = None
        try:
            while self.is_current(conn):
                data = conn.recv(CHUNK)
                if not data:
                    break
                if fd is None:
                    # Blocks until snapserver's pipe source has the FIFO
                    # open for reading, which it normally always has.
                    fd = os.open(self.fifo_path, os.O_WRONLY)
                view = memoryview(data)
                while view and self.is_current(conn):
                    n = os.write(fd, view)
                    view = view[n:]
        except OSError as e:
            log(f"audio sender {peer}: {e}")
        finally:
            if fd is not None:
                os.close(fd)
            conn.close()
            with self.lock:
                if self.current is conn:
                    self.current = None
            log(f"audio sender disconnected: {peer}")


def write_metadata(path: str, payload: bytes) -> bool:
    """Validate the bridge JSON and replace the file atomically."""
    try:
        data = json.loads(payload)
    except ValueError:
        return False
    if not isinstance(data, dict):
        return False
    tmp = os.path.join(
        os.path.dirname(path) or ".", "." + os.path.basename(path) + ".tmp"
    )
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, path)
    return True


def read_limited(conn: socket.socket, limit: int) -> bytes | None:
    """Read until EOF; None when the peer sends more than `limit` bytes."""
    buf = bytearray()
    while True:
        chunk = conn.recv(8192)
        if not chunk:
            return bytes(buf)
        buf += chunk
        if len(buf) > limit:
            return None


def serve_metadata(srv: socket.socket, path: str, allow: list) -> None:
    while True:
        conn, (addr, _port) = srv.accept()
        with conn:
            if not peer_allowed(addr, allow):
                log(f"metadata: refused {addr}")
                continue
            conn.settimeout(5.0)
            try:
                payload = read_limited(conn, META_MAX_BYTES)
            except OSError:
                continue
            if payload is None or not write_metadata(path, payload):
                log(f"metadata from {addr}: rejected (too large or not a JSON object)")


def run_receive() -> None:
    allow = parse_allow(os.environ.get("TIDAL_RELAY_ALLOW", ""))
    ensure_fifo(FIFO_PATH)
    audio_srv = listen(AUDIO_PORT)
    meta_srv = listen(META_PORT)
    log(f"receiving PCM on :{AUDIO_PORT} -> {FIFO_PATH}, metadata on :{META_PORT}")
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(
        target=serve_metadata, args=(meta_srv, META_PATH, allow), daemon=True
    ).start()
    audio = AudioReceiver(FIFO_PATH)
    while True:
        conn, (addr, _port) = audio_srv.accept()
        if not peer_allowed(addr, allow):
            log(f"audio: refused {addr}")
            conn.close()
            continue
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        audio.take_over(conn)
        threading.Thread(target=audio.serve, args=(conn, addr), daemon=True).start()


# --- send (satellite) -------------------------------------------------------


def connect(host: str, port: int) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    return sock


def drain(fd: int, seconds: float) -> None:
    """Discard PCM for `seconds` so the Tidal app never blocks on the FIFO."""
    deadline = time.monotonic() + seconds
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            return
        ready, _, _ = select.select([fd], [], [], left)
        if ready:
            os.read(fd, CHUNK)


def pump_audio(fd: int, host: str, port: int) -> None:
    connected = False
    while True:
        try:
            sock = connect(host, port)
        except OSError as e:
            if connected:
                log(f"audio: lost {host}:{port} ({e}), retrying")
            connected = False
            drain(fd, RETRY_SECONDS)
            continue
        if not connected:
            log(f"audio: connected to {host}:{port}")
        connected = True
        try:
            while True:
                data = os.read(fd, CHUNK)
                if data:
                    sock.sendall(data)
        except OSError as e:
            log(f"audio: send failed ({e}), reconnecting")
        finally:
            sock.close()


def push_metadata(host: str, port: int, payload: bytes) -> None:
    with connect(host, port) as sock:
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)


def watch_metadata(host: str, port: int, path: str) -> None:
    sent_sig = None
    sent_at = 0.0
    while True:
        time.sleep(META_POLL_SECONDS)
        try:
            st = os.stat(path)
        except FileNotFoundError:
            continue
        sig = (st.st_mtime_ns, st.st_size)
        if sig == sent_sig and time.monotonic() - sent_at < META_RESEND_SECONDS:
            continue
        if st.st_size > META_MAX_BYTES:
            continue
        try:
            with open(path, "rb") as f:
                payload = f.read(META_MAX_BYTES)
            push_metadata(host, port, payload)
        except OSError:
            continue  # unchanged sent_sig: retried on the next tick
        sent_sig, sent_at = sig, time.monotonic()


def run_send() -> None:
    host = os.environ.get("TIDAL_RELAY_SERVER", "").strip()
    if not host:
        log("TIDAL_RELAY_SERVER is not set (server host name or IP)")
        sys.exit(2)
    ensure_fifo(FIFO_PATH)
    # O_RDWR: opening never blocks and the Tidal writer never sees EPIPE,
    # even between reconnects.
    fd = os.open(FIFO_PATH, os.O_RDWR)
    log(f"sending {FIFO_PATH} -> {host}:{AUDIO_PORT}, metadata -> {host}:{META_PORT}")
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(
        target=watch_metadata, args=(host, META_PORT, META_PATH), daemon=True
    ).start()
    pump_audio(fd, host, AUDIO_PORT)


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode == "send":
        run_send()
    elif mode == "receive":
        run_receive()
    else:
        print("usage: tidal-relay.py send|receive", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
