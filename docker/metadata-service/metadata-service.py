#!/usr/bin/env python3
"""
snapMULTI Metadata Service (Server-side)

Centralized metadata + cover art service that runs on the server alongside Snapcast.
- Monitors ALL active streams via Snapserver JSON-RPC
- Fetches cover art from MPD (embedded), iTunes, MusicBrainz, Radio-Browser
- Serves artwork via built-in HTTP server (port 8083)
- Pushes metadata to display clients via WebSocket (port 8082)
- Clients subscribe by sending {"subscribe": "CLIENT_ID"} to get their stream's metadata

Replaces per-client metadata-service containers — N clients no longer make N redundant API calls.
"""

import asyncio
import collections
import hashlib
import html
import ipaddress
import json
import logging
import os
import socket
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import websockets
from aiohttp import web

_MAX_CACHE_ENTRIES = 500

# Configuration
WS_PORT = int(os.environ.get("METADATA_WS_PORT", "8082"))
HTTP_PORT = int(os.environ.get("METADATA_HTTP_PORT", "8083"))
SNAPSERVER_HOST = os.environ.get("SNAPSERVER_HOST", "127.0.0.1")
SNAPSERVER_RPC_PORT = int(os.environ.get("SNAPSERVER_RPC_PORT", "1705"))
MPD_HOST = os.environ.get("MPD_HOST", "127.0.0.1")
MPD_PORT = int(os.environ.get("MPD_PORT", "6600"))
ARTWORK_DIR = Path(os.environ.get("ARTWORK_DIR", "/app/artwork"))
DEFAULTS_DIR = Path(os.environ.get("DEFAULTS_DIR", "/app/defaults"))

# External hostname for artwork URLs sent to remote clients.
# SNAPSERVER_HOST may be 127.0.0.1 (for local socket connections),
# but artwork URLs must use a host reachable by clients on the network.
EXTERNAL_HOST = os.environ.get("EXTERNAL_HOST", "") or socket.getfqdn() or SNAPSERVER_HOST

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("metadata-service")


class StreamMetadata:
    """Metadata state for a single stream."""

    def __init__(self, stream_id: str) -> None:
        self.stream_id = stream_id
        self.current: dict[str, Any] = {}


class SubscribedClient:
    """A WebSocket client subscribed to a specific CLIENT_ID."""

    def __init__(self, websocket: Any, client_id: str) -> None:
        self.websocket = websocket
        self.client_id = client_id
        self.stream_id: str | None = None  # Resolved from Snapserver


# Global state
ws_clients: set[SubscribedClient] = set()
_service: "MetadataService | None" = None


class MetadataService:
    """Centralized metadata service for all Snapcast streams."""

    def __init__(self) -> None:
        self.snapserver_host = SNAPSERVER_HOST
        self.snapserver_port = SNAPSERVER_RPC_PORT
        self.mpd_host = MPD_HOST
        self.mpd_port = MPD_PORT
        self.artwork_dir = ARTWORK_DIR
        self.artwork_dir.mkdir(parents=True, exist_ok=True)

        # Per-stream metadata state
        self.streams: dict[str, StreamMetadata] = {}

        # Caches (shared across all streams — same album art doesn't need re-fetch)
        # Bounded to _MAX_CACHE_ENTRIES to prevent unbounded memory growth
        self.artwork_cache: collections.OrderedDict[str, str] = collections.OrderedDict()
        self.artist_image_cache: collections.OrderedDict[str, str] = collections.OrderedDict()
        self._failed_downloads: collections.OrderedDict[str, None] = collections.OrderedDict()

        self._cache_limit = _MAX_CACHE_ENTRIES

        # Snapserver persistent socket
        self._snap_sock: socket.socket | None = None
        self._snap_buffer: bytes = b""
        self._snap_lock = threading.Lock()
        self._last_snap_response: float = 0.0
        self._snap_stale_threshold: float = 30.0

        self._mpd_was_connected = False
        self.user_agent = "snapMULTI-MetadataService/1.0"

        # Client → stream mapping cache (refreshed each poll cycle)
        self._client_stream_map: dict[str, str] = {}

    @staticmethod
    def _cache_set(cache: collections.OrderedDict, key: str, value: str,
                   limit: int = _MAX_CACHE_ENTRIES) -> None:
        """Set a cache entry, evicting oldest if at capacity."""
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > limit:
            cache.popitem(last=False)

    def _mark_failed(self, url: str) -> None:
        """Record a failed download URL, bounded to _MAX_CACHE_ENTRIES."""
        self._failed_downloads[url] = None
        self._failed_downloads.move_to_end(url)
        while len(self._failed_downloads) > self._cache_limit:
            self._failed_downloads.popitem(last=False)

    # ──────────────────────────────────────────────
    # Socket helpers
    # ──────────────────────────────────────────────

    def _create_socket(self, host: str, port: int, timeout: int = 5,
                       log_errors: bool = True) -> socket.socket | None:
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((host, port))
            return sock
        except Exception as e:
            if log_errors:
                logger.error(f"Failed to connect to {host}:{port}: {e}")
            return None

    def _get_snap_socket(self) -> socket.socket | None:
        if self._snap_sock is not None:
            return self._snap_sock
        self._snap_sock = self._create_socket(self.snapserver_host, self.snapserver_port)
        if self._snap_sock:
            self._snap_sock.settimeout(10.0)
            self._last_snap_response = time.monotonic()
            logger.info(f"Connected to Snapserver {self.snapserver_host}:{self.snapserver_port}")
        return self._snap_sock

    def _close_snap_socket(self) -> None:
        if self._snap_sock is not None:
            try:
                self._snap_sock.close()
            except Exception:
                pass
            self._snap_sock = None
            self._snap_buffer = b""

    # ──────────────────────────────────────────────
    # Snapserver JSON-RPC
    # ──────────────────────────────────────────────

    def send_rpc_request(self, sock: socket.socket, method: str,
                         params: dict | None = None) -> dict | None:
        request = {
            "id": 1,
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
        }
        try:
            sock.sendall((json.dumps(request) + "\r\n").encode())
        except (OSError, socket.error) as e:
            logger.warning(f"Failed to send RPC request: {e}")
            return None

        while True:
            while b"\r\n" in self._snap_buffer:
                line, self._snap_buffer = self._snap_buffer.split(b"\r\n", 1)
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8", errors="replace"))
                except json.JSONDecodeError as e:
                    logger.warning(f"Malformed JSON from Snapserver: {line[:100]!r}: {e}")
                    continue
                if "id" in msg:
                    self._last_snap_response = time.monotonic()
                    return msg
            try:
                chunk = sock.recv(8192)
                if not chunk:
                    return None
                self._snap_buffer += chunk
            except socket.timeout:
                logger.warning("Snapserver socket timeout")
                return None
            except (OSError, socket.error) as e:
                logger.warning(f"Snapserver socket error: {e}")
                return None

    def get_server_status(self) -> dict | None:
        """Get full server status, with one retry on failure."""
        with self._snap_lock:
            if (self._snap_sock is not None and self._last_snap_response > 0 and
                    time.monotonic() - self._last_snap_response > self._snap_stale_threshold):
                logger.warning("Snapserver connection stale, reconnecting")
                self._close_snap_socket()

            sock = self._get_snap_socket()
            if not sock:
                return None

            status = self.send_rpc_request(sock, "Server.GetStatus")
            if not status:
                self._close_snap_socket()
                sock = self._get_snap_socket()
                if not sock:
                    return None
                status = self.send_rpc_request(sock, "Server.GetStatus")
            if not status:
                self._close_snap_socket()
                return None

            server = status.get("result", {}).get("server")
            if not server:
                logger.warning("Snapserver returned empty/missing server status")
                return None
            return server

    def _build_client_stream_map(self, server: dict) -> dict[str, str]:
        """Build CLIENT_ID → stream_id mapping from server status."""
        mapping: dict[str, str] = {}
        for group in server.get("groups", []):
            stream_id = group.get("stream_id", "")
            for client in group.get("clients", []):
                for identifier in [
                    client.get("host", {}).get("name", ""),
                    client.get("config", {}).get("name", ""),
                    client.get("id", ""),
                ]:
                    if identifier:
                        mapping[identifier] = stream_id
        return mapping

    def _resolve_client_stream(self, client_id: str) -> str | None:
        """Resolve a CLIENT_ID to its stream_id using cached mapping."""
        # Exact match first
        if client_id in self._client_stream_map:
            return self._client_stream_map[client_id]
        # Substring match (CLIENT_ID might be "snapclient-snapvideo" while
        # Snapserver has "snapvideo")
        for identifier, stream_id in self._client_stream_map.items():
            if client_id in identifier or identifier in client_id:
                logger.debug(f"Fuzzy match: client '{client_id}' matched identifier '{identifier}'")
                return stream_id
        return None

    def _find_client_volume(self, server: dict, client_id: str) -> dict:
        """Find volume info for a specific client."""
        for group in server.get("groups", []):
            for client in group.get("clients", []):
                identifiers = [
                    client.get("host", {}).get("name", ""),
                    client.get("config", {}).get("name", ""),
                    client.get("id", ""),
                ]
                if any(client_id in i or i in client_id for i in identifiers if i):
                    return client.get("config", {}).get("volume", {"percent": 100, "muted": False})
        return {"percent": 100, "muted": False}

    # ──────────────────────────────────────────────
    # MPD metadata
    # ──────────────────────────────────────────────

    def _read_mpd_response(self, sock: socket.socket) -> bytes:
        response = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
            if b"OK\n" in response or b"ACK" in response:
                break
        return response

    def _parse_mpd_response(self, response: bytes) -> dict[str, str]:
        lines = response.decode("utf-8", errors="replace").split("\n")
        return {
            key: value
            for line in lines if ": " in line
            for key, value in [line.split(": ", 1)]
        }

    def _read_mpd_greeting(self, sock: socket.socket, validate: bool = False) -> bool:
        try:
            greeting = sock.recv(1024)
            if validate and not greeting.startswith(b"OK MPD"):
                return False
            return True
        except (socket.error, socket.timeout):
            return False

    @staticmethod
    def _detect_codec(file_path: str, audio_fmt: str) -> str:
        if file_path.startswith(("http://", "https://")):
            return "RADIO"
        codec_map = {
            "flac": "FLAC", "wav": "WAV", "aiff": "AIFF", "aif": "AIFF",
            "mp3": "MP3", "ogg": "OGG", "opus": "OPUS",
            "m4a": "AAC", "aac": "AAC", "mp4": "AAC",
            "wma": "WMA", "ape": "APE", "wv": "WV", "dsf": "DSD", "dff": "DSD",
        }
        ext = file_path.rsplit(".", 1)[-1].lower() if "." in file_path else ""
        if ext in codec_map:
            return codec_map[ext]
        if audio_fmt and ":f:" in audio_fmt:
            return "PCM"
        return ext.upper() if ext else ""

    @staticmethod
    def _parse_audio_format(audio_fmt: str) -> tuple[int, int]:
        if not audio_fmt:
            return 0, 0
        parts = audio_fmt.split(":")
        if len(parts) < 2:
            return 0, 0
        try:
            sample_rate = int(parts[0])
            bits_str = parts[1]
            bit_depth = 32 if bits_str == "f" else int(bits_str)
        except (ValueError, IndexError):
            return 0, 0
        return sample_rate, bit_depth

    def _extract_radio_metadata(self, title: str, artist: str,
                                song: dict[str, str]) -> tuple[str, str, str]:
        if not artist and " - " in title:
            parts = title.split(" - ", 1)
            artist = parts[0].strip()
            title = parts[1].strip() if len(parts) > 1 else title
        album = html.unescape(song.get("Album", "") or song.get("Name", ""))
        return title, artist, album

    def get_mpd_metadata(self) -> dict[str, Any]:
        sock = self._create_socket(self.mpd_host, self.mpd_port, log_errors=False)
        if not sock:
            if self._mpd_was_connected:
                logger.warning(f"MPD connection lost ({self.mpd_host}:{self.mpd_port})")
                self._mpd_was_connected = False
            return {"playing": False, "source": "MPD"}

        try:
            if not self._mpd_was_connected:
                logger.info(f"MPD connected ({self.mpd_host}:{self.mpd_port})")
                self._mpd_was_connected = True

            if not self._read_mpd_greeting(sock):
                return {"playing": False, "source": "MPD"}

            sock.sendall(b"status\n")
            status = self._parse_mpd_response(self._read_mpd_response(sock))

            if status.get("state", "stop") != "play":
                return {"playing": False, "source": "MPD"}

            elapsed = float(status.get("elapsed", 0))
            duration = float(status.get("duration", 0))

            sock.sendall(b"currentsong\n")
            song = self._parse_mpd_response(self._read_mpd_response(sock))

            title, artist, album = self._extract_radio_metadata(
                html.unescape(song.get("Title", "")),
                html.unescape(song.get("Artist", "")),
                song,
            )

            audio_fmt = status.get("audio", "") or song.get("Format", "")
            file_path = song.get("file", "")
            bitrate_str = status.get("bitrate", "")
            bitrate = int(bitrate_str) if bitrate_str else 0
            codec = self._detect_codec(file_path, audio_fmt)
            sample_rate, bit_depth = self._parse_audio_format(audio_fmt)

            return {
                "playing": True,
                "title": title,
                "artist": artist,
                "album": album,
                "artwork": "",
                "stream_id": "MPD",
                "source": "MPD",
                "codec": codec,
                "bitrate": bitrate,
                "sample_rate": sample_rate,
                "bit_depth": bit_depth,
                "file": file_path,
                "station_name": song.get("Name", ""),
                "elapsed": int(elapsed),
                "duration": int(duration),
            }
        except Exception as e:
            if self._mpd_was_connected:
                logger.warning(f"MPD query failed: {e}")
                self._mpd_was_connected = False
            return {"playing": False, "source": "MPD"}
        finally:
            sock.close()

    # ──────────────────────────────────────────────
    # MPD embedded artwork
    # ──────────────────────────────────────────────

    _MAX_MPD_ARTWORK_BYTES = 10_000_000

    @staticmethod
    def _image_extension(data: bytes) -> str:
        if len(data) >= 8 and data[:8] == b"\x89PNG\r\n\x1a\n":
            return ".png"
        if len(data) >= 3 and data[:3] == b"GIF":
            return ".gif"
        if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            return ".webp"
        return ".jpg"

    def fetch_mpd_artwork(self, file_path: str) -> str:
        """Fetch embedded cover art from MPD via readpicture. Returns artwork filename or ""."""
        if not file_path:
            return ""

        art_hash = hashlib.md5(f"mpd:{file_path}".encode()).hexdigest()
        for ext in (".jpg", ".png", ".gif", ".webp"):
            cached = self.artwork_dir / f"artwork_{art_hash}{ext}"
            if cached.exists() and cached.stat().st_size > 0:
                return f"artwork_{art_hash}{ext}"

        sock = self._create_socket(self.mpd_host, self.mpd_port, log_errors=False)
        if not sock:
            return ""

        try:
            sock.settimeout(10)
            if not self._read_mpd_greeting(sock, validate=True):
                return ""

            if any(c in file_path for c in "\n\r\t\x00"):
                logger.warning("Rejected file path with control characters")
                return ""
            safe_path = file_path.replace("\\", "\\\\").replace('"', '\\"')

            image_data = b""
            offset = 0

            while True:
                cmd = f'readpicture "{safe_path}" {offset}\n'
                sock.sendall(cmd.encode())

                header = b""
                while b"binary:" not in header and b"OK\n" not in header and b"ACK" not in header:
                    chunk = sock.recv(4096)
                    if not chunk:
                        return ""
                    header += chunk

                if b"ACK" in header or b"binary:" not in header:
                    break

                bin_size = 0
                for line in header.split(b"\n"):
                    if line.startswith(b"binary: "):
                        try:
                            bin_size = int(line.split(b": ", 1)[1])
                        except (ValueError, IndexError):
                            bin_size = 0
                        break
                else:
                    break

                if bin_size <= 0 or bin_size > self._MAX_MPD_ARTWORK_BYTES:
                    break

                bin_marker = f"binary: {bin_size}\n".encode()
                marker_pos = header.find(bin_marker)
                if marker_pos < 0:
                    break
                remaining = header[marker_pos + len(bin_marker):]

                while len(remaining) < bin_size:
                    chunk = sock.recv(min(8192, bin_size - len(remaining)))
                    if not chunk:
                        return ""
                    remaining += chunk

                if len(image_data) + bin_size > self._MAX_MPD_ARTWORK_BYTES:
                    logger.warning(f"MPD artwork exceeded size limit ({self._MAX_MPD_ARTWORK_BYTES} bytes)")
                    return ""

                image_data += remaining[:bin_size]
                offset += bin_size

                trail = remaining[bin_size:]
                while b"OK\n" not in trail:
                    chunk = sock.recv(1024)
                    if not chunk:
                        return ""
                    trail += chunk

            if len(image_data) > 0:
                ext = self._image_extension(image_data)
                filename = f"artwork_{art_hash}{ext}"
                local_path = self.artwork_dir / filename
                tmp_path = local_path.parent / (local_path.name + ".tmp")
                with open(tmp_path, "wb") as f:
                    f.write(image_data)
                tmp_path.rename(local_path)
                logger.info(f"Got MPD artwork ({len(image_data)} bytes) for {file_path}")
                return filename

            return ""
        except (socket.error, socket.timeout, OSError) as e:
            logger.warning(f"MPD readpicture failed: {e}")
            return ""
        except Exception as e:
            logger.error(f"Unexpected error in MPD readpicture: {e}")
            return ""
        finally:
            sock.close()

    # ──────────────────────────────────────────────
    # External artwork APIs
    # ──────────────────────────────────────────────

    def _make_api_request(self, url: str, timeout: int = 5) -> dict | list | None:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
            with urllib.request.urlopen(req, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except Exception as e:
            logger.debug(f"API request failed for {url}: {e}")
            return None

    def fetch_radio_logo(self, station_name: str, stream_url: str) -> str:
        if not station_name or len(station_name) > 200:
            return ""

        cache_key = f"radio|{station_name}"
        if cache_key in self.artwork_cache:
            return self.artwork_cache[cache_key]

        clean_name = station_name
        for sep in ("(", "[", "-"):
            if sep in clean_name:
                candidate = clean_name.split(sep)[0].strip()
                if len(candidate) >= 3:
                    clean_name = candidate

        query = urllib.parse.quote(clean_name)
        url = f"https://de1.api.radio-browser.info/json/stations/byname/{query}?limit=20&order=votes&reverse=true"
        data = self._make_api_request(url)
        if not data or not isinstance(data, list):
            self._cache_set(self.artwork_cache, cache_key, "")
            return ""

        stream_domain = ""
        if stream_url:
            try:
                stream_domain = urllib.parse.urlparse(stream_url).netloc.split(":")[0]
                parts = stream_domain.split(".")
                if len(parts) > 2:
                    stream_domain = ".".join(parts[-2:])
            except Exception:
                pass

        best_url = ""
        best_score = -1
        for entry in data:
            favicon = entry.get("favicon", "")
            if not favicon:
                continue
            score = entry.get("votes", 0)
            entry_url = entry.get("url_resolved", "") or entry.get("url", "")
            if stream_domain and stream_domain in entry_url:
                score += 10000
            if score > best_score:
                best_score = score
                best_url = favicon

        if best_url:
            logger.info(f"Found radio logo for '{station_name}': {best_url}")
        self._cache_set(self.artwork_cache, cache_key, best_url)
        return best_url

    def fetch_musicbrainz_artwork(self, artist: str, album: str) -> str:
        query = urllib.parse.quote(f'artist:"{artist}" AND release:"{album}"')
        url = f"https://musicbrainz.org/ws/2/release/?query={query}&fmt=json&limit=1"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return ""
        releases = data.get("releases", [])
        if releases and (mbid := releases[0].get("id")):
            return f"https://coverartarchive.org/release/{mbid}/front-500"
        return ""

    def _get_wikidata_id_from_relations(self, relations: list) -> str | None:
        for rel in relations:
            if rel.get("type") == "wikidata":
                wikidata_url = rel.get("url", {}).get("resource", "")
                if wikidata_url:
                    return wikidata_url.split("/")[-1]
        return None

    def _build_wikimedia_image_url(self, image_name: str) -> str:
        image_name = image_name.replace(" ", "_")
        md5 = hashlib.md5(image_name.encode()).hexdigest()
        base_url = (
            f"https://upload.wikimedia.org/wikipedia/commons/thumb/"
            f"{md5[0]}/{md5[0:2]}/{urllib.parse.quote(image_name)}/"
            f"500px-{urllib.parse.quote(image_name)}"
        )
        if image_name.lower().endswith(".svg"):
            base_url += ".png"
        return base_url

    def fetch_artist_image(self, artist: str) -> str:
        if not artist or artist in self.artist_image_cache:
            return self.artist_image_cache.get(artist, "")

        query = urllib.parse.quote(f'artist:"{artist}"')
        url = f"https://musicbrainz.org/ws/2/artist/?query={query}&fmt=json&limit=1"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict) or not (artists := data.get("artists", [])):
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        artist_mbid = artists[0].get("id")
        if not artist_mbid:
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        time.sleep(1.1)  # MusicBrainz rate limit

        url = f"https://musicbrainz.org/ws/2/artist/{artist_mbid}?inc=url-rels&fmt=json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        wikidata_id = self._get_wikidata_id_from_relations(data.get("relations", []))
        if not wikidata_id:
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        time.sleep(1.1)

        url = f"https://www.wikidata.org/wiki/Special:EntityData/{wikidata_id}.json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        entity = data.get("entities", {}).get(wikidata_id, {})
        image_claims = entity.get("claims", {}).get("P18", [])

        if image_claims and (
            image_name := image_claims[0]
            .get("mainsnak", {})
            .get("datavalue", {})
            .get("value", "")
        ):
            image_url = self._build_wikimedia_image_url(image_name)
            self._cache_set(self.artist_image_cache, artist, image_url)
            logger.info(f"Found artist image for {artist}")
            return image_url

        self._cache_set(self.artist_image_cache, artist, "")
        return ""

    def fetch_album_artwork(self, artist: str, album: str) -> str:
        if not artist or not album:
            return ""

        cache_key = f"{artist}|{album}"
        if cache_key in self.artwork_cache:
            return self.artwork_cache[cache_key]

        artwork_url = self._fetch_itunes_artwork(artist, album)
        if artwork_url:
            self._cache_set(self.artwork_cache, cache_key, artwork_url)
            logger.info(f"Found iTunes artwork for {artist} - {album}")
            return artwork_url

        artwork_url = self.fetch_musicbrainz_artwork(artist, album)
        if artwork_url:
            self._cache_set(self.artwork_cache, cache_key, artwork_url)
            logger.info(f"Found MusicBrainz artwork for {artist} - {album}")
            return artwork_url

        self._cache_set(self.artwork_cache, cache_key, "")
        return ""

    def _fetch_itunes_artwork(self, artist: str, album: str) -> str:
        query = urllib.parse.quote(f"{artist} {album}")
        url = f"https://itunes.apple.com/search?term={query}&media=music&entity=album&limit=10"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict) or data.get("resultCount", 0) == 0:
            return ""

        album_lower = album.lower().strip()
        artist_lower = artist.lower().strip()
        for result in data["results"]:
            name = result.get("collectionName", "").lower().strip()
            result_artist = result.get("artistName", "").lower().strip()
            album_ok = name == album_lower or name.startswith(album_lower + " (")
            artist_ok = artist_lower == result_artist
            if album_ok and artist_ok:
                artwork_url = result.get("artworkUrl100", "")
                return artwork_url.replace("100x100", "600x600") if artwork_url else ""
        return ""

    # ──────────────────────────────────────────────
    # Artwork download with SSRF protection
    # ──────────────────────────────────────────────

    _MAX_ARTWORK_BYTES = 10_000_000

    def download_artwork(self, url: str) -> str:
        """Download artwork, save to artwork dir. Returns filename or ""."""
        if not url or url in self._failed_downloads:
            return ""

        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            logger.warning(f"Rejected artwork URL with scheme: {parsed.scheme}")
            self._mark_failed(url)
            return ""

        # Block private/loopback IPs (SSRF protection)
        # Exception: allow Snapserver host (internal, trusted)
        # Resolve once and connect to the resolved IP to prevent DNS rebinding
        resolved_ip = None
        try:
            is_snapserver = parsed.hostname == self.snapserver_host
            blocked_addr = None
            for _family, _, _, _, sockaddr in socket.getaddrinfo(
                parsed.hostname or "", None, socket.AF_UNSPEC
            ):
                addr = sockaddr[0]
                ip = ipaddress.ip_address(addr)
                if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_reserved:
                    if is_snapserver:
                        logger.debug(f"Allowing artwork from Snapserver: {addr}")
                        resolved_ip = addr
                    else:
                        blocked_addr = addr
                        break
                else:
                    resolved_ip = addr
                    break
            if blocked_addr:
                logger.warning(f"Blocked artwork download to restricted IP: {blocked_addr}")
                self._mark_failed(url)
                return ""
        except (socket.gaierror, ValueError, OSError) as e:
            logger.warning(f"Cannot resolve artwork host {parsed.hostname}: {e}")
            self._mark_failed(url)
            return ""

        try:
            url_hash = hashlib.md5(url.encode()).hexdigest()

            # Check if already downloaded with any extension
            for ext in (".jpg", ".png", ".gif", ".webp"):
                existing = self.artwork_dir / f"artwork_{url_hash}{ext}"
                if existing.exists() and existing.stat().st_size > 0:
                    return existing.name

            # Use resolved IP to prevent DNS rebinding (TOCTOU).
            # Only for HTTP — HTTPS certificate checks protect against rebinding.
            if resolved_ip and parsed.hostname and parsed.scheme == "http":
                ip_for_url = f"[{resolved_ip}]" if ":" in resolved_ip else resolved_ip
                fetch_url = url.replace(parsed.hostname, ip_for_url, 1)
                req = urllib.request.Request(
                    fetch_url, headers={"User-Agent": self.user_agent, "Host": parsed.hostname}
                )
            else:
                req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
            with urllib.request.urlopen(req, timeout=5) as response:
                data = b""
                dl_start = time.monotonic()
                while len(data) < self._MAX_ARTWORK_BYTES:
                    if time.monotonic() - dl_start > 15:
                        logger.warning("Artwork download total timeout (15s)")
                        self._mark_failed(url)
                        return ""
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    data += chunk

                if len(data) >= self._MAX_ARTWORK_BYTES:
                    logger.warning(f"Artwork exceeded size limit ({self._MAX_ARTWORK_BYTES} bytes)")
                    self._mark_failed(url)
                    return ""

                if len(data) > 0:
                    ext = self._image_extension(data)
                    filename = f"artwork_{url_hash}{ext}"
                    local_path = self.artwork_dir / filename
                    tmp_path = local_path.parent / (local_path.name + ".tmp")
                    with open(tmp_path, "wb") as f:
                        f.write(data)
                    tmp_path.rename(local_path)
                    logger.info(f"Downloaded artwork ({len(data)} bytes) to {local_path}")
                    return filename
                else:
                    logger.warning("Downloaded empty artwork")
                    self._mark_failed(url)
                    return ""
        except Exception as e:
            logger.error(f"Failed to download artwork: {e}")
            self._mark_failed(url)
            try:
                for tmp in self.artwork_dir.glob(f"artwork_{url_hash}*"):
                    tmp.unlink(missing_ok=True)
            except Exception:
                pass
            return ""

    # ──────────────────────────────────────────────
    # Playback control (bidirectional)
    # ──────────────────────────────────────────────

    def toggle_playback(self) -> bool:
        """Toggle play/pause via MPD."""
        sock = self._create_socket(self.mpd_host, self.mpd_port, log_errors=False)
        if not sock:
            return False
        try:
            if not self._read_mpd_greeting(sock):
                return False
            sock.sendall(b"status\n")
            status = self._parse_mpd_response(self._read_mpd_response(sock))
            state = status.get("state", "stop")
            if state == "play":
                sock.sendall(b"pause 1\n")
                logger.info("MPD: paused")
            else:
                sock.sendall(b"play\n")
                logger.info("MPD: playing")
            self._read_mpd_response(sock)
            return True
        except Exception as e:
            logger.warning(f"MPD playback toggle failed: {e}")
            return False
        finally:
            sock.close()

    def set_client_volume(self, client_id: str, volume: int) -> bool:
        """Set volume for a specific client (0-100)."""
        with self._snap_lock:
            if (self._snap_sock is not None and self._last_snap_response > 0 and
                    time.monotonic() - self._last_snap_response > self._snap_stale_threshold):
                self._close_snap_socket()

            sock = self._get_snap_socket()
            if not sock:
                return False

            status = self.send_rpc_request(sock, "Server.GetStatus")
            if not status:
                return False

            server = status.get("result", {}).get("server", {})
            snap_client_id = None
            for group in server.get("groups", []):
                for client in group.get("clients", []):
                    identifiers = [
                        client.get("host", {}).get("name", ""),
                        client.get("config", {}).get("name", ""),
                        client.get("id", ""),
                    ]
                    if any(client_id in i or i in client_id for i in identifiers if i):
                        snap_client_id = client.get("id")
                        break
                if snap_client_id:
                    break

            if not snap_client_id:
                logger.warning(f"Client {client_id} not found for volume control")
                return False

            volume = max(0, min(100, volume))
            params = {"id": snap_client_id, "volume": {"percent": volume, "muted": False}}
            response = self.send_rpc_request(sock, "Client.SetVolume", params)
            if response and "result" in response:
                logger.info(f"Set client {client_id} volume to {volume}%")
                return True
            return False

    # ──────────────────────────────────────────────
    # Metadata change detection
    # ──────────────────────────────────────────────

    _VOLATILE_FIELDS = {"bitrate", "artwork", "artist_image", "elapsed"}
    _INTERNAL_FIELDS = {"file", "station_name"}

    def _metadata_changed(self, new: dict, old: dict) -> bool:
        if not old:
            return True
        for key in set(new.keys()) | set(old.keys()):
            if key in self._VOLATILE_FIELDS:
                continue
            if new.get(key) != old.get(key):
                return True
        return False

    def _output_metadata(self, metadata: dict) -> dict:
        return {k: v for k, v in metadata.items() if k not in self._INTERNAL_FIELDS}

    # ──────────────────────────────────────────────
    # Per-stream metadata extraction from Snapserver status
    # ──────────────────────────────────────────────

    def _extract_stream_metadata(self, stream: dict) -> dict[str, Any]:
        """Extract metadata dict from a Snapserver stream object."""
        props = stream.get("properties", {})
        meta = props.get("metadata", {})

        artist = meta.get("artist", "")
        if isinstance(artist, list):
            artist = ", ".join(artist)

        artwork = meta.get("artUrl", "")
        if artwork and "://snapcast:" in artwork:
            artwork = artwork.replace("://snapcast:", f"://{self.snapserver_host}:")

        uri_query = stream.get("uri", {}).get("query", {})
        snap_codec = uri_query.get("codec", "")
        snap_fmt = uri_query.get("sampleformat", "")
        sample_rate, bit_depth = self._parse_audio_format(snap_fmt)

        position = props.get("position", 0)
        duration = meta.get("duration", 0)

        return {
            "playing": stream.get("status") == "playing",
            "title": meta.get("title", ""),
            "artist": artist,
            "album": meta.get("album", ""),
            "artwork": artwork,
            "stream_id": stream.get("id", ""),
            "source": stream.get("id", ""),
            "codec": snap_codec.upper() if snap_codec else "",
            "sample_rate": sample_rate,
            "bit_depth": bit_depth,
            "elapsed": int(position),
            "duration": int(duration),
        }

    # ──────────────────────────────────────────────
    # Artwork enrichment for a metadata dict
    # ──────────────────────────────────────────────

    def _artwork_url(self, filename: str) -> str:
        """Build full HTTP URL for an artwork filename."""
        if not filename:
            return ""
        return f"http://{EXTERNAL_HOST}:{HTTP_PORT}/artwork/{filename}"

    def enrich_artwork(self, metadata: dict[str, Any]) -> None:
        """Fetch/download artwork for a metadata dict. Mutates in place."""
        if not metadata.get("playing"):
            return

        artwork_url = metadata.get("artwork", "")
        is_radio = metadata.get("codec") == "RADIO"

        # For MPD files, try embedded cover art first
        if not artwork_url and metadata.get("source") == "MPD" and not is_radio:
            mpd_art = self.fetch_mpd_artwork(metadata.get("file", ""))
            if mpd_art:
                metadata["artwork"] = self._artwork_url(mpd_art)
                artwork_url = None  # skip further lookups

        if not artwork_url and not metadata.get("artwork"):
            if is_radio and metadata.get("station_name"):
                artwork_url = self.fetch_radio_logo(
                    metadata["station_name"], metadata.get("file", "")
                )
            elif metadata.get("artist") and metadata.get("album"):
                artwork_url = self.fetch_album_artwork(
                    metadata["artist"], metadata["album"]
                )

        # Download external artwork locally
        if artwork_url:
            local_file = self.download_artwork(artwork_url)
            metadata["artwork"] = self._artwork_url(local_file) if local_file else ""

        # Fallback: radio logo
        if not metadata.get("artwork") and is_radio and metadata.get("station_name"):
            logo_url = self.fetch_radio_logo(
                metadata["station_name"], metadata.get("file", "")
            )
            if logo_url:
                local_file = self.download_artwork(logo_url)
                if local_file:
                    metadata["artwork"] = self._artwork_url(local_file)

        # Final radio fallback
        if not metadata.get("artwork") and is_radio:
            metadata["artwork"] = f"http://{EXTERNAL_HOST}:{HTTP_PORT}/defaults/default-radio.png"

        # Artist image (not for radio)
        if not is_radio and metadata.get("artist"):
            artist_image = self.fetch_artist_image(metadata["artist"])
            if artist_image:
                # Artist images are external URLs (Wikimedia), serve as-is
                metadata["artist_image"] = artist_image

    # ──────────────────────────────────────────────
    # Main polling loop
    # ──────────────────────────────────────────────

    async def poll_loop(self) -> None:
        """Main loop: poll Snapserver, enrich metadata, broadcast to clients."""
        loop = asyncio.get_running_loop()

        while True:
            try:
                server = await loop.run_in_executor(None, self.get_server_status)
                if not server:
                    await asyncio.sleep(5)
                    continue

                # Rebuild client → stream mapping
                self._client_stream_map = self._build_client_stream_map(server)

                # Update subscribed clients' stream_id
                for sc in ws_clients.copy():
                    resolved = self._resolve_client_stream(sc.client_id)
                    if resolved:
                        sc.stream_id = resolved

                # Process each stream
                for stream in server.get("streams", []):
                    stream_id = stream.get("id", "")
                    if not stream_id:
                        continue

                    if stream_id not in self.streams:
                        self.streams[stream_id] = StreamMetadata(stream_id)
                    sm = self.streams[stream_id]

                    metadata = await loop.run_in_executor(
                        None, self._extract_stream_metadata, stream
                    )

                    # Enrich MPD stream with richer metadata
                    if metadata.get("source") == "MPD":
                        mpd_meta = await loop.run_in_executor(None, self.get_mpd_metadata)
                        if mpd_meta.get("playing"):
                            if not mpd_meta.get("title") and mpd_meta.get("station_name"):
                                mpd_meta["title"] = mpd_meta["station_name"]
                            metadata = mpd_meta

                    # Enrich with artwork
                    await loop.run_in_executor(None, self.enrich_artwork, metadata)

                    # Check for changes
                    changed = self._metadata_changed(metadata, sm.current)
                    volatile_changed = not changed and any(
                        metadata.get(f) != sm.current.get(f)
                        for f in self._VOLATILE_FIELDS
                    )

                    if changed:
                        new_title = metadata.get("title", "")
                        new_artist = metadata.get("artist", "")
                        old_title = sm.current.get("title", "")
                        old_artist = sm.current.get("artist", "")
                        if (new_title or new_artist) and (new_title, new_artist) != (old_title, old_artist):
                            self._failed_downloads.clear()

                        sm.current = metadata
                        title = metadata.get("title", "N/A")
                        artist = metadata.get("artist", "N/A")
                        logger.info(f"[{stream_id}] Updated: {title} - {artist}")

                    if changed or volatile_changed:
                        sm.current = metadata
                        # Write per-stream metadata.json (atomic)
                        meta_file = self.artwork_dir / f"metadata_{stream_id}.json"
                        try:
                            tmp_file = meta_file.parent / (meta_file.name + ".tmp")
                            with open(tmp_file, "w") as f:
                                json.dump(self._output_metadata(metadata), f, indent=2)
                            tmp_file.rename(meta_file)
                        except Exception as e:
                            logger.error(f"Failed to write metadata for {stream_id}: {e}")
                            try:
                                tmp_file.unlink(missing_ok=True)
                            except Exception:
                                pass

                        # Broadcast to subscribed clients
                        await self._broadcast_to_stream(stream_id, metadata, server)

            except Exception as e:
                logger.error(f"Error in poll loop: {e}")

            await asyncio.sleep(2)

    async def _broadcast_to_stream(self, stream_id: str, metadata: dict,
                                   server: dict) -> None:
        """Broadcast metadata to all clients subscribed to this stream."""
        output = self._output_metadata(metadata)

        for sc in ws_clients.copy():
            if sc.stream_id != stream_id:
                continue

            # Add per-client volume info (client expects "volume" and "muted" keys)
            volume_info = self._find_client_volume(server, sc.client_id)
            client_output = {
                **output,
                "volume": volume_info.get("percent", 100),
                "muted": volume_info.get("muted", False),
            }

            try:
                await sc.websocket.send(json.dumps(client_output))
            except Exception:
                ws_clients.discard(sc)

    async def handle_control_command(self, client_id: str, message: str) -> None:
        """Handle control commands from a subscribed client."""
        try:
            cmd = json.loads(message)
            cmd_type = cmd.get("cmd")
            logger.info(f"Control command from {client_id}: {cmd_type}")

            loop = asyncio.get_running_loop()

            if cmd_type == "toggle_play":
                await loop.run_in_executor(None, self.toggle_playback)
            elif cmd_type == "volume":
                delta = cmd.get("delta", 0)
                if isinstance(delta, (int, float)) and delta:
                    # Get current volume, then adjust
                    server = await loop.run_in_executor(None, self.get_server_status)
                    if server:
                        vol = self._find_client_volume(server, client_id)
                        new_vol = int(max(0, min(100, vol.get("percent", 50) + delta)))
                        await loop.run_in_executor(
                            None, self.set_client_volume, client_id, new_vol
                        )
            elif cmd_type == "seek":
                logger.debug(f"Seek command ignored: {cmd.get('delta')}")
        except json.JSONDecodeError as e:
            logger.warning(f"Invalid control command JSON: {e}")
        except Exception as e:
            logger.error(f"Control command error: {e}")


# ──────────────────────────────────────────────
# WebSocket handler
# ──────────────────────────────────────────────

async def ws_handler(websocket: Any) -> None:
    """Handle WebSocket connections. Clients must subscribe with CLIENT_ID."""
    client_addr = websocket.remote_address
    logger.info(f"WebSocket client connected: {client_addr}")

    sc: SubscribedClient | None = None

    try:
        async for message in websocket:
            if not message:
                continue

            try:
                data = json.loads(message)
            except json.JSONDecodeError:
                continue

            # Subscription message
            if "subscribe" in data:
                client_id = str(data["subscribe"])[:256]
                if sc:
                    ws_clients.discard(sc)
                sc = SubscribedClient(websocket, client_id)
                ws_clients.add(sc)
                logger.info(f"Client {client_addr} subscribed as '{client_id}'")

                # Resolve stream and send current metadata immediately
                if _service:
                    stream_id = _service._resolve_client_stream(client_id)
                    if stream_id:
                        sc.stream_id = stream_id
                        sm = _service.streams.get(stream_id)
                        if sm and sm.current:
                            loop = asyncio.get_running_loop()
                            server = await loop.run_in_executor(
                                None, _service.get_server_status
                            )
                            volume = _service._find_client_volume(server, client_id) if server else {}
                            output = {
                                **_service._output_metadata(sm.current),
                                "volume": volume.get("percent", 100),
                                "muted": volume.get("muted", False),
                            }
                            await websocket.send(json.dumps(output))
                continue

            # Control commands (must be subscribed)
            if sc and _service and "cmd" in data:
                await _service.handle_control_command(sc.client_id, message)

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if sc:
            ws_clients.discard(sc)
        logger.info(f"WebSocket client disconnected: {client_addr}")


# ──────────────────────────────────────────────
# HTTP server (artwork + metadata.json)
# ──────────────────────────────────────────────

async def handle_artwork(request: web.Request) -> web.StreamResponse:
    """Serve artwork files from the artwork directory."""
    filename = request.match_info["filename"]
    # Sanitize: only allow alphanumeric, dash, underscore, dot
    if not all(c.isalnum() or c in "-_." for c in filename):
        return web.Response(status=400, text="Invalid filename")
    # Prevent path traversal
    if ".." in filename or "/" in filename:
        return web.Response(status=400, text="Invalid filename")

    filepath = ARTWORK_DIR / filename
    if not filepath.exists():
        return web.Response(status=404)

    # Detect content type
    ext = filepath.suffix.lower()
    content_types = {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".png": "image/png", ".gif": "image/gif",
        ".webp": "image/webp", ".svg": "image/svg+xml",
    }
    content_type = content_types.get(ext, "application/octet-stream")

    return web.FileResponse(filepath, headers={
        "Content-Type": content_type,
        "Cache-Control": "public, max-age=3600",
        "Access-Control-Allow-Origin": "*",
    })


async def handle_defaults(request: web.Request) -> web.StreamResponse:
    """Serve default asset files (not shadowed by artwork bind mount)."""
    filename = request.match_info["filename"]
    if not all(c.isalnum() or c in "-_." for c in filename):
        return web.Response(status=400, text="Invalid filename")
    if ".." in filename or "/" in filename:
        return web.Response(status=400, text="Invalid filename")

    filepath = DEFAULTS_DIR / filename
    if not filepath.exists():
        return web.Response(status=404)

    ext = filepath.suffix.lower()
    content_types = {
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".gif": "image/gif", ".webp": "image/webp",
    }
    content_type = content_types.get(ext, "application/octet-stream")

    return web.FileResponse(filepath, headers={
        "Content-Type": content_type,
        "Cache-Control": "public, max-age=86400",
        "Access-Control-Allow-Origin": "*",
    })


async def handle_metadata(request: web.Request) -> web.Response:
    """Serve metadata JSON for a specific stream or default."""
    stream_id = request.query.get("stream")

    if _service and stream_id and stream_id in _service.streams:
        sm = _service.streams[stream_id]
        output = _service._output_metadata(sm.current) if sm.current else {"playing": False}
    elif _service and _service.streams:
        # Default: first playing stream, or first stream
        playing = [s for s in _service.streams.values() if s.current.get("playing")]
        sm = playing[0] if playing else next(iter(_service.streams.values()))
        output = _service._output_metadata(sm.current) if sm.current else {"playing": False}
    else:
        output = {"playing": False}

    return web.json_response(output, headers={
        "Access-Control-Allow-Origin": "*",
        "Cache-Control": "no-cache",
    })


async def handle_health(request: web.Request) -> web.Response:
    """Health check endpoint."""
    return web.Response(text="OK")


# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────

async def main() -> None:
    global _service

    # Clean stale metadata and orphaned tmp files from previous session
    for pattern in ("metadata_*.json", "*.tmp"):
        for f in ARTWORK_DIR.glob(pattern):
            try:
                f.unlink()
                logger.info(f"Cleared stale {f.name}")
            except OSError:
                pass

    _service = MetadataService()

    logger.info("Starting snapMULTI Metadata Service")
    logger.info(f"  Snapserver: {SNAPSERVER_HOST}:{SNAPSERVER_RPC_PORT}")
    logger.info(f"  External host: {EXTERNAL_HOST}")
    try:
        if ipaddress.ip_address(socket.gethostbyname(EXTERNAL_HOST)).is_loopback:
            logger.warning("EXTERNAL_HOST resolves to loopback — "
                           "set EXTERNAL_HOST explicitly if artwork fails on clients")
    except (socket.gaierror, ValueError):
        pass
    logger.info(f"  MPD: {MPD_HOST}:{MPD_PORT}")
    logger.info(f"  WebSocket port: {WS_PORT}")
    logger.info(f"  HTTP port: {HTTP_PORT}")
    logger.info(f"  Artwork dir: {ARTWORK_DIR}")

    # Start WebSocket server
    ws_server = await websockets.serve(ws_handler, "0.0.0.0", WS_PORT)
    logger.info(f"WebSocket server listening on port {WS_PORT}")

    # Start HTTP server
    app = web.Application()
    app.router.add_get("/artwork/{filename}", handle_artwork)
    app.router.add_get("/defaults/{filename}", handle_defaults)
    app.router.add_get("/metadata.json", handle_metadata)
    app.router.add_get("/health", handle_health)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", HTTP_PORT)
    await site.start()
    logger.info(f"HTTP server listening on port {HTTP_PORT}")

    # Start polling loop
    await _service.poll_loop()


if __name__ == "__main__":
    asyncio.run(main())
