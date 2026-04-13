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


class TestIdleWave:
    """Test idle animation wave generation."""

    def test_returns_correct_shape(self):
        wave = fb_display.generate_idle_wave()
        assert len(wave) == fb_display.NUM_BANDS

    def test_values_above_display_floor(self):
        wave = fb_display.generate_idle_wave()
        assert all(v >= fb_display.DISPLAY_FLOOR for v in wave)

    def test_values_below_zero(self):
        """Idle wave should be subtle (well below 0 dBFS)."""
        wave = fb_display.generate_idle_wave()
        assert all(v < 0 for v in wave)

    def test_wave_changes_over_time(self):
        """Consecutive calls should produce different values (animation)."""
        w1 = fb_display.generate_idle_wave().copy()
        w2 = fb_display.generate_idle_wave().copy()
        assert not np.array_equal(w1, w2)


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
                (socket.AF_INET, socket.SOCK_DGRAM, 0, "", ("192.168.63.104", 0)),
            ],
        )
        assert fb_display._get_lan_ip() == "192.168.63.104"

    def test_fallback_on_total_failure(self, monkeypatch):
        import socket

        def _raise(*a, **kw):
            raise OSError("no network")

        monkeypatch.setattr(socket, "socket", _raise)
        monkeypatch.setattr(socket, "getaddrinfo", _raise)
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
                return FakeServiceInfo([b"\xc0\xa8\x3f\x68"])  # 192.168.63.104

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
        assert "192.168.63.104" in servers

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
        status = f"192.168.1.1  →  snapvideo{suffix}"
        assert status == "192.168.1.1  →  snapvideo  •  v0.2.4  /  srv 0.3.7"


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
