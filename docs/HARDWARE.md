🇬🇧 **English** | 🇮🇹 [Italiano](HARDWARE.it.md)

# Hardware & Network Guide

Hardware requirements, recommended setups, and network considerations for snapMULTI.

> **⚠️ Pi Zero 2 W users — read this first.** The installer behaves differently on the Zero 2 W because the board only has 512 MB RAM:
> - **`prepare-sd.sh` choice 1 (Audio Player)** works, but the profile is auto-promoted to `client-native`: native snapclient `.deb`, no Docker, no cover-art display, single-client role only. The full Docker stack does not fit in RAM
> - **Choices 2 (Music Server) and 3 (Server + Player)** — first boot aborts with `Pi Zero 2W (512 MB RAM) cannot host the snapMULTI server stack` and stops. The server needs at least a Pi 3 B+ with 1 GB RAM. Reflash with choice 1, or use a different Pi
>
> Full details in [Pi Zero 2 W Notes](#pi-zero-2-w-notes) below.

## If unsure, buy/use this

Quick recommendations if you don't want to read the whole guide.

| Role | Buy / use | Why |
|------|-----------|-----|
| **Server + Player** (one Pi does everything) | **Pi 4 4 GB**, good-brand A1/A2 SD ≥ 16 GB, official 15 W PSU, **HiFiBerry DAC+ family** or **InnoMaker PCM5122 HAT** | This is the launch-validated path. The 4 GB model leaves headroom for MPD scans + Spotify / Tidal peaks; A1/A2 cards are the #1 install-hang preventer |
| **Server only** (speakers live in other rooms) | **Pi 4 2 GB+** or any mini PC / NAS with Docker | Server stack is ~1 GB of container limits; 2 GB host RAM is enough |
| **Speaker / client** | **Pi 3 B+ / Pi 4** with HiFiBerry DAC+/Digi+ or InnoMaker PCM5122, or **Pi Zero 2 W + InnoMaker PCM5122** headless (native install — no Docker) | These are the launch-validated client paths. Use other DACs only if you are comfortable troubleshooting ALSA |
| **Avoid** | Pi Zero 2 W as server or in both-mode (512 MB RAM is not enough), 32-bit Raspberry Pi OS, no-brand cheap SD cards, USB-powered hubs without their own PSU when driving multiple Pis | These are the recurring failure modes in real installs |

The rest of this guide goes into the *why* and the corner cases.

## Hardware support policy

snapMULTI intentionally keeps the launch hardware matrix small. Audio on Raspberry Pi is where most "almost works" failures happen, so the public promise is based on devices we have actually reflashed, booted, smoke-tested and heard playing audio.

| Tier | Meaning | Support expectation |
|------|---------|---------------------|
| **Validated** | Tested end-to-end by the project: first boot, read-only reboot, smoke/fleet smoke, and real playback through the output | Recommended for first installs and commercial/reference builds |
| **Expected to work** | Same chipset or Linux audio path as validated hardware, but not physically tested by the project yet | Good for experienced users; please report results |
| **Experimental / manual** | Present in the installer menu or configurable with ALSA, but not launch-validated | No compatibility promise; use only if you can debug audio devices |

Launch-validated audio outputs:

| Output family | Validation status |
|---------------|-------------------|
| HiFiBerry DAC+ family / PCM5122 analog | **Validated** |
| InnoMaker PCM5122 analog HATs, including Pi Zero 2 W headless | **Validated** |
| HiFiBerry Digi+ family / WM8804 S/PDIF | **Validated** |
| Pi onboard/bcm2835 audio on Pi 4 client | **Validated, but quality-limited** |
| HDMI output on Pi 4 display client | **Validated for display/client path** |
| Generic USB DACs, amplifier HATs, IQaudio, JustBoom, Allo, Waveshare | **Experimental / manual until physically validated** |

## Server Requirements

The server runs all audio services: Snapcast, MPD, shairport-sync (AirPlay), go-librespot (Spotify Connect) and — on `linux/arm64` only — tidal-connect (Tidal), all inside Docker containers.

### Minimum Server Hardware

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| CPU | 4 cores, ARMv8 or x86_64 (Pi 3B+) | Pi 4 or x86_64 (faster single-core) |
| RAM | 2 GB | 4 GB+ |
| Storage | 32 GB microSD | 32 GB+ |
| Network | 100 Mbps Ethernet or WiFi 5 GHz | Gigabit Ethernet |
| Architecture | `linux/amd64` or `linux/arm64` | Either |

> **Why 2 GB recommended?** A 1 GB Pi 3 works but has limited headroom for spikes (MPD library scans, concurrent streaming + active AirPlay / Spotify / Tidal). A Pi 4 with 2 GB gives a comfortable margin. See [resource profiles](#resource-profiles) below for the per-container limits applied automatically.

### What Drives Server Requirements

- **shairport-sync** (AirPlay receiver): lightweight; requires a Pi 2 or better ([source](https://github.com/mikebrady/shairport-sync))
- **librespot** (Spotify Connect): lightweight at idle, peaks during active streaming ([source](https://github.com/librespot-org/librespot/issues/343))
- **MPD**: heaviest on first startup with an NFS-mounted library (full scan) — proportional to library size
- **Snapserver**: scales linearly with the number of connected clients ([source](https://github.com/badaix/snapcast/issues/1336))
- **tidal-connect** (ARM only): runs only when the `tidal` Compose profile is enabled; idle most of the time

### Server Examples

**TL;DR**: Pi 4 (2+ GB) is the safe pick. Pi 3 B+ works but tight. Pi Zero 2 W cannot run the server — use it as a client instead.

| Hardware | Verdict | Best for | Why |
|----------|---------|----------|-----|
| Raspberry Pi 4 (4 GB+) | ✅ Recommended | Any setup, including server + display | Handles all 5 sources + 10 clients + cover-art display comfortably |
| Raspberry Pi 4 (2 GB) | ✅ Good | Server-only or server + headless client | Tight if you also want the cover-art display on the same Pi |
| Raspberry Pi 3 B+ | ⚠️ Server-only | Single-purpose server with 1-2 streaming sources | 1 GB RAM is enough at idle but leaves no spike headroom for big MPD scans |
| Raspberry Pi Zero 2 W | ❌ Not supported | — (use as a client only) | 512 MB RAM cannot fit all server containers |
| Intel NUC / mini PC | ✅ Excellent | Large libraries, many clients | Plenty of CPU and RAM, low power |
| Old laptop / desktop | ✅ Excellent | Reusing existing hardware | Any x86_64 with 2+ GB RAM works |
| NAS with Docker | ✅ Good | Always-on appliance | Needs 2+ cores, 2+ GB RAM, Docker support |

> **Note:** Pi 3B+ has only **1 GB RAM**. Server-only works but leaves limited headroom. Not recommended for "both" mode (server + client with display). Pi 2 is too slow for simultaneous AirPlay + Spotify; avoid for server use.

> **Beginners:** If this is your first time, use a Raspberry Pi 4 (4 GB) and follow the [Quick start in the README](../README.md#quick-start). It handles everything automatically — no Linux administration required.

## Client Requirements

Snapcast clients are lightweight — they receive audio and play it through speakers.

### Minimum Client Hardware

| Component | Minimum | Notes |
|-----------|---------|-------|
| CPU | Any ARMv6+ or x86_64 | Even Pi Zero W (original) works |
| RAM | 256 MB | Snapclient uses very little memory |
| Storage | 8 GB microSD | 16 GB recommended |
| Audio output | Validated I2S HAT, HDMI/onboard, or manual USB DAC | See hardware support policy and audio output section |

### Client Device Options

| Device | Audio Output | Power | Notes |
|--------|--------------|-------|-------|
| **Raspberry Pi Zero 2 W** | Validated I2S HAT | 0.75 W | Best budget option; 2.4 GHz WiFi only; audio-only (no display) |
| **Raspberry Pi Zero W** (v1) | USB DAC or I2S HAT | 0.5 W | Works but slow; no GPIO audio; 2.4 GHz WiFi only |
| **Raspberry Pi 3B/3B+** | Validated I2S HAT, manual onboard/USB | 2.5 W | 5 GHz WiFi + Ethernet; onboard/USB paths are not the recommended launch path |
| **Raspberry Pi 4** (2 GB+) | Validated I2S HAT, HDMI, onboard, manual USB | 3–6 W | Required for client with cover art display (fb-display) |
| **Raspberry Pi 5** | HDMI, manual USB | 4–8 W | Overkill for client use; launch validation is thinner than Pi 4 |
| **Old Android phone** | Built-in speaker | Battery | Via [Snapcast Android app](https://github.com/badaix/snapdroid) |
| **Any Linux PC** | Built-in audio | Varies | `apt install snapclient` |

### Pi Zero 2 W Notes

The Pi Zero 2 W is the cheapest client option but has specific requirements.

> **What snapMULTI does automatically on Pi Zero 2 W:**
>
> | Menu choice in `prepare-sd.sh` | What happens on first boot |
> |-----|-----|
> | **1) Audio Player** | Profile auto-promotes from `client` to `client-native`. No Docker, no display containers (fb-display / visualizer), single-client role with no multi-server failover. Native snapclient `.deb` installed instead |
> | **2) Music Server** | First boot **aborts with an error** pointing here. 512 MB RAM cannot host the 7-container server stack. Reflash with menu choice 1 instead |
> | **3) Server + Player** | First boot **aborts with the same error**. Same RAM constraint as choice 2 |
>
> If you picked "Audio Player" and expected the standard Docker stack with cover-art display — this is the trade-off for fitting in 512 MB RAM. Use a Pi 3 B+ or Pi 4 if you need the display, multi-server failover, or full Docker isolation.

Detail:

- **64-bit OS required** — Imager defaults to 32-bit for this model. Select "Raspberry Pi OS Lite (64-bit)" explicitly
- **2.4 GHz WiFi only** — no 5 GHz. Use your 2.4 GHz SSID when configuring WiFi in Imager
- **512 MB RAM** — headless audio only (no display). Cannot run fb-display or server
- **Native snapclient (no Docker)** — `firstboot.sh` detects the Pi Zero 2 W via `is_pi_zero_2w` (`scripts/common/device-detect.sh`), promotes the install profile from `client` to `client-native`, then dispatches to `client/common/scripts/setup-zero2w.sh`. That script installs snapclient v0.35 from the upstream badaix `.deb` and skips Docker, dockerd, and fuse-overlayfs entirely. Other client models keep the standard Docker path
- **Hardware guard for server / both** — at the start of `firstboot.sh`, `_validate_profile_hardware()` rejects `INSTALL_TYPE=server` and `INSTALL_TYPE=both` on Pi Zero 2 W. The first boot aborts with `log_error` and `exit 1`, surfacing the constraint immediately instead of failing later during `docker compose pull` with a cryptic OOM. Reflash the SD card with the Audio Player choice to recover
- **Zram swap disabled** — `tune_pi_zero_2w_swap_safety()` in `scripts/common/system-tune.sh` masks `dev-zram0.swap` / `rpi-zram-writeback.service` and removes `/var/swap` at first boot. Without this fix, `rpi-zram-writeback` writes to the swap file living in the 256 MB overlay tmpfs upper layer and the kernel panics when the tmpfs fills (observed 2026-05-11)
- **Single-client role, no multi-server failover** — the native snapclient uses libavahi-client autodiscovery directly. The multi-server failover state machine from `discover-server.sh` (TCP probing, anti-flapping, smart IPv4 selection) is not available on Pi Zero 2 W. Acceptable for typical single-room headless setups; if you need failover, use a Pi 3 B+ or Pi 4 client
- **I2S HAT compatibility** — launch validation covers PCM5122-based HiFiBerry/InnoMaker HATs. Other PCM5122 boards are expected to work but should be treated as unvalidated until tested. The USB `otg_mode=1` setting from Imager conflicts with I2S — `prepare-sd.sh` and `setup.sh` fix this automatically
- **USB gadget mode** — for debugging without WiFi, connect the data USB port to your computer. Requires `dtoverlay=dwc2` under `[all]` in config.txt (not under `[cm5]`)

### Audio Output Quality

| Output Method | Quality | Notes |
|---------------|---------|-------|
| **I2S DAC HAT** (validated HiFiBerry DAC+ / InnoMaker PCM5122) | Excellent | Best analog quality, RCA output, connects directly to Pi GPIO |
| **I2S S/PDIF HAT** (validated HiFiBerry Digi+) | Excellent | Digital optical/coaxial out to AV receiver or external DAC; no analog conversion on the Pi |
| **USB DAC** | Very good when supported by Linux | Manual/experimental until a specific model is physically validated |
| **HDMI** | Good | Validated on Pi 4 display/client path. ALSA card name varies by kernel: `vc4-hdmi-0` (Bookworm/Trixie KMS), `HDMI` (legacy). Resolved automatically at first boot via `aplay -L` |
| **3.5mm jack** (Pi 3/4) | Adequate | Validated only as onboard fallback. Noticeable noise floor on some boards; fine for casual listening. **Pi 5 has no analog jack** — picking "jack" in the install menu auto-falls back to HDMI |

> **Tip:** Use launch-validated I2S HATs for the first install: HiFiBerry DAC+ family or InnoMaker PCM5122 for analog output, HiFiBerry Digi+ family for S/PDIF.

> **Manual override:** `prepare-sd.sh` offers an *Audio output* menu (auto-detect, pick a HAT from the list, or pick built-in HDMI/jack). Menu entries beyond the validated matrix are compatibility helpers, not a launch support promise. See [INSTALL.md — Menu 2 — Audio output](INSTALL.md#menu-2--audio-output-audio-player-and-serverplayer-only).

### Client Install Method

snapMULTI uses **Docker Compose for client deployment** via the [client](../client/) directory. This provides a self-contained stack including snapclient, cover art display, and audio visualizer — all managed together.

The client Docker stack runs three containers from the pinned release image set:

- `lollonet/snapclient-pi:<image-set>` — Snapcast audio player
- `lollonet/snapclient-pi-fb-display:<image-set>` — Cover art display (framebuffer)
- `lollonet/snapclient-pi-visualizer:<image-set>` — Audio visualizer

`<image-set>` comes from `release-manifest.json`. Script-only releases can reuse the same image set; container-changing releases publish a new pinned image set. Do not use `latest` for reproducible appliance installs.

See [README.md](../README.md) for the full installation procedure (SD card path or manual).

For minimal or manual setups without the full client directory, snapclient can be installed natively:

```bash
sudo apt install snapclient
```

Docker is recommended for the **server** and for full client nodes with display; native `apt` install is adequate for a bare audio-only client on very constrained hardware.

## Network Requirements

### Bandwidth

Audio format: 44100 Hz, 16-bit, stereo (default FLAC codec).

| Metric | Value |
|--------|-------|
| Raw PCM bitrate | 1.536 Mbps (192 KB/s) |
| FLAC compressed (typical) | ~0.9 Mbps (~115 KB/s) |
| Protocol overhead per client | ~14 kbps (negligible) |

**Total bandwidth by number of clients:**

| Clients | FLAC Bandwidth | Network Needed |
|---------|---------------|----------------|
| 5 | ~4.5 Mbps | Any modern network |
| 10 | ~9 Mbps | Any modern network |
| 20 | ~18 Mbps | 100 Mbps Ethernet or 5 GHz WiFi |
| 50 | ~45 Mbps | Gigabit Ethernet recommended |

> **Bandwidth is NOT a bottleneck** for typical home setups. Even 2.4 GHz WiFi (practical throughput ~20–50 Mbps) handles 10+ clients.

### WiFi vs Ethernet

| Factor | WiFi (2.4 GHz) | WiFi (5 GHz) | Ethernet |
|--------|-----------------|---------------|----------|
| Bandwidth | 20–50 Mbps practical | 150–400 Mbps | 100–1000 Mbps |
| Latency | 2–10 ms | 1–5 ms | <1 ms |
| Reliability | Variable (interference) | Good | Excellent |
| Client capacity | 10–15 clients | 20+ clients | 50+ clients |
| Best for | Clients in rooms without Ethernet | Clients needing reliability | Server, critical clients |

**Recommendations:**
- **Server**: Ethernet whenever possible
- **Clients**: WiFi works fine; use 5 GHz if available
- **Latency-sensitive setups**: Ethernet reduces sync jitter

### Synchronization

- Snapcast achieves **sub-millisecond sync** across clients
- Default buffer: 2400 ms (configurable in `snapserver.conf`)
- Larger buffer = more stable on poor networks, but adds playback delay
- WiFi jitter is compensated automatically — clients adjust playback speed

### Network Configuration

**Required ports:**

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 1704 | TCP | Server → Clients | Audio streaming |
| 1705 | TCP | Bidirectional | Snapcast JSON-RPC control |
| 1780 | HTTP | Bidirectional | Snapweb UI + HTTP API |
| 4953 | TCP | Inbound | TCP audio input (ffmpeg/Android streaming) |
| 5000 | TCP | Inbound | AirPlay (shairport-sync RTSP) |
| 5858 | TCP | Inbound | AirPlay cover art (meta_shairport.py) |
| 2019 | TCP | Inbound | Tidal Connect discovery (ARM only) |
| 6600 | TCP | Bidirectional | MPD protocol (client control) |
| 8000 | HTTP | Server → Clients | MPD HTTP audio stream |
| 8082 | WebSocket | Server → Clients | Metadata service (track info push) |
| 8083 | HTTP | Server → Clients | Metadata service (cover art, health) |
| 8180 | HTTP | Bidirectional | myMPD web UI |
| 5353 | UDP | Multicast | mDNS autodiscovery |

**Router requirements:**
- Clients and server must be on the same subnet (or mDNS must be forwarded)
- IGMP snooping support recommended for larger networks
- No special router features needed for typical home use

Firewall configuration (`ufw` rules) and QoS / `cake` qdisc setup are documented in [ADVANCED.md — Firewall rules](ADVANCED.md#firewall-rules) and [Network QoS](ADVANCED.md#network-qos).

## Storage

### Docker Images

**Server images:**

| Image | Size |
|-------|------|
| `lollonet/snapmulti-server:<image-set>` | ~80–120 MB |
| `lollonet/snapmulti-airplay:<image-set>` | ~30–50 MB |
| `ghcr.io/devgianlu/go-librespot:v0.7.3` | ~30–50 MB |
| `lollonet/snapmulti-mpd:<image-set>` | ~50–80 MB |
| `lollonet/snapmulti-metadata:<image-set>` | ~60–80 MB |
| `ghcr.io/jcorporation/mympd/mympd:25.0.2` | ~30–50 MB |
| `lollonet/snapmulti-tidal:<image-set>` | ~200–300 MB |

**Client images** (from [client](../client/) directory):

| Image | Size |
|-------|------|
| `lollonet/snapclient-pi:<image-set>` | ~30–50 MB |
| `lollonet/snapclient-pi-fb-display:<image-set>` | ~80–120 MB |
| `lollonet/snapclient-pi-visualizer:<image-set>` | ~50–80 MB |

### Music Library

| Format | Typical Album Size | 1000 Albums |
|--------|--------------------|-------------|
| FLAC (lossless) | 300–500 MB | 300–500 GB |
| MP3 320 kbps | 80–120 MB | 80–120 GB |
| MP3 192 kbps | 50–80 MB | 50–80 GB |

**Storage recommendations:**
- FLAC libraries: external USB drive or NAS mount
- MP3 libraries: 256 GB+ microSD or internal drive
- MPD database file: <100 MB regardless of library size

## Recommended Setups

### Starter — 2 rooms

| Node | Hardware | Audio output |
|------|----------|-------------|
| Server + Client | Pi 4 (4 GB) + HiFiBerry DAC2 Pro | RCA analog |
| Client (headless) | Pi Zero 2 W + HiFiBerry DAC+ Zero | RCA analog |

> Pi Zero 2 W requires soldering a GPIO header (or buy the WH variant with pre-soldered header). **WiFi only** — no Ethernet port, 2.4 GHz only.

### Budget — 2 rooms (all available on Amazon)

| Node | Hardware | Audio output |
|------|----------|-------------|
| Server + Client | Pi 4 (2 GB) + InnoMaker HiFi DAC HAT (PCM5122) | RCA + 3.5mm |
| Client (headless) | Pi 3 B+ + InnoMaker DAC Mini HAT (PCM5122) | RCA + 3.5mm |

> Pi 4 2 GB is comfortable for server-only. For server + client with display, the 4 GB model is preferred.

### Enthusiast — 4+ rooms

| Node | Hardware | Connection |
|------|----------|------------|
| Server | Intel NUC or mini PC (x86_64) | Ethernet |
| Client × 3+ | Pi Zero 2 W + HiFiBerry DAC+ Zero | WiFi (2.4 GHz) |

> Pi Zero clients connect via WiFi (no Ethernet port). Server should use Ethernet for reliability. A managed switch helps if you also have wired clients (Pi 3/4).

### Alternative: S/PDIF to AV Receiver

If a node connects to an AV receiver via optical cable, use HiFiBerry Digi+ instead of a DAC HAT. This shifts the D/A conversion to your receiver — better quality if your receiver has a good DAC.

## Tested Combinations

These hardware combinations have been verified end-to-end (firstboot → smoke test → audio playback) on the dates indicated. Treat this table as the source of truth for launch-validated hardware. This table records hardware validation, not the latest release gate; release-level confidence comes from the current device/fleet smoke runs described in the changelog and release notes. The 2026-04-27 batch was the v0.6.x hardware validation run: 6 devices reflashed from `main`, smoke test PASS on each, ALSA `hw_ptr` advancing during playback (audio actually reaching the DAC, not just the FIFO).

| Hostname | Pi Model | Audio HAT | DAC chip | Mode | Display | Music Source | Validated | Status |
|---|---|---|---|---|---|---|---|---|
| pi-server | Pi 4 B (8 GB) | HiFiBerry DAC+ | PCM5122 (analog) | both | HDMI 800×600 (cover art display) | local | 2026-04-27 | Working |
| pi4-test | Pi 4 B (2 GB) | HiFiBerry DAC+ Standard | PCM5122 (analog) | both | headless | USB | 2026-04-27 | Working |
| pi-display | Pi 4 B (2 GB) | HiFiBerry Digi+ | WM8804 (S/PDIF) | client | HDMI to LG 50" TV | n/a | 2026-04-27 | Working |
| pi4-2gb-cli | Pi 4 B (2 GB) | none (bcm2835 onboard) | — | client | headless | n/a | 2026-04-27 | Working |
| pi3-1gb-cli | Pi 3 B+ (1 GB) | InnoMaker HIFI DAC HAT | PCM5122 (analog) | client | headless | n/a | 2026-04-27 | Working |
| pi-zero | Pi Zero 2 W (512 MB) | InnoMaker DAC | PCM5122 (analog) | client | headless | n/a | 2026-04-27 | Working |

**Coverage achieved on 2026-04-27**:

- 3 Pi families: Pi Zero 2 W, Pi 3 B+, Pi 4 B (4 different rev numbers on the Pi 4: 1.1, 1.2, 1.4, 1.5)
- 2 DAC chip families: PCM5122 (analog, 4 boards across HiFiBerry + InnoMaker brands) and WM8804 (S/PDIF digital)
- Plus 1 device with onboard `bcm2835` (no HAT)
- Both mixer paths: hardware (`hardware:Digital` on PCM5122) and software fallback (S/PDIF + onboard)
- Both install modes (`--both`, `--client`) and `--server` exercised in earlier rounds
- Headless and HDMI-display variants
- Read-only filesystem (overlayroot + fuse-overlayfs) active on every device
- Auto-detect via I2C bus 1 EEPROM-less PCM5122 detection works on all four DAC HATs

## Known Limitations

| Limitation | Details |
|------------|---------|
| **Pi Zero 2 W as server** | 512 MB RAM cannot fit server containers (592M limits in minimal profile). Use as headless client only |
| **Pi Zero 2 W with display** | 512 MB RAM is too tight for fb-display + visualizer (352M limits). Use Pi 3+ for display clients |
| **Pi 3 1 GB — both mode with display** | Server (592M) + client display (352M) = 944M limits on 1 GB — not supported. Use server-only or client-only, not both |
| **Pi Zero W (v1) as server** | Too slow for shairport-sync + librespot simultaneously |
| **librespot on ARMv6** | Not officially supported on Pi Zero v1 / Pi 1 ([details](https://github.com/librespot-org/librespot/pull/1457)). Cross-compilation possible but unsupported |
| **3.5mm audio on Pi** | Noticeable noise floor; use DAC HAT or USB DAC for quality |
| **2.4 GHz WiFi** | Works but susceptible to interference; 5 GHz preferred for >10 clients |
| **Docker on 32-bit Pi OS** | Being deprecated; use 64-bit Pi OS for Docker deployments |

---

## Resource profiles

Container memory limits are applied automatically based on detected hardware (minimal / standard / performance). Full per-service tables and the hardware-compatibility matrix: [ADVANCED.md — Resource profiles](ADVANCED.md#resource-profiles).

---

## Reference builds — load characteristics

Per-service memory limits live in [ADVANCED.md — Resource profiles](ADVANCED.md#resource-profiles). The notes below describe how the system *behaves* under load, so you can size hardware without chasing point-in-time benchmarks.

### Scenario A — server fan-out (multi-source → multiple client groups)

A server-with-display Pi feeding several remote snapclients plus its own loopback. Typical workload: MPD library, AirPlay, and Spotify Connect active at the same time, each routed to a different client group.

| Role | Board floor | Audio path |
|------|-------------|------------|
| Server + display | Pi 4 4 GB+ (8 GB recommended for headroom) | HAT DAC, analog or digital |
| Client group with display | Pi 4 2 GB+ | HDMI / HAT DAC |
| Client group, headless | Pi 3 / Pi Zero 2 W native | HAT DAC |
| Loopback (server plays locally too) | same Pi as server | server HAT DAC |

**Dominant costs to size for:**

- **MPD library streaming** is the heaviest server-side workload — it grows with library size and NFS/SMB latency, not with the number of fan-out clients. Cover-art generation amplifies the RAM footprint.
- **snapserver fan-out itself is cheap.** Adding remote client groups bumps CPU only marginally; the main cost stays in the source decoders.
- **Per-client CPU is dominated by the display stack, not `snapclient`.** A 4K HDMI cover-art display can take an order of magnitude more CPU than the audio client. Headless clients are essentially free.
- **Spotify/Tidal/AirPlay daemons stay warm even when idle** — they hold modest baseline RAM so handoff between sources is immediate.

**Sizing rule of thumb for the server:** Pi 4 4 GB is the comfortable floor when the server also runs the cover-art display; 8 GB gives margin for MPD scans, source switches, and a growing library. A Pi 3 / Pi 4 2 GB can serve audio fan-out but will feel tight as soon as the local display stack joins in.

> **Pi Zero 2 W stays viable as a client** *only* via the native `.deb` install (no Docker, no display containers — see [Pi Zero 2 W Notes](#pi-zero-2-w-notes)). Under Docker the same role would not fit in 512 MB; native, it is a single lightweight process and runs indefinitely.

### Scenario B — single-host both-mode (local library only)

A single Pi running server + client at the same time, playing from its own MPD library to its own snapclient. No fan-out, no remote clients.

**Characteristics:**

- All container costs collapse onto one board, but with no fan-out the snapserver path is light.
- The heaviest single contributor is MPD when scanning or playing from a large library.
- Tidal/Spotify/AirPlay daemons remain resident but quiet when not actively casting.
- A Pi 4 2 GB has clear margin for both-mode without a server-side display; jumping to 4 GB is overkill for this case. The 4 GB+ floor only matters once cover-art display containers join the stack.

**Sizing rule of thumb for both-mode:** Pi 4 2 GB is enough for pure audio (no display). Add the cover-art display stack → step up to 4 GB+. Both-mode on Pi 3 / Pi Zero is not supported — see the [hardware compatibility matrix](ADVANCED.md#hardware-compatibility-matrix).

### General observations

- **Thermals stay within margin** on all Pi 4 boards under typical home-streaming load — passive cooling (heatsink case) is sufficient, no active fan required. The hottest component tends to be the server when running cover-art rendering alongside audio fan-out.
- **Container memory limits target steady-state, not peaks.** Brief headroom during MPD scans, container restarts, or source switches is normal; the per-service ceilings in [ADVANCED.md](ADVANCED.md#resource-profiles) leave room for it.
- **Reflash-first deployment means actual RAM usage decays after first boot.** The MPD cached database removes the worst-case scan cost on subsequent boots — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the first-boot scan window on large NFS libraries.

> **Want point-in-time numbers?** Run `docker stats --no-stream`, `free -h`, and `vcgencmd measure_temp` on your own device after smoke test passes — actual figures depend on library size, source mix, and playback activity, so a snapshot in this doc rots within months.

---

## Thermal

Pi 4 boards run continuously without thermal throttling under typical home-streaming load. Passive cooling (heatsink case) is sufficient; active cooling (fan) is not required.
