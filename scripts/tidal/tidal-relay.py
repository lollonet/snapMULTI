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
re-encoded. Real-time semantics: the FIFO is the Tidal app's only clock.
While the server takes the audio, the sender waits for it, so the app plays
at snapserver's pace and nothing is lost; while the server is unreachable,
the sender reads at the PCM rate and discards the audio instead of stalling
the app.

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
import queue
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
BYTES_PER_SECOND = 44100 * 2 * 2
# How far behind real time the FIFO reader may catch up at full speed,
# after playback paused or the network stalled. The burst refills the
# server-side buffers, the cushion that absorbs WiFi jitter; anything older
# is dropped from the schedule, not replayed.
JITTER_BUFFER_SECONDS = 1.0
QUEUE_CHUNKS = 16  # ~370 ms, what the 64 KiB pipe buffer holds
META_MAX_BYTES = 64 * 1024
CONNECT_TIMEOUT = 3.0
# A send that makes no progress this long means the server is gone without
# a RST (power loss, cable pull): reconnect and drain instead of letting the
# FIFO fill and stall the Tidal app.
SEND_TIMEOUT = 2.0
# Kernel send buffer (~0.37 s of PCM). Left to autotuning it grows to
# megabytes under back-pressure: seconds between a tap in the app and the
# speakers. The jitter buffer is the server's receive buffer, past the WiFi.
SEND_BUFFER_BYTES = 64 * 1024
RETRY_SECONDS = 2.0
META_POLL_SECONDS = 1.0
META_RESEND_SECONDS = 60.0  # re-push unchanged metadata after a server restart
HEARTBEAT_SECONDS = 15.0
# Threads that must live as long as the process (see exit_on_thread_crash).
# A per-connection handler that dies only drops its own connection.
WORKER_THREADS = frozenset({"fifo-reader", "metadata-watch", "metadata-accept"})


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
    except (ValueError, RecursionError):  # RecursionError: deeply nested
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


_meta_lock = threading.Lock()


def handle_metadata(conn: socket.socket, addr: str, path: str) -> None:
    with conn:
        conn.settimeout(5.0)
        try:
            payload = read_limited(conn, META_MAX_BYTES)
        except OSError:
            return
        try:
            with _meta_lock:
                ok = payload is not None and write_metadata(path, payload)
        except OSError as e:
            log(f"metadata from {addr}: cannot write {path}: {e}")
            return
        if not ok:
            log(f"metadata from {addr}: rejected (too large or not a JSON object)")


def serve_metadata(srv: socket.socket, path: str, allow: list) -> None:
    # One thread per connection: an idle peer cannot hold up real updates.
    while True:
        conn, (addr, _port) = srv.accept()
        if not peer_allowed(addr, allow):
            log(f"metadata: refused {addr}")
            conn.close()
            continue
        threading.Thread(
            target=handle_metadata, args=(conn, addr, path), daemon=True
        ).start()


def run_receive() -> None:
    allow = parse_allow(os.environ.get("TIDAL_RELAY_ALLOW", ""))
    ensure_fifo(FIFO_PATH)
    audio_srv = listen(AUDIO_PORT)
    meta_srv = listen(META_PORT)
    log(f"receiving PCM on :{AUDIO_PORT} -> {FIFO_PATH}, metadata on :{META_PORT}")
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(
        target=serve_metadata,
        args=(meta_srv, META_PATH, allow),
        name="metadata-accept",
        daemon=True,
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
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, SEND_BUFFER_BYTES)
    sock.settimeout(SEND_TIMEOUT)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    if hasattr(socket, "TCP_USER_TIMEOUT"):  # Linux: unacked data limit
        sock.setsockopt(
            socket.IPPROTO_TCP, socket.TCP_USER_TIMEOUT, int(SEND_TIMEOUT * 1000)
        )
    return sock


def read_fifo(fd: int, chunks: queue.Queue, link: threading.Event) -> None:
    """Read the FIFO, never faster than the PCM rate.

    The ALSA FIFO output has no clock: the Tidal app plays exactly as fast
    as this loop reads. While `link` is set the loop waits for the network,
    so the server's consumption paces the app and WiFi jitter costs no
    audio; the wait is bounded by SEND_TIMEOUT, after which send_audio drops
    the link. Without a link the chunks are dropped and the local clock
    alone keeps the app in real time.
    """
    due = time.monotonic()
    while True:
        data = os.read(fd, CHUNK)
        if not data:
            continue
        try:
            chunks.put(data, block=link.is_set(), timeout=SEND_TIMEOUT)
        except queue.Full:
            pass
        now = time.monotonic()
        due = max(due, now - JITTER_BUFFER_SECONDS) + len(data) / BYTES_PER_SECOND
        if due > now:
            time.sleep(due - now)


def discard_queued(chunks: queue.Queue) -> None:
    while True:
        try:
            chunks.get_nowait()
        except queue.Empty:
            return


def send_audio(
    chunks: queue.Queue, host: str, port: int, link: threading.Event
) -> None:
    connected = False
    while True:
        try:
            sock = connect(host, port)
        except OSError as e:
            if connected:
                log(f"audio: lost {host}:{port} ({e}), retrying")
            connected = False
            time.sleep(RETRY_SECONDS)
            continue
        if not connected:
            log(f"audio: connected to {host}:{port}")
        connected = True
        # PCM queued while disconnected is stale: resume with live audio.
        discard_queued(chunks)
        link.set()
        try:
            while True:
                sock.sendall(chunks.get())
        except OSError as e:
            log(f"audio: send failed ({e}), reconnecting")
        finally:
            link.clear()
            sock.close()


def pump_audio(fd: int, host: str, port: int) -> None:
    chunks = queue.Queue(maxsize=QUEUE_CHUNKS)
    link = threading.Event()
    threading.Thread(
        target=read_fifo, args=(fd, chunks, link), name="fifo-reader", daemon=True
    ).start()
    send_audio(chunks, host, port, link)


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
        target=watch_metadata,
        args=(host, META_PORT, META_PATH),
        name="metadata-watch",
        daemon=True,
    ).start()
    pump_audio(fd, host, AUDIO_PORT)


def exit_on_thread_crash(args: threading.ExceptHookArgs) -> None:
    """A dead worker thread exits the process so Docker restarts it.

    Without this the heartbeat thread keeps the container healthy while
    the thread that moves audio or metadata is gone. Only WORKER_THREADS
    qualify: a peer must not be able to restart the relay by crashing the
    thread that handles its own connection.
    """
    if args.thread is None or args.thread.name not in WORKER_THREADS:
        threading.__excepthook__(args)
        return
    log(f"thread {args.thread.name} died: {args.exc_type.__name__}: {args.exc_value}")
    os._exit(1)


def main() -> None:
    threading.excepthook = exit_on_thread_crash
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
