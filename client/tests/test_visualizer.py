"""Tests for audio-visualizer spectrum analyzer (pure numpy, no hardware)."""

import asyncio
import sys
import os
from unittest.mock import AsyncMock, MagicMock

import numpy as np
import pytest

# Add visualizer to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "common", "docker", "audio-visualizer"))

import visualizer


class TestBandCenters:
    """Test frequency band center generation."""

    def test_half_octave_count(self):
        centers = visualizer.generate_band_centers("half-octave")
        assert len(centers) == 21

    def test_third_octave_count(self):
        centers = visualizer.generate_band_centers("third-octave")
        assert len(centers) == 31

    def test_half_octave_range(self):
        centers = visualizer.generate_band_centers("half-octave")
        assert centers[0] == 20
        assert centers[-1] == 20000

    def test_third_octave_range(self):
        centers = visualizer.generate_band_centers("third-octave")
        assert centers[0] == 20
        assert centers[-1] == 20000

    def test_centers_monotonically_increasing(self):
        for mode in ("half-octave", "third-octave"):
            centers = visualizer.generate_band_centers(mode)
            for i in range(1, len(centers)):
                assert centers[i] > centers[i - 1], f"{mode}: center {i} not increasing"


class TestBandBins:
    """Test FFT bin range computation."""

    def test_bin_count_matches_bands(self):
        bins = visualizer.compute_band_bins()
        assert len(bins) == visualizer.NUM_BANDS

    def test_bins_are_valid_ranges(self):
        bins = visualizer.compute_band_bins()
        for lo, hi in bins:
            assert lo >= 0
            assert hi > lo, f"Empty bin range: ({lo}, {hi})"

    def test_bins_cover_audible_range(self):
        bins = visualizer.compute_band_bins()
        # First band should start near DC
        assert bins[0][0] <= 5
        # Last band should reach near Nyquist
        nyquist_bin = visualizer.FFT_SIZE // 2
        assert bins[-1][1] >= nyquist_bin * 0.8


class TestAnalyzePcm:
    """Test PCM analysis pipeline."""

    def setup_method(self):
        """Reset global state before each test."""
        visualizer.prev_db = np.full(visualizer.NUM_BANDS, visualizer.NOISE_FLOOR, dtype=np.float32)
        visualizer.audio_ring = np.zeros(visualizer.FFT_SIZE, dtype=np.float32)

    def test_silence_returns_noise_floor(self):
        """Pure silence should return noise floor for all bands."""
        silence = np.zeros(visualizer.HOP_SIZE, dtype=np.float32)
        result = visualizer.analyze_pcm(silence)
        values = [float(v) for v in result.split(";")]
        assert len(values) == visualizer.NUM_BANDS
        assert all(v == visualizer.NOISE_FLOOR for v in values)

    def test_output_format(self):
        """Output should be semicolon-separated float values."""
        # Generate a 1kHz sine wave at full scale
        t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
        sine = 30000.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
        result = visualizer.analyze_pcm(sine)
        parts = result.split(";")
        assert len(parts) == visualizer.NUM_BANDS
        for p in parts:
            float(p)  # should not raise

    def test_sine_wave_peaks_at_correct_band(self):
        """A 1kHz sine should produce highest energy near the 1kHz band."""
        # Fill the ring buffer with enough data
        for _ in range(10):
            t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
            sine = 30000.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
            result = visualizer.analyze_pcm(sine)

        values = [float(v) for v in result.split(";")]

        # Find the band closest to 1kHz
        centers = visualizer.BAND_CENTERS
        closest_idx = min(range(len(centers)), key=lambda i: abs(centers[i] - 1000))

        # The peak should be at or very near the 1kHz band
        peak_idx = np.argmax(values)
        assert abs(peak_idx - closest_idx) <= 2, (
            f"Peak at band {peak_idx} ({centers[peak_idx]} Hz), "
            f"expected near band {closest_idx} ({centers[closest_idx]} Hz)"
        )

    def test_full_scale_sine_near_zero_dbfs(self):
        """A full-scale sine should produce values near 0 dBFS in its band."""
        for _ in range(15):
            t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
            sine = 32000.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
            result = visualizer.analyze_pcm(sine)

        values = [float(v) for v in result.split(";")]
        peak_val = max(values)
        # Full-scale sine should be within -15 dBFS (accounting for windowing spread)
        assert peak_val > -15.0, f"Peak {peak_val} dBFS too low for full-scale sine"

    def test_quiet_signal_lower_than_loud(self):
        """A quieter signal should produce lower dBFS values."""
        # Loud sine
        for _ in range(10):
            t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
            loud = 30000.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
            result_loud = visualizer.analyze_pcm(loud)

        loud_peak = max(float(v) for v in result_loud.split(";"))

        # Reset state
        self.setup_method()

        # Quiet sine (20 dB lower)
        for _ in range(10):
            t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
            quiet = 3000.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
            result_quiet = visualizer.analyze_pcm(quiet)

        quiet_peak = max(float(v) for v in result_quiet.split(";"))
        assert quiet_peak < loud_peak, f"Quiet {quiet_peak} not less than loud {loud_peak}"

    def test_values_clamped_to_noise_floor(self):
        """No output value should be below NOISE_FLOOR."""
        t = np.arange(visualizer.HOP_SIZE, dtype=np.float32)
        sine = 100.0 * np.sin(2 * np.pi * 1000 * t / visualizer.SAMPLE_RATE)
        result = visualizer.analyze_pcm(sine)
        values = [float(v) for v in result.split(";")]
        assert all(v >= visualizer.NOISE_FLOOR for v in values)

    def test_dc_removal(self):
        """DC offset should not leak into low-frequency bands."""
        # Signal with large DC offset but no AC content
        for _ in range(10):
            dc_signal = np.full(visualizer.HOP_SIZE, 10000.0, dtype=np.float32)
            # Add tiny noise to avoid silence detection
            dc_signal += np.random.randn(visualizer.HOP_SIZE).astype(np.float32) * 2.0
            result = visualizer.analyze_pcm(dc_signal)

        values = [float(v) for v in result.split(";")]
        # First band (20 Hz) should not be significantly above noise floor
        # because DC is removed before FFT
        assert values[0] < visualizer.NOISE_FLOOR + 20, (
            f"DC leaking into lowest band: {values[0]} dBFS"
        )


class TestSmoothingCoefficients:
    """Test that smoothing coefficients are in valid range."""

    def test_attack_in_range(self):
        assert 0.0 < visualizer.ATTACK_COEFF < 1.0

    def test_decay_in_range(self):
        assert 0.0 < visualizer.DECAY_COEFF < 1.0

    def test_attack_faster_than_decay(self):
        # Attack alpha = 1 - ATTACK_COEFF, decay alpha = 1 - DECAY_COEFF
        # Larger alpha = faster response
        attack_alpha = 1.0 - visualizer.ATTACK_COEFF
        decay_alpha = 1.0 - visualizer.DECAY_COEFF
        assert attack_alpha > decay_alpha, "Attack should be faster than decay"


class TestBroadcast:
    """Test WebSocket broadcast with dedup logic."""

    def setup_method(self):
        """Reset broadcast state before each test."""
        visualizer._last_broadcast = ""
        visualizer.clients = set()

    def test_first_send(self):
        """First broadcast should send to client."""
        client = AsyncMock()
        visualizer.clients.add(client)
        asyncio.run(visualizer.broadcast("data1"))
        client.send.assert_awaited_once_with("data1")

    def test_dedup_skips_same_data(self):
        """Duplicate data should not be sent again."""
        client = AsyncMock()
        visualizer.clients.add(client)
        asyncio.run(visualizer.broadcast("data1"))
        asyncio.run(visualizer.broadcast("data1"))
        client.send.assert_awaited_once_with("data1")

    def test_different_data_sends(self):
        """Different data should be sent."""
        client = AsyncMock()
        visualizer.clients.add(client)
        asyncio.run(visualizer.broadcast("data1"))
        asyncio.run(visualizer.broadcast("data2"))
        assert client.send.await_count == 2

    def test_no_clients_resets_cache(self):
        """Empty client set should reset _last_broadcast."""
        visualizer._last_broadcast = "stale"
        asyncio.run(visualizer.broadcast("data1"))
        assert visualizer._last_broadcast == ""

    def test_reconnect_after_reset_receives_data(self):
        """Client connecting after cache reset should receive current frame."""
        client = AsyncMock()
        visualizer.clients.add(client)
        # Send data, then remove client (simulates disconnect)
        asyncio.run(visualizer.broadcast("data1"))
        visualizer.clients.clear()
        # Trigger reset
        asyncio.run(visualizer.broadcast("data1"))
        assert visualizer._last_broadcast == ""
        # Reconnect — same data should send
        client2 = AsyncMock()
        visualizer.clients.add(client2)
        asyncio.run(visualizer.broadcast("data1"))
        client2.send.assert_awaited_once_with("data1")


class TestConstants:
    """Test that key constants have sensible values."""

    def test_fft_size_power_of_two(self):
        assert visualizer.FFT_SIZE & (visualizer.FFT_SIZE - 1) == 0

    def test_sample_rate(self):
        assert visualizer.SAMPLE_RATE == 44100

    def test_noise_floor_negative(self):
        assert visualizer.NOISE_FLOOR < 0

    def test_window_size_matches_fft(self):
        assert len(visualizer.WINDOW) == visualizer.FFT_SIZE
