"""Tests for scripts/tidal/tidal-relay.py — Tidal satellite PCM/metadata relay.

Unit tests for the peer filter, metadata validation and FIFO setup, plus
end-to-end runs over localhost sockets and real FIFOs in a temp dir.
"""

import importlib.util
import json
import os
import socket
import stat
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parent.parent / "scripts" / "tidal" / "tidal-relay.py"
_spec = importlib.util.spec_from_file_location("tidal_relay", _PATH)
relay = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(relay)


def _listener() -> socket.socket:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    return srv


def _read_fifo(path: str, want: int, timeout: float = 5.0) -> bytes:
    """Open a FIFO for reading and collect `want` bytes (or until timeout)."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    buf = bytearray()
    deadline = time.monotonic() + timeout
    try:
        while len(buf) < want and time.monotonic() < deadline:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                chunk = b""
            if chunk:
                buf += chunk
            else:
                time.sleep(0.01)
    finally:
        os.close(fd)
    return bytes(buf)


class TestPeerAllowed:
    def test_default_allows_lan_only(self):
        assert relay.peer_allowed("192.168.1.20", [])
        assert relay.peer_allowed("10.0.0.5", [])
        assert relay.peer_allowed("127.0.0.1", [])
        assert relay.peer_allowed("169.254.10.1", [])
        assert not relay.peer_allowed("8.8.8.8", [])

    def test_explicit_allow_list(self):
        allow = relay.parse_allow("192.168.1.50, 10.1.0.0/16")
        assert relay.peer_allowed("192.168.1.50", allow)
        assert relay.peer_allowed("10.1.2.3", allow)
        assert not relay.peer_allowed("192.168.1.51", allow)

    def test_garbage_address_refused(self):
        assert not relay.peer_allowed("not-an-ip", [])


class TestMetadata:
    def test_valid_object_written_atomically(self, tmp_path):
        target = tmp_path / "tidal-metadata.json"
        assert relay.write_metadata(
            str(target), b'{"title": "Song", "state": "PLAYING"}'
        )
        assert json.loads(target.read_text()) == {"title": "Song", "state": "PLAYING"}
        assert not any(p.name.endswith(".tmp") for p in tmp_path.iterdir())

    @pytest.mark.parametrize("payload", [b"not json", b'"a string"', b"[1, 2]", b""])
    def test_invalid_payload_leaves_file_alone(self, tmp_path, payload):
        target = tmp_path / "tidal-metadata.json"
        target.write_text('{"title": "Old"}')
        assert not relay.write_metadata(str(target), payload)
        assert json.loads(target.read_text()) == {"title": "Old"}

    def test_read_limited_rejects_oversize(self):
        a, b = socket.socketpair()
        with a, b:
            a.sendall(b"x" * 300)
            a.shutdown(socket.SHUT_WR)
            assert relay.read_limited(b, 100) is None

    def test_push_and_serve_end_to_end(self, tmp_path):
        target = tmp_path / "tidal-metadata.json"
        srv = _listener()
        port = srv.getsockname()[1]
        threading.Thread(
            target=relay.serve_metadata, args=(srv, str(target), []), daemon=True
        ).start()
        relay.push_metadata("127.0.0.1", port, b'{"title": "Live"}')
        deadline = time.monotonic() + 3
        while not target.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert json.loads(target.read_text()) == {"title": "Live"}


class TestEnsureFifo:
    def test_creates_fifo(self, tmp_path):
        path = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(path))
        assert stat.S_ISFIFO(path.stat().st_mode)

    def test_replaces_regular_file_left_by_alsa(self, tmp_path):
        path = tmp_path / "tidal_fifo"
        path.write_bytes(b"\x00" * 1024)
        relay.ensure_fifo(str(path))
        assert stat.S_ISFIFO(path.stat().st_mode)

    def test_keeps_existing_fifo(self, tmp_path):
        path = tmp_path / "tidal_fifo"
        os.mkfifo(path)
        ino = path.stat().st_ino
        relay.ensure_fifo(str(path))
        assert path.stat().st_ino == ino


class TestAudioReceiver:
    def test_pcm_reaches_fifo(self, tmp_path):
        fifo = tmp_path / "tidal_fifo"
        os.mkfifo(fifo)
        receiver = relay.AudioReceiver(str(fifo))
        a, b = socket.socketpair()
        receiver.take_over(b)
        threading.Thread(target=receiver.serve, args=(b, "test"), daemon=True).start()
        pcm = os.urandom(20000)
        result = {}
        reader = threading.Thread(
            target=lambda: result.update(data=_read_fifo(str(fifo), len(pcm)))
        )
        reader.start()
        time.sleep(0.1)  # reader holds the FIFO open, as snapserver does
        a.sendall(pcm)
        a.close()
        reader.join(6)
        assert result["data"] == pcm

    def test_newest_connection_replaces_old(self, tmp_path):
        fifo = tmp_path / "tidal_fifo"
        os.mkfifo(fifo)
        receiver = relay.AudioReceiver(str(fifo))
        old_a, old_b = socket.socketpair()
        receiver.take_over(old_b)
        old_worker = threading.Thread(
            target=receiver.serve, args=(old_b, "old"), daemon=True
        )
        old_worker.start()
        new_a, new_b = socket.socketpair()
        receiver.take_over(new_b)
        old_worker.join(3)
        assert not old_worker.is_alive()
        assert receiver.is_current(new_b)
        for s in (old_a, new_a, new_b):
            s.close()


class TestSender:
    def test_pcm_forwarded_to_server(self, tmp_path):
        fifo = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(fifo))
        fd = os.open(fifo, os.O_RDWR)
        srv = _listener()
        port = srv.getsockname()[1]
        threading.Thread(
            target=relay.pump_audio, args=(fd, "127.0.0.1", port), daemon=True
        ).start()
        conn, _ = srv.accept()
        pcm = os.urandom(50000)
        wfd = os.open(fifo, os.O_WRONLY)
        os.write(wfd, pcm)
        os.close(wfd)
        conn.settimeout(5)
        got = bytearray()
        while len(got) < len(pcm):
            chunk = conn.recv(65536)
            if not chunk:
                break
            got += chunk
        conn.close()
        srv.close()
        assert bytes(got) == pcm

    def test_writer_never_blocks_while_server_is_down(self, tmp_path, monkeypatch):
        monkeypatch.setattr(relay, "RETRY_SECONDS", 0.2)
        monkeypatch.setattr(relay, "CONNECT_TIMEOUT", 0.2)
        fifo = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(fifo))
        fd = os.open(fifo, os.O_RDWR)
        dead = _listener()
        port = dead.getsockname()[1]
        dead.close()  # nothing listens: every connect is refused
        threading.Thread(
            target=relay.pump_audio, args=(fd, "127.0.0.1", port), daemon=True
        ).start()
        done = threading.Event()

        def writer():
            wfd = os.open(fifo, os.O_WRONLY)
            for _ in range(64):  # 1 MiB, far beyond the 64 KiB pipe buffer
                os.write(wfd, b"\x00" * 16384)
            os.close(wfd)
            done.set()

        threading.Thread(target=writer, daemon=True).start()
        assert done.wait(10), "Tidal-side writer blocked: sender did not drain the FIFO"


def _longest_write_stall(fifo: Path, total_chunks: int = 256) -> float:
    """Write PCM-sized chunks as the Tidal app would; return the longest
    time a single write blocked (the app stalls for that long)."""
    wfd = os.open(fifo, os.O_WRONLY)
    worst = 0.0
    try:
        for _ in range(total_chunks):
            start = time.monotonic()
            os.write(wfd, b"\x00" * 4096)
            worst = max(worst, time.monotonic() - start)
    finally:
        os.close(wfd)
    return worst


class TestWriterNeverStalls:
    # The pipe buffer holds ~0.37 s of PCM. Any network wait longer than
    # that in the FIFO reader blocks the Tidal app; these servers make the
    # network wait for 1 s and the writer must not notice.

    def test_slow_connect_does_not_block_the_writer(self, tmp_path, monkeypatch):
        def blackholed(host, port):
            time.sleep(1.0)  # SYN to a powered-off host: connect times out
            raise OSError("timed out")

        monkeypatch.setattr(relay, "connect", blackholed)
        monkeypatch.setattr(relay, "RETRY_SECONDS", 0.1)
        fifo = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(fifo))
        fd = os.open(fifo, os.O_RDWR)
        threading.Thread(
            target=relay.pump_audio, args=(fd, "192.0.2.1", 4954), daemon=True
        ).start()
        assert _longest_write_stall(fifo) < 0.3

    def test_stalled_send_does_not_block_the_writer(self, tmp_path, monkeypatch):
        monkeypatch.setattr(relay, "SEND_TIMEOUT", 1.0)
        monkeypatch.setattr(relay, "RETRY_SECONDS", 0.1)
        fifo = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(fifo))
        fd = os.open(fifo, os.O_RDWR)
        srv = _listener()  # accepts, never reads: sends stall once buffers fill
        port = srv.getsockname()[1]
        threading.Thread(
            target=relay.pump_audio, args=(fd, "127.0.0.1", port), daemon=True
        ).start()
        held = []

        def accept_and_hold():
            try:
                while True:
                    held.append(srv.accept())
            except OSError:  # listener closed at the end of the test
                pass

        threading.Thread(target=accept_and_hold, daemon=True).start()
        try:
            assert _longest_write_stall(fifo, total_chunks=2048) < 0.3
        finally:
            srv.close()

    def test_queued_audio_is_dropped_on_reconnect(self):
        chunks = relay.queue.Queue(maxsize=relay.QUEUE_CHUNKS)
        for _ in range(relay.QUEUE_CHUNKS):
            chunks.put_nowait(b"stale")
        relay.discard_queued(chunks)
        assert chunks.empty()


class TestWorkerFailure:
    def test_crashed_thread_exits_the_process(self):
        code = (
            "import importlib.util, threading, time\n"
            f"spec = importlib.util.spec_from_file_location('r', {str(_PATH)!r})\n"
            "r = importlib.util.module_from_spec(spec); spec.loader.exec_module(r)\n"
            "threading.excepthook = r.exit_on_thread_crash\n"
            "def boom(): raise RuntimeError('worker bug')\n"
            "threading.Thread(target=boom, daemon=True).start()\n"
            "time.sleep(10)\n"
        )
        start = time.monotonic()
        done = subprocess.run(
            [sys.executable, "-c", code], capture_output=True, text=True, timeout=20
        )
        assert done.returncode == 1
        assert time.monotonic() - start < 5
        assert "worker bug" in done.stderr

    def test_unwritable_metadata_path_is_logged_not_raised(self, tmp_path):
        a, b = socket.socketpair()
        a.sendall(b'{"title": "Song"}')
        a.shutdown(socket.SHUT_WR)
        missing_dir = tmp_path / "gone" / "tidal-metadata.json"
        relay.handle_metadata(b, "test", str(missing_dir))
        a.close()
        assert not missing_dir.exists()


class TestDeadServer:
    def test_connect_bounds_sends(self):
        srv = _listener()
        sock = relay.connect("127.0.0.1", srv.getsockname()[1])
        try:
            assert sock.gettimeout() == relay.SEND_TIMEOUT
            if hasattr(socket, "TCP_USER_TIMEOUT"):
                got = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_USER_TIMEOUT)
                assert got == int(relay.SEND_TIMEOUT * 1000)
        finally:
            sock.close()
            srv.close()

    def test_sender_abandons_a_server_that_stops_reading(self, tmp_path, monkeypatch):
        # A server that accepts but never reads stands in for one that died
        # without a RST: the send stalls, and the sender must give up on it
        # instead of letting the FIFO fill and block the Tidal app.
        monkeypatch.setattr(relay, "SEND_TIMEOUT", 0.3)
        monkeypatch.setattr(relay, "RETRY_SECONDS", 0.2)
        fifo = tmp_path / "tidal_fifo"
        relay.ensure_fifo(str(fifo))
        fd = os.open(fifo, os.O_RDWR)
        srv = _listener()
        srv.settimeout(10)
        port = srv.getsockname()[1]
        threading.Thread(
            target=relay.pump_audio, args=(fd, "127.0.0.1", port), daemon=True
        ).start()
        stalled, _ = srv.accept()
        reconnected = threading.Event()

        def writer():
            # Write nonstop, as Tidal does, until the socket buffers fill
            # and the stalled send times out.
            wfd = os.open(fifo, os.O_WRONLY)
            try:
                while not reconnected.is_set():
                    os.write(wfd, b"\x00" * 16384)
            except OSError:
                pass
            finally:
                os.close(wfd)

        threading.Thread(target=writer, daemon=True).start()
        try:
            second, _ = srv.accept()  # the sender reconnected after the stall
        finally:
            reconnected.set()
        for s in (stalled, second, srv):
            s.close()


class TestMetadataConcurrency:
    def test_idle_peer_does_not_block_updates(self, tmp_path):
        target = tmp_path / "tidal-metadata.json"
        srv = _listener()
        port = srv.getsockname()[1]
        threading.Thread(
            target=relay.serve_metadata, args=(srv, str(target), []), daemon=True
        ).start()
        idle = socket.create_connection(("127.0.0.1", port))
        try:
            start = time.monotonic()
            relay.push_metadata("127.0.0.1", port, b'{"title": "Next"}')
            while not target.exists() and time.monotonic() - start < 3:
                time.sleep(0.02)
            assert json.loads(target.read_text()) == {"title": "Next"}
            assert time.monotonic() - start < 2  # not after the idle peer's 5 s timeout
        finally:
            idle.close()
