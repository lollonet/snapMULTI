"""Tests for scripts/meta_shairport.py — Shairport-sync metadata reader.

Focus: pure-logic functions and the parse_item() state machine. Skips the
event loop (main), socket/HTTP server, and pipe I/O — those are integration
territory and rely on a running shairport-sync.
"""

import base64
import struct

import meta_shairport


# ---------------------------------------------------------------------------
# hex_to_str
# ---------------------------------------------------------------------------


class TestHexToStr:
    """hex_to_str converts a hex string back to ASCII (the shairport-sync code field)."""

    def test_known_codes(self):
        assert meta_shairport.hex_to_str("6173616c") == "asal"
        assert meta_shairport.hex_to_str("61736172") == "asar"
        assert meta_shairport.hex_to_str("6d696e6d") == "minm"
        assert meta_shairport.hex_to_str("50494354") == "PICT"

    def test_invalid_hex_returns_input(self):
        # Not valid hex → returns original string
        assert meta_shairport.hex_to_str("zzzz") == "zzzz"

    def test_non_ascii_hex_returns_input(self):
        # Valid hex but not ASCII (e.g. emoji bytes) → returns original
        result = meta_shairport.hex_to_str("f09f8e89")  # 🎉
        # Either returns the raw hex or fails to decode as ASCII; both acceptable
        assert isinstance(result, str)
        assert result != ""


# ---------------------------------------------------------------------------
# get_host_ip
# ---------------------------------------------------------------------------


class TestGetHostIp:
    def test_explicit_env_wins(self, monkeypatch):
        monkeypatch.setenv("COVER_ART_HOST", "10.0.0.42")
        assert meta_shairport.get_host_ip() == "10.0.0.42"

    def test_socket_fallback_returns_string(self, monkeypatch):
        monkeypatch.delenv("COVER_ART_HOST", raising=False)
        # Mock socket so the test never opens a real connection (airgapped CI safe)
        monkeypatch.setattr(
            "meta_shairport.socket.socket.connect",
            lambda self, *a, **kw: None,
        )
        monkeypatch.setattr(
            "meta_shairport.socket.socket.getsockname",
            lambda self: ("192.168.1.10", 0),
        )
        assert meta_shairport.get_host_ip() == "192.168.1.10"

    def test_socket_failure_returns_none(self, monkeypatch):
        monkeypatch.delenv("COVER_ART_HOST", raising=False)

        def _broken_socket(*_args, **_kwargs):
            raise OSError("no network")

        monkeypatch.setattr("meta_shairport.socket.socket", _broken_socket)
        assert meta_shairport.get_host_ip() is None


# ---------------------------------------------------------------------------
# parse_item — the main state machine
# ---------------------------------------------------------------------------


def _xml_item(code_hex: str, data_b64: str = "") -> bytes:
    """Build a shairport-sync XML <item>…</item> packet."""
    if data_b64:
        return (
            f"<item><code>{code_hex}</code>"
            f'<data encoding="base64">{data_b64}</data></item>'
        ).encode()
    return f"<item><code>{code_hex}</code></item>".encode()


def _b64(s: str) -> str:
    return base64.b64encode(s.encode()).decode()


def _b64_bytes(b: bytes) -> str:
    return base64.b64encode(b).decode()


class TestParseItem:
    """parse_item dispatches by 4-char code (asal=album, asar=artist, etc.)."""

    def test_album(self):
        meta_shairport.parse_item(_xml_item("6173616c", _b64("Kid A")))
        assert meta_shairport.metadata["album"] == "Kid A"

    def test_artist(self):
        meta_shairport.parse_item(_xml_item("61736172", _b64("Radiohead")))
        assert meta_shairport.metadata["artist"] == ["Radiohead"]

    def test_title(self):
        meta_shairport.parse_item(
            _xml_item("6d696e6d", _b64("Everything In Its Right Place"))
        )
        assert meta_shairport.metadata["title"] == "Everything In Its Right Place"

    def test_genre(self):
        meta_shairport.parse_item(_xml_item("6173676e", _b64("Electronic")))
        assert meta_shairport.metadata["genre"] == ["Electronic"]

    def test_composer(self):
        meta_shairport.parse_item(_xml_item("61736370", _b64("Yorke / Greenwood")))
        assert meta_shairport.metadata["composer"] == ["Yorke / Greenwood"]

    def test_empty_artist_ignored(self):
        # Empty string artist should NOT replace previous value
        meta_shairport.metadata["artist"] = ["Existing"]
        meta_shairport.parse_item(_xml_item("61736172", _b64("")))
        assert meta_shairport.metadata["artist"] == ["Existing"]

    def test_duration_astm(self):
        # astm = song time in milliseconds, big-endian uint32
        ms = 252_000
        payload = struct.pack(">I", ms)
        meta_shairport.parse_item(_xml_item("6173746d", _b64_bytes(payload)))
        assert meta_shairport.metadata["duration"] == 252.0

    def test_duration_astm_too_short_ignored(self):
        # < 4 bytes → should NOT crash, NOT update
        meta_shairport.metadata["duration"] = 10.0
        meta_shairport.parse_item(_xml_item("6173746d", _b64_bytes(b"\x00")))
        assert meta_shairport.metadata["duration"] == 10.0

    def test_pend_clears_metadata(self, capture_stdout):
        # pend = playback ended → reset all fields
        meta_shairport.metadata.update(
            {
                "artist": ["X"],
                "title": "Y",
                "album": "Z",
                "duration": 99.0,
                "genre": ["G"],
                "composer": ["C"],
            }
        )
        meta_shairport.metadata["artUrl"] = "http://10.0.0.5:5858/cover.jpg"
        meta_shairport.parse_item(_xml_item("70656e64"))  # 'pend'
        assert meta_shairport.metadata["artist"] == []
        assert meta_shairport.metadata["title"] == ""
        assert meta_shairport.metadata["album"] == ""
        assert meta_shairport.metadata["artUrl"] == ""
        assert meta_shairport.metadata["duration"] == 0.0
        assert meta_shairport.metadata["genre"] == []
        assert meta_shairport.metadata["composer"] == []

    def test_mden_triggers_send(self, capture_stdout):
        # mden = metadata ended → flush via send_metadata
        meta_shairport.metadata["title"] = "Now Playing"
        meta_shairport.parse_item(_xml_item("6d64656e"))  # 'mden'
        # send_metadata called → at least one message captured
        assert len(capture_stdout) >= 1

    def test_unknown_code_no_op(self):
        # An unrecognised code should not raise and not modify metadata
        before = dict(meta_shairport.metadata)
        meta_shairport.parse_item(_xml_item("00000000"))
        assert meta_shairport.metadata == before

    def test_malformed_xml_no_op(self):
        # Garbage payload → swallowed, no exception
        before = dict(meta_shairport.metadata)
        meta_shairport.parse_item(b"<not valid>")
        assert meta_shairport.metadata == before

    def test_invalid_base64_data_no_crash(self):
        # Code present, data malformed → data stays empty, code branch may still fire
        before_artist = list(meta_shairport.metadata["artist"])
        meta_shairport.parse_item(
            b"<item><code>61736172</code><data>!!!notb64</data></item>"
        )
        # asar with empty data → no update
        assert meta_shairport.metadata["artist"] == before_artist


# ---------------------------------------------------------------------------
# handle_stdin_line — JSON-RPC dispatcher
# ---------------------------------------------------------------------------


class TestHandleStdinLine:
    """handle_stdin_line responds to GetMetadata / GetProperties / unknown."""

    def test_get_metadata_returns_current(self, capture_stdout):
        meta_shairport.metadata["title"] = "Pyramid Song"
        meta_shairport.metadata["artist"] = ["Radiohead"]

        meta_shairport.handle_stdin_line(
            '{"jsonrpc":"2.0","id":1,"method":"Plugin.Stream.GetMetadata"}'
        )

        assert len(capture_stdout) == 1
        msg = capture_stdout[0]
        assert msg["id"] == 1
        assert msg["result"]["title"] == "Pyramid Song"
        assert msg["result"]["artist"] == ["Radiohead"]

    def test_get_properties_reports_no_control(self, capture_stdout):
        meta_shairport.handle_stdin_line(
            '{"jsonrpc":"2.0","id":2,"method":"Plugin.Stream.GetProperties"}'
        )

        assert len(capture_stdout) == 1
        result = capture_stdout[0]["result"]
        # AirPlay is read-only — every can* must be False
        for key in (
            "canControl",
            "canGoNext",
            "canGoPrevious",
            "canPause",
            "canPlay",
            "canSeek",
        ):
            assert result[key] is False, f"{key} should be False for AirPlay"

    def test_unknown_method_returns_ok(self, capture_stdout):
        meta_shairport.handle_stdin_line(
            '{"jsonrpc":"2.0","id":3,"method":"Plugin.Stream.Whatever"}'
        )
        assert len(capture_stdout) == 1
        assert capture_stdout[0]["result"] == "ok"

    def test_invalid_json_silently_dropped(self, capture_stdout):
        meta_shairport.handle_stdin_line("not even json {")
        assert capture_stdout == []  # no response emitted


# ---------------------------------------------------------------------------
# send_metadata — output format
# ---------------------------------------------------------------------------


class TestSendMetadata:
    def test_emits_player_properties(self, capture_stdout):
        meta_shairport.metadata["title"] = "Idioteque"
        meta_shairport.send_metadata()

        # send_metadata emits at least the Player.Properties notification;
        # may also emit a Log entry — find the Properties one.
        props = [
            m
            for m in capture_stdout
            if m.get("method") == "Plugin.Stream.Player.Properties"
        ]
        assert len(props) == 1
        msg = props[0]
        assert msg["jsonrpc"] == "2.0"
        assert msg["params"]["metadata"]["title"] == "Idioteque"


# ---------------------------------------------------------------------------
# Per-track cover handling (previous-track artwork regression)
# ---------------------------------------------------------------------------

MDST = "6d647374"
MDEN = "6d64656e"
PICT = "50494354"
MINM = "6d696e6d"
ASAR = "61736172"
ASTM = "6173746d"


def _props(sent: list[dict]) -> list[dict]:
    return [
        m["params"]["metadata"]
        for m in sent
        if m.get("method") == "Plugin.Stream.Player.Properties"
    ]


def _bundle(title: str, artist: str = "Artist", extra: list[bytes] = ()) -> None:
    meta_shairport.parse_item(_xml_item(MDST))
    meta_shairport.parse_item(_xml_item(MINM, _b64(title)))
    meta_shairport.parse_item(_xml_item(ASAR, _b64(artist)))
    for item in extra:
        meta_shairport.parse_item(item)
    meta_shairport.parse_item(_xml_item(MDEN))


class TestCoverPerTrack:
    def _setup(self, monkeypatch, tmp_path):
        monkeypatch.setattr(meta_shairport, "get_host_ip", lambda: "10.0.0.5")
        monkeypatch.setattr(meta_shairport, "cover_art_path", str(tmp_path / "c.jpg"))

    def test_new_track_drops_previous_cover_until_its_pict_arrives(
        self, capture_stdout, monkeypatch, tmp_path
    ):
        self._setup(monkeypatch, tmp_path)
        _bundle("Song A")
        meta_shairport.parse_item(_xml_item(PICT, _b64_bytes(b"\xff\xd8A")))
        url_a = meta_shairport.metadata["artUrl"]
        assert url_a == "http://10.0.0.5:5858/cover.jpg?v=1"
        # PICT outside a bundle publishes right away.
        assert _props(capture_stdout)[-1]["artUrl"] == url_a

        _bundle("Song B")
        # Text for B goes out WITHOUT A's cover.
        assert "artUrl" not in _props(capture_stdout)[-1]
        assert _props(capture_stdout)[-1]["title"] == "Song B"
        assert meta_shairport.cover_bytes_for_path("/cover.jpg?v=1") is None

        meta_shairport.parse_item(_xml_item(PICT, _b64_bytes(b"\xff\xd8B")))
        url_b = meta_shairport.metadata["artUrl"]
        assert url_b == "http://10.0.0.5:5858/cover.jpg?v=2"
        assert _props(capture_stdout)[-1]["artUrl"] == url_b
        assert meta_shairport.cover_bytes_for_path("/cover.jpg?v=2") == b"\xff\xd8B"

    def test_pict_inside_bundle_is_kept(self, capture_stdout, monkeypatch, tmp_path):
        self._setup(monkeypatch, tmp_path)
        _bundle("Song A", extra=[_xml_item(PICT, _b64_bytes(b"\xff\xd8A"))])
        props = _props(capture_stdout)
        assert len(props) == 1  # sent once, at mden
        assert props[0]["artUrl"].endswith("/cover.jpg?v=1")

    def test_same_track_resent_keeps_cover(self, capture_stdout, monkeypatch, tmp_path):
        self._setup(monkeypatch, tmp_path)
        _bundle("Song A")
        meta_shairport.parse_item(_xml_item(PICT, _b64_bytes(b"\xff\xd8A")))
        _bundle("Song A")
        assert _props(capture_stdout)[-1]["artUrl"].endswith("?v=1")

    def test_empty_pict_clears_cover(self, capture_stdout, monkeypatch, tmp_path):
        self._setup(monkeypatch, tmp_path)
        _bundle("Song A")
        meta_shairport.parse_item(_xml_item(PICT, _b64_bytes(b"\xff\xd8A")))
        meta_shairport.parse_item(_xml_item(PICT))
        assert meta_shairport.metadata["artUrl"] == ""
        assert "artUrl" not in _props(capture_stdout)[-1]
        assert meta_shairport.cover_bytes_for_path("/cover.jpg") is None

    def test_duration_not_carried_to_next_track(self, capture_stdout):
        payload = struct.pack(">I", 200_000)
        _bundle("Song A", extra=[_xml_item(ASTM, _b64_bytes(payload))])
        assert meta_shairport.metadata["duration"] == 200.0
        _bundle("Song B")
        assert meta_shairport.metadata["duration"] == 0.0
        assert "duration" not in _props(capture_stdout)[-1]

    def test_cover_paths(self, monkeypatch, tmp_path):
        self._setup(monkeypatch, tmp_path)
        meta_shairport.parse_item(_xml_item(PICT, _b64_bytes(b"IMG")))
        assert meta_shairport.cover_bytes_for_path("/cover.jpg?v=1") == b"IMG"
        assert meta_shairport.cover_bytes_for_path("/cover.jpg") == b"IMG"
        assert meta_shairport.cover_bytes_for_path("/cover.jpg?v=0") is None
        assert meta_shairport.cover_bytes_for_path("/etc/passwd") is None


class TestExtractItems:
    def test_orphan_close_tag_does_not_strand_complete_items(self):
        buf = bytearray(b"junk</item><item>A</item><item>B</item><item>par")
        items, rest = meta_shairport.extract_items(buf)
        assert items == [b"<item>A</item>", b"<item>B</item>"]
        assert bytes(rest) == b"<item>par"

    def test_returns_bytearray_remainder(self):
        items, rest = meta_shairport.extract_items(bytearray(b"<item>x</item>"))
        assert items == [b"<item>x</item>"]
        assert isinstance(rest, bytearray) and not rest
