#!/usr/bin/env python3
"""Framebuffer display renderer for Raspberry Pi.

Renders album art (left), track info (top-right), and spectrum bars
(bottom-right, 55% height) directly to /dev/fb0.

Performance: static content (art, text) is cached and only redrawn on
metadata change. Spectrum region uses numpy arrays for fast rendering
and a pre-allocated framebuffer write buffer to avoid per-frame allocations.
"""

import asyncio
import colorsys
import io
import json
import logging
import mmap
import os
import signal
import socket
import sys
import threading
import time
from typing import Callable, Optional

import numpy as np
import requests
import websockets
from PIL import Image, ImageDraw, ImageFont

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Display configuration
METADATA_HOST = os.environ.get("METADATA_HOST", "") or "localhost"
METADATA_WS_PORT = int(os.environ.get("METADATA_WS_PORT", "8082"))
METADATA_HTTP_PORT = int(os.environ.get("METADATA_HTTP_PORT", "8083"))
CLIENT_ID = os.environ.get("CLIENT_ID", "")
APP_VERSION = os.environ.get("APP_VERSION", "")
SPECTRUM_WS_PORT = int(os.environ.get("VISUALIZER_WS_PORT", "8081"))
FB_DEVICE = "/dev/fb0"
TARGET_FPS = 20


def _get_lan_ip() -> str:
    """Get LAN IP. Works on offline LANs (no internet required)."""
    # Try default gateway first (works without internet)
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.1)
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
    except OSError:
        pass
    # Fallback: find first non-loopback interface IP
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127."):
                return ip
    except OSError:
        pass
    return "?.?.?.?"


LAN_IP = _get_lan_ip()
server_info: dict = {}

SNAPCAST_MDNS_TYPE = "_snapcast._tcp.local."
DISCOVERY_TIMEOUT = 5.0
MAX_RECONNECT_BEFORE_DISCOVERY = 3


async def discover_snapservers(timeout: float = DISCOVERY_TIMEOUT) -> list[str]:
    """Discover snapcast servers via mDNS. Returns list of IPs."""
    from zeroconf import ServiceBrowser, Zeroconf

    servers: list[str] = []

    class _Listener:
        def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            info = zc.get_service_info(type_, name)
            if info and info.addresses:
                ip = socket.inet_ntoa(info.addresses[0])
                if ip not in servers:
                    servers.append(ip)
                    logger.info(f"mDNS: discovered snapcast server at {ip}")

        def remove_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

        def update_service(self, zc: Zeroconf, type_: str, name: str) -> None:
            pass

    zc = Zeroconf()
    browser = ServiceBrowser(zc, SNAPCAST_MDNS_TYPE, _Listener())
    try:
        await asyncio.sleep(timeout)
    finally:
        browser.cancel()
        zc.close()
    return servers


# Mutable server state (updated on mDNS discovery/failover)
metadata_host: str = METADATA_HOST
snapserver_display: str = METADATA_HOST

# Render resolution: from DISPLAY_RESOLUTION env var if set,
# otherwise auto-detected from framebuffer (capped at 1920x1080).
# Actual FB dimensions stored separately in FB_WIDTH/FB_HEIGHT.
_init_res = os.environ.get("DISPLAY_RESOLUTION") or "1920x1080"
WIDTH, HEIGHT = (int(x) for x in _init_res.split("x"))

# Colors
BG_TOP = (10, 10, 10)
BG_BOTTOM = (22, 33, 62)
TEXT_COLOR = (255, 255, 255)
ARTIST_COLOR = (179, 179, 179)
ALBUM_COLOR = (153, 153, 153)
DETAIL_COLOR = (120, 120, 120)
DIM_COLOR = (85, 85, 85)
PANEL_BG = (17, 17, 17)

# Spectrum state — NUM_BANDS initialized to default, updated when first WS message received
NUM_BANDS = 21  # default (21 for half-octave, 31 for third-octave)
NOISE_FLOOR = -72.0  # dBFS

bands = np.full(NUM_BANDS, NOISE_FLOOR, dtype=np.float64)
display_bands = np.full(NUM_BANDS, NOISE_FLOOR, dtype=np.float64)
peak_bands = np.zeros(NUM_BANDS, dtype=np.float64)
peak_time = np.zeros(NUM_BANDS, dtype=np.float64)

# Lock protecting band arrays against concurrent resize/render access
_band_lock = threading.Lock()


def resize_bands(n: int) -> None:
    """Resize all band arrays and recompute layout when NUM_BANDS changes."""
    global NUM_BANDS, bands, display_bands, peak_bands, peak_time, layout
    with _band_lock:
        if n == NUM_BANDS:
            return
        NUM_BANDS = n
        bands = np.full(n, NOISE_FLOOR, dtype=np.float64)
        display_bands = np.full(n, NOISE_FLOOR, dtype=np.float64)
        peak_bands = np.zeros(n, dtype=np.float64)
        peak_time = np.zeros(n, dtype=np.float64)
        precompute_colors()
        precompute_fb_colors()
        layout = compute_layout()
        _init_spectrum_buffer()
    logger.info(f"Band count changed to {n}")


# Smoothing coefficients
ATTACK_COEFF = 0.7  # fast attack (higher = faster)
DECAY_COEFF = 0.15  # decay speed (higher = faster)
PEAK_HOLD_S = 1.5  # seconds before peak marker vanishes

# Fixed display range for spectrum visualization
# Visualizer outputs absolute dBFS; with hardware mixer, levels are volume-independent.
# 72 dB window covers 16-bit dynamic range from noise floor to 0 dBFS.
DISPLAY_FLOOR = -72.0  # dBFS below which bars show nothing (16-bit noise floor)
DISPLAY_RANGE = 72.0  # maps DISPLAY_FLOOR..0 dBFS to 0..1

# Idle animation state
idle_animation_phase: float = 0.0
IDLE_ANIMATION_SPEED = 0.05  # radians per frame


def generate_idle_wave() -> np.ndarray:
    """Generate a subtle breathing wave pattern for idle state."""
    global idle_animation_phase
    idle_animation_phase += IDLE_ANIMATION_SPEED
    if idle_animation_phase > 2 * np.pi:
        idle_animation_phase -= 2 * np.pi

    # Vectorized wave: phase offset per bar, scaled to low levels
    offsets = idle_animation_phase + np.arange(NUM_BANDS) * 0.3
    wave = np.sin(offsets) * 0.5 + 0.5
    return DISPLAY_FLOOR + 4 + wave * 6


# Metadata state
current_metadata: dict | None = None
metadata_version: int = 0  # bumped on change
cached_artwork: Image.Image | None = None
cached_artwork_url: str = ""

# Playback time tracking (local clock for smooth updates)
_playback_start: float = 0.0  # monotonic time when playback started
_playback_offset: float = 0.0  # initial elapsed position from MPD (seconds)
_is_playing: bool = False
_last_duration: int = 0  # to detect track changes

# Framebuffer
fb_fd = None
fb_mmap = None
fb_stride = 0
fb_bpp = 32
fb_big_endian = sys.byteorder == "big"

# Actual framebuffer dimensions (may differ from render WIDTH/HEIGHT)
FB_WIDTH, FB_HEIGHT = WIDTH, HEIGHT

# Cached frames: base_frame has bg+art+text, spectrum_bg is native FB format
base_frame: Image.Image | None = None
base_frame_version: int = -1
spectrum_bg_np: np.ndarray | None = None  # numpy RGB array for alpha blending
spectrum_bg_fb: np.ndarray | None = None  # native FB format (RGB565 or BGRA32)
_spectrum_work_buf: np.ndarray | None = (
    None  # pre-allocated render buffer (avoids copy per frame)
)

# Cached clock overlay (re-rendered every second)
_clock_cache: dict = {
    "time_str": None,
    "fb": None,
    "width": 0,
    "height": 0,
    "dirty": True,
}

# Cached progress bar overlay (re-rendered every second)
_progress_cache: dict = {
    "elapsed": -1,
    "duration": 0,
    "fb": None,
    "width": 0,
    "height": 0,
    "dirty": True,
}

# Logo and brand text images (loaded once at startup)
_logo_img: Image.Image | None = None
_brand_img: Image.Image | None = None

# Cached fonts (loaded once)
_font_cache: dict[tuple[str, int], ImageFont.FreeTypeFont] = {}
_FONT_CACHE_MAX = 200

# Layout geometry (computed once in compute_layout)
layout: dict = {}


def get_fb_info() -> tuple[int, int, int, int]:
    """Read framebuffer geometry from sysfs."""
    fb_path = "/sys/class/graphics/fb0"
    try:
        with open(f"{fb_path}/virtual_size") as f:
            vw, vh = f.read().strip().split(",")
        with open(f"{fb_path}/bits_per_pixel") as f:
            bpp = int(f.read().strip())
        with open(f"{fb_path}/stride") as f:
            stride = int(f.read().strip())
        return int(vw), int(vh), bpp, stride
    except FileNotFoundError:
        logger.warning(
            "Framebuffer sysfs not found, using defaults %dx%d", WIDTH, HEIGHT
        )
        return WIDTH, HEIGHT, 32, WIDTH * 4


def open_framebuffer() -> None:
    """Open and memory-map the framebuffer device.

    Sets FB_WIDTH/FB_HEIGHT to actual framebuffer dimensions and
    WIDTH/HEIGHT to the (possibly lower) internal render resolution.
    Output is scaled from render to FB resolution when writing.
    """
    global fb_fd, fb_mmap, fb_stride, fb_bpp, WIDTH, HEIGHT, FB_WIDTH, FB_HEIGHT

    fb_w, fb_h, fb_bpp, fb_stride = get_fb_info()
    FB_WIDTH, FB_HEIGHT = fb_w, fb_h

    # Determine render resolution
    display_res = os.environ.get("DISPLAY_RESOLUTION")
    if display_res:
        # Explicit render resolution — use it, capped at actual FB size
        rw, rh = (int(x) for x in display_res.split("x"))
        WIDTH = min(rw, fb_w)
        HEIGHT = min(rh, fb_h)
    else:
        # Auto-detect: use FB native, capped at 1920x1080 for memory safety
        max_w, max_h = 1920, 1080
        if fb_w <= max_w and fb_h <= max_h:
            WIDTH, HEIGHT = fb_w, fb_h
        else:
            scale = min(max_w / fb_w, max_h / fb_h)
            WIDTH = int(fb_w * scale)
            HEIGHT = int(fb_h * scale)

    logger.info(f"Framebuffer: {FB_WIDTH}x{FB_HEIGHT}, {fb_bpp}bpp, stride={fb_stride}")
    if (WIDTH, HEIGHT) != (FB_WIDTH, FB_HEIGHT):
        logger.info(f"Render resolution: {WIDTH}x{HEIGHT} (scaled to FB on output)")

    try:
        fd = os.open(FB_DEVICE, os.O_RDWR)
    except OSError as e:
        logger.critical(f"Cannot open framebuffer {FB_DEVICE}: {e}")
        raise SystemExit(1) from e
    size = fb_stride * fb_h
    try:
        fb_mmap = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
    except Exception:
        os.close(fd)
        raise
    fb_fd = fd


def write_region_to_fb_fast(fb_pixels: np.ndarray, x: int, y: int) -> None:
    """Write a native-format pixel array to the framebuffer at position (x, y).

    Accepts pre-converted pixels: uint16 (h,w) for 16bpp or uint8 (h,w,4) for 32bpp.
    Coordinates are in render space; scaled to FB resolution if needed.
    """
    if fb_mmap is None:
        return

    # Scale from render resolution to FB resolution
    if WIDTH != FB_WIDTH or HEIGHT != FB_HEIGHT:
        fb_pixels = _scale_to_fb(fb_pixels)
        x = round(x * FB_WIDTH / WIDTH)
        y = round(y * FB_HEIGHT / HEIGHT)

    h, w = fb_pixels.shape[:2]
    if x < 0 or y < 0 or x + w > FB_WIDTH or y + h > FB_HEIGHT:
        logger.warning(
            f"Framebuffer write out of bounds: ({x},{y}) {w}x{h} on {FB_WIDTH}x{FB_HEIGHT}"
        )
        return

    bpp_bytes = fb_bpp // 8

    try:
        for row in range(h):
            offset = (y + row) * fb_stride + x * bpp_bytes
            fb_mmap.seek(offset)
            fb_mmap.write(fb_pixels[row].tobytes())
    except (ValueError, OSError) as e:
        logger.error(f"Framebuffer write failed: {e}")


def write_full_frame(img: Image.Image) -> None:
    """Write a full-screen image to the framebuffer, scaling to fit.

    Scales and writes in strips (CHUNK rows at a time) to avoid allocating
    a full FB-sized image in memory (e.g. 24 MB for 4K).
    """
    if fb_mmap is None:
        return

    needs_scale = (img.width, img.height) != (FB_WIDTH, FB_HEIGHT)
    bpp_bytes = fb_bpp // 8
    row_bytes = FB_WIDTH * bpp_bytes
    CHUNK = 64
    try:
        for fb_y0 in range(0, FB_HEIGHT, CHUNK):
            fb_y1 = min(fb_y0 + CHUNK, FB_HEIGHT)

            if needs_scale:
                # Map FB rows back to source image rows
                src_y0 = fb_y0 * img.height // FB_HEIGHT
                src_y1 = max(src_y0 + 1, fb_y1 * img.height // FB_HEIGHT)
                strip = img.crop((0, src_y0, img.width, src_y1))
                strip = strip.resize((FB_WIDTH, fb_y1 - fb_y0), Image.BILINEAR)
            else:
                strip = img.crop((0, fb_y0, FB_WIDTH, fb_y1))

            chunk_rgb = np.array(strip.convert("RGB"))
            chunk_fb = _rgb_to_fb_native(chunk_rgb)
            if fb_stride == row_bytes:
                fb_mmap.seek(fb_y0 * fb_stride)
                fb_mmap.write(chunk_fb.tobytes())
            else:
                for row in range(chunk_fb.shape[0]):
                    fb_mmap.seek((fb_y0 + row) * fb_stride)
                    fb_mmap.write(chunk_fb[row].tobytes())
    except (ValueError, OSError) as e:
        logger.error(f"Framebuffer full-frame write failed: {e}")


def _get_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Load font with caching."""
    key = ("bold" if bold else "regular", size)
    if key in _font_cache:
        return _font_cache[key]

    if len(_font_cache) >= _FONT_CACHE_MAX:
        _font_cache.pop(next(iter(_font_cache)))

    if bold:
        paths = [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
        ]
    else:
        paths = [
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
            "/usr/share/fonts/TTF/DejaVuSans.ttf",
        ]
    for path in paths:
        if os.path.exists(path):
            font = ImageFont.truetype(path, size)
            _font_cache[key] = font
            return font
    font = ImageFont.load_default()
    _font_cache[key] = font
    return font


def lerp_color(c1: tuple, c2: tuple, t: float) -> tuple:
    """Linear interpolation between two RGB colors."""
    return tuple(int(a + (b - a) * t) for a, b in zip(c1, c2))


def rainbow_color(i: int, total: int) -> tuple[int, int, int]:
    """Get rainbow color for bar index (hue 0-300 degrees)."""
    hue = (i / total) * (300 / 360)  # 0 to 300 degrees
    r, g, b = colorsys.hsv_to_rgb(hue, 0.85, 0.85)
    return (int(r * 255), int(g * 255), int(b * 255))


def get_current_elapsed() -> int:
    """Get current elapsed time using local clock for smooth updates."""
    if not _is_playing:
        return int(_playback_offset)
    return int(_playback_offset + (time.monotonic() - _playback_start))


def format_time(seconds: int) -> str:
    """Format seconds as M:SS or H:MM:SS."""
    if seconds < 0:
        seconds = 0
    m, s = divmod(seconds, 60)
    if m >= 60:
        h, m = divmod(m, 60)
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


# Pre-computed rainbow colors
BAR_COLORS: list[tuple[int, int, int]] = []
PEAK_COLORS: list[tuple[int, int, int]] = []


def precompute_colors() -> None:
    """Pre-compute rainbow colors for all bands."""
    global BAR_COLORS, PEAK_COLORS
    BAR_COLORS = [rainbow_color(i, NUM_BANDS) for i in range(NUM_BANDS)]
    PEAK_COLORS = []
    for i in range(NUM_BANDS):
        hue = (i / NUM_BANDS) * (300 / 360)
        r, g, b = colorsys.hsv_to_rgb(hue, 0.95, 0.95)
        PEAK_COLORS.append((int(r * 255), int(g * 255), int(b * 255)))


def create_background() -> Image.Image:
    """Create gradient background image."""
    img = Image.new("RGB", (WIDTH, HEIGHT))
    draw = ImageDraw.Draw(img)
    for y in range(HEIGHT):
        t = y / HEIGHT
        color = lerp_color(BG_TOP, BG_BOTTOM, t)
        draw.line([(0, y), (WIDTH, y)], fill=color)
    return img


def compute_layout() -> dict:
    """Compute all layout geometry once."""
    outer_gap = int(min(WIDTH, HEIGHT) * 0.025)
    container_w = int(WIDTH * 0.92)
    container_h = int(HEIGHT * 0.85)
    start_x = (WIDTH - container_w) // 2
    start_y = (HEIGHT - container_h) // 2

    art_size = min(int(container_w * 0.46), container_h)
    art_x = start_x
    art_y = start_y + (container_h - art_size) // 2

    right_x = art_x + art_size + outer_gap
    right_w = container_w - art_size - outer_gap
    right_y = art_y
    right_h = art_size

    spec_h = int(right_h * 0.55)
    spec_y = right_y + right_h - spec_h
    info_h = right_h - spec_h - outer_gap
    info_y = right_y

    pad = int(right_w * 0.06)
    bar_area_w = right_w - pad * 2
    bar_area_h = spec_h - pad * 2
    bar_gap = max(1, int(bar_area_w * 0.008))
    bar_w = (bar_area_w - bar_gap * (NUM_BANDS - 1)) // NUM_BANDS
    bar_base_y = spec_y + spec_h - pad

    # Bottom bar: between container bottom and screen bottom
    bottom_y = start_y + container_h
    bottom_h = HEIGHT - bottom_y
    bottom_pad = max(2, bottom_h // 16)
    nudge_up = bottom_pad * 4  # shift logo/knob upward

    # Logo: left-aligned, square, enlarged
    logo_size = bottom_h - bottom_pad * 2
    logo_x = start_x
    logo_y = bottom_y + (bottom_h - logo_size) // 2 - nudge_up

    # Volume knob: right-aligned, enlarged
    vol_radius = max(16, (bottom_h - bottom_pad * 2) // 2)
    vol_x = start_x + container_w - vol_radius * 2 - bottom_pad
    vol_y = bottom_y + (bottom_h - vol_radius * 2) // 2 - nudge_up

    # Clock+date: centered in bottom bar
    clock_h = max(20, bottom_h - bottom_pad * 2)
    clock_y = bottom_y + bottom_pad

    # Status line (LAN IP → server): below clock
    status_y = clock_y + max(10, clock_h // 2) + 4

    return {
        "start_x": start_x,
        "container_w": container_w,
        "art_x": art_x,
        "art_y": art_y,
        "art_size": art_size,
        "right_x": right_x,
        "right_w": right_w,
        "right_y": right_y,
        "right_h": right_h,
        "spec_y": spec_y,
        "spec_h": spec_h,
        "info_y": info_y,
        "info_h": info_h,
        "outer_gap": outer_gap,
        "pad": pad,
        "bar_area_w": bar_area_w,
        "bar_area_h": bar_area_h,
        "bar_gap": bar_gap,
        "bar_w": bar_w,
        "bar_base_y": bar_base_y,
        "clock_y": clock_y,
        "clock_h": clock_h,
        "status_y": status_y,
        "bottom_y": bottom_y,
        "bottom_h": bottom_h,
        "bottom_pad": bottom_pad,
        "logo_size": logo_size,
        "logo_x": logo_x,
        "logo_y": logo_y,
        "vol_radius": vol_radius,
        "vol_x": vol_x,
        "vol_y": vol_y,
    }


def _rgb_to_fb_native(rgb_array: np.ndarray) -> np.ndarray:
    """Convert RGB numpy array to native FB pixel format array.

    Returns uint16 (h,w) for 16bpp or uint8 (h,w,4) for 32bpp.
    """
    if fb_bpp == 16:
        return (
            (rgb_array[:, :, 0].astype(np.uint16) & 0xF8) << 8
            | (rgb_array[:, :, 1].astype(np.uint16) & 0xFC) << 3
            | rgb_array[:, :, 2].astype(np.uint16) >> 3
        )
    else:
        h, w = rgb_array.shape[:2]
        out = np.empty((h, w, 4), dtype=np.uint8)
        if fb_big_endian:
            # Big-endian: bytes in memory [X][R][G][B] (XRGB)
            out[:, :, 0] = 255
            out[:, :, 1] = rgb_array[:, :, 0]
            out[:, :, 2] = rgb_array[:, :, 1]
            out[:, :, 3] = rgb_array[:, :, 2]
        else:
            # Little-endian: bytes in memory [B][G][R][X] (BGRA)
            out[:, :, 0] = rgb_array[:, :, 2]
            out[:, :, 1] = rgb_array[:, :, 1]
            out[:, :, 2] = rgb_array[:, :, 0]
            out[:, :, 3] = 255
        return out


_scale_idx_cache: dict[tuple, tuple] = {}


def _scale_to_fb(pixels: np.ndarray) -> np.ndarray:
    """Scale native-format pixel array from render to FB resolution.

    Uses nearest-neighbor interpolation via numpy fancy indexing.
    Works for both 2D (uint16, 16bpp) and 3D (uint8 h×w×4, 32bpp) arrays.
    Caches index arrays for repeated same-size calls.
    """
    if WIDTH == FB_WIDTH and HEIGHT == FB_HEIGHT:
        return pixels
    h, w = pixels.shape[:2]
    new_w = round(w * FB_WIDTH / WIDTH)
    new_h = round(h * FB_HEIGHT / HEIGHT)
    if new_w == w and new_h == h:
        return pixels
    key = (h, w, new_h, new_w)
    if key not in _scale_idx_cache:
        row_idx = (np.arange(new_h) * h / new_h).astype(int)
        col_idx = (np.arange(new_w) * w / new_w).astype(int)
        _scale_idx_cache[key] = (row_idx, col_idx)
    row_idx, col_idx = _scale_idx_cache[key]
    return pixels[row_idx[:, None], col_idx[None, :]]


def _rgb_tuple_to_fb(r: int, g: int, b: int) -> int | tuple:
    """Convert a single RGB tuple to native FB pixel value."""
    if fb_bpp == 16:
        return int(((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3))
    return (255, r, g, b) if fb_big_endian else (b, g, r, 255)


# Pre-computed bar/peak colors in native FB format (populated after FB init)
BAR_COLORS_FB: list = []
PEAK_COLORS_FB: list = []


def precompute_fb_colors() -> None:
    """Pre-compute bar/peak colors in native FB pixel format."""
    global BAR_COLORS_FB, PEAK_COLORS_FB
    BAR_COLORS_FB = [_rgb_tuple_to_fb(*c) for c in BAR_COLORS]
    PEAK_COLORS_FB = [_rgb_tuple_to_fb(*c) for c in PEAK_COLORS]


def _init_spectrum_buffer() -> None:
    """Initialize pre-allocated spectrum numpy buffer after layout is known."""
    global spectrum_bg_np, spectrum_bg_fb
    L = layout
    if not L:
        return
    spectrum_bg_np = None  # will be set from base frame
    spectrum_bg_fb = None  # will be set from base frame


def fit_font(
    text: str, max_width: int, base_size: int, bold: bool = False
) -> ImageFont.FreeTypeFont:
    """Return the largest font size (down to 10px) that fits text within max_width."""
    for size in range(base_size, 9, -1):
        font = _get_font(size, bold)
        bbox = font.getbbox(text)
        if (bbox[2] - bbox[0]) <= max_width:
            return font
    return _get_font(10, bold)


def _format_audio_badge(meta: dict) -> str:
    """Build audio format badge text from metadata."""
    codec = meta.get("codec", "")
    if not codec:
        return ""

    sample_rate = meta.get("sample_rate", 0)
    bit_depth = meta.get("bit_depth", 0)
    bitrate = meta.get("bitrate", 0)

    # Lossless codecs: show sample rate and bit depth
    lossless = codec in ("FLAC", "WAV", "AIFF", "APE", "WV", "PCM", "DSD")

    parts = [codec]
    if lossless and sample_rate:
        if sample_rate >= 1000:
            parts.append(
                f"{sample_rate / 1000:.0f}kHz"
                if sample_rate % 1000 == 0
                else f"{sample_rate / 1000:.1f}kHz"
            )
        else:
            parts.append(f"{sample_rate}Hz")
        if bit_depth:
            parts.append(f"{bit_depth}bit")
    elif bitrate:
        parts.append(f"{bitrate}kbps")
    elif sample_rate:
        if sample_rate >= 1000:
            parts.append(
                f"{sample_rate / 1000:.0f}kHz"
                if sample_rate % 1000 == 0
                else f"{sample_rate / 1000:.1f}kHz"
            )

    return " ".join(parts)


# Badge colors by quality tier
_BADGE_COLOR_LOSSLESS = (100, 200, 120)  # green — lossless
_BADGE_COLOR_HD = (120, 160, 255)  # blue — hi-res
_BADGE_COLOR_LOSSY = (170, 140, 100)  # amber — lossy


def _format_badge_color(meta: dict) -> tuple[int, int, int]:
    """Pick badge color based on codec quality tier."""
    codec = meta.get("codec", "")
    sample_rate = meta.get("sample_rate", 0)
    lossless = codec in ("FLAC", "WAV", "AIFF", "APE", "WV", "PCM", "DSD")

    if lossless and sample_rate > 48000:
        return _BADGE_COLOR_HD  # hi-res
    if lossless:
        return _BADGE_COLOR_LOSSLESS
    return _BADGE_COLOR_LOSSY


def _display_release_year(meta: dict) -> str:
    """Return the preferred release year for display.

    Prefer the first/original release date when the metadata service provides it;
    otherwise fall back to the edition-specific `date` field.
    """
    for key in (
        "original_date",
        "original_release_date",
        "first_release_date",
        "release_group_first_date",
        "date",
    ):
        value = str(meta.get(key, "") or "").strip()
        if len(value) >= 4 and value[:4].isdigit():
            return value[:4]
    return ""


def fetch_artwork(url: str) -> Image.Image | None:
    """Fetch and cache artwork image."""
    global cached_artwork, cached_artwork_url
    if url == cached_artwork_url and cached_artwork is not None:
        return cached_artwork
    try:
        full_url = url
        if url.startswith("/"):
            full_url = f"http://{metadata_host}:{METADATA_HTTP_PORT}{url}"
        resp = requests.get(full_url, timeout=3)
        if resp.status_code == 200:
            cached_artwork = Image.open(io.BytesIO(resp.content))
            cached_artwork_url = url
            return cached_artwork
        elif resp.status_code != 404:
            logger.debug(f"Artwork fetch returned {resp.status_code}: {url}")
    except requests.exceptions.RequestException as e:
        logger.debug(f"Artwork fetch failed: {e}")
    except Exception as e:
        logger.warning(f"Unexpected error fetching artwork: {e}")
    return None


def render_base_frame() -> Image.Image:
    """Render static content: background, album art, track info.

    Called only when metadata changes.
    """
    bg = create_background()
    draw = ImageDraw.Draw(bg)
    L = layout
    max_text_w = L["right_w"]
    base_title_size = max(16, HEIGHT // 18)
    base_detail_size = max(12, HEIGHT // 24)

    # Left panel: album art
    draw.rounded_rectangle(
        [
            L["art_x"],
            L["art_y"],
            L["art_x"] + L["art_size"],
            L["art_y"] + L["art_size"],
        ],
        radius=8,
        fill=PANEL_BG,
    )

    meta = current_metadata
    is_playing = meta and meta.get("playing")

    if is_playing:
        artwork_url = meta.get("artwork") or meta.get("artist_image") or ""
        if artwork_url:
            art_img = fetch_artwork(artwork_url)
            if art_img:
                resized = art_img.resize((L["art_size"], L["art_size"]), Image.LANCZOS)
                bg.paste(resized, (L["art_x"], L["art_y"]))
    else:
        # Standby mode: show standby artwork
        standby_path = "/app/public/standby.png"
        if os.path.exists(standby_path):
            try:
                standby_img = Image.open(standby_path)
                resized = standby_img.resize(
                    (L["art_size"], L["art_size"]), Image.LANCZOS
                )
                bg.paste(resized, (L["art_x"], L["art_y"]))
            except Exception as e:
                logger.info(f"Failed to load standby image: {e}")

    # Right top: track info (right-aligned, font shrinks to fit)
    text_right = L["right_x"] + L["right_w"]
    if is_playing:
        title = meta.get("title", "")
        artist = meta.get("artist", "")
        album = meta.get("album", "")

        ft_title = (
            fit_font(title, max_text_w, base_title_size, bold=True) if title else None
        )
        ft_artist = fit_font(artist, max_text_w, base_detail_size) if artist else None
        ft_album = fit_font(album, max_text_w, base_detail_size) if album else None

        # Source label (e.g. "Tidal", "MPD", "Spotify")
        source_name = meta.get("source", "")
        source_size = max(14, HEIGHT // 27)

        # Album detail line: "1978 · Reggae · Track 1 · Disc 2"
        detail_parts: list[str] = []
        release_year = _display_release_year(meta)
        if release_year:
            detail_parts.append(release_year)
        if meta.get("genre"):
            detail_parts.append(meta["genre"])
        if meta.get("track"):
            detail_parts.append(f"Track {meta['track']}")
        if meta.get("disc"):
            detail_parts.append(f"Disc {meta['disc']}")
        detail_text = " · ".join(detail_parts)
        detail_size = max(10, HEIGHT // 36)

        # Audio format badge
        fmt_text = _format_audio_badge(meta) if meta else ""
        badge_size = max(10, HEIGHT // 36)

        line_gap = 4
        total_h = 0
        if source_name:
            total_h += source_size + line_gap
        if ft_title:
            total_h += ft_title.size
        if ft_artist:
            total_h += ft_artist.size + line_gap
        if ft_album:
            total_h += ft_album.size + line_gap // 2
        if detail_text:
            total_h += detail_size + line_gap // 2
        if fmt_text:
            total_h += badge_size + line_gap

        text_y = L["info_y"] + (L["info_h"] - total_h) // 2

        if source_name:
            ft_source = fit_font(source_name, max_text_w, source_size)
            bbox = draw.textbbox((0, 0), source_name, font=ft_source)
            tw = bbox[2] - bbox[0]
            draw.text(
                (text_right - tw, text_y), source_name, fill=DIM_COLOR, font=ft_source
            )
            text_y += source_size + line_gap

        if ft_title:
            bbox = draw.textbbox((0, 0), title, font=ft_title)
            tw = bbox[2] - bbox[0]
            draw.text((text_right - tw, text_y), title, fill=TEXT_COLOR, font=ft_title)
            text_y += ft_title.size + line_gap

        if ft_artist:
            bbox = draw.textbbox((0, 0), artist, font=ft_artist)
            tw = bbox[2] - bbox[0]
            draw.text(
                (text_right - tw, text_y), artist, fill=ARTIST_COLOR, font=ft_artist
            )
            text_y += ft_artist.size + line_gap // 2

        if ft_album:
            bbox = draw.textbbox((0, 0), album, font=ft_album)
            tw = bbox[2] - bbox[0]
            draw.text((text_right - tw, text_y), album, fill=ALBUM_COLOR, font=ft_album)
            text_y += ft_album.size + line_gap // 2

        # Album details (year, genre, track, disc)
        if detail_text:
            ft_detail = fit_font(detail_text, max_text_w, detail_size)
            bbox = draw.textbbox((0, 0), detail_text, font=ft_detail)
            tw = bbox[2] - bbox[0]
            draw.text(
                (text_right - tw, text_y),
                detail_text,
                fill=DETAIL_COLOR,
                font=ft_detail,
            )
            text_y += detail_size + line_gap // 2

        # Audio format badge (e.g. "FLAC 48kHz/16bit" or "MP3 320kbps")
        if fmt_text:
            ft_badge = _get_font(badge_size)
            bbox = draw.textbbox((0, 0), fmt_text, font=ft_badge)
            tw = bbox[2] - bbox[0]
            draw.text(
                (text_right - tw, text_y),
                fmt_text,
                fill=_format_badge_color(meta),
                font=ft_badge,
            )
    else:
        # Standby mode: show reassuring status
        hostname = os.environ.get("HOSTNAME", os.environ.get("CLIENT_ID", "snapclient"))

        # Line 1: Ready status
        msg1 = "Ready to Play"
        ft1 = _get_font(base_title_size, bold=True)

        # Line 2: Hostname/client ID
        msg2 = f"▸ {hostname}"
        ft2 = _get_font(base_detail_size)

        # Line 3: Connection status
        msg3 = "Waiting for audio..."
        ft3 = _get_font(max(10, base_detail_size - 4))

        # Calculate total height
        line_gap = 8
        total_h = ft1.size + ft2.size + ft3.size + line_gap * 2
        text_y = L["info_y"] + (L["info_h"] - total_h) // 2

        # Draw lines (right-aligned)
        bbox = draw.textbbox((0, 0), msg1, font=ft1)
        tw = bbox[2] - bbox[0]
        draw.text((text_right - tw, text_y), msg1, fill=(100, 180, 120), font=ft1)
        text_y += ft1.size + line_gap

        bbox = draw.textbbox((0, 0), msg2, font=ft2)
        tw = bbox[2] - bbox[0]
        draw.text((text_right - tw, text_y), msg2, fill=ARTIST_COLOR, font=ft2)
        text_y += ft2.size + line_gap

        bbox = draw.textbbox((0, 0), msg3, font=ft3)
        tw = bbox[2] - bbox[0]
        draw.text((text_right - tw, text_y), msg3, fill=DIM_COLOR, font=ft3)

    # Spectrum panel background (will be overwritten each frame)
    draw.rounded_rectangle(
        [
            L["right_x"],
            L["spec_y"],
            L["right_x"] + L["right_w"],
            L["spec_y"] + L["spec_h"],
        ],
        radius=6,
        fill=(10, 10, 15),
    )

    # Bottom bar: logo (left) + SnapForge brand image
    if _logo_img is not None:
        logo_resized = _logo_img.resize((L["logo_size"], L["logo_size"]), Image.LANCZOS)
        bg.paste(logo_resized, (L["logo_x"], L["logo_y"]), logo_resized)

        # Brand text image next to logo
        if _brand_img is not None:
            # Scale brand image to match logo height
            brand_h = L["logo_size"]
            brand_w = int(_brand_img.width * brand_h / _brand_img.height)
            brand_resized = _brand_img.resize((brand_w, brand_h), Image.LANCZOS)
            brand_x = L["logo_x"] + L["logo_size"] + 8
            brand_y = L["logo_y"]
            bg.paste(brand_resized, (brand_x, brand_y), brand_resized)

    # Bottom bar: status line (LAN IP → server  client_ver  /  server_ver)
    # APP_VERSION already carries its own "v" prefix (from git describe, e.g. "v0.2.4").
    # srv_ver is prefixed inline as "srv X.Y.Z" — asymmetry is intentional.
    srv_ver = server_info.get("server_version", "")
    ver_parts = []
    if APP_VERSION:
        ver_parts.append(APP_VERSION)
    if srv_ver and srv_ver != "unknown":
        ver_parts.append(f"srv {srv_ver}")
    ver_suffix = "  •  " + "  /  ".join(ver_parts) if ver_parts else ""
    status_text = f"{LAN_IP}  →  {snapserver_display}{ver_suffix}"
    status_font_size = max(10, L["clock_h"] // 3)
    status_font = _get_font(status_font_size)
    bbox = draw.textbbox((0, 0), status_text, font=status_font)
    status_w = bbox[2] - bbox[0]
    status_x = (WIDTH - status_w) // 2
    draw.text((status_x, L["status_y"]), status_text, fill=DIM_COLOR, font=status_font)

    # Bottom bar: volume knob (right) — reuses `meta` from above
    vol = meta.get("volume") if meta else None
    muted = meta.get("muted", False) if meta else False
    if vol is not None:
        vol = max(0, min(100, vol))
        knob_img = _render_volume_knob(vol, muted)
        bg.paste(knob_img, (L["vol_x"], L["vol_y"]), knob_img)

    return bg


def extract_spectrum_bg() -> None:
    """Extract the spectrum region from base frame in both RGB and native FB format."""
    global spectrum_bg_np, spectrum_bg_fb
    L = layout
    region = base_frame.crop(
        (
            L["right_x"],
            L["spec_y"],
            L["right_x"] + L["right_w"],
            L["spec_y"] + L["spec_h"],
        )
    )
    spectrum_bg_np = np.array(region.convert("RGB"), dtype=np.uint8)
    spectrum_bg_fb = _rgb_to_fb_native(spectrum_bg_np)


def _render_volume_knob(vol: int, muted: bool) -> Image.Image:
    """Render the volume knob as an RGBA image for the bottom bar."""
    L = layout
    radius = L["vol_radius"]
    size = radius * 2 + 4
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = size // 2, size // 2
    ring_w = max(2, radius // 5)

    # Background ring (dark)
    draw.ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        outline=(50, 50, 50),
        width=ring_w,
    )

    # Filled arc proportional to volume
    if not muted and vol > 0:
        sweep = vol / 100.0 * 360
        draw.arc(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            start=135,
            end=135 + sweep,
            fill=ARTIST_COLOR,
            width=ring_w,
        )

    # Volume text centered inside (smaller font)
    vol_text = "M" if muted else str(vol)
    vol_font = _get_font(max(8, int(radius * 0.7)))
    bbox = draw.textbbox((0, 0), vol_text, font=vol_font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    draw.text(
        (cx - tw // 2, cy - th // 2 - bbox[1]),
        vol_text,
        fill=ARTIST_COLOR if not muted else (200, 60, 60),
        font=vol_font,
    )
    return img


def render_clock() -> tuple[np.ndarray, int, int] | None:
    """Render small date+time text. Returns (fb_pixels, width, height)."""
    L = layout
    if not L:
        return None

    date_str = time.strftime("%a %d %b")
    time_str = time.strftime("%H:%M:%S")
    display_str = f"{date_str}  {time_str}"

    # Check cache (changes every second)
    if display_str == _clock_cache["time_str"] and _clock_cache["fb"] is not None:
        _clock_cache["dirty"] = False
        return _clock_cache["fb"], _clock_cache["width"], _clock_cache["height"]

    # Small font — roughly half the bottom bar height
    clock_font_size = max(10, L["clock_h"] // 2)
    font = _get_font(clock_font_size)

    bbox = font.getbbox(display_str)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]

    pad_x, pad_y = 4, 2
    img_w = text_w + pad_x * 2
    img_h = text_h + pad_y * 2

    img = Image.new("RGB", (img_w, img_h), BG_TOP)
    draw = ImageDraw.Draw(img)

    text_x = pad_x
    text_y = pad_y - bbox[1]
    draw.text((text_x, text_y), display_str, fill=(140, 150, 160), font=font)

    fb_pixels = _rgb_to_fb_native(np.array(img))

    _clock_cache["time_str"] = display_str
    _clock_cache["fb"] = fb_pixels
    _clock_cache["width"] = img_w
    _clock_cache["height"] = img_h
    _clock_cache["dirty"] = True

    return fb_pixels, img_w, img_h


def render_progress_overlay() -> tuple[np.ndarray, int, int, int, int] | None:
    """Render progress bar overlay. Returns (fb_pixels, width, height, x, y) or None."""
    L = layout
    if not L or not current_metadata:
        return None

    duration = current_metadata.get("duration", 0)
    if duration <= 0:
        return None

    elapsed = min(get_current_elapsed(), duration)

    # Check cache (updates every second)
    if (
        elapsed == _progress_cache["elapsed"]
        and duration == _progress_cache["duration"]
        and _progress_cache["fb"] is not None
    ):
        _progress_cache["dirty"] = False
        return (
            _progress_cache["fb"],
            _progress_cache["width"],
            _progress_cache["height"],
            _progress_cache["x"],
            _progress_cache["y"],
        )

    progress = min(elapsed / duration, 1.0)

    # Proportional sizing (larger for visibility)
    time_font_size = max(16, HEIGHT // 32)
    bar_height = max(8, HEIGHT // 90)
    time_font = _get_font(time_font_size)

    # Format times
    elapsed_text = format_time(elapsed)
    duration_text = format_time(duration)

    # Measure text
    def get_text_width(text: str) -> int:
        bbox = time_font.getbbox(text)
        return bbox[2] - bbox[0]

    elapsed_w = get_text_width(elapsed_text)
    duration_w = get_text_width(duration_text)
    text_h = time_font.getbbox(elapsed_text)[3] - time_font.getbbox(elapsed_text)[1]

    # Layout calculations (span full container width at bottom)
    max_width = L["container_w"]
    bar_margin = 16
    total_bar_width = max_width - 8
    bar_width = total_bar_width - elapsed_w - duration_w - (bar_margin * 2)

    if bar_width < 40:
        return None

    # Image dimensions with padding
    img_w = total_bar_width + 8
    img_h = text_h + 12

    # Create image
    img = Image.new("RGB", (img_w, img_h), BG_BOTTOM)  # Match bottom bar bg
    draw = ImageDraw.Draw(img)

    # Positions relative to image
    pad = 2
    bar_x = pad + elapsed_w + bar_margin
    bar_y = (img_h - bar_height) // 2

    # Colors
    text_dim = (130, 130, 135)
    bar_bg = (50, 50, 55)
    bar_fg = (90, 160, 230)

    # Draw elapsed time (left)
    draw.text((pad, pad), elapsed_text, fill=text_dim, font=time_font)

    # Draw duration (right)
    draw.text(
        (img_w - duration_w - pad, pad), duration_text, fill=text_dim, font=time_font
    )

    # Draw bar background (rounded corners proportional to height)
    bar_radius = max(3, bar_height // 2)
    draw.rounded_rectangle(
        [bar_x, bar_y, bar_x + bar_width, bar_y + bar_height],
        radius=bar_radius,
        fill=bar_bg,
    )

    # Draw progress fill
    fill_width = int(bar_width * progress)
    if fill_width > bar_radius * 2:
        draw.rounded_rectangle(
            [bar_x, bar_y, bar_x + fill_width, bar_y + bar_height],
            radius=bar_radius,
            fill=bar_fg,
        )

    # Convert to native FB format
    rgb = np.array(img)
    fb_pixels = _rgb_to_fb_native(rgb)

    # Calculate position: centered, just above bottom bar (above clock)
    overlay_x = L["start_x"] + (L["container_w"] - img_w) // 2
    overlay_y = L["bottom_y"] - img_h - 20

    # Update cache
    _progress_cache.update(
        {
            "elapsed": elapsed,
            "duration": duration,
            "fb": fb_pixels,
            "width": img_w,
            "height": img_h,
            "x": overlay_x,
            "y": overlay_y,
            "dirty": True,
        }
    )

    return fb_pixels, img_w, img_h, overlay_x, overlay_y


def render_spectrum() -> np.ndarray:
    """Render spectrum bars in native FB format (RGB565 or BGRA32).

    Works directly in framebuffer pixel format to avoid per-frame RGB→RGB565
    conversion overhead.
    """
    global display_bands, peak_bands, peak_time

    with _band_lock:
        return _render_spectrum_locked()


def _render_spectrum_locked() -> np.ndarray:
    """Inner render, called with _band_lock held."""
    global display_bands, peak_bands, peak_time, _spectrum_work_buf

    L = layout
    now = time.monotonic()

    # Restore spectrum background into pre-allocated buffer (avoids .copy() allocation)
    if _spectrum_work_buf is None or _spectrum_work_buf.shape != spectrum_bg_fb.shape:
        _spectrum_work_buf = spectrum_bg_fb.copy()
    else:
        _spectrum_work_buf[:] = spectrum_bg_fb
    buf = _spectrum_work_buf

    pad = L["pad"]
    bar_area_h = L["bar_area_h"]
    bar_gap = L["bar_gap"]
    bar_w = L["bar_w"]
    bar_base_y = L["spec_h"] - pad  # relative to region

    # Vectorized asymmetric smoothing
    attack_mask = bands > display_bands
    alpha = np.where(attack_mask, ATTACK_COEFF, DECAY_COEFF)
    display_bands += (bands - display_bands) * alpha

    # Map dBFS to 0..1 using fixed display range
    db_vals = np.maximum(display_bands, DISPLAY_FLOOR)
    fractions = np.clip((db_vals - DISPLAY_FLOOR) / DISPLAY_RANGE, 0.0, 1.0)

    # Peak hold — vectorized
    new_peak_mask = fractions >= peak_bands
    peak_bands[new_peak_mask] = fractions[new_peak_mask]
    peak_time[new_peak_mask] = now
    expired_mask = (~new_peak_mask) & ((now - peak_time) > PEAK_HOLD_S)
    peak_bands[expired_mask] = 0

    marker_h = max(2, bar_w // 12)

    # Draw bars (this loop is necessary for array slice writes but body is minimal)
    for i in range(NUM_BANDS):
        fraction = fractions[i]
        bx = pad + i * (bar_w + bar_gap)

        if fraction < 0.01 and peak_bands[i] < 0.01:
            continue

        if fraction >= 0.01:
            bar_h = max(2, int(fraction * bar_area_h))
            by = max(0, bar_base_y - bar_h)
            if fb_bpp == 16:
                buf[by:bar_base_y, bx : bx + bar_w] = BAR_COLORS_FB[i]
            else:
                buf[by:bar_base_y, bx : bx + bar_w, :] = BAR_COLORS_FB[i]

        if peak_bands[i] > 0.01:
            peak_h = int(peak_bands[i] * bar_area_h)
            peak_y = max(0, bar_base_y - peak_h)
            if fb_bpp == 16:
                buf[peak_y : peak_y + marker_h, bx : bx + bar_w] = PEAK_COLORS_FB[i]
            else:
                buf[peak_y : peak_y + marker_h, bx : bx + bar_w, :] = PEAK_COLORS_FB[i]

    return buf


async def websocket_client_loop(
    url: str,
    name: str,
    message_handler: Callable,
    error_handler: Optional[Callable] = None,
    on_connect: Optional[Callable] = None,
) -> None:
    """Generic WebSocket client with reconnection.

    Args:
        url: WebSocket URL to connect to
        name: Client name for logging (e.g., "spectrum", "metadata")
        message_handler: Async function called for each message
        error_handler: Optional async function called on error (before reconnect)
        on_connect: Optional async function called after connection (e.g., subscribe)
    """
    while True:
        try:
            async with websockets.connect(url) as ws:
                logger.info(f"Connected to {name} WebSocket: {url}")
                if on_connect:
                    await on_connect(ws)
                async for message in ws:
                    await message_handler(message)
        except Exception as e:
            logger.debug(f"{name} WS error: {e}")
            if error_handler:
                await error_handler(e)
            await asyncio.sleep(5)


async def _handle_spectrum_message(message: str) -> None:
    """Process spectrum WebSocket message."""
    values = message.split(";")
    new_num_bands = len(values)
    resize_bands(new_num_bands)

    # Parse new values safely
    new_vals = np.full(new_num_bands, NOISE_FLOOR, dtype=np.float64)
    for i in range(new_num_bands):
        try:
            v = float(values[i])
            new_vals[i] = v if not np.isnan(v) else NOISE_FLOOR
        except (ValueError, IndexError):
            pass

    # Thread-safe assignment using current NUM_BANDS
    with _band_lock:
        if len(new_vals) == NUM_BANDS:
            bands[:] = new_vals


async def _handle_spectrum_error(error: Exception) -> None:
    """Handle spectrum WebSocket error."""
    with _band_lock:
        bands[:] = NOISE_FLOOR


async def spectrum_ws_reader() -> None:
    """Connect to spectrum WebSocket and update band dBFS values."""
    ws_url = f"ws://localhost:{SPECTRUM_WS_PORT}"
    await websocket_client_loop(
        ws_url, "spectrum", _handle_spectrum_message, _handle_spectrum_error
    )


async def _handle_metadata_message(message: str) -> None:
    """Process metadata WebSocket message."""
    global current_metadata, metadata_version
    global _playback_start, _playback_offset, _is_playing, _last_duration
    global server_info

    try:
        data = json.loads(message)

        # Server info broadcast — only redraw if content actually changed
        if data.get("type") == "server_info":
            if data != server_info:
                server_info = data
                metadata_version += 1
            return

        # Sync playback clock for progress bar
        new_elapsed = data.get("elapsed", 0)
        new_duration = data.get("duration", 0)
        new_playing = data.get("playing", False)

        # Resync clock if: track changed, significant seek, or state changed
        local_elapsed = get_current_elapsed()
        track_changed = new_duration != _last_duration and new_duration > 0
        significant_seek = abs(new_elapsed - local_elapsed) > 3
        state_changed = new_playing != _is_playing

        if track_changed or significant_seek or state_changed:
            _playback_offset = new_elapsed
            _playback_start = time.monotonic()
            _last_duration = new_duration
            _is_playing = new_playing
            if track_changed:
                logger.debug(f"Clock sync: new track ({new_duration}s)")
            elif significant_seek:
                logger.debug(f"Clock sync: seek to {new_elapsed}s")

        # Ignore volatile fields for change detection (must match metadata-service)
        _VOLATILE = {"bitrate", "artwork", "artist_image", "elapsed", "duration"}
        old_stable = {
            k: v for k, v in (current_metadata or {}).items() if k not in _VOLATILE
        }
        new_stable = {k: v for k, v in data.items() if k not in _VOLATILE}

        # Artwork changes need a base frame redraw even though they're volatile
        # on the server (artwork URL may arrive after title change)
        old_art = (current_metadata or {}).get("artwork", "")
        new_art = data.get("artwork", "")
        artwork_changed = old_art != new_art and new_art

        if new_stable != old_stable or artwork_changed:
            current_metadata = data
            metadata_version += 1
            logger.debug(f"Metadata updated: {data.get('title', 'N/A')}")
        else:
            current_metadata = data  # update volatile fields silently
    except json.JSONDecodeError as e:
        logger.warning(f"Invalid metadata JSON: {e}")


async def metadata_ws_reader() -> None:
    """Connect to server metadata WebSocket with mDNS failover.

    On connection failure, retries the current server up to 3 times,
    then discovers alternative servers via mDNS and switches.
    """
    global metadata_host, snapserver_display, metadata_version
    consecutive_failures = 0

    while True:
        ws_url = f"ws://{metadata_host}:{METADATA_WS_PORT}"
        try:
            async with websockets.connect(ws_url) as ws:
                logger.info(f"Connected to metadata WebSocket: {ws_url}")
                if CLIENT_ID:
                    await ws.send(json.dumps({"subscribe": CLIENT_ID}))
                    logger.info(f"Subscribed to metadata for client '{CLIENT_ID}'")
                consecutive_failures = 0
                async for message in ws:
                    await _handle_metadata_message(message)
        except Exception as e:
            consecutive_failures += 1
            logger.debug(f"Metadata WS error (attempt {consecutive_failures}): {e}")

            if consecutive_failures >= MAX_RECONNECT_BEFORE_DISCOVERY:
                logger.info("Discovering snapcast servers via mDNS...")
                servers = await discover_snapservers()
                candidates = [s for s in servers if s != metadata_host] or servers
                if candidates:
                    new_host = candidates[0]
                    if new_host != metadata_host:
                        logger.info(f"Switching server: {metadata_host} → {new_host}")
                        metadata_host = new_host
                        snapserver_display = new_host
                        metadata_version += 1
                    consecutive_failures = 0
                else:
                    logger.warning("No snapcast servers found via mDNS")
                    consecutive_failures = 0

            await asyncio.sleep(5)


def is_spectrum_active() -> bool:
    """Check if any spectrum band has meaningful signal above noise floor."""
    threshold = NOISE_FLOOR + 3.0
    return bool(np.any(bands > threshold))


_RENDER_MAX_ERRORS = 50


def _render_and_write_frame(is_playing: bool) -> None:
    """Render spectrum + clock + progress and write all to FB in one call.

    Batches all rendering into a single executor call to avoid
    multiple thread switches per frame.
    """
    # Spectrum — always rendered
    spec_fb = render_spectrum()
    write_region_to_fb_fast(spec_fb, layout["right_x"], layout["spec_y"])

    # Clock — rendered every call but only written when dirty (once/second)
    clock_result = render_clock()
    if clock_result and _clock_cache["dirty"]:
        clock_fb, clock_w, clock_h = clock_result
        clock_x = (WIDTH - clock_w) // 2
        write_region_to_fb_fast(clock_fb, clock_x, layout["clock_y"])
        _clock_cache["dirty"] = False

    # Progress bar — only for file playback, written when dirty
    if is_playing:
        progress_result = render_progress_overlay()
        if progress_result and _progress_cache["dirty"]:
            prog_fb, prog_w, prog_h, prog_x, prog_y = progress_result
            write_region_to_fb_fast(prog_fb, prog_x, prog_y)
            _progress_cache["dirty"] = False


async def render_loop() -> None:
    """Main render loop with adaptive FPS."""
    global base_frame, base_frame_version, spectrum_bg_np

    FPS_ACTIVE = 20
    FPS_QUIET = 5
    consecutive_errors = 0

    while True:
        try:
            start = time.monotonic()

            # Rebuild base frame if metadata changed
            if base_frame_version != metadata_version:
                base_frame = await asyncio.get_event_loop().run_in_executor(
                    None, render_base_frame
                )
                extract_spectrum_bg()
                base_frame_version = metadata_version
                await asyncio.get_event_loop().run_in_executor(
                    None, write_full_frame, base_frame
                )
                # Full frame overwrites clock/progress regions — force redraw
                _clock_cache["dirty"] = True
                _progress_cache["dirty"] = True
                logger.info("Base frame updated (metadata changed)")

            if spectrum_bg_np is None or spectrum_bg_fb is None:
                await asyncio.sleep(0.1)
                continue

            # Determine adaptive FPS
            is_playing = current_metadata and current_metadata.get("playing")
            spectrum_active = is_spectrum_active()

            if is_playing and spectrum_active:
                fps = FPS_ACTIVE
            elif is_playing:
                fps = FPS_QUIET
            else:
                fps = FPS_QUIET  # Keep animating idle wave at reasonable FPS

            # When idle, generate subtle wave animation instead of real spectrum
            if not is_playing:
                with _band_lock:
                    bands[:] = generate_idle_wave()

            # Batch all rendering + FB writes into a single executor call
            # to avoid 5+ thread switches per frame
            await asyncio.get_event_loop().run_in_executor(
                None,
                _render_and_write_frame,
                is_playing,
            )

            elapsed = time.monotonic() - start
            sleep_time = (1.0 / fps) - elapsed
            if sleep_time > 0:
                await asyncio.sleep(sleep_time)
            consecutive_errors = 0
        except (OSError, ValueError, RuntimeError) as e:
            consecutive_errors += 1
            if consecutive_errors >= _RENDER_MAX_ERRORS:
                logger.critical(
                    f"Render loop: {consecutive_errors} consecutive errors, exiting"
                )
                sys.exit(1)
            logger.error(
                f"Render loop error ({consecutive_errors}/{_RENDER_MAX_ERRORS}): {e}"
            )
            await asyncio.sleep(1)


async def main() -> None:
    """Start all tasks."""
    global layout, _logo_img, _brand_img

    logger.info(f"Starting framebuffer display: {WIDTH}x{HEIGHT}")
    logger.info(f"  Metadata WS port: {METADATA_WS_PORT}")
    logger.info(f"  Spectrum WS port: {SPECTRUM_WS_PORT}")
    logger.info(f"  Framebuffer: {FB_DEVICE}")

    open_framebuffer()
    layout = compute_layout()
    precompute_colors()
    precompute_fb_colors()
    _init_spectrum_buffer()

    # Load logo for bottom bar
    logo_path = "/app/logo.png"
    if os.path.exists(logo_path):
        try:
            _logo_img = Image.open(logo_path).convert("RGBA")
            logger.info(f"Loaded logo: {logo_path}")
        except Exception as e:
            logger.warning(f"Failed to load logo: {e}")

    # Load brand text image (SnapForge)
    brand_path = "/app/snapforge-text.png"
    if os.path.exists(brand_path):
        try:
            _brand_img = Image.open(brand_path).convert("RGBA")
            logger.info(f"Loaded brand image: {brand_path}")
        except Exception as e:
            logger.warning(f"Failed to load brand image: {e}")

    logger.info(
        f"  Layout: art={layout['art_size']}px, "
        f"spectrum={layout['right_w']}x{layout['spec_h']}px, "
        f"FPS={TARGET_FPS}"
    )

    await asyncio.gather(
        render_loop(),
        spectrum_ws_reader(),
        metadata_ws_reader(),
    )


def cleanup(signum: int | None = None, frame=None) -> None:
    """Clean up on exit."""
    if fb_mmap:
        fb_mmap.close()
    if fb_fd:
        os.close(fb_fd)
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        cleanup(None, None)
