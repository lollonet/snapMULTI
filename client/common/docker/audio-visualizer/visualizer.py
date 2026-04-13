#!/usr/bin/env python3
"""Real-time octave-band spectrum analyzer.

Reads raw PCM from ALSA loopback capture device, computes FFT, groups into
octave bands, outputs dBFS values via WebSocket.

Output format: "dB_1;dB_2;...;dB_N" per frame.
Values are absolute dBFS (volume-independent with hardware mixer, volume-dependent with software mixer).
Silence = NOISE_FLOOR.
"""

import asyncio
import ctypes
import ctypes.util
import logging
import os
import signal
import sys

import numpy as np
import websockets

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Audio parameters (must match snapclient output)
SAMPLE_RATE = int(os.environ.get("SAMPLE_RATE", "44100"))
CHANNELS = 2
SAMPLE_WIDTH = 2  # 16-bit
FRAME_SIZE = CHANNELS * SAMPLE_WIDTH

# FFT parameters
FFT_SIZE = 8192  # ~186ms window at 44.1kHz — better frequency resolution for low bands (5.4Hz/bin)
HOP_SIZE = 1600  # ~36ms hop ≈ 28 FPS (below 30 FPS target for processing headroom)
TARGET_FPS = 30

# Band mode: "half-octave" (21 bands) or "third-octave" (31 bands)
BAND_MODE = os.environ.get("BAND_MODE", "half-octave")


def generate_band_centers(mode: str) -> list[float]:
    """Generate center frequencies for the given band mode.

    half-octave:  step = 2^(1/2), edges = center / 2^(1/4) to center * 2^(1/4)
                  21 bands from 20 Hz to 20 kHz
    third-octave: step = 2^(1/3), edges = center / 2^(1/6) to center * 2^(1/6)
                  31 bands from 20 Hz to 20 kHz (ISO 266 standard)
    """
    if mode == "third-octave":
        # ISO 266 preferred 1/3-octave centers (20 Hz to 20 kHz)
        return [
            20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160,
            200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600,
            2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000,
        ]
    # Default: half-octave (21 bands, 20 Hz to 20 kHz)
    return [
        20, 28, 40, 57, 80, 113, 160, 226, 320, 453,
        640, 894, 1250, 1768, 2500, 3536, 5000, 7071, 10000, 14142, 20000,
    ]


BAND_CENTERS = generate_band_centers(BAND_MODE)
NUM_BANDS = len(BAND_CENTERS)

# Display range
NOISE_FLOOR = -72.0  # dBFS — below this = silence (16-bit theoretical = -96)
REF_LEVEL = 0.0  # dBFS — top of display

# ALSA loopback capture device
LOOPBACK_DEVICE = os.environ.get("LOOPBACK_DEVICE", "hw:Loopback,1,0")
WS_PORT = int(os.environ.get("VISUALIZER_WS_PORT", "8081"))

# Smoothing: fast attack, slow decay (in dB domain)
ATTACK_COEFF = np.float32(0.3)  # lower = faster attack (0 = instant)
DECAY_COEFF = np.float32(0.9)   # higher = slower decay
_ATTACK_FACTOR = np.float32(1.0) - ATTACK_COEFF  # pre-computed to stay float32
_DECAY_FACTOR = np.float32(1.0) - DECAY_COEFF

clients: set = set()
prev_db: np.ndarray = np.full(NUM_BANDS, NOISE_FLOOR, dtype=np.float32)
audio_ring: np.ndarray = np.zeros(FFT_SIZE, dtype=np.float32)
_ring_pos: int = 0  # circular write position — avoids np.roll copy

# Pre-allocated buffers to avoid per-frame allocation
_cumsum_buf: np.ndarray = np.zeros(FFT_SIZE // 2 + 2, dtype=np.float32)
_ordered_buf: np.ndarray = np.zeros(FFT_SIZE, dtype=np.float32)
_dc_estimate: float = 0.0  # rolling DC offset estimate


def compute_band_bins() -> list[tuple[int, int]]:
    """Compute FFT bin ranges for each band.

    half-octave:  edges = center / 2^(1/4) to center * 2^(1/4)
    third-octave: edges = center / 2^(1/6) to center * 2^(1/6)
    """
    freq_bins = np.fft.rfftfreq(FFT_SIZE, d=1.0 / SAMPLE_RATE)
    if BAND_MODE == "third-octave":
        edge_ratio = 2.0 ** (1.0 / 6.0)  # ≈ 1.1225
    else:
        edge_ratio = 2.0 ** 0.25  # ≈ 1.1892
    edges = []
    for center in BAND_CENTERS:
        lo_freq = center / edge_ratio
        hi_freq = center * edge_ratio
        lo_bin = int(np.searchsorted(freq_bins, lo_freq))
        hi_bin = int(np.searchsorted(freq_bins, hi_freq))
        hi_bin = max(hi_bin, lo_bin + 1)  # at least 1 bin
        edges.append((lo_bin, hi_bin))
    return edges


BAND_BINS = compute_band_bins()
WINDOW = np.hanning(FFT_SIZE).astype(np.float32)
# Window correction factor for power (Hanning window)
WINDOW_POWER_CORR = 1.0 / np.mean(WINDOW ** 2)

# Pre-compute reduceat indices for vectorized band power summation
_BAND_EDGES = np.array([lo for lo, _ in BAND_BINS], dtype=np.intp)
_BAND_HI = np.array([hi for _, hi in BAND_BINS], dtype=np.intp)


def analyze_pcm(new_samples: np.ndarray) -> str | None:
    """Compute octave-band levels in dBFS from PCM samples.

    Uses overlap-add: new_samples are appended to a circular ring buffer,
    and FFT is computed over the full FFT_SIZE window.
    """
    global prev_db, audio_ring, _ring_pos, _dc_estimate

    # Check for silence on NEW samples (not ring buffer — which has old data)
    # Threshold ~-70 dBFS — practical noise floor to skip FFT on near-silence
    rms_new = np.sqrt(np.mean(new_samples ** 2))
    if rms_new < 30.0:
        audio_ring[:] = 0.0
        _ring_pos = 0
        _dc_estimate = 0.0
        prev_db[:] = NOISE_FLOOR
        return _format_db(prev_db)

    # Circular ring buffer — write new samples without copying the whole array
    n = len(new_samples)
    if n >= FFT_SIZE:
        audio_ring[:] = new_samples[-FFT_SIZE:]
        _ring_pos = 0
    else:
        end = _ring_pos + n
        if end <= FFT_SIZE:
            audio_ring[_ring_pos:end] = new_samples
        else:
            split = FFT_SIZE - _ring_pos
            audio_ring[_ring_pos:] = new_samples[:split]
            audio_ring[:n - split] = new_samples[split:]
        _ring_pos = end % FFT_SIZE

    # Get ordered view from circular buffer into pre-allocated buffer
    if _ring_pos == 0:
        ordered = audio_ring
    else:
        _ordered_buf[:FFT_SIZE - _ring_pos] = audio_ring[_ring_pos:]
        _ordered_buf[FFT_SIZE - _ring_pos:] = audio_ring[:_ring_pos]
        ordered = _ordered_buf

    # Normalize to [-1.0, 1.0] (0 dBFS = 32768)
    normalized = ordered / 32768.0

    # Rolling DC offset — avoids full-array np.mean() every frame
    _dc_estimate = _dc_estimate * 0.95 + np.mean(new_samples / 32768.0) * 0.05
    normalized = normalized - _dc_estimate

    # Apply window
    windowed = normalized * WINDOW

    # FFT — power spectrum (V²)
    spectrum = np.abs(np.fft.rfft(windowed)) ** 2

    # Apply window power correction and dBFS scaling in one step
    spectrum *= (WINDOW_POWER_CORR / (FFT_SIZE * FFT_SIZE))

    # Band power summation using pre-allocated cumsum buffer
    spec_len = len(spectrum)
    edges = np.minimum(_BAND_EDGES, spec_len)
    hi = np.minimum(_BAND_HI, spec_len)

    _cumsum_buf[0] = 0.0
    np.cumsum(spectrum, out=_cumsum_buf[1:spec_len + 1])
    band_power = np.maximum(_cumsum_buf[hi] - _cumsum_buf[edges], 0.0)

    # Convert to dBFS (no normalization — bars reflect actual volume)
    with np.errstate(divide="ignore"):
        band_db = np.where(
            band_power > 0,
            np.maximum(10.0 * np.log10(band_power), NOISE_FLOOR),
            NOISE_FLOOR,
        )

    # In-place asymmetric smoothing — avoids intermediate array allocation
    diff = band_db - prev_db
    prev_db += diff * np.where(diff > 0, _ATTACK_FACTOR, _DECAY_FACTOR)

    return _format_db(prev_db)


def _format_db(db_vals: np.ndarray) -> str:
    """Format dBFS values as semicolon-separated string."""
    rounded = np.round(db_vals, 1)
    return ";".join(str(v) for v in rounded)


# Dedup cache: skips sending identical consecutive frames (e.g. silence).
# A late-joining client may miss one frame (~33ms) until data changes.
_last_broadcast: str = ""


async def broadcast(data: str) -> None:
    """Send data to all connected WebSocket clients."""
    global _last_broadcast
    if not clients:
        _last_broadcast = ""
        return
    if data == _last_broadcast:
        return
    _last_broadcast = data
    dead = set()
    for client in clients:
        try:
            await client.send(data)
        except (OSError, RuntimeError, websockets.exceptions.ConnectionClosed) as e:
            logger.debug(f"WebSocket send failed: {e}")
            dead.add(client)
    clients.difference_update(dead)


def open_alsa_capture():
    """Open ALSA loopback capture device for reading raw PCM.

    Uses ctypes to call libasound directly — avoids pyalsaaudio dependency.
    Returns the PCM handle and libasound library reference.
    """
    libasound_path = ctypes.util.find_library("asound")
    if not libasound_path:
        raise RuntimeError("libasound not found — install libasound2")

    libasound = ctypes.CDLL(libasound_path)

    # Set argtypes/restype for snd_pcm_readi to prevent 64-bit truncation on ARM64
    libasound.snd_pcm_readi.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulong]
    libasound.snd_pcm_readi.restype = ctypes.c_long

    # Opaque pointer types
    class snd_pcm_t(ctypes.Structure):
        pass

    class snd_pcm_hw_params_t(ctypes.Structure):
        pass

    pcm_p = ctypes.POINTER(snd_pcm_t)
    hw_p = ctypes.POINTER(snd_pcm_hw_params_t)

    SND_PCM_STREAM_CAPTURE = 1
    # Always use S16_LE — matches loopback format regardless of platform endianness
    SND_PCM_FORMAT_S16_LE = 2
    SND_PCM_ACCESS_RW_INTERLEAVED = 3

    # Open device
    handle = pcm_p()
    device = LOOPBACK_DEVICE.encode()
    rc = libasound.snd_pcm_open(
        ctypes.byref(handle), device, SND_PCM_STREAM_CAPTURE, 0
    )
    if rc < 0:
        raise RuntimeError(
            f"Cannot open ALSA device {LOOPBACK_DEVICE}: error {rc}"
        )

    # Allocate and configure hw_params
    hw_params = hw_p()
    libasound.snd_pcm_hw_params_malloc(ctypes.byref(hw_params))
    libasound.snd_pcm_hw_params_any(handle, hw_params)
    libasound.snd_pcm_hw_params_set_access(
        handle, hw_params, SND_PCM_ACCESS_RW_INTERLEAVED
    )
    libasound.snd_pcm_hw_params_set_format(
        handle, hw_params, SND_PCM_FORMAT_S16_LE
    )

    rate = ctypes.c_uint(SAMPLE_RATE)
    libasound.snd_pcm_hw_params_set_rate_near(
        handle, hw_params, ctypes.byref(rate), None
    )

    libasound.snd_pcm_hw_params_set_channels(handle, hw_params, CHANNELS)

    # Set buffer/period for low latency
    period_size = ctypes.c_ulong(HOP_SIZE)
    rc = libasound.snd_pcm_hw_params_set_period_size_near(
        handle, hw_params, ctypes.byref(period_size), None
    )
    if rc < 0:
        logger.warning(f"Could not set ALSA period size: error {rc}")

    # Explicit buffer size: 4 periods (~133ms) to prevent multi-second backlog
    buffer_size = ctypes.c_ulong(HOP_SIZE * 4)
    rc = libasound.snd_pcm_hw_params_set_buffer_size_near(
        handle, hw_params, ctypes.byref(buffer_size),
    )
    if rc < 0:
        logger.warning(f"Could not set ALSA buffer size: error {rc}")

    rc = libasound.snd_pcm_hw_params(handle, hw_params)
    if rc < 0:
        raise RuntimeError(f"Cannot set ALSA hw params: error {rc}")

    libasound.snd_pcm_hw_params_free(hw_params)
    libasound.snd_pcm_prepare(handle)

    return handle, libasound


def alsa_read_frames(handle, libasound, num_frames: int) -> bytes | None:
    """Read num_frames from ALSA capture handle. Returns raw bytes or None."""
    buf = ctypes.create_string_buffer(num_frames * FRAME_SIZE)
    frames_read = libasound.snd_pcm_readi(handle, buf, num_frames)
    if frames_read < 0:
        # Try to recover from XRUN or other errors
        libasound.snd_pcm_prepare(handle)
        frames_read = libasound.snd_pcm_readi(handle, buf, num_frames)
        if frames_read < 0:
            return None
    return buf.raw[: frames_read * FRAME_SIZE]


async def read_loopback_and_broadcast() -> None:
    """Read raw PCM from ALSA loopback capture, compute spectrum, broadcast."""
    frame_interval = 1.0 / TARGET_FPS
    retry_delay = 2
    max_retry_delay = 60

    while True:
        try:
            logger.info(f"Opening ALSA loopback capture: {LOOPBACK_DEVICE}")
            handle, libasound = open_alsa_capture()
            logger.info("ALSA capture opened, reading audio data...")
            retry_delay = 2  # Reset on successful open

            try:
                while True:
                    start = asyncio.get_event_loop().time()

                    data = await asyncio.get_event_loop().run_in_executor(
                        None, alsa_read_frames, handle, libasound, HOP_SIZE
                    )

                    if not data:
                        logger.warning("ALSA read failed, reopening...")
                        prev_db[:] = NOISE_FLOOR
                        _ring_pos = 0
                        zero_msg = ";".join(
                            str(NOISE_FLOOR) for _ in range(NUM_BANDS)
                        )
                        await broadcast(zero_msg)
                        break

                    # Parse 16-bit stereo PCM, mix to mono
                    # Explicit little-endian: loopback always uses S16_LE
                    samples = np.frombuffer(data, dtype="<i2").astype(
                        np.float32
                    )
                    if CHANNELS == 2 and len(samples) >= 2:
                        mono = (samples[0::2] + samples[1::2]) * 0.5
                    else:
                        mono = samples

                    result = analyze_pcm(mono)
                    if result:
                        await broadcast(result)

                    elapsed = asyncio.get_event_loop().time() - start
                    sleep_time = frame_interval - elapsed
                    if sleep_time > 0:
                        await asyncio.sleep(sleep_time)
            finally:
                libasound.snd_pcm_close(handle)

        except RuntimeError as e:
            # Device open errors - use exponential backoff
            logger.error(f"ALSA device error: {e}, retrying in {retry_delay}s...")
            await asyncio.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, max_retry_delay)
        except Exception as e:
            logger.error(f"Unexpected error: {e}, retrying in {retry_delay}s...")
            await asyncio.sleep(retry_delay)
            retry_delay = min(retry_delay * 2, max_retry_delay)


# Rate limiting: max connections per IP and total
MAX_CLIENTS = 20
MAX_PER_IP = 5
client_ips: dict[str, int] = {}


async def websocket_handler(websocket) -> None:
    """Handle WebSocket connections with rate limiting."""
    client_ip = websocket.remote_address[0] if websocket.remote_address else "unknown"

    # Check total connection limit
    if len(clients) >= MAX_CLIENTS:
        logger.warning(f"Rejected connection from {client_ip}: max clients reached")
        await websocket.close(1013, "Server at capacity")
        return

    # Check per-IP limit
    current_count = client_ips.get(client_ip, 0)
    if current_count >= MAX_PER_IP:
        logger.warning(f"Rejected connection from {client_ip}: per-IP limit reached")
        await websocket.close(1013, "Too many connections from this IP")
        return

    # Accept connection
    clients.add(websocket)
    client_ips[client_ip] = current_count + 1
    logger.info(f"Client connected: {client_ip} ({len(clients)} total)")

    try:
        async for _ in websocket:
            pass
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        clients.discard(websocket)
        client_ips[client_ip] = client_ips.get(client_ip, 1) - 1
        if client_ips.get(client_ip, 0) <= 0:
            client_ips.pop(client_ip, None)
        logger.info(f"Client disconnected: {client_ip} ({len(clients)} remaining)")


async def main() -> None:
    """Start WebSocket server and ALSA loopback reader."""
    logger.info(f"Starting spectrum analyzer on port {WS_PORT}")
    logger.info(f"  ALSA capture: {LOOPBACK_DEVICE}")
    logger.info(f"  FFT size: {FFT_SIZE} ({FFT_SIZE / SAMPLE_RATE * 1000:.0f}ms)")
    logger.info(f"  Bands: {NUM_BANDS} {BAND_MODE} ({BAND_CENTERS[0]}-{BAND_CENTERS[-1]} Hz)")
    logger.info(f"  Range: {NOISE_FLOOR} to {REF_LEVEL} dBFS")
    logger.info(f"  Target FPS: {TARGET_FPS}")

    async with websockets.serve(websocket_handler, "0.0.0.0", WS_PORT):
        await read_loopback_and_broadcast()


def cleanup(signum=None, frame=None):
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        cleanup()
