"""Tests for fb-display renderer (pure logic, no hardware)."""

import asyncio
import sys
import os
import time

import numpy as np
import pytest

# Add fb-display to path
sys.path.insert(
    0, os.path.join(os.path.dirname(__file__), "..", "common", "docker", "fb-display")
)

# Stub out hardware-dependent imports before importing fb_display
# PIL is available but websockets/requests may not have all runtime deps
import fb_display


def _mock_proc_uptime(monkeypatch, seconds: float) -> None:
    """Make `open('/proc/uptime')` return the given uptime value.

    `_get_lan_ip()` reads /proc/uptime to decide between the transient
    'Booting…' label and the persistent '?.?.?.?' fallback. Tests pin
    that value so the assertion does not depend on real host uptime
    (e.g. dev laptop has been up for hours, CI container for seconds).
    """
    import io

    real_open = open

    def fake_open(path, *a, **kw):
        if str(path) == "/proc/uptime":
            return io.StringIO(f"{seconds} {seconds}\n")
        return real_open(path, *a, **kw)

    monkeypatch.setattr("builtins.open", fake_open)


class TestFormatTime:
    """Test time formatting function."""

    def test_zero(self):
        assert fb_display.format_time(0) == "0:00"

    def test_seconds_only(self):
        assert fb_display.format_time(45) == "0:45"

    def test_minutes_and_seconds(self):
        assert fb_display.format_time(204) == "3:24"

    def test_exact_minute(self):
        assert fb_display.format_time(60) == "1:00"

    def test_hour_format(self):
        assert fb_display.format_time(3661) == "1:01:01"

    def test_negative_clamped_to_zero(self):
        assert fb_display.format_time(-5) == "0:00"

    def test_large_value(self):
        assert fb_display.format_time(7200) == "2:00:00"

    def test_59_minutes(self):
        assert fb_display.format_time(3599) == "59:59"

    def test_60_minutes_wraps_to_hour(self):
        assert fb_display.format_time(3600) == "1:00:00"


class TestLerpColor:
    """Test color interpolation."""

    def test_t_zero_returns_first(self):
        assert fb_display.lerp_color((0, 0, 0), (255, 255, 255), 0.0) == (0, 0, 0)

    def test_t_one_returns_second(self):
        assert fb_display.lerp_color((0, 0, 0), (255, 255, 255), 1.0) == (255, 255, 255)

    def test_t_half_returns_midpoint(self):
        result = fb_display.lerp_color((0, 0, 0), (200, 100, 50), 0.5)
        assert result == (100, 50, 25)


class TestRainbowColor:
    """Test rainbow color generation."""

    def test_returns_rgb_tuple(self):
        r, g, b = fb_display.rainbow_color(0, 21)
        assert 0 <= r <= 255
        assert 0 <= g <= 255
        assert 0 <= b <= 255

    def test_first_bar_is_red(self):
        r, g, b = fb_display.rainbow_color(0, 21)
        assert r > g and r > b

    def test_different_bars_different_colors(self):
        c1 = fb_display.rainbow_color(0, 21)
        c2 = fb_display.rainbow_color(10, 21)
        assert c1 != c2


class TestDisplayRange:
    """Test display range constants and mapping."""

    def test_display_floor_is_negative(self):
        assert fb_display.DISPLAY_FLOOR < 0

    def test_display_range_positive(self):
        assert fb_display.DISPLAY_RANGE > 0

    def test_display_range_matches_floor_magnitude(self):
        assert fb_display.DISPLAY_RANGE == abs(fb_display.DISPLAY_FLOOR)

    def test_spectrum_mapping_silence(self):
        """At DISPLAY_FLOOR, fraction should be 0."""
        db = fb_display.DISPLAY_FLOOR
        fraction = (db - fb_display.DISPLAY_FLOOR) / fb_display.DISPLAY_RANGE
        assert fraction == pytest.approx(0.0)

    def test_spectrum_mapping_full_scale(self):
        """At 0 dBFS, fraction should be 1."""
        db = 0.0
        fraction = (db - fb_display.DISPLAY_FLOOR) / fb_display.DISPLAY_RANGE
        assert fraction == pytest.approx(1.0)

    def test_spectrum_mapping_mid(self):
        """Halfway point should map to 0.5."""
        db = fb_display.DISPLAY_FLOOR / 2
        fraction = (db - fb_display.DISPLAY_FLOOR) / fb_display.DISPLAY_RANGE
        assert fraction == pytest.approx(0.5)


class TestSmoothingCoefficients:
    """Test smoothing constants are valid."""

    def test_attack_in_range(self):
        assert 0.0 < fb_display.ATTACK_COEFF < 1.0

    def test_decay_in_range(self):
        assert 0.0 < fb_display.DECAY_COEFF < 1.0

    def test_attack_faster_than_decay(self):
        assert fb_display.ATTACK_COEFF > fb_display.DECAY_COEFF


class TestGetCurrentElapsed:
    """Test local clock elapsed time calculation."""

    def test_returns_offset_when_paused(self):
        fb_display._is_playing = False
        fb_display._playback_offset = 42.0
        assert fb_display.get_current_elapsed() == 42

    def test_advances_when_playing(self):
        fb_display._is_playing = True
        fb_display._playback_offset = 10.0
        fb_display._playback_start = time.monotonic() - 5.0
        elapsed = fb_display.get_current_elapsed()
        assert 14 <= elapsed <= 16  # ~15 seconds (10 + 5)

    def test_frozen_when_paused(self):
        fb_display._is_playing = False
        fb_display._playback_offset = 30.0
        fb_display._playback_start = time.monotonic() - 100.0
        assert fb_display.get_current_elapsed() == 30


class TestAudioBadge:
    """Test audio format badge generation."""

    def test_flac_with_sample_rate(self):
        meta = {"codec": "FLAC", "sample_rate": 44100, "bit_depth": 16}
        badge = fb_display._format_audio_badge(meta)
        assert "FLAC" in badge
        assert "44.1kHz" in badge
        assert "16bit" in badge

    def test_flac_hires(self):
        meta = {"codec": "FLAC", "sample_rate": 96000, "bit_depth": 24}
        badge = fb_display._format_audio_badge(meta)
        assert "96kHz" in badge
        assert "24bit" in badge

    def test_mp3_with_bitrate(self):
        meta = {"codec": "MP3", "bitrate": 320}
        badge = fb_display._format_audio_badge(meta)
        assert "MP3" in badge
        assert "320kbps" in badge

    def test_empty_codec(self):
        meta = {"codec": ""}
        assert fb_display._format_audio_badge(meta) == ""

    def test_no_codec(self):
        meta = {}
        assert fb_display._format_audio_badge(meta) == ""

    def test_wav_lossless(self):
        meta = {"codec": "WAV", "sample_rate": 48000, "bit_depth": 24}
        badge = fb_display._format_audio_badge(meta)
        assert "WAV" in badge
        assert "48kHz" in badge


class TestBadgeColor:
    """Test badge color selection by codec quality."""

    def test_lossless_green(self):
        meta = {"codec": "FLAC", "sample_rate": 44100}
        assert fb_display._format_badge_color(meta) == fb_display._BADGE_COLOR_LOSSLESS

    def test_hires_blue(self):
        meta = {"codec": "FLAC", "sample_rate": 96000}
        assert fb_display._format_badge_color(meta) == fb_display._BADGE_COLOR_HD

    def test_lossy_amber(self):
        meta = {"codec": "MP3", "sample_rate": 44100}
        assert fb_display._format_badge_color(meta) == fb_display._BADGE_COLOR_LOSSY

    def test_dsd_lossless(self):
        meta = {"codec": "DSD", "sample_rate": 44100}
        assert fb_display._format_badge_color(meta) == fb_display._BADGE_COLOR_LOSSLESS

    def test_dsd_hires(self):
        meta = {"codec": "DSD", "sample_rate": 2822400}
        assert fb_display._format_badge_color(meta) == fb_display._BADGE_COLOR_HD


class TestDisplayReleaseYear:
    """Test release-year precedence for album detail line."""

    def test_prefers_original_date(self):
        meta = {"original_date": "1979-11-30", "date": "2011-09-26"}
        assert fb_display._display_release_year(meta) == "1979"

    def test_prefers_original_release_date_alias(self):
        meta = {"original_release_date": "1973-03-01", "date": "2011-09-26"}
        assert fb_display._display_release_year(meta) == "1973"

    def test_falls_back_to_date(self):
        meta = {"date": "2011-09-26"}
        assert fb_display._display_release_year(meta) == "2011"

    def test_ignores_invalid_values(self):
        meta = {"original_date": "remaster", "date": "unknown"}
        assert fb_display._display_release_year(meta) == ""


class TestRgbToFbNative:
    """Test RGB to framebuffer format conversion."""

    def test_32bpp_bgra_shape(self):
        fb_display.fb_bpp = 32
        rgb = np.zeros((10, 20, 3), dtype=np.uint8)
        result = fb_display._rgb_to_fb_native(rgb)
        assert result.shape == (10, 20, 4)
        assert result.dtype == np.uint8

    def test_32bpp_bgra_swap(self):
        """Red pixel in RGB should become BGRA on little-endian."""
        fb_display.fb_bpp = 32
        fb_display.fb_big_endian = False
        rgb = np.zeros((1, 1, 3), dtype=np.uint8)
        rgb[0, 0] = [255, 0, 0]  # Pure red
        result = fb_display._rgb_to_fb_native(rgb)
        assert result[0, 0, 0] == 0  # B
        assert result[0, 0, 1] == 0  # G
        assert result[0, 0, 2] == 255  # R
        assert result[0, 0, 3] == 255  # A

    def test_32bpp_xrgb_swap(self):
        """Red pixel in RGB should become XRGB on big-endian."""
        fb_display.fb_bpp = 32
        fb_display.fb_big_endian = True
        rgb = np.zeros((1, 1, 3), dtype=np.uint8)
        rgb[0, 0] = [255, 0, 0]  # Pure red
        result = fb_display._rgb_to_fb_native(rgb)
        assert result[0, 0, 0] == 255  # X (pad)
        assert result[0, 0, 1] == 255  # R
        assert result[0, 0, 2] == 0  # G
        assert result[0, 0, 3] == 0  # B

    def test_16bpp_rgb565_shape(self):
        fb_display.fb_bpp = 16
        rgb = np.zeros((10, 20, 3), dtype=np.uint8)
        result = fb_display._rgb_to_fb_native(rgb)
        assert result.shape == (10, 20)
        assert result.dtype == np.uint16

    def test_16bpp_rgb565_white(self):
        """White in RGB565 should be 0xFFFF."""
        fb_display.fb_bpp = 16
        rgb = np.full((1, 1, 3), 255, dtype=np.uint8)
        result = fb_display._rgb_to_fb_native(rgb)
        assert result[0, 0] == 0xFFFF

    def test_16bpp_rgb565_black(self):
        fb_display.fb_bpp = 16
        rgb = np.zeros((1, 1, 3), dtype=np.uint8)
        result = fb_display._rgb_to_fb_native(rgb)
        assert result[0, 0] == 0

    def test_16bpp_rgb565_pure_red(self):
        """Pure red (255,0,0) in RGB565: R=31<<11=0xF800."""
        fb_display.fb_bpp = 16
        rgb = np.zeros((1, 1, 3), dtype=np.uint8)
        rgb[0, 0] = [255, 0, 0]
        result = fb_display._rgb_to_fb_native(rgb)
        assert result[0, 0] == 0xF800


class TestRgbTupleToFb:
    """Test single-pixel RGB to FB conversion."""

    def test_32bpp_returns_bgra_tuple(self):
        fb_display.fb_bpp = 32
        fb_display.fb_big_endian = False
        result = fb_display._rgb_tuple_to_fb(255, 128, 64)
        assert result == (64, 128, 255, 255)

    def test_32bpp_returns_xrgb_tuple(self):
        fb_display.fb_bpp = 32
        fb_display.fb_big_endian = True
        result = fb_display._rgb_tuple_to_fb(255, 128, 64)
        assert result == (255, 255, 128, 64)

    def test_16bpp_returns_int(self):
        fb_display.fb_bpp = 16
        result = fb_display._rgb_tuple_to_fb(0, 0, 0)
        assert result == 0

    def test_16bpp_white(self):
        fb_display.fb_bpp = 16
        result = fb_display._rgb_tuple_to_fb(255, 255, 255)
        assert result == 0xFFFF


class TestScaleToFb:
    """Test render-to-FB resolution scaling."""

    def test_no_scale_same_resolution(self):
        fb_display.WIDTH = 100
        fb_display.FB_WIDTH = 100
        fb_display.HEIGHT = 50
        fb_display.FB_HEIGHT = 50
        pixels = np.ones((10, 20), dtype=np.uint16)
        result = fb_display._scale_to_fb(pixels)
        assert result is pixels  # Same object, no copy

    def test_scale_2x(self):
        fb_display.WIDTH = 100
        fb_display.FB_WIDTH = 200
        fb_display.HEIGHT = 50
        fb_display.FB_HEIGHT = 100
        pixels = np.ones((10, 20), dtype=np.uint16)
        result = fb_display._scale_to_fb(pixels)
        assert result.shape == (20, 40)

    def test_scale_preserves_dtype_16bpp(self):
        fb_display.WIDTH = 100
        fb_display.FB_WIDTH = 200
        fb_display.HEIGHT = 100
        fb_display.FB_HEIGHT = 200
        pixels = np.ones((10, 10), dtype=np.uint16)
        result = fb_display._scale_to_fb(pixels)
        assert result.dtype == np.uint16

    def test_scale_preserves_dtype_32bpp(self):
        fb_display.WIDTH = 100
        fb_display.FB_WIDTH = 200
        fb_display.HEIGHT = 100
        fb_display.FB_HEIGHT = 200
        pixels = np.ones((10, 10, 4), dtype=np.uint8)
        result = fb_display._scale_to_fb(pixels)
        assert result.dtype == np.uint8
        assert result.shape[2] == 4


class TestResizeBands:
    """Test band array resizing."""

    def test_resize_changes_num_bands(self):
        old = fb_display.NUM_BANDS
        try:
            fb_display.resize_bands(31)
            assert fb_display.NUM_BANDS == 31
            assert len(fb_display.bands) == 31
            assert len(fb_display.display_bands) == 31
            assert len(fb_display.peak_bands) == 31
            assert len(fb_display.peak_time) == 31
        finally:
            fb_display.resize_bands(old)

    def test_noop_same_count(self):
        old_bands = fb_display.bands
        fb_display.resize_bands(fb_display.NUM_BANDS)
        assert fb_display.bands is old_bands  # No change


class TestComputeLayout:
    """Test layout computation."""

    def test_layout_keys_present(self):
        fb_display.WIDTH = 1920
        fb_display.HEIGHT = 1080
        fb_display.NUM_BANDS = 21
        L = fb_display.compute_layout()
        required_keys = [
            "art_x",
            "art_y",
            "art_size",
            "right_x",
            "right_w",
            "spec_y",
            "spec_h",
            "bar_w",
            "bar_gap",
            "pad",
            "start_x",
            "container_w",
            "bottom_y",
            "status_y",
        ]
        for key in required_keys:
            assert key in L, f"Missing layout key: {key}"

    def test_art_fits_in_screen(self):
        fb_display.WIDTH = 1920
        fb_display.HEIGHT = 1080
        L = fb_display.compute_layout()
        assert L["art_x"] >= 0
        assert L["art_y"] >= 0
        assert L["art_x"] + L["art_size"] <= fb_display.WIDTH
        assert L["art_y"] + L["art_size"] <= fb_display.HEIGHT

    def test_spectrum_below_info(self):
        fb_display.WIDTH = 1920
        fb_display.HEIGHT = 1080
        L = fb_display.compute_layout()
        assert L["spec_y"] >= L["info_y"] + L["info_h"]

    def test_bar_width_positive(self):
        fb_display.WIDTH = 1920
        fb_display.HEIGHT = 1080
        fb_display.NUM_BANDS = 31
        L = fb_display.compute_layout()
        assert L["bar_w"] > 0

    def test_small_resolution(self):
        """Layout should work even at 800x600."""
        fb_display.WIDTH = 800
        fb_display.HEIGHT = 600
        fb_display.NUM_BANDS = 21
        L = fb_display.compute_layout()
        assert L["bar_w"] > 0
        assert L["art_size"] > 0


class TestGetLanIp:
    """Test LAN IP detection."""

    def test_returns_ip_string(self):
        ip = fb_display._get_lan_ip()
        parts = ip.split(".")
        assert len(parts) == 4
        for part in parts:
            assert part.isdigit()
            assert 0 <= int(part) <= 255

    def test_fallback_to_hostname_resolution(self, monkeypatch):
        import socket

        def _raise(*a, **kw):
            raise OSError("no route")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(
            socket,
            "getaddrinfo",
            lambda *a, **kw: [
                (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("127.0.0.1", 0)),
                (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("192.0.2.104", 0)),
            ],
        )
        assert fb_display._get_lan_ip() == "192.0.2.104"

    def test_fallback_on_total_failure(self, monkeypatch):
        import socket

        def _raise(*a, **kw):
            raise OSError("no network")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(socket, "getaddrinfo", _raise)
        # Pin uptime to past the 90 s boot-age gate so the test asserts
        # the bare placeholder (the actual fail-mode contract) and is
        # not flaky on CI runners whose container uptime is < 90 s.
        _mock_proc_uptime(monkeypatch, 600.0)
        assert fb_display._get_lan_ip() == "?.?.?.?"

    def test_booting_placeholder_during_first_90s(self, monkeypatch):
        """Within 90 s of boot, no-IP should render as 'Booting…' rather
        than '?.?.?.?' — the placeholder reads as broken-network and
        triggered unnecessary user reboots on every fresh boot."""
        import socket

        def _raise(*a, **kw):
            raise OSError("no network yet")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(socket, "getaddrinfo", _raise)
        _mock_proc_uptime(monkeypatch, 30.0)
        assert fb_display._get_lan_ip() == "Booting…"

    def test_placeholder_returns_at_90s_threshold(self, monkeypatch):
        """At uptime >= 90 s the no-IP state is a real persistent
        failure and the bare placeholder must surface."""
        import socket

        def _raise(*a, **kw):
            raise OSError("no network")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(socket, "getaddrinfo", _raise)
        _mock_proc_uptime(monkeypatch, 90.0)
        assert fb_display._get_lan_ip() == "?.?.?.?"

    def test_unreadable_uptime_falls_through_conservative(self, monkeypatch):
        """If /proc/uptime cannot be read at all (exotic container, no
        /proc mount, IO error), the boot-age gate must NOT silently
        cover up a real outage — fall through to '?.?.?.?' so a true
        failure still surfaces."""
        import socket

        def _raise(*a, **kw):
            raise OSError("no network")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(socket, "getaddrinfo", _raise)
        # Open of /proc/uptime raises OSError → caught → fall through
        real_open = open

        def fake_open(path, *a, **kw):
            if str(path) == "/proc/uptime":
                raise OSError("not mounted")
            return real_open(path, *a, **kw)

        monkeypatch.setattr("builtins.open", fake_open)
        assert fb_display._get_lan_ip() == "?.?.?.?"


class TestDiscoverSnapservers:
    """Test mDNS server discovery."""

    def test_discovers_servers(self, monkeypatch):
        """Mock zeroconf to simulate server discovery."""
        import types

        class FakeServiceInfo:
            def __init__(self, addresses):
                self.addresses = addresses

        class FakeZeroconf:
            def get_service_info(self, type_, name):
                return FakeServiceInfo(
                    [b"\xc0\x00\x02\x68"]
                )  # 192.0.2.104 (0xc0.0x00.0x02.0x68)

            def close(self):
                pass

        class FakeBrowser:
            def __init__(self, zc, type_, listener):
                # Simulate discovering a service
                listener.add_service(zc, type_, "Snapcast._snapcast._tcp.local.")

            def cancel(self):
                pass

        fake_zeroconf_mod = types.ModuleType("zeroconf")
        fake_zeroconf_mod.Zeroconf = FakeZeroconf
        fake_zeroconf_mod.ServiceBrowser = FakeBrowser
        monkeypatch.setitem(sys.modules, "zeroconf", fake_zeroconf_mod)

        servers = asyncio.run(fb_display.discover_snapservers(timeout=0.1))
        assert "192.0.2.104" in servers

    def test_empty_discovery(self, monkeypatch):
        """No servers found returns empty list."""
        import types

        class FakeZeroconf:
            def close(self):
                pass

        class FakeBrowser:
            def __init__(self, zc, type_, listener):
                pass  # No services discovered

            def cancel(self):
                pass

        fake_zeroconf_mod = types.ModuleType("zeroconf")
        fake_zeroconf_mod.Zeroconf = FakeZeroconf
        fake_zeroconf_mod.ServiceBrowser = FakeBrowser
        monkeypatch.setitem(sys.modules, "zeroconf", fake_zeroconf_mod)

        import asyncio

        servers = asyncio.run(fb_display.discover_snapservers(timeout=0.1))
        assert servers == []


class TestHandleMetadataMessage:
    """Test _handle_metadata_message async handler."""

    def setup_method(self):
        """Reset globals before each test."""
        fb_display.server_info = {}
        fb_display.current_metadata = None
        fb_display.metadata_version = 0

    def test_server_info_updates_global(self):
        """server_info message populates the server_info global."""
        msg = '{"type": "server_info", "server_version": "0.3.6"}'
        asyncio.run(fb_display._handle_metadata_message(msg))
        assert fb_display.server_info.get("server_version") == "0.3.6"

    def test_server_info_bumps_metadata_version(self):
        """server_info message triggers a base frame redraw via metadata_version."""
        before = fb_display.metadata_version
        msg = '{"type": "server_info", "server_version": "0.3.6"}'
        asyncio.run(fb_display._handle_metadata_message(msg))
        assert fb_display.metadata_version == before + 1

    def test_server_info_no_redraw_on_repeat(self):
        """Duplicate server_info message must not bump metadata_version."""
        msg = '{"type": "server_info", "server_version": "0.3.6"}'
        asyncio.run(fb_display._handle_metadata_message(msg))
        version_after_first = fb_display.metadata_version
        asyncio.run(fb_display._handle_metadata_message(msg))  # identical repeat
        assert fb_display.metadata_version == version_after_first

    def test_server_info_does_not_update_current_metadata(self):
        """server_info message returns early — current_metadata must stay unchanged."""
        fb_display.current_metadata = {"title": "Previous Track"}
        msg = '{"type": "server_info", "server_version": "0.3.6"}'
        asyncio.run(fb_display._handle_metadata_message(msg))
        assert fb_display.current_metadata == {"title": "Previous Track"}

    def test_normal_metadata_does_not_touch_server_info(self):
        """A regular track metadata message must not alter server_info."""
        fb_display.server_info = {"server_version": "0.3.6"}
        msg = '{"title": "Song", "artist": "Band", "codec": "FLAC"}'
        asyncio.run(fb_display._handle_metadata_message(msg))
        assert fb_display.server_info == {"server_version": "0.3.6"}

    def test_invalid_json_is_handled(self):
        """Malformed JSON should not raise — just log and return."""
        asyncio.run(fb_display._handle_metadata_message("not-json"))
        # No exception = pass; globals unchanged
        assert fb_display.server_info == {}


class TestVersionSuffix:
    """Test ver_suffix formatting logic from render_base_frame (4 combinations)."""

    def _compute_suffix(self, app_version: str, srv_ver: str) -> str:
        """Mirror the ver_suffix logic from render_base_frame."""
        ver_parts = []
        if app_version:
            ver_parts.append(app_version)
        if srv_ver and srv_ver != "unknown":
            ver_parts.append(f"srv {srv_ver}")
        return "  •  " + "  /  ".join(ver_parts) if ver_parts else ""

    def test_both_versions(self):
        suffix = self._compute_suffix("v0.2.4", "0.3.7")
        assert suffix == "  •  v0.2.4  /  srv 0.3.7"

    def test_client_only(self):
        suffix = self._compute_suffix("v0.2.4", "")
        assert suffix == "  •  v0.2.4"

    def test_server_only(self):
        suffix = self._compute_suffix("", "0.3.7")
        assert suffix == "  •  srv 0.3.7"

    def test_neither(self):
        suffix = self._compute_suffix("", "")
        assert suffix == ""

    def test_server_unknown_treated_as_missing(self):
        suffix = self._compute_suffix("v0.2.4", "unknown")
        assert suffix == "  •  v0.2.4"

    def test_status_text_format(self):
        """Full status_text assembles correctly."""
        suffix = self._compute_suffix("v0.2.4", "0.3.7")
        status = f"192.168.1.1  →  pi-server{suffix}"
        assert status == "192.168.1.1  →  pi-server  •  v0.2.4  /  srv 0.3.7"


class TestIsSpectrumActive:
    """Test spectrum activity detection."""

    def test_silence_not_active(self):
        fb_display.bands[:] = fb_display.NOISE_FLOOR
        assert not fb_display.is_spectrum_active()

    def test_signal_is_active(self):
        fb_display.bands[:] = fb_display.NOISE_FLOOR
        fb_display.bands[5] = fb_display.NOISE_FLOOR + 10
        assert fb_display.is_spectrum_active()

    def test_just_above_threshold(self):
        fb_display.bands[:] = fb_display.NOISE_FLOOR
        fb_display.bands[0] = fb_display.NOISE_FLOOR + 4
        assert fb_display.is_spectrum_active()


class TestVitals:
    """Bottom-line system vitals (temp · load · resync) from the /status snapshot."""

    def _records(self, msgs):
        return [{"section": "x", "status": "info", "msg": m} for m in msgs]

    def test_parse_all_three(self):
        s = fb_display._parse_vitals(
            self._records(
                [
                    "SoC 69.1°C via vcgencmd (below 75°C warn floor)",
                    "CPU load: 0.39 0.28 0.27 (4 cores)",
                    "Audio resync (snapclient, 24h): 7",
                ]
            )
        )
        assert "69.1°C" in s
        assert "load 0.39" in s
        assert "resync 7" in s
        assert "·" in s  # DejaVuSans-safe separator, no emoji

    def test_parse_partial_temp_only(self):
        s = fb_display._parse_vitals(
            self._records(["SoC 62.0°C via vcgencmd (below 75°C warn floor)"])
        )
        assert s == "62.0°C"

    def test_parse_unavailable_resync_not_numeric(self):
        s = fb_display._parse_vitals(
            self._records(["Audio resync (24h): log source unavailable"])
        )
        assert s == ""

    def test_parse_empty(self):
        assert fb_display._parse_vitals([]) == ""

    def test_get_vitals_ttl_cache(self, monkeypatch):
        calls = {"n": 0}

        def fake_fetch():
            calls["n"] += 1
            return "71°C"

        monkeypatch.setattr(fb_display, "_fetch_vitals", fake_fetch)
        fb_display._VITALS_CACHE = ("", 0.0)
        assert fb_display.get_vitals() == "71°C"
        assert fb_display.get_vitals() == "71°C"  # cache hit within TTL
        assert calls["n"] == 1

    def test_get_vitals_keeps_last_good_on_failure(self, monkeypatch):
        fb_display._VITALS_CACHE = ("70°C", 0.0)  # stale timestamp -> refetch
        monkeypatch.setattr(fb_display, "_fetch_vitals", lambda: "")  # failure
        assert fb_display.get_vitals() == "70°C"  # last good kept


class TestStandby:
    """Pure standby decision (_should_standby) for the panel power management."""

    def test_disabled_never_blanks(self):
        assert fb_display._should_standby(False, 9999, 0) is False

    def test_playing_never_blanks(self):
        assert fb_display._should_standby(True, 9999, 15) is False

    def test_idle_below_threshold(self):
        assert fb_display._should_standby(False, 10, 15) is False

    def test_idle_at_threshold(self):
        assert fb_display._should_standby(False, 15, 15) is True

    def test_idle_above_threshold(self):
        assert fb_display._should_standby(False, 30, 15) is True

    def test_reassert_not_due_before_interval(self):
        assert fb_display._should_reassert_standby(129.9, 100.0, 30) is False

    def test_reassert_due_at_interval(self):
        assert fb_display._should_reassert_standby(130.0, 100.0, 30) is True

    def test_reassert_due_long_after(self):
        assert fb_display._should_reassert_standby(10_000.0, 100.0, 30) is True

    def test_reassert_interval_is_positive(self):
        # 0 would repeat the ioctl on every 1 s blanked tick.
        assert fb_display.STANDBY_REASSERT_SECONDS > 1


class _StopLoop(BaseException):
    """Ends render_loop; BaseException so its error handler does not catch it."""


def _run_idle_render_loop(monkeypatch, power_results, until):
    """Drive render_loop on a fake clock with nothing playing and no frame
    to render, until the clock passes `until`. `power_results` feeds the
    return values of _fb_set_power (then True). Returns (now, on) calls."""
    clock = {"now": 1000.0}
    calls = []
    results = list(power_results)

    def fake_power(on):
        calls.append((clock["now"], on))
        return results.pop(0) if results else True

    async def fake_sleep(seconds):
        clock["now"] += seconds
        if clock["now"] > until:
            raise _StopLoop

    monkeypatch.setattr(fb_display.time, "monotonic", lambda: clock["now"])
    monkeypatch.setattr(fb_display.asyncio, "sleep", fake_sleep)
    monkeypatch.setattr(fb_display, "_fb_set_power", fake_power)
    monkeypatch.setattr(fb_display, "is_spectrum_active", lambda: False)
    monkeypatch.setattr(fb_display, "current_metadata", None)
    monkeypatch.setattr(fb_display, "STANDBY_SECONDS", 15)
    monkeypatch.setattr(fb_display, "base_frame_version", fb_display.metadata_version)
    monkeypatch.setattr(fb_display, "spectrum_bg_np", None)
    # A wake forces a full redraw; there is no framebuffer to draw on here.
    monkeypatch.setattr(fb_display, "render_base_frame", lambda: None)
    monkeypatch.setattr(fb_display, "extract_spectrum_bg", lambda: None)
    monkeypatch.setattr(fb_display, "write_full_frame", lambda frame: None)

    with pytest.raises(_StopLoop):
        asyncio.run(fb_display.render_loop())
    return calls


class TestStandbyRenderLoop:
    """render_loop keeps a blanked panel off."""

    def test_power_off_repeats_while_blanked(self, monkeypatch):
        calls = _run_idle_render_loop(monkeypatch, [], until=1100.0)
        offs = [t - 1000.0 for t, on in calls if not on]
        assert [on for _, on in calls] == [False] * len(calls)
        # First power-off after 15 s idle, then one every 30 s.
        assert len(offs) == 3
        assert offs[0] == pytest.approx(15, abs=1)
        assert offs[1] - offs[0] == pytest.approx(30, abs=1)
        assert offs[2] - offs[1] == pytest.approx(30, abs=1)

    def test_failed_repeat_renders_again_then_disables_standby(self, monkeypatch):
        # Initial power-off works, the repeat fails, the retry after the
        # idle timer fails too: standby is disabled, no further ioctls.
        calls = _run_idle_render_loop(monkeypatch, [True, False, False], until=1300.0)
        offs = [t - 1000.0 for t, on in calls if not on]
        assert len(offs) == 3
        assert offs[1] - offs[0] == pytest.approx(30, abs=1)
        assert offs[2] - offs[1] == pytest.approx(15, abs=1)


# ---------------------------------------------------------------------------
# Render robustness: band-count resize, bad artwork, per-frame exceptions,
# clock box, status-line refresh, asset caches.
# ---------------------------------------------------------------------------

from PIL import Image  # noqa: E402


@pytest.fixture
def screen(monkeypatch):
    """Small 32bpp little-endian render target with no real framebuffer."""
    monkeypatch.setattr(fb_display, "WIDTH", 800)
    monkeypatch.setattr(fb_display, "HEIGHT", 480)
    monkeypatch.setattr(fb_display, "FB_WIDTH", 800)
    monkeypatch.setattr(fb_display, "FB_HEIGHT", 480)
    monkeypatch.setattr(fb_display, "fb_bpp", 32)
    monkeypatch.setattr(fb_display, "fb_big_endian", False)
    monkeypatch.setattr(fb_display, "fb_mmap", None)
    # resize_bands() rebinds these module globals; register them so
    # monkeypatch restores the originals after the test.
    for name in (
        "NUM_BANDS",
        "bands",
        "display_bands",
        "peak_bands",
        "peak_time",
        "BAR_COLORS",
        "PEAK_COLORS",
        "BAR_COLORS_FB",
        "PEAK_COLORS_FB",
        "base_frame",
        "base_frame_version",
        "spectrum_bg_np",
        "spectrum_bg_fb",
        "_spectrum_work_buf",
        "current_metadata",
        "cached_artwork",
        "cached_artwork_url",
        "_failed_artwork",
        "_status_text_drawn",
        "_logo_img",
        "_brand_img",
    ):
        monkeypatch.setattr(
            fb_display, name, getattr(fb_display, name, None), raising=False
        )
    monkeypatch.setattr(fb_display, "NUM_BANDS", 21)
    monkeypatch.setattr(fb_display, "bands", np.full(21, fb_display.NOISE_FLOOR))
    monkeypatch.setattr(
        fb_display, "display_bands", np.full(21, fb_display.NOISE_FLOOR)
    )
    monkeypatch.setattr(fb_display, "peak_bands", np.zeros(21))
    monkeypatch.setattr(fb_display, "peak_time", np.zeros(21))
    monkeypatch.setattr(fb_display, "_logo_img", None)
    monkeypatch.setattr(fb_display, "_brand_img", None)
    monkeypatch.setattr(fb_display, "current_metadata", None)
    monkeypatch.setattr(fb_display, "cached_artwork", None)
    monkeypatch.setattr(fb_display, "cached_artwork_url", "")
    monkeypatch.setattr(fb_display, "_failed_artwork", ("", 0.0), raising=False)
    monkeypatch.setattr(fb_display, "get_lan_ip", lambda: "192.168.1.50")
    monkeypatch.setattr(fb_display, "get_vitals", lambda: "")
    monkeypatch.setattr(
        fb_display,
        "_clock_cache",
        {"time_str": None, "fb": None, "width": 0, "height": 0, "dirty": True},
    )
    monkeypatch.setattr(
        fb_display, "_bg_cache", {"size": None, "img": None}, raising=False
    )
    monkeypatch.setattr(fb_display, "_art_resized_cache", {}, raising=False)
    monkeypatch.setattr(fb_display, "_asset_resized_cache", {}, raising=False)
    monkeypatch.setattr(fb_display, "layout", fb_display.compute_layout())
    fb_display.precompute_colors()
    fb_display.precompute_fb_colors()
    return fb_display.layout


def _jpeg_bytes(size=(64, 64)) -> bytes:
    """Noisy JPEG: big enough that cutting it in half keeps the header intact
    (Image.open succeeds, decoding fails) — the real truncated-download case."""
    import io

    rng = np.random.default_rng(0)
    pixels = rng.integers(0, 255, (size[1], size[0], 3), dtype=np.uint8)
    buf = io.BytesIO()
    Image.fromarray(pixels, "RGB").save(buf, "JPEG")
    return buf.getvalue()


class _Resp:
    def __init__(self, content: bytes, status_code: int = 200):
        self.content = content
        self.status_code = status_code


class TestSpectrumResize:
    """resize_bands() drops the spectrum background; nothing may crash or freeze."""

    def test_render_spectrum_returns_none_without_background(self, screen):
        fb_display.spectrum_bg_fb = None
        assert fb_display.render_spectrum() is None
        # Full frame path tolerates it too (fb_mmap is None → writes are no-ops)
        fb_display._render_and_write_frame(True, True)

    def test_resize_between_check_and_render_does_not_raise(self, screen):
        fb_display.base_frame = fb_display.create_background()
        fb_display.extract_spectrum_bg()
        assert fb_display.render_spectrum() is not None
        fb_display.resize_bands(31)  # what the spectrum WS reader can do mid-frame
        assert fb_display.spectrum_bg_fb is None
        fb_display._render_and_write_frame(True, True)  # used to AttributeError

    def test_render_loop_reextracts_background_after_resize(self, screen, monkeypatch):
        fb_display.base_frame = fb_display.create_background()
        monkeypatch.setattr(
            fb_display, "base_frame_version", fb_display.metadata_version
        )
        fb_display.spectrum_bg_np = None
        fb_display.spectrum_bg_fb = None
        monkeypatch.setattr(fb_display, "is_spectrum_active", lambda: False)
        monkeypatch.setattr(fb_display, "STANDBY_SECONDS", 0)

        async def stop_sleep(seconds):
            raise _StopLoop

        monkeypatch.setattr(fb_display.asyncio, "sleep", stop_sleep)
        with pytest.raises(_StopLoop):
            asyncio.run(fb_display.render_loop())
        assert fb_display.spectrum_bg_fb is not None
        assert fb_display.spectrum_bg_np is not None


class TestBadArtwork:
    """A truncated/corrupt cover must not crash-loop the display."""

    def test_truncated_jpeg_rejected_at_fetch(self, screen, monkeypatch):
        data = _jpeg_bytes()
        calls = []

        def fake_get(url, timeout):
            calls.append(url)
            return _Resp(data[: len(data) // 2])

        monkeypatch.setattr(fb_display.requests, "get", fake_get)
        assert fb_display.fetch_artwork("/art/bad.jpg") is None
        assert fb_display.cached_artwork is None
        # Not re-downloaded on every base-frame rebuild
        assert fb_display.fetch_artwork("/art/bad.jpg") is None
        assert len(calls) == 1

    def test_valid_jpeg_cached_and_decoded(self, screen, monkeypatch):
        monkeypatch.setattr(
            fb_display.requests, "get", lambda url, timeout: _Resp(_jpeg_bytes())
        )
        img = fb_display.fetch_artwork("/art/good.jpg")
        assert img is not None and img.size == (64, 64)
        assert fb_display.cached_artwork is img

    def test_render_base_frame_drops_unusable_cached_artwork(self, screen):
        import io

        data = _jpeg_bytes()
        lazy = Image.open(io.BytesIO(data[: len(data) // 2]))  # not decoded yet
        fb_display.cached_artwork = lazy
        fb_display.cached_artwork_url = "/art/lazy.jpg"
        fb_display.current_metadata = {
            "playing": True,
            "artwork": "/art/lazy.jpg",
            "title": "T",
            "artist": "A",
        }
        frame = fb_display.render_base_frame()  # used to raise OSError
        assert frame.size == (fb_display.WIDTH, fb_display.HEIGHT)
        assert fb_display.cached_artwork is None
        assert fb_display.cached_artwork_url == ""


class TestRenderLoopErrors:
    def test_unexpected_exception_does_not_end_render_loop(self, screen, monkeypatch):
        calls = {"render": 0, "sleep": 0}

        def flaky_render():
            calls["render"] += 1
            if calls["render"] == 1:
                raise KeyError("boom")  # not OSError/ValueError/RuntimeError
            return fb_display.create_background()

        async def fake_sleep(seconds):
            calls["sleep"] += 1
            if calls["sleep"] >= 3:
                raise _StopLoop

        monkeypatch.setattr(fb_display, "render_base_frame", flaky_render)
        monkeypatch.setattr(fb_display, "base_frame_version", -1)
        monkeypatch.setattr(fb_display, "is_spectrum_active", lambda: False)
        monkeypatch.setattr(fb_display, "STANDBY_SECONDS", 0)
        monkeypatch.setattr(fb_display.asyncio, "sleep", fake_sleep)
        with pytest.raises(_StopLoop):
            asyncio.run(fb_display.render_loop())
        assert calls["render"] >= 2
        assert fb_display.base_frame_version == fb_display.metadata_version


class TestClockBox:
    def test_clock_background_comes_from_base_frame(self, screen):
        fb_display.base_frame = fb_display.create_background()
        fb, w, h = fb_display.render_clock()
        x = (fb_display.WIDTH - w) // 2
        y = screen["clock_y"]
        r, g, b = fb_display.base_frame.getpixel((x, y))
        assert tuple(fb[0, 0, :3]) == (b, g, r)
        top = fb_display.BG_TOP
        assert tuple(fb[0, 0, :3]) != (top[2], top[1], top[0])

    def test_clock_box_never_shrinks(self, screen, monkeypatch):
        dates = iter(["WWW 28 MMM", "iii 11 iii"])
        state = {"date": None}

        def fake_strftime(fmt, *a):
            if fmt == "%a %d %b":
                state["date"] = next(dates)
                return state["date"]
            return "12:00:00"

        monkeypatch.setattr(fb_display.time, "strftime", fake_strftime)
        _, w1, h1 = fb_display.render_clock()
        _, w2, h2 = fb_display.render_clock()
        assert w2 == w1
        assert h2 >= h1


class TestStatusLineRefresh:
    def test_changed_status_writes_only_the_strip(self, screen, monkeypatch):
        fb_display.base_frame = fb_display.create_background()
        monkeypatch.setattr(
            fb_display, "base_frame_version", fb_display.metadata_version
        )
        fb_display._status_text_drawn = "10.0.0.1  →  srv"
        new_frame = fb_display.create_background()
        writes = []
        monkeypatch.setattr(
            fb_display, "_build_status_text", lambda: "10.0.0.2  →  srv"
        )
        monkeypatch.setattr(fb_display, "render_base_frame", lambda: new_frame)
        monkeypatch.setattr(fb_display, "_write_status_strip", writes.append)
        monkeypatch.setattr(
            fb_display, "write_full_frame", lambda f: pytest.fail("full write")
        )
        assert asyncio.run(fb_display._refresh_status_line()) is True
        assert writes == [new_frame]
        assert fb_display.base_frame is new_frame

    def test_unchanged_status_is_a_noop(self, screen, monkeypatch):
        fb_display._status_text_drawn = "same"
        monkeypatch.setattr(fb_display, "_build_status_text", lambda: "same")
        monkeypatch.setattr(
            fb_display, "render_base_frame", lambda: pytest.fail("re-rendered")
        )
        assert asyncio.run(fb_display._refresh_status_line()) is False

    def test_render_base_frame_records_status_text(self, screen):
        fb_display.render_base_frame()
        assert fb_display._status_text_drawn.startswith("192.168.1.50")

    def test_write_status_strip_without_framebuffer(self, screen):
        fb_display._write_status_strip(fb_display.create_background())


class TestAssetCaches:
    def test_background_cached_but_returned_as_copy(self, screen):
        a = fb_display.create_background()
        a.putpixel((0, 0), (255, 0, 255))
        b = fb_display.create_background()
        assert b.getpixel((0, 0)) != (255, 0, 255)
        assert fb_display._bg_cache["img"] is not None

    def test_resized_asset_reused(self, screen):
        logo = Image.new("RGBA", (40, 40), (1, 2, 3, 255))
        r1 = fb_display._resized_asset(("logo", 1), logo, (20, 20))
        r2 = fb_display._resized_asset(("logo", 1), logo, (20, 20))
        assert r1 is r2 and r1.size == (20, 20)
