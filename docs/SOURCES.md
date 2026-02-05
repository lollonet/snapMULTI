🇬🇧 **English** | 🇮🇹 [Italiano](SOURCES.it.md)

# Audio Sources Reference

Technical reference for all Snapcast audio source types supported by snapMULTI.
Designed for remote management applications and advanced configuration.

## Overview

| # | Source | Type | Stream ID | Status | Binary/Dependency |
|---|--------|------|-----------|--------|-------------------|
| 1 | MPD | `pipe` | `MPD` | Active | — (FIFO) |
| 2 | TCP Input | `tcp` (server) | `TCP-Input` | Active | — (built-in) |
| 3 | AirPlay | `pipe` | `AirPlay` | Active | `shairport-sync` (separate container) |
| 4 | Spotify Connect | `pipe` | `Spotify` | Active | `librespot` (separate container) |
| 5 | Tidal | `tcp` | `TCP-Input` | Optional | `tidal-bridge` (separate container) |
| 6 | ALSA Capture | `alsa` | `LineIn` | Available | ALSA device |
| 7 | Meta Stream | `meta` | `AutoSwitch` | Available | — (built-in) |
| 8 | File Playback | `file` | `Alert` | Available | — (built-in) |
| 9 | TCP Client | `tcp` (client) | `Remote` | Available | — (built-in) |

**Status legend:**
- **Active** — Enabled in `config/snapserver.conf`, running in production
- **Available** — Commented-out example in config, ready to enable

---

## Active Sources

### 1. MPD (pipe)

Reads PCM audio from a named FIFO pipe. MPD writes its output to `/audio/snapcast_fifo`, and Snapserver reads from it.

**Config:**
```ini
source = pipe:////audio/snapcast_fifo?name=MPD&controlscript=meta_mpd.py
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `MPD` | Stream ID for client/API use |
| `mode` | `create` (default) | Snapserver creates the FIFO if missing |
| `controlscript` | `meta_mpd.py` | Fetches now-playing metadata (title, artist, album, cover art) from MPD |

**Sample format:** Inherited from global `sampleformat = 44100:16:2`

**How it works:**
1. MPD plays local music files from `/music` (mapped to `MUSIC_PATH` on host)
2. MPD writes PCM audio to `/audio/snapcast_fifo` (FIFO output in `mpd.conf`)
3. Snapserver reads from the FIFO and distributes to clients

**Control:**
```bash
mpc play                    # Start playback
mpc add "Artist/Album"      # Queue music
mpc status                  # Check status
```

**Connect to MPD:** `<server-ip>:6600`

---

### 2. TCP Input (tcp server)

Listens on a TCP port for incoming PCM audio. Any application that can send raw audio over TCP can use this source.

**Config:**
```ini
source = tcp://0.0.0.0:4953?name=TCP-Input&mode=server
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `TCP-Input` | Stream ID |
| `mode` | `server` | Snapserver listens for connections |
| `bind` | `0.0.0.0` | Accept from any interface |
| `port` | `4953` | Listening port |

**Sample format:** 44100:16:2 (PCM s16le, stereo)

**Send audio:**
```bash
# Stream a file
ffmpeg -i music.mp3 \
  -f s16le -ar 44100 -ac 2 \
  tcp://<server-ip>:4953

# Stream internet radio
ffmpeg -i http://stream.example.com/radio \
  -f s16le -ar 44100 -ac 2 \
  tcp://<server-ip>:4953

# Generate test tone
ffmpeg -f lavfi -i "sine=frequency=440:duration=5" \
  -f s16le -ar 44100 -ac 2 \
  tcp://<server-ip>:4953
```

**Required audio format:**

| Property | Value |
|----------|-------|
| Sample rate | 44100 Hz |
| Bit depth | 16 bit |
| Channels | 2 (stereo) |
| Encoding | Raw PCM (s16le) |

---

### 3. AirPlay (pipe from shairport-sync)

The shairport-sync container receives AirPlay audio from Apple devices and writes raw PCM to a named pipe. Snapserver reads from the pipe.

**Config:**
```ini
source = pipe:////audio/airplay_fifo?name=AirPlay
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `AirPlay` | Stream ID |

**shairport-sync configuration** (`config/shairport-sync.conf`):

| Setting | Value | Description |
|---------|-------|-------------|
| `general.name` | `%H AirPlay` | Name shown on Apple devices (%H = hostname) |
| `pipe.name` | `/audio/airplay_fifo` | Named pipe path for audio output |

**Custom service name:** Set `AIRPLAY_NAME` in `.env` to override the default hostname-based name:
```bash
AIRPLAY_NAME="Living Room AirPlay"
```

**Sample format:** 44100:16:2 (fixed by shairport-sync)

**Connect from iOS/macOS:**
1. Open **Control Center**
2. Tap **AirPlay** icon
3. Select **"snapMULTI"**

**Verify visibility:**
```bash
avahi-browse -r _raop._tcp --terminate
```

**Docker requirements:** Host network mode for mDNS. Shared `/audio` volume with snapserver.

---

### 4. Spotify Connect (pipe from librespot)

The librespot container acts as a Spotify Connect receiver and writes raw PCM to a named pipe. Snapserver reads from the pipe.

**Config:**
```ini
source = pipe:////audio/spotify_fifo?name=Spotify
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `Spotify` | Stream ID |

**librespot container settings** (Dockerfile.librespot CMD):

| Flag | Value | Description |
|------|-------|-------------|
| `--name` | `$(hostname) Spotify` | Name shown in Spotify app (hostname-based) |
| `--bitrate` | `320` | Audio quality: 96, 160, or 320 kbps |
| `--backend` | `pipe` | Output to named pipe |
| `--device` | `/audio/spotify_fifo` | Named pipe path for audio output |

**Custom service name:** Set `SPOTIFY_NAME` in `.env` to override the default hostname-based name:
```bash
SPOTIFY_NAME="Living Room Spotify"
```

**Sample format:** 44100:16:2 (fixed by librespot)

**Requirements:** Spotify Premium account (free tier not supported).

**Connect from Spotify:**
1. Open **Spotify** on any device
2. Start playing a song
3. Tap **Connect to a device**
4. Select **"snapMULTI"**

---

### 5. Tidal (via tidal-bridge)

Native Tidal streaming using [tidalapi](https://github.com/EbbLabs/python-tidal). Fetches stream URLs from Tidal's API and pipes decoded audio to snapserver's TCP input.

**Requirements:** Tidal subscription (HiFi or HiFi+)

**Architecture:**
```
Tidal API → tidalapi → stream URL → ffmpeg → PCM (s16le 48kHz) → snapserver TCP :4953
```

**First-time setup (OAuth authentication):**
```bash
# One-time login (opens browser for Tidal OAuth)
docker compose --profile tidal run --rm tidal login

# Session saved to ./tidal/tidal-session.json
```

**Play music:**
```bash
# Play a track by URL
docker compose --profile tidal run --rm tidal play https://tidal.com/browse/track/12345678

# Play an album
docker compose --profile tidal run --rm tidal play album:77646169

# Play a playlist
docker compose --profile tidal run --rm tidal play playlist:uuid-here

# Search for content
docker compose --profile tidal run --rm tidal search "pink floyd"
```

**Quality settings:**

| Quality | Format | Subscription |
|---------|--------|--------------|
| `low_96k` | M4A 96 kbps | Any |
| `low_320k` | M4A 320 kbps | Any |
| `high_lossless` | FLAC lossless | HiFi |
| `hi_res_lossless` | FLAC 24-bit/192kHz | HiFi+ |

Set quality in `.env`:
```bash
TIDAL_QUALITY=high_lossless
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `TIDAL_SESSION_FILE` | `/config/tidal-session.json` | Session file path |
| `TIDAL_QUALITY` | `high_lossless` | Audio quality |
| `SNAPSERVER_HOST` | `127.0.0.1` | Snapserver hostname |
| `SNAPSERVER_PORT` | `4953` | TCP input port |

**Notes:**
- Uses existing TCP-Input source (port 4953) — no snapserver config changes needed
- No "cast" UX like Spotify Connect — playback is CLI-driven
- Session tokens refresh automatically; re-login if expired
- Optional service — pull image manually: `docker compose --profile tidal pull tidal`

---

## Available Sources

These sources are included as commented-out examples in `config/snapserver.conf`. Uncomment to enable.

### 6. ALSA Capture (alsa)

Captures audio from an ALSA hardware device. Use for line-in inputs, microphones, or ALSA loopback devices.

**Config:**
```ini
source = alsa:///?name=LineIn&device=hw:0,0
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `LineIn` | Stream ID |
| `device` | `hw:0,0` | ALSA device identifier |
| `idle_threshold` | `100` (default) | Switch to idle after N ms of silence |
| `silence_threshold_percent` | `0.0` (default) | Amplitude threshold for silence detection |
| `send_silence` | `false` (default) | Send audio when stream is idle |

**Use cases:**
- Vinyl turntable or FM radio via audio interface
- Microphone input for announcements
- ALSA loopback device to capture desktop audio

**Docker requirements:**
```yaml
# Add to docker-compose.yml snapserver service:
devices:
  - /dev/snd:/dev/snd
```

**List available ALSA devices:**
```bash
docker exec snapserver cat /proc/asound/cards
```

---

### 7. Meta Stream (meta)

Reads and mixes audio from other stream sources with priority-based switching. Plays audio from the highest-priority active source.

**Config:**
```ini
source = meta:///MPD/Spotify/AirPlay?name=AutoSwitch
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `AutoSwitch` | Stream ID |
| Sources | `MPD/Spotify/AirPlay` | Priority order (left = highest) |

**How priority works:**
- Sources are listed left-to-right, highest priority first
- When a higher-priority source becomes active, it takes over
- When it stops, the next active source plays
- Example: `meta:///Spotify/AirPlay/MPD` — Spotify overrides AirPlay, AirPlay overrides MPD

**Use cases:**
- Auto-switch to Spotify when someone starts casting, fall back to MPD
- Combine doorbell alerts (highest priority) with background music (lowest)
- Create a "smart" stream that plays whatever source is active

**Tip:** Use `codec=null` on sources that serve only as meta inputs to save encoding overhead.

---

### 8. File Playback (file)

Reads raw PCM audio from a file. Useful for alerts, doorbell sounds, or TTS announcements.

**Config:**
```ini
source = file:///audio/alert.pcm?name=Alert
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `Alert` | Stream ID |
| Path | `/audio/alert.pcm` | Absolute path to PCM file |

**Sample format:** Must match global `sampleformat` (44100:16:2 by default).

**Create a PCM file from any audio:**
```bash
ffmpeg -i doorbell.mp3 \
  -f s16le -ar 44100 -ac 2 \
  /path/to/audio/alert.pcm
```

**Use cases:**
- Doorbell or alarm sounds
- Text-to-speech announcements (generate PCM via `espeak` or cloud TTS)
- Pre-recorded messages

**Docker requirements:** The PCM file must be accessible inside the container via the `/audio` volume mount.

---

### 9. TCP Client (tcp client)

Connects to a remote TCP server to receive audio. The inverse of TCP server mode — Snapserver pulls audio from a remote source.

**Config:**
```ini
source = tcp://192.168.1.100:4953?name=Remote&mode=client
```

**Parameters:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `name` | `Remote` | Stream ID |
| `mode` | `client` | Snapserver connects to the remote host |
| Host | `192.168.1.100` | IP of the remote audio source |
| Port | `4953` | Port to connect to |

**Sample format:** 44100:16:2 (must match remote source).

**Use cases:**
- Pull audio from another Snapserver or audio source on the network
- Chain multiple servers together
- Receive audio from a dedicated streaming appliance

---

## Streaming from Android

Android doesn't have a built-in equivalent of Apple's AirPlay for audio casting to arbitrary receivers. Here are the methods to stream audio from Android apps to snapMULTI.

> **Note:** For Tidal specifically, consider using the [native Tidal integration](#5-tidal-via-tidal-bridge) instead of these workarounds. It provides better audio quality and doesn't require an Android device as intermediary.

### Method 1: TCP Input via BubbleUPnP

[BubbleUPnP](https://play.google.com/store/apps/details?id=com.bubblesoft.android.bubbleupnp) has an **Audio Cast** feature that captures audio output from any Android app and streams it over the network.

**Setup:**
1. Install **BubbleUPnP** from Google Play
2. Open BubbleUPnP, go to **Settings > Audio Cast**
3. Configure output to stream raw PCM audio
4. On a machine with `ffmpeg`, set up a relay to forward to snapMULTI:

```bash
# Relay audio from BubbleUPnP (UPnP renderer) to Snapcast TCP input
# Run on a machine that acts as a UPnP/DLNA renderer
ffmpeg -i <upnp-audio-stream> \
  -f s16le -ar 44100 -ac 2 \
  tcp://<snapmulti-server-ip>:4953
```

**Stream any app (including Tidal):**
1. Open any audio app on Android, start playing music
2. Open **BubbleUPnP**, use Audio Cast to capture the app's output
3. Audio is relayed to snapMULTI via TCP Input
4. All Snapcast clients receive the stream

> **For Tidal specifically:** Use the [native Tidal integration](#5-tidal-via-tidal-bridge) instead — better quality, no Android device required.

### Method 2: AirPlay from Android

Several Android apps can emulate AirPlay sending, allowing you to use the existing AirPlay source.

**Apps:**
- **AirMusic** — Streams Android audio to AirPlay receivers
- **AllStream** — Captures system audio and casts via AirPlay

**Setup:**
1. Install an AirPlay sender app
2. Select **"snapMULTI"** as the AirPlay target
3. Play Tidal (or any app) — audio routes through AirPlay to Snapcast

### Method 3: Direct TCP Streaming

For apps that can output raw audio (or with a local `ffmpeg` relay):

```bash
# On Android (via Termux) or a relay machine:
ffmpeg -f pulse -i default \
  -f s16le -ar 44100 -ac 2 \
  tcp://<snapmulti-server-ip>:4953
```

This captures all system audio and sends it to the TCP Input source.

### Comparison

| Method | App Needed | Tidal Support | Audio Quality | Complexity |
|--------|-----------|---------------|---------------|------------|
| BubbleUPnP | BubbleUPnP | Yes | Good (depends on relay) | Medium |
| AirPlay app | AirMusic / AllStream | Yes (any app) | Good (44100:16:2) | Low |
| Direct TCP | Termux + ffmpeg | Yes (system audio) | Lossless (44100:16:2) | High |

---

## JSON-RPC API Reference

Snapserver exposes a JSON-RPC API on port 1780 (HTTP) and port 1705 (TCP). Use these endpoints to manage sources programmatically from a management app.

**Base URL:** `http://<server-ip>:1780/jsonrpc`

### List All Streams

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  | jq '.result.server.streams'
```

**Response fields per stream:**

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Stream ID (e.g. `"MPD"`, `"Spotify"`) |
| `status` | string | `"playing"`, `"idle"`, or `"unknown"` |
| `uri` | object | Source URI and parameters |
| `properties` | object | Metadata (name, codec, sample format) |

### Switch a Group to a Different Stream

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Group.SetStream",
    "params":{"id":"<GROUP_ID>","stream_id":"Spotify"}
  }'
```

### Add a Stream at Runtime

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Stream.AddStream",
    "params":{"streamUri":"tcp://0.0.0.0:5000?name=NewStream&mode=server"}
  }'
```

### Remove a Stream at Runtime

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Stream.RemoveStream",
    "params":{"id":"NewStream"}
  }'
```

### Set Client Volume

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{
    "id":1,
    "jsonrpc":"2.0",
    "method":"Client.SetVolume",
    "params":{"id":"<CLIENT_ID>","volume":{"muted":false,"percent":80}}
  }'
```

### Get Server Status (full)

```bash
curl -s http://<server-ip>:1780/jsonrpc \
  -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}' \
  | jq '.'
```

Returns: all groups, clients, streams, and server info.

---

## Source Type Schema

Machine-readable reference for each source type. Use this to build configuration UIs or management APIs.

### pipe

| Property | Value |
|----------|-------|
| **Format** | `pipe:///<path>?name=<id>[&mode=create]` |
| **Required binaries** | None |
| **Docker requirements** | Volume mount for FIFO path |
| **Sample format** | Configurable (default: global) |
| **Parameters** | `name` (required), `mode` (create\|read), `controlscript` (optional) |

### tcp

| Property | Value |
|----------|-------|
| **Format (server)** | `tcp://<bind>:<port>?name=<id>&mode=server` |
| **Format (client)** | `tcp://<host>:<port>?name=<id>&mode=client` |
| **Required binaries** | None |
| **Docker requirements** | Port exposed (server mode) |
| **Sample format** | Configurable (default: global) |
| **Parameters** | `name` (required), `mode` (server\|client), `port` |

### airplay (not used — snapMULTI uses pipe instead)

Snapcast's built-in `airplay://` source type launches shairport-sync as a child process. snapMULTI runs shairport-sync in a separate container and uses `pipe://` to read its output.

| Property | Value |
|----------|-------|
| **Format** | `airplay:///<binary>?name=<id>&devicename=<name>[&port=5000]` |
| **Required binaries** | `shairport-sync` (in same container) |
| **Docker requirements** | Host network + D-Bus socket + Avahi |
| **Sample format** | 44100:16:2 (fixed) |
| **Parameters** | `name`, `devicename`, `port` (5000\|7000), `password` |

### librespot (not used — snapMULTI uses pipe instead)

Snapcast's built-in `librespot://` source type launches librespot as a child process. snapMULTI runs librespot in a separate container and uses `pipe://` to read its output.

| Property | Value |
|----------|-------|
| **Format** | `librespot:///<binary>?name=<id>&devicename=<name>[&bitrate=320]` |
| **Required binaries** | `librespot` (in same container) |
| **Docker requirements** | Network access for Spotify API |
| **Sample format** | 44100:16:2 (fixed) |
| **Parameters** | `name`, `devicename`, `bitrate` (96\|160\|320), `volume`, `normalize`, `username`, `password`, `cache`, `killall` |

### alsa

| Property | Value |
|----------|-------|
| **Format** | `alsa:///?name=<id>&device=<alsa-device>` |
| **Required binaries** | None (uses ALSA lib) |
| **Docker requirements** | `devices: [/dev/snd:/dev/snd]` |
| **Sample format** | Configurable (default: global) |
| **Parameters** | `name`, `device` (e.g. hw:0,0), `idle_threshold`, `silence_threshold_percent`, `send_silence` |

### meta

| Property | Value |
|----------|-------|
| **Format** | `meta:///<source1>/<source2>/...?name=<id>` |
| **Required binaries** | None |
| **Docker requirements** | None |
| **Sample format** | Matches input sources |
| **Parameters** | `name`, source list (by stream ID, `/`-separated, left=highest priority) |

### file

| Property | Value |
|----------|-------|
| **Format** | `file:///<path>?name=<id>` |
| **Required binaries** | None |
| **Docker requirements** | Volume mount for file path |
| **Sample format** | Must match global sampleformat |
| **Parameters** | `name`, file path |

### Global Parameters (all source types)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `codec` | `flac` | Encoding: flac, ogg, opus, pcm |
| `sampleformat` | (global) | Format: `<rate>:<bits>:<channels>` |
| `chunk_ms` | (auto) | Read chunk size in ms |
| `controlscript` | — | Path to metadata/control script |
