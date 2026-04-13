# Data Models

## Metadata Message (WebSocket)

The centralized metadata service pushes JSON messages to subscribed clients via WebSocket (port 8082).

### Subscription Request

```json
{"subscribe": "snapclient-<hostname>"}
```

### Track Update Message

```json
{
  "source": "MPD",
  "title": "Bohemian Rhapsody",
  "artist": "Queen",
  "album": "A Night at the Opera",
  "date": "2011-01-01",
  "original_date": "1975-11-21",
  "duration": 354.0,
  "elapsed": 42.5,
  "playing": true,
  "codec": "flac",
  "sample_rate": 44100,
  "bit_depth": 16,
  "artwork": "/artwork/queen_a_night_at_the_opera.jpg",
  "volume": 80,
  "muted": false
}
```

### Field Reference

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `source` | string | Audio source name | `"MPD"`, `"Spotify"`, `"AirPlay"`, `"Tidal"` |
| `title` | string | Track title | `"Bohemian Rhapsody"` |
| `artist` | string | Artist name | `"Queen"` |
| `album` | string | Album name | `"A Night at the Opera"` |
| `date` | string | Release date for the current edition when known | `"2011-01-01"` |
| `original_date` | string | First/original release date when known; clients should prefer this over `date` for display | `"1975-11-21"` |
| `duration` | float | Track duration in seconds (0 for streams) | `354.0` |
| `elapsed` | float | Current playback position in seconds | `42.5` |
| `playing` | bool | Whether audio is currently playing | `true`, `false` |
| `codec` | string | Audio codec | `"flac"`, `"mp3"`, `"aac"`, `"opus"` |
| `sample_rate` | int | Sample rate in Hz | `44100`, `96000` |
| `bit_depth` | int | Bit depth | `16`, `24` |
| `artwork` | string | Relative URL for cover art | `"/artwork/abc123.jpg"` |
| `volume` | int | Client volume level (0-100) | `80` |
| `muted` | bool | Whether client output is muted | `false` |

### Cover Art (HTTP)

Cover art is fetched from `http://<METADATA_HOST>:8083<artwork>`.

Source priority (server-side):
1. Embedded art (from local files via MPD)
2. iTunes Search API (free, no key)
3. MusicBrainz Cover Art Archive (rate-limited 1 req/s)
4. Radio-Browser API (for radio streams)

### Server Info Message

The metadata service also broadcasts server identity. fb-display uses this to show the server version in the status line.

```json
{"type": "server_info", "server_version": "0.3.14"}
```

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `type` | string | Message discriminator (always `"server_info"`) | `"server_info"` |
| `server_version` | string | snapMULTI server version | `"0.3.14"` |

This message does not update track metadata — it triggers a status bar redraw only.

## Spectrum Data (WebSocket)

The audio-visualizer broadcasts spectrum data via WebSocket (port 8081).

### Spectrum Frame

The audio-visualizer broadcasts raw dBFS values as a semicolon-delimited string (not JSON):

```
-45.2;-38.7;-32.1;-28.5;-19.3;-15.1;...
```

Each value is a float dBFS level for one frequency band. The number of values determines the band count (21 or 31). fb-display auto-detects the band count from the first message received.

### Band Modes

| Mode | Bands | Range | Standard |
|------|-------|-------|----------|
| `third-octave` | 31 | 20 Hz – 20 kHz | ISO 266 |
| `half-octave` | 21 | 20 Hz – 20 kHz | — |

Band count is auto-detected by fb-display from the first WebSocket message received.

## Display Layout

The `compute_layout()` function returns a dictionary describing the render layout:

| Key | Type | Description |
|-----|------|-------------|
| `art_x`, `art_y` | int | Album art top-left position |
| `art_size` | int | Album art square dimension |
| `right_x`, `right_w` | int | Info panel position and width |
| `spec_y`, `spec_h` | int | Spectrum area top and height |
| `bar_w`, `bar_gap` | int | Spectrum bar width and gap |
| `pad` | int | General padding |
| `start_x` | int | Content area left edge |
| `container_w` | int | Content area width |
| `bottom_y` | int | Bottom bar top edge |

## Audio HAT Configuration

Each `.conf` file in `common/audio-hats/` defines:

```bash
HAT_OVERLAY="hifiberry-dacplus-std"  # Device tree overlay name
HAT_CARD_NAME="sndrpihifiberry"      # ALSA card name
HAT_RATE="48000"                     # DAC native max rate (informational)
```

## Environment Variables

### Core Configuration (`.env`)

| Variable | Default | Used By | Description |
|----------|---------|---------|-------------|
| `SNAPSERVER_HOST` | (empty = mDNS) | snapclient, fb-display | Server IP or hostname |
| `SNAPSERVER_PORT` | `1704` | snapclient | Snapcast streaming port |
| `CLIENT_ID` | `snapclient-<hostname>` | snapclient, fb-display | Unique client identifier |
| `SOUNDCARD` | `default` | snapclient | ALSA output device |
| `MIXER` | `software` | snapclient | Mixer mode (software/hardware/none) |
| `SAMPLE_RATE` | `44100` | audio-visualizer | Must match Snapserver (44100 Hz) |
| `BAND_MODE` | `third-octave` | audio-visualizer | Spectrum band resolution |
| `DISPLAY_RESOLUTION` | (empty = auto) | fb-display | Override render resolution |
| `COMPOSE_PROFILES` | (empty) | docker-compose | Set to `framebuffer` for display |
| `ENABLE_READONLY` | `true` | setup.sh | Read-only root filesystem |
| `ALSA_BUFFER_TIME` | `150` (Ethernet), `250` (WiFi) | snapclient | ALSA buffer time in ms (50–2000) |
| `ALSA_FRAGMENTS` | `4` (Ethernet), `8` (WiFi) | snapclient | ALSA buffer fragments (2–16) |
| `CONNECTION_TYPE` | `auto` | setup.sh | Network type: `auto`, `ethernet`, `wifi` |
| `APP_VERSION` | (empty → git tag) | fb-display | Client version shown in status line |

### Derived Variables (set by docker-compose.yml)

| Variable | Source | Used By |
|----------|--------|---------|
| `METADATA_HOST` | `${SNAPSERVER_HOST:-localhost}` | fb-display |
| `METADATA_WS_PORT` | `8082` (hardcoded) | fb-display |
| `METADATA_HTTP_PORT` | `8083` (hardcoded) | fb-display |
| `VISUALIZER_WS_PORT` | `8081` (hardcoded) | audio-visualizer, fb-display |
