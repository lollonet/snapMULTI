# Requirements

## Functional Requirements

### FR-01: Audio Playback

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-01.1 | Receive synchronized audio from Snapserver over TCP (port 1704) | Must | ✅ IMPLEMENTED |
| FR-01.2 | Output audio via ALSA to any of the 17 supported HATs or USB DAC | Must | ✅ IMPLEMENTED |
| FR-01.3 | Support hardware and software mixer modes | Must | ✅ IMPLEMENTED |
| FR-01.4 | Route audio to both DAC and ALSA loopback simultaneously (for spectrum) | Must | ✅ IMPLEMENTED |
| FR-01.5 | Auto-discover Snapserver via mDNS (`_snapcast._tcp`) | Must | ✅ IMPLEMENTED |
| FR-01.6 | Buffer tuning via `ALSA_BUFFER_TIME` and `ALSA_FRAGMENTS` | Should | ✅ IMPLEMENTED |

### FR-02: Spectrum Analyzer

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-02.1 | Capture audio from ALSA loopback device | Must | ✅ IMPLEMENTED |
| FR-02.2 | Compute FFT spectrum (8192-point) at 44100 Hz sample rate | Must | ✅ IMPLEMENTED |
| FR-02.3 | Support third-octave (31 bands) and half-octave (21 bands) modes | Must | ✅ IMPLEMENTED |
| FR-02.4 | Broadcast dBFS spectrum data via WebSocket (port 8081) | Must | ✅ IMPLEMENTED |
| FR-02.5 | Apply attack/decay smoothing for visual quality | Should | ✅ IMPLEMENTED |
| FR-02.6 | Deduplicate identical frames during silence | Should | ✅ IMPLEMENTED |
| FR-02.7 | Work on both little-endian (ARM) and big-endian (PowerPC) platforms | Must | ✅ IMPLEMENTED |

### FR-03: Framebuffer Display

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-03.1 | Render album art, track metadata, and spectrum to `/dev/fb0` | Must | ✅ IMPLEMENTED |
| FR-03.2 | Display source name, title, artist, album | Must | ✅ IMPLEMENTED |
| FR-03.3 | Show format badge (codec, sample rate, bit depth) | Must | ✅ IMPLEMENTED |
| FR-03.4 | Animate song progress bar with local clock interpolation | Must | ✅ IMPLEMENTED |
| FR-03.5 | Show volume knob, date/time, and branding in bottom bar | Must | ✅ IMPLEMENTED |
| FR-03.6 | Display standby screen with breathing animation when idle | Must | ✅ IMPLEMENTED |
| FR-03.7 | Auto-detect resolution from framebuffer, cap at 1920x1080 | Must | ✅ IMPLEMENTED |
| FR-03.8 | Scale render output to actual framebuffer dimensions | Must | ✅ IMPLEMENTED |
| FR-03.9 | Support 16bpp (RGB565) and 32bpp (BGRA/XRGB) framebuffers | Must | ✅ IMPLEMENTED |
| FR-03.10 | Connect to metadata service via WebSocket and HTTP | Must | ✅ IMPLEMENTED |

### FR-04: Installation & Setup

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-04.1 | Zero-touch install via SD card (`prepare-sd.sh` + `firstboot.sh`) | Must | ✅ IMPLEMENTED |
| FR-04.2 | Auto-detect audio HAT from EEPROM, ALSA, or I2C scan | Must | ✅ IMPLEMENTED |
| FR-04.3 | Interactive setup mode with HAT and resolution selection | Must | ✅ IMPLEMENTED |
| FR-04.4 | Generate `.env` and ALSA configuration from selections | Must | ✅ IMPLEMENTED |
| FR-04.5 | Install Docker CE with Compose v2 plugin | Must | ✅ IMPLEMENTED |
| FR-04.6 | Pull pre-built Docker images (never build on Pi) | Must | ✅ IMPLEMENTED |
| FR-04.7 | Support cloud-init (Bookworm+) boot paths | Must | ✅ IMPLEMENTED |
| FR-04.8 | Discover snapserver via mDNS on every boot (`discover-server.sh`) | Must | ✅ IMPLEMENTED |

### FR-05: Metadata Integration

| ID | Requirement | Priority | Status |
|----|-------------|----------|--------|
| FR-05.1 | Subscribe to centralized metadata service with `CLIENT_ID` via WebSocket (port 8082) | Must | ✅ IMPLEMENTED |
| FR-05.2 | Receive track info pushes (title, artist, album, duration, position, state) | Must | ✅ IMPLEMENTED |
| FR-05.3 | Fetch cover art via HTTP (port 8083) | Must | ✅ IMPLEMENTED |
| FR-05.4 | Derive `METADATA_HOST` from `SNAPSERVER_HOST` (same server) | Must | ✅ IMPLEMENTED |
| FR-05.5 | Auto-reconnect on WebSocket disconnection | Must | ✅ IMPLEMENTED |

## Non-Functional Requirements

### NFR-01: Performance

| ID | Requirement | Target | Status |
|----|-------------|--------|--------|
| NFR-01.1 | Boot to audio playback | < 30 seconds | ✅ ACHIEVED |
| NFR-01.2 | Display frame rate | >= 15 FPS | ✅ ACHIEVED |
| NFR-01.3 | Spectrum latency (capture to display) | < 100ms | ✅ ACHIEVED |
| NFR-01.4 | Memory usage (all containers) | < 512MB total | ✅ ACHIEVED |
| NFR-01.5 | CPU usage at idle | < 15% | ✅ ACHIEVED |

### NFR-02: Reliability

| ID | Requirement | Target | Status |
|----|-------------|--------|--------|
| NFR-02.1 | Survive unexpected power loss | No corruption | ✅ ACHIEVED (read-only FS) |
| NFR-02.2 | Auto-restart on container crash | < 10 seconds | ✅ ACHIEVED |
| NFR-02.3 | Circuit breaker on persistent failures | Exit after 30-50 errors | ✅ IMPLEMENTED |
| NFR-02.4 | Reconnect to metadata on server restart | Automatic | ✅ ACHIEVED |

### NFR-03: Security

| ID | Requirement | Target | Status |
|----|-------------|--------|--------|
| NFR-03.1 | Containers run as non-root (uid 1000) | All 3 containers | ✅ IMPLEMENTED |
| NFR-03.2 | Read-only container filesystems | All 3 containers | ✅ IMPLEMENTED |
| NFR-03.3 | Minimal capabilities (`CAP_DROP: ALL` + specific adds) | All 3 containers | ✅ IMPLEMENTED |
| NFR-03.4 | No secrets in repository | Enforced | ✅ ACHIEVED |
| NFR-03.5 | Input validation in setup scripts | All user input | ✅ IMPLEMENTED |
| NFR-03.6 | Artwork URLs constrained to metadata server | fb-display | ✅ IMPLEMENTED |

### NFR-04: Compatibility

| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-04.1 | Raspberry Pi 4 (2/4/8 GB) | ✅ TESTED | Standard/performance profiles |
| NFR-04.2 | Raspberry Pi 5 | ⚠️ UNTESTED | Should work (performance profile) |
| NFR-04.3 | Raspberry Pi 3B+ | ✅ TESTED | Minimal profile |
| NFR-04.4 | 17 audio HATs + USB audio | ✅ TESTED | Auto-detection via EEPROM + I2C scan |
| NFR-04.5 | Resolutions 800x480 to 3840x2160 | ✅ TESTED | Render capped at 1920x1080, scaled |
| NFR-04.6 | Big-endian platforms (PowerPC) | ✅ TESTED | Native Python, no Docker |