# Client metadata integration guide

> **For the architectural rationale** (why the metadata pipeline is centralized server-side, trade-offs, cover-art lookup chain), see [`docs/adr/ADR-004.metadata-architecture.md`](adr/ADR-004.metadata-architecture.md). This file is the operational integration contract; the ADR is the frozen decision record.

How to write a client (UI, mobile app, kiosk display, secondary controller)
that consumes snapMULTI's metadata pipeline correctly. Drop this file into
the context of whatever AI coding assistant or human contributor is working
on the client.

You are writing a client for snapMULTI, a multiroom audio appliance built on
Snapcast. Your job is to present "now playing" + cover art + transport controls.

snapMULTI exposes two cooperating services on the server host:

```
Snapserver       http://<SERVER>:1780/jsonrpc  authoritative Snapcast state/control
Metadata-service ws://<SERVER>:8082            live metadata push (full snapshots, not deltas)
                 http://<SERVER>:8083          metadata snapshot + artwork bytes
```

`<SERVER>` is the hostname/IP/FQDN the user gave you, or the host resolved from
`_snapcast._tcp.local`. Never hardcode an IP. Never assume `.local` works.

## Required protocol

1. On startup, open:

   ```
   ws://<SERVER>:8082
   ```

   Then subscribe using ONE of these forms.

   Follow a Snapcast client/room (includes volume/muted):

   ```json
   {"subscribe":"<snapcast-client-id-or-hostname>"}
   ```

   Follow one stream directly (no volume/muted):

   ```json
   {"subscribe_stream":"Tidal"}
   ```

   Valid stream examples: `"MPD"`, `"Spotify"`, `"AirPlay"`, `"Tidal"`. To
   enumerate the streams actually configured on this server, call
   `Server.GetStatus` on Snapserver and read `streams[].id`.

2. Seed initial state. The seed strategy depends on which subscription form
   you used in step 1.

   **Stream-bound UI** (you sent `{"subscribe_stream":"Tidal"}`): seed via HTTP
   on the same stream. This is reliable because the query parameter pins the
   answer to the stream you actually care about.

   ```
   GET http://<SERVER>:8083/metadata.json?stream=Tidal
   ```

   **Client/room-bound UI** (you sent `{"subscribe":"<client-id>"}`): the WS
   IS the source of truth — it tracks the room's currently-assigned stream
   AND keeps it correct when an operator reassigns the room. An HTTP fetch
   here is best-effort only:

   ```
   GET http://<SERVER>:8083/metadata.json       # no ?stream
   ```

   Without `?stream=...` the service returns the first playing stream, or
   the first known stream — which is NOT necessarily the stream assigned to
   your client. For client-bound subscriptions, prefer rendering nothing for
   the first ~200 ms (or a brief "connecting…" state) until the first WS
   message arrives, instead of risking a flash of wrong-room metadata.

3. On every WebSocket metadata message, treat it as a complete metadata
   snapshot for that subscription, not as a partial delta. Replace your
   local now-playing state with the received object.

   Special case: messages with `"type":"server_info"` are server status
   messages, not track metadata. Handle them separately.

4. On WebSocket disconnect, reconnect with exponential backoff (start 1 s,
   cap 30 s). After reconnect, resubscribe and repeat the HTTP seed request.

## Metadata shape

Example — an **MPD** payload, which carries the full set of keys (streaming
sources omit `track` / `disc` / `bitrate`, see below):

```json
{
  "playing": true,
  "stream_id": "MPD",
  "source": "MPD",
  "title": "Malibu",
  "artist": "Hole",
  "album": "Celebrity Skin",
  "artwork": "http://<server>:8083/artwork/artwork_<md5>.jpg",
  "artwork_source": "musicbrainz",
  "artist_image": "http://<server>:8083/artwork/artwork_<md5>.jpg",
  "codec": "FLAC",
  "sample_rate": 44100,
  "bit_depth": 16,
  "bitrate": 1411,
  "elapsed": 15,
  "duration": 230,
  "date": "1998-09-02",
  "original_date": "1998-09-02",
  "genre": "rock",
  "track": "3",
  "disc": "1",
  "volume": 72,
  "muted": false
}
```

`volume` and `muted` are present only when subscribing with `{"subscribe":...}`,
because they are client/room-specific. They are not present when using
`{"subscribe_stream":...}`.

`date`, `track`, `disc` and `bitrate` are **source-dependent**: the MPD source
populates all four from the file's tags. Streaming sources (Tidal / AirPlay /
Spotify) never populate `track`, `disc`, or `bitrate` — these keys are **absent
from the payload entirely** for those sources, not empty or zero. Read them with
a default (e.g. `payload.get("bitrate", 0)`), never `payload["bitrate"]`. `date`
may still be filled in via MusicBrainz enrichment for any source; `original_date`
is the original-release date when a separate tag exists — often equal to `date`
(an MPD file without an `OriginalDate` tag reports its `date` here).

The `artwork` / `artist_image` URLs embed the server hostname as the
metadata-service sees itself. If the client lives on a different network
segment and that hostname does not resolve there, rewrite the host portion
of the URL to the `<SERVER>` you connected to. Do not change the path.

## Missing fields

Fields may be missing, empty, or null.

- `artwork` — artwork lookup may still be pending. Text metadata is
  pushed as soon as the track changes, with `"artwork": ""` while the
  cover lookup runs in the background; a second message carries the
  `artwork` URL (and any enriched `date` / `genre`) when the lookup
  finishes — usually well under a second for cached art, up to tens of
  seconds on a slow internet link.
- `artist_image` — optional fallback image.
- `elapsed` / `duration` — not all streams expose a timeline.
- `date`, `original_date`, `genre`, `artwork_source` — informational only.
- `track`, `disc`, `bitrate` — MPD-only; absent entirely on streaming sources.

For AirPlay and Tidal specifically, `elapsed` may be **absent** even on
a playing stream when metadata-service was restarted while a track was
already in progress. There is no native position API for these sources,
so the service can only estimate elapsed by counting from the moment it
first observed the track. If it boots mid-track, it has no anchor for
"track start" and would emit a wrong value — so it omits the field
entirely. This applies to the first track the service sees on each
stream after it starts, however soon after startup that is. Clients
should render that as "elapsed unknown" (e.g. an indeterminate progress
bar or `--:--`), not 0:00. The field reappears on the next track change. MPD and Spotify never hit this case because
they report position natively.

If `playing: false`, keep the last-known metadata visible if useful, but show
the transport/playback state as idle.

## Artwork rules

Use the `artwork` URL exactly as provided. Do not build artwork URLs from
artist/title/album.

Artwork URLs are hash-named:

```
/artwork/artwork_<md5>.jpg
```

Same URL means same bytes. If artwork changes, the URL changes.

Fallback order:

```
artwork -> artist_image -> bundled placeholder
```

On 404 for artwork, treat it as transient: retry once after 500 ms, then
fall back.

### Source-specific artwork notes

For every source the `artwork` URL points to the metadata-service cache
at `http://<SERVER>:8083/artwork/artwork_<md5>.<ext>`. The service tries,
in order: the source's own cover (Snapcast `artUrl`), embedded art (MPD
files), MusicBrainz / Cover Art Archive, iTunes, the Radio-Browser logo
and default placeholder (radio only), then the artist photo. If a
download fails (timeout, 404) the next step is tried; failures are
retried after a few minutes rather than never.

- **MPD**: embedded cover art first, then the MusicBrainz → iTunes
  lookup from the file's artist/album tags.
- **Spotify**: the cover URL supplied by go-librespot, re-hosted on
  `:8083`; MusicBrainz → iTunes if it cannot be downloaded.
- **Tidal**: the Tidal binary exposes no artwork, so the cover comes
  from the MusicBrainz → iTunes lookup on artist/album. It can be
  missing for releases those services don't know; fall back to
  `artist_image` or the bundled placeholder.
- **AirPlay**: the cover sent by the AirPlay sender is decoded by
  `meta_shairport.py`, fetched by the metadata-service from
  meta_shairport's internal server (`:5858/cover.jpg?v=<n>`, one URL per
  picture) and re-hosted on `:8083`. Clients never need to reach port
  5858. On a track change the text arrives first and the cover follows
  as soon as the sender delivers the picture; a track without a picture
  goes through the lookup chain above. Operators on multi-NIC, VPN or
  sandboxed hosts can set `COVER_ART_HOST` (snapserver container, via
  `.env`) to the address the metadata-service should use to reach
  meta_shairport.

## Transport control

For a new client, use Snapserver as the authoritative control API:

```
POST http://<SERVER>:1780/jsonrpc
```

Use `Server.GetStatus` to inspect groups, streams, clients, and stream
properties.

Before showing play/pause/next controls, check the stream properties:

```
properties.canControl
properties.canPlay
properties.canPause
properties.canGoNext
properties.canGoPrevious
properties.canSeek
```

Many streams are controlled by their native app and may report
`canControl: false` or individual capabilities as false.

Concrete examples from the snapMULTI sources:

- **MPD**: `canControl: true`, `canSeek: true`, `canPlay/Pause/GoNext/GoPrevious: true`. Full transport supported.
- **Spotify** (`meta_go-librespot.py`): `canControl: true`. Play/pause/next/previous/seek all bidirectional.
- **AirPlay** (`meta_shairport.py`): `canControl: false`, every `can*` false. The AirPlay sender (iPhone/Mac) is the only control surface; hide transport controls.
- **Tidal** (`meta_tidal.py`): `canControl: false` always. The Tidal source uses a proprietary binary whose control surface is the Tidal mobile/desktop app — there is no API the controlscript can call back into. Clients MUST hide play/pause/next/previous controls when the active stream is Tidal, otherwise tapping them does nothing and confuses the user.

Volume is client-specific. Use Snapcast client/group state from
`Server.GetStatus` and Snapcast JSON-RPC methods for volume changes.

The metadata-service also has limited legacy control support over its
WebSocket for subscribed clients (`{"cmd":"toggle_play"}`,
`{"cmd":"volume","delta":N}`), but new clients should prefer Snapserver
JSON-RPC for explicit control behavior. `toggle_play` sends `playPause`
(`Stream.Control`) to the stream the client's group is playing, and is
ignored for streams that don't advertise control (AirPlay, Tidal).

### Server.GetStatus response shape (subset)

```json
{
  "result": {
    "server": {
      "groups": [
        {
          "id": "<uuid>",
          "name": "",
          "muted": false,
          "stream_id": "Tidal",
          "clients": [
            {
              "id": "snapclient-<host>",
              "connected": true,
              "host": { "ip": "...", "mac": "...", "name": "<host>", "os": "..." },
              "config": { "volume": { "muted": false, "percent": 100 }, "latency": 0 }
            }
          ]
        }
      ],
      "streams": [
        {
          "id": "Tidal",
          "status": "playing",
          "properties": {
            "playbackStatus": "playing",
            "canControl": false, "canPlay": false, "canPause": false,
            "canGoNext": false, "canGoPrevious": false, "canSeek": false,
            "metadata": { "title": "...", "artist": ["..."], "album": "...", "duration": 230.0 }
          }
        }
      ]
    }
  }
}
```

Note: `properties.metadata.artist` is a JSON array, not a string. The
`/metadata.json` endpoint of the metadata-service flattens it to a string —
do not assume one is the other.

### JSON-RPC methods you will use

```
Server.GetStatus                            full snapshot
Stream.Control      { id, command }         command in { play, pause, playPause, next, previous, stop, seek }
Stream.SetProperty  { id, property, value } typically `shuffle`, `loopStatus`, `volume`
Group.SetStream     { id, stream_id }       move a room to a different source
Group.SetMute       { id, mute }            mute a whole room
Group.SetClients    { id, clients: [...] }  reassign clients to a group
Client.SetVolume    { id, volume }          volume = { percent: 0..100, muted: bool }
Client.SetLatency   { id, latency }
Client.SetName      { id, name }
```

All take a JSON-RPC envelope: `{"jsonrpc":"2.0","id":<n>,"method":"...","params":{...}}`.

### End-to-end client sequence (pseudocode)

```
server      = user_input  or  mdns_resolve("_snapcast._tcp.local")
status      = http_post("http://" + server + ":1780/jsonrpc",
                        { method: "Server.GetStatus", id: 1 })

stream_id   = pick_stream(status)        // e.g. group's stream_id, or user choice
seed        = http_get("http://" + server + ":8083/metadata.json?stream=" + stream_id)
render(seed)

ws = ws_open("ws://" + server + ":8082")
ws.send({ subscribe_stream: stream_id })  // or { subscribe: client_id }

on ws.message(msg):
    if msg.type == "server_info":  update_server_status(msg); continue
    render(msg)                    // complete snapshot, not delta
    if msg.artwork != last_artwork:
        prefetch(msg.artwork)      // optional, lets the renderer avoid a flash
        last_artwork = msg.artwork

on ws.close():
    backoff_sleep()
    goto reconnect (resubscribe + re-seed)
```

## Do not do

- Do not poll `/metadata.json` on a timer for live updates.
- Do not refetch cover art on every WebSocket message.
- Do not assume artwork is ready at the same moment title/artist changes.
- Do not assume `.local` resolution exists.
- Do not scrape MPD, Spotify, Tidal, AirPlay, or Snapserver internals
  directly for now-playing data.
- Do not treat `server_info` messages as track metadata.

## Error handling

- WS close: reconnect with backoff and resubscribe.
- `/metadata.json` 5xx: keep last-known state and retry on next push/reconnect.
- Artwork 404: retry once after 500 ms, then fallback.
- Unknown stream/client: show disconnected/idle state and keep retrying.

## Discovery

The server publishes `_snapcast._tcp` on mDNS. On a platform with mDNS
support, use it to locate `<SERVER>`. On platforms without it (some Android
versions, some Linux distros without `avahi-daemon`, some corporate Wi-Fi)
the user must enter the server hostname or IP manually.
