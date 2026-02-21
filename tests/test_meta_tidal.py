"""Tests for scripts/meta_tidal.py — Tidal Connect metadata reader."""

import json
import os
import time

import pytest

import meta_tidal


# ---------------------------------------------------------------------------
# apply_metadata
# ---------------------------------------------------------------------------

class TestApplyMetadata:
    """Tests for apply_metadata() — pure logic, highest value."""

    def test_full_track_data(self):
        data = {
            "state": "PLAYING",
            "artist": "Radiohead",
            "title": "Everything In Its Right Place",
            "album": "Kid A",
            "duration": 252,
        }
        assert meta_tidal.apply_metadata(data) is True
        assert meta_tidal.metadata["title"] == "Everything In Its Right Place"
        assert meta_tidal.metadata["artist"] == ["Radiohead"]
        assert meta_tidal.metadata["album"] == "Kid A"
        assert meta_tidal.metadata["duration"] == 252.0
        assert meta_tidal.playback_status == "playing"

    def test_partial_data_title_only(self):
        assert meta_tidal.apply_metadata({"title": "Intro"}) is True
        assert meta_tidal.metadata["title"] == "Intro"
        assert meta_tidal.metadata["artist"] == []
        assert meta_tidal.playback_status == "unknown"

    def test_partial_data_state_only(self):
        assert meta_tidal.apply_metadata({"state": "PAUSED"}) is True
        assert meta_tidal.playback_status == "paused"
        assert meta_tidal.metadata["title"] == ""

    def test_state_playing(self):
        meta_tidal.apply_metadata({"state": "PLAYING"})
        assert meta_tidal.playback_status == "playing"

    def test_state_paused(self):
        meta_tidal.apply_metadata({"state": "PAUSED"})
        assert meta_tidal.playback_status == "paused"

    def test_state_idle(self):
        meta_tidal.apply_metadata({"state": "IDLE"})
        assert meta_tidal.playback_status == "stopped"

    def test_state_stopped(self):
        meta_tidal.apply_metadata({"state": "STOPPED"})
        assert meta_tidal.playback_status == "stopped"

    def test_state_buffering(self):
        meta_tidal.apply_metadata({"state": "BUFFERING"})
        assert meta_tidal.playback_status == "playing"

    def test_unknown_state_no_change(self):
        meta_tidal.apply_metadata({"state": "EXPLODING"})
        assert meta_tidal.playback_status == "unknown"

    def test_empty_strings_no_change(self):
        assert meta_tidal.apply_metadata({"title": "", "artist": "", "album": ""}) is False

    def test_idempotent(self):
        data = {"title": "Song", "artist": "Band", "state": "PLAYING"}
        assert meta_tidal.apply_metadata(data) is True
        assert meta_tidal.apply_metadata(data) is False

    def test_duration_zero_not_applied(self):
        assert meta_tidal.apply_metadata({"duration": 0}) is False
        assert meta_tidal.metadata["duration"] == 0.0

    def test_artist_string_wrapped_in_list(self):
        meta_tidal.apply_metadata({"artist": "Bjork"})
        assert meta_tidal.metadata["artist"] == ["Bjork"]

    def test_empty_artist_yields_empty_list(self):
        meta_tidal.metadata["artist"] = ["Previous"]
        meta_tidal.apply_metadata({"artist": ""})
        assert meta_tidal.metadata["artist"] == []

    def test_case_insensitive_state(self):
        meta_tidal.apply_metadata({"state": "playing"})
        assert meta_tidal.playback_status == "playing"


# ---------------------------------------------------------------------------
# _filtered_metadata
# ---------------------------------------------------------------------------

class TestFilteredMetadata:
    """Tests for _filtered_metadata() — removes empty/zero values."""

    def test_all_empty(self):
        assert meta_tidal._filtered_metadata() == {}

    def test_only_title(self):
        meta_tidal.metadata["title"] = "Hello"
        assert meta_tidal._filtered_metadata() == {"title": "Hello"}

    def test_all_populated(self):
        meta_tidal.metadata.update({
            "title": "Track",
            "artist": ["Band"],
            "album": "Album",
            "artUrl": "http://example.com/art.jpg",
            "duration": 180.0,
        })
        result = meta_tidal._filtered_metadata()
        assert result == {
            "title": "Track",
            "artist": ["Band"],
            "album": "Album",
            "artUrl": "http://example.com/art.jpg",
            "duration": 180.0,
        }


# ---------------------------------------------------------------------------
# handle_stdin_line
# ---------------------------------------------------------------------------

class TestHandleStdinLine:
    """Tests for handle_stdin_line() — JSON-RPC request dispatcher."""

    def test_get_metadata(self, capture_stdout):
        meta_tidal.metadata["title"] = "Test"
        meta_tidal.handle_stdin_line(
            json.dumps({"jsonrpc": "2.0", "id": 1, "method": "Plugin.Stream.GetMetadata"})
        )
        assert len(capture_stdout) == 1
        assert capture_stdout[0]["id"] == 1
        assert capture_stdout[0]["result"] == {"title": "Test"}

    def test_get_properties(self, capture_stdout):
        meta_tidal.playback_status = "playing"
        meta_tidal.handle_stdin_line(
            json.dumps({"jsonrpc": "2.0", "id": 2, "method": "Plugin.Stream.GetProperties"})
        )
        assert len(capture_stdout) == 1
        result = capture_stdout[0]["result"]
        assert result["playbackStatus"] == "playing"
        assert result["canControl"] is False
        assert result["canGoNext"] is False
        assert result["canPause"] is False

    def test_player_control_returns_error(self, capture_stdout):
        meta_tidal.handle_stdin_line(
            json.dumps({"jsonrpc": "2.0", "id": 3, "method": "Plugin.Stream.Player.Control"})
        )
        assert len(capture_stdout) == 1
        assert capture_stdout[0]["error"]["code"] == -32601

    def test_unknown_method_returns_ok(self, capture_stdout):
        meta_tidal.handle_stdin_line(
            json.dumps({"jsonrpc": "2.0", "id": 4, "method": "Plugin.Stream.SomethingNew"})
        )
        assert len(capture_stdout) == 1
        assert capture_stdout[0]["result"] == "ok"

    def test_invalid_json_silently_ignored(self, capture_stdout):
        meta_tidal.handle_stdin_line("not json at all {{{")
        assert len(capture_stdout) == 0

    def test_missing_id_responds_with_null_id(self, capture_stdout):
        meta_tidal.handle_stdin_line(
            json.dumps({"jsonrpc": "2.0", "method": "Plugin.Stream.GetMetadata"})
        )
        assert len(capture_stdout) == 1
        assert capture_stdout[0]["id"] is None


# ---------------------------------------------------------------------------
# send_properties
# ---------------------------------------------------------------------------

class TestSendProperties:
    """Tests for send_properties() — sends metadata + playback status."""

    def test_with_metadata(self, capture_stdout):
        meta_tidal.metadata["title"] = "Song"
        meta_tidal.metadata["artist"] = ["Artist"]
        meta_tidal.playback_status = "playing"
        meta_tidal.send_properties()

        assert len(capture_stdout) == 1
        msg = capture_stdout[0]
        assert msg["method"] == "Plugin.Stream.Player.Properties"
        assert msg["params"]["metadata"]["title"] == "Song"
        assert msg["params"]["playbackStatus"] == "playing"

    def test_empty_metadata_unknown_status_sends_nothing(self, capture_stdout):
        meta_tidal.send_properties()
        assert len(capture_stdout) == 0

    def test_only_playback_status(self, capture_stdout):
        meta_tidal.playback_status = "paused"
        meta_tidal.send_properties()

        assert len(capture_stdout) == 1
        params = capture_stdout[0]["params"]
        assert params["playbackStatus"] == "paused"
        assert "metadata" not in params


# ---------------------------------------------------------------------------
# file_watch_thread
# ---------------------------------------------------------------------------

class TestFileWatchThread:
    """Tests for file_watch_thread() — file polling loop."""

    def test_file_with_valid_json(self, tmp_path, capture_stdout, monkeypatch):
        meta_file = tmp_path / "tidal-metadata.json"
        meta_file.write_text(json.dumps({
            "state": "PLAYING",
            "title": "Hello",
            "artist": "World",
            "album": "Earth",
            "duration": 200,
        }))

        monkeypatch.setattr(meta_tidal, "METADATA_FILE", str(meta_file))

        # Run one iteration then stop
        call_count = 0

        def _sleep_then_stop(seconds):
            nonlocal call_count
            call_count += 1
            if call_count >= 2:
                raise SystemExit("stop")

        monkeypatch.setattr(time, "sleep", _sleep_then_stop)

        with pytest.raises(SystemExit, match="stop"):
            meta_tidal.file_watch_thread()

        assert meta_tidal.metadata["title"] == "Hello"
        assert meta_tidal.playback_status == "playing"
        # Should have sent properties
        props_msgs = [m for m in capture_stdout if m.get("method") == "Plugin.Stream.Player.Properties"]
        assert len(props_msgs) == 1

    def test_file_not_found_backs_off(self, tmp_path, monkeypatch):
        monkeypatch.setattr(meta_tidal, "METADATA_FILE", str(tmp_path / "nonexistent.json"))

        delays: list[float] = []
        call_count = 0

        def _capture_sleep(seconds):
            nonlocal call_count
            delays.append(seconds)
            call_count += 1
            if call_count >= 4:
                raise SystemExit("stop")

        monkeypatch.setattr(time, "sleep", _capture_sleep)

        with pytest.raises(SystemExit, match="stop"):
            meta_tidal.file_watch_thread()

        # Delays should double each time (exponential backoff)
        assert delays[0] == pytest.approx(meta_tidal.POLL_INTERVAL * 2)
        assert delays[1] == pytest.approx(delays[0] * 2)
        assert delays[2] == pytest.approx(delays[1] * 2)

    def test_invalid_json_continues(self, tmp_path, capture_stdout, monkeypatch):
        meta_file = tmp_path / "tidal-metadata.json"
        meta_file.write_text("not valid json {{{")

        monkeypatch.setattr(meta_tidal, "METADATA_FILE", str(meta_file))

        call_count = 0

        def _sleep_then_stop(seconds):
            nonlocal call_count
            call_count += 1
            if call_count >= 2:
                raise SystemExit("stop")

        monkeypatch.setattr(time, "sleep", _sleep_then_stop)

        with pytest.raises(SystemExit, match="stop"):
            meta_tidal.file_watch_thread()

        # No crash, metadata unchanged
        assert meta_tidal.metadata["title"] == ""
        # Only the log message, no properties sent
        props_msgs = [m for m in capture_stdout if m.get("method") == "Plugin.Stream.Player.Properties"]
        assert len(props_msgs) == 0
