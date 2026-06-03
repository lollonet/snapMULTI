#!/usr/bin/env python3
"""
snapMULTI Metadata Service (Server-side)

Centralized metadata + cover art service that runs on the server alongside Snapcast.
- Monitors ALL active streams via Snapserver JSON-RPC
- Fetches cover art from MPD (embedded), iTunes, MusicBrainz, Radio-Browser
- Serves artwork via built-in HTTP server (port 8083)
- Pushes metadata to display clients via WebSocket (port 8082)
- Clients subscribe by sending {"subscribe": "CLIENT_ID"} to get their stream's metadata
- Controllers subscribe by sending {"subscribe_stream": "STREAM_ID"} for raw stream metadata (no volume)

Replaces per-client metadata-service containers — N clients no longer make N redundant API calls.
"""

import asyncio
import collections
import hashlib
import html
import ipaddress
import json
from datetime import datetime
import logging
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import aiohttp
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

# go-librespot API for accurate Spotify track position
GO_LIBRESPOT_HOST = os.environ.get("GO_LIBRESPOT_HOST", "127.0.0.1")
GO_LIBRESPOT_PORT = int(os.environ.get("GO_LIBRESPOT_PORT", "24879"))


# External hostname for artwork URLs sent to remote clients.
# SNAPSERVER_HOST may be 127.0.0.1 (for local socket connections),
# but artwork URLs must use a host reachable by clients on the network.
def _detect_lan_ip() -> str | None:
    """Kernel-route-based LAN IP detection — no network traffic emitted."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        finally:
            s.close()
    except OSError:
        return None


def _resolve_external_host() -> str:
    """Pick a usable EXTERNAL_HOST: explicit env > FQDN-if-non-loopback > kernel LAN IP > SNAPSERVER_HOST."""
    explicit = os.environ.get("EXTERNAL_HOST", "")
    if explicit:
        return explicit
    fqdn = socket.getfqdn()
    try:
        if fqdn and not ipaddress.ip_address(socket.gethostbyname(fqdn)).is_loopback:
            return fqdn
    except (socket.gaierror, ValueError):
        pass
    lan_ip = _detect_lan_ip()
    if lan_ip and not ipaddress.ip_address(lan_ip).is_loopback:
        return lan_ip
    return SNAPSERVER_HOST


# Lazy-evaluated to avoid blocking module import on slow DNS / reverse lookup
# (observed: macOS dev hosts where socket.getfqdn() hangs ~30 s on stale
# resolvers, blocking every pytest import). Resolution happens once on first
# access; runtime Pi hosts hit LAN DNS so cost is sub-millisecond.
_EXTERNAL_HOST: str | None = None


def get_external_host() -> str:
    global _EXTERNAL_HOST
    if _EXTERNAL_HOST is None:
        _EXTERNAL_HOST = _resolve_external_host()
    return _EXTERNAL_HOST


_POLL_LOOP_MAX_ERRORS = 30

# MusicBrainz rate limiter (1 request per 1.1 seconds, shared across threads)
_mb_last_request: float = 0.0
_mb_lock = threading.Lock()

# Defensive lock for OrderedDict cache mutations. Today the only caller of
# _cache_set is enrich_artwork / enrich_tags, both run SERIALLY by the poll
# loop via `await loop.run_in_executor(...)` (no asyncio.gather, no
# create_task on cache writers). So in current code there's no concurrent
# write — the lock is cheap insurance against future code paths that might
# parallelise enrich (e.g. asyncio.gather across streams). OrderedDict's
# internal doubly-linked list pointers can be corrupted by concurrent
# move_to_end / popitem, with crashes (KeyError) hard to reproduce.
_cache_lock = threading.Lock()


def _mb_rate_limit() -> None:
    """Enforce MusicBrainz 1 req/s rate limit, sleeping only the remaining time.

    Lock is released BEFORE sleep so concurrent threads don't queue on the
    lock during the 1.1s window — they each reserve their slot atomically
    via the timestamp update, then sleep independently. This keeps the
    thread pool free for non-MusicBrainz tasks (HTTP /status, file I/O)
    even when several artwork lookups land in MusicBrainz at once.
    """
    global _mb_last_request
    with _mb_lock:
        now = time.monotonic()
        wait = 1.1 - (now - _mb_last_request)
        # Reserve the slot atomically: even if we sleep outside the lock,
        # the next thread's `now - _mb_last_request` already accounts for
        # our sleep window via this forward-dated timestamp.
        if wait > 0:
            _mb_last_request = now + wait
        else:
            _mb_last_request = now
            wait = 0.0
    # Sleep OUTSIDE the lock — other waiters can compute their slot.
    if wait > 0:
        time.sleep(wait)


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("metadata-service")


class StreamMetadata:
    """Metadata state for a single stream."""

    def __init__(self, stream_id: str) -> None:
        self.stream_id = stream_id
        self.current: dict[str, Any] = {}


class SubscribedClient:
    """A WebSocket client subscribed to a CLIENT_ID or directly to a stream name."""

    def __init__(
        self, websocket: Any, client_id: str = "", stream_id_direct: str = ""
    ) -> None:
        self.websocket = websocket
        self.client_id = client_id
        self.stream_id: str | None = stream_id_direct if stream_id_direct else None
        self.is_stream_subscriber = bool(stream_id_direct)


# Global state
ws_clients: set[SubscribedClient] = set()
ws_clients_lock = asyncio.Lock()  # CRITICAL: Protect concurrent access
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

        # Liveness signal for the /health endpoint. Bumped on every successful
        # poll_loop iteration. Allows /health to report "stale" when the
        # snapserver socket connection is broken even if the HTTP server is
        # still happily serving requests on its own.
        self.last_successful_poll_at: float = 0.0

        # Per-stream metadata state
        self.streams: dict[str, StreamMetadata] = {}

        # Caches (shared across all streams — same album art doesn't need re-fetch)
        # Bounded to _MAX_CACHE_ENTRIES to prevent unbounded memory growth
        self.artwork_cache: collections.OrderedDict[str, str] = (
            collections.OrderedDict()
        )
        self.artist_image_cache: collections.OrderedDict[str, str] = (
            collections.OrderedDict()
        )
        self._failed_downloads: collections.OrderedDict[str, None] = (
            collections.OrderedDict()
        )
        self._release_meta_cache: collections.OrderedDict[str, str] = (
            collections.OrderedDict()
        )

        self._cache_limit = _MAX_CACHE_ENTRIES

        # Trusted IPs: local interfaces + snapserver — artwork from these is allowed
        # even though they're private IPs (SSRF exemption for co-located services)
        self._trusted_ips: set[str] = {"127.0.0.1", "::1"}
        try:
            for _fam, _, _, _, sa in socket.getaddrinfo(
                self.snapserver_host, None, socket.AF_UNSPEC
            ):
                self._trusted_ips.add(sa[0])
        except (socket.gaierror, OSError):
            pass
        # Get all local interface IPs (hostname resolution misses them on Debian)
        try:
            result = subprocess.run(
                ["hostname", "-I"], capture_output=True, text=True, timeout=5
            )
            for ip_str in result.stdout.split():
                self._trusted_ips.add(ip_str.strip())
        except (subprocess.SubprocessError, OSError) as e:
            logger.warning("Could not get hostname IPs for trusted list: %s", e)
        logger.info(f"Trusted IPs for artwork: {self._trusted_ips}")

        # Snapserver persistent socket
        self._snap_sock: socket.socket | None = None
        self._snap_buffer: bytes = b""
        self._snap_lock = threading.Lock()
        self._last_snap_response: float = 0.0
        self._snap_stale_threshold: float = 30.0

        self._mpd_was_connected = False
        self._mpd_last_fail: float = 0.0
        self._mpd_retry_interval: float = 10.0  # seconds between reconnection attempts
        self._mpd_last_retry_log: float = 0.0
        self._mpd_retry_log_interval: float = 30.0  # log retry attempts every 30s
        self.user_agent = "snapMULTI-MetadataService/1.0"
        self._server_version = os.environ.get("SNAPMULTI_VERSION", "unknown")

        # Client → stream mapping cache (refreshed each poll cycle)
        self._client_stream_map: dict[str, str] = {}

        # Track elapsed timers for sources without native position reporting
        # {stream_id: {"key": "title|artist", "start": monotonic, "accumulated": float}}
        self._track_timers: dict[str, dict[str, Any]] = {}

    @staticmethod
    def _cache_set(
        cache: collections.OrderedDict,
        key: str,
        value: str,
        limit: int = _MAX_CACHE_ENTRIES,
    ) -> None:
        """Set a cache entry, evicting oldest if at capacity. Thread-safe."""
        with _cache_lock:
            cache[key] = value
            cache.move_to_end(key)
            while len(cache) > limit:
                cache.popitem(last=False)

    def _mark_failed(self, url: str) -> None:
        """Record a failed download URL, bounded to _MAX_CACHE_ENTRIES."""
        with _cache_lock:
            self._failed_downloads[url] = None
            self._failed_downloads.move_to_end(url)
            while len(self._failed_downloads) > self._cache_limit:
                self._failed_downloads.popitem(last=False)

    @staticmethod
    def _release_meta_cache_value(date: str, original_date: str, genre: str) -> str:
        """Serialize release metadata for cache storage.

        Format is pipe-delimited for compactness and backward-compatible parsing.
        """
        return f"{date}|{original_date}|{genre}"

    @staticmethod
    def _parse_release_meta_cache(cached: str) -> tuple[str, str, str]:
        """Parse cached release metadata.

        Legacy cache entries stored `date|genre`; treat those as missing
        `original_date` so in-memory caches remain backward-compatible.
        """
        parts = cached.split("|")
        if len(parts) >= 3:
            return parts[0], parts[1], parts[2]
        if len(parts) == 2:
            return parts[0], "", parts[1]
        if len(parts) == 1:
            return parts[0], "", ""
        return "", "", ""

    # ──────────────────────────────────────────────
    # Socket helpers
    # ──────────────────────────────────────────────

    def _create_socket(
        self, host: str, port: int, timeout: int = 5, log_errors: bool = True
    ) -> socket.socket | None:
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(timeout)
            sock.connect((host, port))
            return sock
        except Exception as e:
            if log_errors:
                logger.error(f"Failed to connect to {host}:{port}: {e}")
            if sock is not None:
                try:
                    sock.close()
                except Exception:
                    pass
            return None

    def _get_snap_socket(self) -> socket.socket | None:
        # Check if existing socket is stale BEFORE reusing
        if self._snap_sock is not None:
            time_since_response = time.monotonic() - self._last_snap_response
            if time_since_response > self._snap_stale_threshold:
                logger.warning(
                    f"Snapserver socket stale ({time_since_response:.1f}s), reconnecting"
                )
                self._close_snap_socket()
            else:
                return self._snap_sock

        self._snap_sock = self._create_socket(
            self.snapserver_host, self.snapserver_port
        )
        if self._snap_sock:
            self._snap_sock.settimeout(10.0)
            self._last_snap_response = time.monotonic()
            logger.info(
                f"Connected to Snapserver {self.snapserver_host}:{self.snapserver_port}"
            )
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

    def send_rpc_request(
        self, sock: socket.socket, method: str, params: dict | None = None
    ) -> dict | None:
        request = {
            "id": 1,
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
        }
        try:
            sock.sendall((json.dumps(request) + "\r\n").encode())
        except OSError as e:
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
                    logger.warning(
                        f"Malformed JSON from Snapserver: {line[:100]!r}: {e}"
                    )
                    continue
                if "id" in msg:
                    self._last_snap_response = time.monotonic()
                    return msg
            try:
                chunk = sock.recv(8192)
                if not chunk:
                    return None
                self._snap_buffer += chunk
            except TimeoutError:
                logger.warning("Snapserver socket timeout")
                return None
            except OSError as e:
                logger.warning(f"Snapserver socket error: {e}")
                return None

    def get_server_status(self) -> dict | None:
        """Get full server status, with one retry on failure."""
        with self._snap_lock:
            if (
                self._snap_sock is not None
                and self._last_snap_response > 0
                and time.monotonic() - self._last_snap_response
                > self._snap_stale_threshold
            ):
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

    def _build_server_info(self, server: dict) -> dict:
        """Build server_info payload from current server status."""
        snap_info = server.get("snapserver", {})
        clients = sum(len(g.get("clients", [])) for g in server.get("groups", []))
        active = [
            s["id"] for s in server.get("streams", []) if s.get("status") == "playing"
        ]
        return {
            "type": "server_info",
            "server_version": self._server_version,
            "snapcast_version": snap_info.get("version", ""),
            "connected_clients": clients,
            "active_streams": active,
        }

    async def _broadcast_server_info(self, server: dict) -> None:
        """Broadcast server_info to all connected WebSocket clients."""
        info = self._build_server_info(server)
        msg = json.dumps(info)
        async with ws_clients_lock:
            clients_to_remove = set()
            for sc in list(ws_clients):  # Create list snapshot
                try:
                    await sc.websocket.send(msg)
                except Exception as exc:
                    logger.debug("server_info send failed, dropping client: %s", exc)
                    clients_to_remove.add(sc)
            # Remove failed clients outside iteration
            ws_clients.difference_update(clients_to_remove)

    @staticmethod
    def _match_client_id(client_id: str, identifiers: list[str]) -> bool:
        # Exact match or `snapclient-`-prefix-stripped exact match. Substring matching here would mis-route "Sala" volume to "Sala Grande".
        if any(client_id == i for i in identifiers if i):
            return True
        if client_id.startswith("snapclient-"):
            stripped = client_id[len("snapclient-") :]
            if any(stripped == i for i in identifiers if i):
                return True
        return False

    def _resolve_client_stream(self, client_id: str) -> str | None:
        """Resolve a CLIENT_ID to its stream_id using cached mapping.

        Resolution order:
          1. Exact match on `_client_stream_map` (the snapserver-reported
             client identifier).
          2. Strip the standard `snapclient-` prefix and try exact match
             again — handles the documented case where snapclient sets its
             ID as `snapclient-<hostname>` while snapserver registers
             `<hostname>`.

        Word-boundary fuzzy matching was removed: it correctly fixed the
        "Cucina" / "Cucinino" collision but still misfired on
        "Sala" / "Sala Grande" (the space is a word boundary, so `\bSala\b`
        matches both rooms). In a multiroom setup, sending metadata or
        volume commands to the wrong room is a worse failure mode than
        refusing to resolve and logging a warning. Users who relied on
        substring matching should rename their snapcast clients to match
        the snapserver identifier exactly, or use the `snapclient-` prefix
        convention.
        """
        # Exact match first
        if client_id in self._client_stream_map:
            return self._client_stream_map[client_id]
        # Documented prefix convention: snapclient may identify itself as
        # `snapclient-<hostname>` while snapserver registered just
        # `<hostname>`.
        if client_id.startswith("snapclient-"):
            stripped = client_id[len("snapclient-") :]
            if stripped in self._client_stream_map:
                logger.debug(
                    "Resolved '%s' via snapclient- prefix strip → '%s'",
                    client_id,
                    stripped,
                )
                return self._client_stream_map[stripped]
        logger.debug(
            "No stream match for client '%s' (registered: %s). "
            "Rename to match exactly or use 'snapclient-<id>' prefix.",
            client_id,
            list(self._client_stream_map.keys()),
        )
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
                if self._match_client_id(client_id, identifiers):
                    return client.get("config", {}).get(
                        "volume", {"percent": 100, "muted": False}
                    )
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
            for line in lines
            if ": " in line
            for key, value in [line.split(": ", 1)]
        }

    def _read_mpd_greeting(self, sock: socket.socket, validate: bool = False) -> bool:
        try:
            greeting = sock.recv(1024)
            if validate and not greeting.startswith(b"OK MPD"):
                return False
            return True
        except OSError:
            return False

    @staticmethod
    def _detect_codec(file_path: str, audio_fmt: str) -> str:
        if file_path.startswith(("http://", "https://")):
            return "RADIO"
        codec_map = {
            "flac": "FLAC",
            "wav": "WAV",
            "aiff": "AIFF",
            "aif": "AIFF",
            "mp3": "MP3",
            "ogg": "OGG",
            "opus": "OPUS",
            "m4a": "AAC",
            "aac": "AAC",
            "mp4": "AAC",
            "wma": "WMA",
            "ape": "APE",
            "wv": "WV",
            "dsf": "DSD",
            "dff": "DSD",
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

    def _extract_radio_metadata(
        self, title: str, artist: str, song: dict[str, str]
    ) -> tuple[str, str, str]:
        if not artist and " - " in title:
            parts = title.split(" - ", 1)
            artist = parts[0].strip()
            title = parts[1].strip() if len(parts) > 1 else title
        album = html.unescape(song.get("Album", "") or song.get("Name", ""))
        return title, artist, album

    def get_mpd_metadata(self) -> dict[str, Any]:
        # Cooldown: don't hammer MPD if it's unresponsive (e.g. NFS scan on startup)
        now = time.monotonic()
        if not self._mpd_was_connected and self._mpd_last_fail > 0:
            if now - self._mpd_last_fail < self._mpd_retry_interval:
                return {"playing": False, "source": "MPD"}

        sock = self._create_socket(
            self.mpd_host, self.mpd_port, timeout=2, log_errors=False
        )
        if not sock:
            self._mpd_last_fail = now
            if self._mpd_was_connected:
                logger.warning(f"MPD connection lost ({self.mpd_host}:{self.mpd_port})")
                self._mpd_was_connected = False
            elif now - self._mpd_last_retry_log > self._mpd_retry_log_interval:
                logger.info(
                    f"MPD still unreachable ({self.mpd_host}:{self.mpd_port}), retrying..."
                )
                self._mpd_last_retry_log = now
            return {"playing": False, "source": "MPD"}

        try:
            if not self._mpd_was_connected:
                logger.info(f"MPD connected ({self.mpd_host}:{self.mpd_port})")
                self._mpd_was_connected = True
                self._mpd_last_fail = 0.0

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
                "date": song.get("Date", ""),
                "genre": song.get("Genre", ""),
                "track": song.get("Track", ""),
                "disc": song.get("Disc", ""),
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

        # Skip artwork fetch if MPD is known to be down
        if not self._mpd_was_connected and self._mpd_last_fail > 0:
            if time.monotonic() - self._mpd_last_fail < self._mpd_retry_interval:
                return ""

        sock = self._create_socket(
            self.mpd_host, self.mpd_port, timeout=2, log_errors=False
        )
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
                while (
                    b"binary:" not in header
                    and b"OK\n" not in header
                    and b"ACK" not in header
                ):
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
                remaining = header[marker_pos + len(bin_marker) :]

                while len(remaining) < bin_size:
                    chunk = sock.recv(min(8192, bin_size - len(remaining)))
                    if not chunk:
                        return ""
                    remaining += chunk

                if len(image_data) + bin_size > self._MAX_MPD_ARTWORK_BYTES:
                    logger.warning(
                        f"MPD artwork exceeded size limit ({self._MAX_MPD_ARTWORK_BYTES} bytes)"
                    )
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
                try:
                    with open(tmp_path, "wb") as f:
                        f.write(image_data)
                    tmp_path.rename(local_path)
                except Exception as e:
                    logger.warning(f"MPD artwork write/rename failed: {e}")
                    try:
                        tmp_path.unlink(missing_ok=True)
                    except Exception:
                        pass
                    return ""
                logger.info(
                    f"Got MPD artwork ({len(image_data)} bytes) for {file_path}"
                )
                return filename

            return ""
        except OSError as e:
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
        _mb_rate_limit()
        query = urllib.parse.quote(f'artist:"{artist}" AND release:"{album}"')
        url = f"https://musicbrainz.org/ws/2/release/?query={query}&fmt=json&limit=5"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return ""
        for release in data.get("releases", []):
            score = release.get("score", 0)
            if score < 80:
                continue
            # Cache release metadata (date, genre) for enrich_tags()
            # Clean album name to match enrich_tags() cache key
            clean = album
            if "(" in clean and ")" not in clean:
                clean = clean[: clean.rfind("(")].rstrip()
            cache_key = f"{artist}|{clean}"
            date = release.get("date", "")
            original_date = ""
            tags = release.get("tags", [])
            genre = tags[0].get("name", "") if tags else ""
            release_group = release.get("release-group", {})
            release_group_id = (
                release_group.get("id", "") if isinstance(release_group, dict) else ""
            )
            if release_group_id:
                original_date = self.fetch_musicbrainz_release_group_first_date(
                    release_group_id
                )
            self._cache_set(
                self._release_meta_cache,
                cache_key,
                self._release_meta_cache_value(date, original_date, genre),
            )
            mbid = release.get("id")
            if mbid:
                return f"https://coverartarchive.org/release/{mbid}/front-500"
        return ""

    def fetch_musicbrainz_release_group_first_date(self, release_group_id: str) -> str:
        """Fetch the earliest known release date for a release group."""
        if not release_group_id:
            return ""
        _mb_rate_limit()
        url = f"https://musicbrainz.org/ws/2/release-group/{release_group_id}?fmt=json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return ""
        value = str(data.get("first-release-date", "") or "").strip()
        return value

    def enrich_tags(self, metadata: dict[str, Any]) -> None:
        """Fill in missing date/original_date/genre from MusicBrainz release data.

        Uses cached data from fetch_musicbrainz_artwork() — no extra API calls
        when artwork was already looked up. Only makes a new query if no cached
        release metadata exists.
        """
        if not metadata.get("playing"):
            return
        # Skip if already has all fields we can enrich.
        if (
            metadata.get("date")
            and metadata.get("original_date")
            and metadata.get("genre")
        ):
            return
        artist = metadata.get("artist", "")
        album = metadata.get("album", "")
        if not artist or not album:
            return

        # Clean album name: remove truncated parenthetical suffixes
        # e.g. "Version 2.0 (20th Annivers" → "Version 2.0"
        clean_album = album
        if "(" in clean_album and ")" not in clean_album:
            clean_album = clean_album[: clean_album.rfind("(")].rstrip()

        cache_key = f"{artist}|{clean_album}"
        cached = self._release_meta_cache.get(cache_key)

        if cached is None:
            # No cached data — trigger a MusicBrainz lookup
            _mb_rate_limit()
            query = urllib.parse.quote(f'artist:"{artist}" AND release:"{clean_album}"')
            url = (
                f"https://musicbrainz.org/ws/2/release/?query={query}&fmt=json&limit=5"
            )
            data = self._make_api_request(url)
            if data and isinstance(data, dict):
                for release in data.get("releases", []):
                    if release.get("score", 0) >= 80:
                        date = release.get("date", "")
                        original_date = ""
                        tags = release.get("tags", [])
                        genre = tags[0].get("name", "") if tags else ""
                        release_group = release.get("release-group", {})
                        release_group_id = (
                            release_group.get("id", "")
                            if isinstance(release_group, dict)
                            else ""
                        )
                        if release_group_id:
                            original_date = (
                                self.fetch_musicbrainz_release_group_first_date(
                                    release_group_id
                                )
                            )
                        cached = self._release_meta_cache_value(
                            date, original_date, genre
                        )
                        self._cache_set(self._release_meta_cache, cache_key, cached)
                        break
            if cached is None:
                self._cache_set(
                    self._release_meta_cache,
                    cache_key,
                    self._release_meta_cache_value("", "", ""),
                )
                return

        date, original_date, genre = self._parse_release_meta_cache(cached)
        if not metadata.get("date") and date:
            metadata["date"] = date
        if not metadata.get("original_date") and original_date:
            metadata["original_date"] = original_date
        if not metadata.get("genre") and genre:
            metadata["genre"] = genre

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
        if (
            not data
            or not isinstance(data, dict)
            or not (artists := data.get("artists", []))
        ):
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        artist_mbid = artists[0].get("id")
        if not artist_mbid:
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        _mb_rate_limit()

        url = f"https://musicbrainz.org/ws/2/artist/{artist_mbid}?inc=url-rels&fmt=json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        wikidata_id = self._get_wikidata_id_from_relations(data.get("relations", []))
        if not wikidata_id:
            self._cache_set(self.artist_image_cache, artist, "")
            return ""

        _mb_rate_limit()

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

    def fetch_album_artwork(self, artist: str, album: str) -> tuple[str, str]:
        """Fetch album artwork. Returns (url, source) tuple."""
        if not artist or not album:
            return "", ""

        cache_key = f"{artist}|{album}"
        if cache_key in self.artwork_cache:
            cached = self.artwork_cache[cache_key]
            # Expired failed lookup — retry after 1 hour
            if cached.startswith("|failed|"):
                try:
                    failed_at = int(cached.split("|")[2])
                    if time.monotonic() - failed_at < 3600:
                        return "", ""
                except (IndexError, ValueError):
                    pass
                self.artwork_cache.pop(cache_key, None)
            elif "|" in cached:
                url, source = cached.split("|", 1)
                return url, source
            elif cached:
                return cached, ""  # old-format entry — source unknown
            else:
                return "", ""

        # Priority: MusicBrainz (album-specific, scored) then iTunes
        artwork_url = self.fetch_musicbrainz_artwork(artist, album)
        if artwork_url:
            self._cache_set(self.artwork_cache, cache_key, f"{artwork_url}|musicbrainz")
            logger.info("Found MusicBrainz artwork for %s - %s", artist, album)
            return artwork_url, "musicbrainz"

        artwork_url = self._fetch_itunes_artwork(artist, album)
        if artwork_url:
            self._cache_set(self.artwork_cache, cache_key, f"{artwork_url}|itunes")
            logger.info("Found iTunes artwork for %s - %s", artist, album)
            return artwork_url, "itunes"

        # Cache miss with TTL — retry after 1 hour (don't cache failures forever)
        self._cache_set(
            self.artwork_cache, cache_key, f"|failed|{int(time.monotonic())}"
        )
        return "", ""

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

    def download_artwork(self, url: str, cache_key: str = "") -> str:
        """Download artwork, save to artwork dir. Returns filename or "".

        Args:
            url: The URL to download from.
            cache_key: Optional override for the cache hash. Use when the same
                URL serves different content (e.g. shairport-sync /cover.jpg).
        """
        fail_key = cache_key or url
        if not url or fail_key in self._failed_downloads:
            return ""

        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            logger.warning(f"Rejected artwork URL with scheme: {parsed.scheme}")
            self._mark_failed(fail_key)
            return ""

        # Block private/loopback IPs (SSRF protection)
        # Exception: allow IPs belonging to this host (snapserver, shairport-sync,
        # and other co-located services serve artwork on local interfaces).
        # Resolve once and connect to the resolved IP to prevent DNS rebinding
        resolved_ip = None
        try:
            blocked_addr = None
            for _family, _, _, _, sockaddr in socket.getaddrinfo(
                parsed.hostname or "", None, socket.AF_UNSPEC
            ):
                addr = sockaddr[0]
                ip = ipaddress.ip_address(addr)
                if (
                    ip.is_private
                    or ip.is_loopback
                    or ip.is_link_local
                    or ip.is_multicast
                    or ip.is_reserved
                ):
                    if addr in self._trusted_ips:
                        logger.debug(f"Allowing artwork from trusted local IP: {addr}")
                        resolved_ip = addr
                        break
                    else:
                        blocked_addr = addr
                        break
                else:
                    resolved_ip = addr
                    break
            if blocked_addr:
                logger.warning(
                    f"Blocked artwork download to restricted IP: {blocked_addr}"
                )
                self._mark_failed(fail_key)
                return ""
        except (socket.gaierror, ValueError, OSError) as e:
            logger.warning(f"Cannot resolve artwork host {parsed.hostname}: {e}")
            self._mark_failed(fail_key)
            return ""

        try:
            url_hash = hashlib.md5((cache_key or url).encode()).hexdigest()

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
                    fetch_url,
                    headers={"User-Agent": self.user_agent, "Host": parsed.hostname},
                )
            else:
                req = urllib.request.Request(
                    url, headers={"User-Agent": self.user_agent}
                )
            with urllib.request.urlopen(req, timeout=5) as response:
                data = b""
                dl_start = time.monotonic()
                while len(data) < self._MAX_ARTWORK_BYTES:
                    if time.monotonic() - dl_start > 15:
                        logger.warning("Artwork download total timeout (15s)")
                        self._mark_failed(fail_key)
                        return ""
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    data += chunk

                if len(data) >= self._MAX_ARTWORK_BYTES:
                    logger.warning(
                        f"Artwork exceeded size limit ({self._MAX_ARTWORK_BYTES} bytes)"
                    )
                    self._mark_failed(fail_key)
                    return ""

                if len(data) > 0:
                    ext = self._image_extension(data)
                    filename = f"artwork_{url_hash}{ext}"
                    local_path = self.artwork_dir / filename
                    tmp_path = local_path.parent / (local_path.name + ".tmp")
                    with open(tmp_path, "wb") as f:
                        f.write(data)
                    tmp_path.rename(local_path)
                    logger.info(
                        f"Downloaded artwork ({len(data)} bytes) to {local_path}"
                    )
                    return filename
                else:
                    logger.warning("Downloaded empty artwork")
                    self._mark_failed(fail_key)
                    return ""
        except Exception as e:
            logger.error(f"Failed to download artwork: {e}")
            self._mark_failed(fail_key)
            try:
                for tmp in self.artwork_dir.glob(f"artwork_{url_hash}*.tmp"):
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
            if (
                self._snap_sock is not None
                and self._last_snap_response > 0
                and time.monotonic() - self._last_snap_response
                > self._snap_stale_threshold
            ):
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
                    if self._match_client_id(client_id, identifiers):
                        snap_client_id = client.get("id")
                        break
                if snap_client_id:
                    break

            if not snap_client_id:
                logger.warning(f"Client {client_id} not found for volume control")
                return False

            volume = max(0, min(100, volume))
            params = {
                "id": snap_client_id,
                "volume": {"percent": volume, "muted": False},
            }
            response = self.send_rpc_request(sock, "Client.SetVolume", params)
            if response and "result" in response:
                logger.info(f"Set client {client_id} volume to {volume}%")
                return True
            return False

    # ──────────────────────────────────────────────
    # Source-specific position enrichment
    # ──────────────────────────────────────────────

    def get_spotify_position(self) -> tuple[int, int] | None:
        """Query go-librespot API for current track position and duration (seconds).

        Returns (elapsed, duration) or None if unavailable/paused/stopped.
        """
        try:
            url = f"http://{GO_LIBRESPOT_HOST}:{GO_LIBRESPOT_PORT}/status"
            req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
            with urllib.request.urlopen(req, timeout=2) as response:
                data = json.loads(response.read().decode())
            if data.get("stopped") or data.get("paused"):
                return None
            track = data.get("track", {})
            position_ms = track.get("position", 0)
            duration_ms = track.get("duration", 0)
            return (int(position_ms / 1000), int(duration_ms / 1000))
        except Exception as e:
            logger.debug(f"go-librespot API unavailable: {e}")
            return None

    def _estimate_elapsed(
        self, stream_id: str, track_key: str, is_playing: bool
    ) -> int:
        """Estimate elapsed seconds for sources without native position reporting.

        Tracks play/pause transitions per stream. Resets when track_key changes.
        """
        now = time.monotonic()
        timer = self._track_timers.get(stream_id)

        if timer is None or timer["key"] != track_key:
            # New track — reset timer
            self._track_timers[stream_id] = {
                "key": track_key,
                "start": now if is_playing else 0.0,
                "accumulated": 0.0,
            }
            return 0

        if is_playing:
            if timer["start"] == 0.0:
                # Resumed from pause
                timer["start"] = now
            return int(timer["accumulated"] + (now - timer["start"]))
        else:
            if timer["start"] > 0.0:
                # Just paused — accumulate elapsed
                timer["accumulated"] += now - timer["start"]
                timer["start"] = 0.0
            return int(timer["accumulated"])

    # ──────────────────────────────────────────────
    # Metadata change detection
    # ──────────────────────────────────────────────

    _VOLATILE_FIELDS = {
        "bitrate",
        "artwork",
        "artist_image",
        "artwork_source",
        "elapsed",
    }
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

        try:
            position = float(props.get("position") or 0)
        except (ValueError, TypeError):
            position = 0.0
        try:
            duration = float(meta.get("duration") or 0)
        except (ValueError, TypeError):
            duration = 0.0

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
        return f"http://{get_external_host()}:{HTTP_PORT}/artwork/{filename}"

    def enrich_artwork(self, metadata: dict[str, Any]) -> None:
        """Fetch/download artwork for a metadata dict. Mutates in place.

        Priority chain:
        1. Embedded art (MPD) / Snapcast HTTP art URL
        2. MusicBrainz Cover Art Archive (album-specific, score >= 80)
        3. iTunes Search API (album-specific, validated)
        4. Radio-Browser logo (radio streams only)
        5. artist_image (generic artist photo — last resort)
        6. Default radio placeholder (radio streams only)
        """
        if not metadata.get("playing"):
            return

        artwork_url = metadata.get("artwork", "")
        artwork_source = "snapcast" if artwork_url else ""
        is_radio = metadata.get("codec") == "RADIO"

        # For MPD files, try embedded cover art first
        if not artwork_url and metadata.get("source") == "MPD" and not is_radio:
            mpd_art = self.fetch_mpd_artwork(metadata.get("file", ""))
            if mpd_art:
                metadata["artwork"] = self._artwork_url(mpd_art)
                artwork_source = "embedded"
                artwork_url = None  # skip further lookups

        if not artwork_url and not metadata.get("artwork"):
            logger.debug(
                "No artwork from source for %s - %s (%s), trying fallback",
                metadata.get("artist"),
                metadata.get("album"),
                metadata.get("source"),
            )
            if is_radio and metadata.get("station_name"):
                artwork_url = self.fetch_radio_logo(
                    metadata["station_name"], metadata.get("file", "")
                )
                if artwork_url:
                    artwork_source = "radio-browser"
            elif metadata.get("artist") and metadata.get("album"):
                artwork_url, artwork_source = self.fetch_album_artwork(
                    metadata["artist"], metadata["album"]
                )

        # Download external artwork locally
        if artwork_url:
            cache_key = ""
            if "/cover.jpg" in artwork_url and metadata.get("title"):
                cache_key = (
                    f"{artwork_url}|{metadata.get('title', '')}"
                    f"|{metadata.get('artist', '')}"
                )
            local_file = self.download_artwork(artwork_url, cache_key=cache_key)
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
                    artwork_source = "radio-browser"

        # Final radio fallback
        if not metadata.get("artwork") and is_radio:
            metadata["artwork"] = (
                f"http://{get_external_host()}:{HTTP_PORT}/defaults/default-radio.png"
            )
            artwork_source = "default"

        # Artist image (not for radio) — download through SSRF-safe pipeline
        if not is_radio and metadata.get("artist"):
            artist_image_url = self.fetch_artist_image(metadata["artist"])
            if artist_image_url:
                cached = self.download_artwork(artist_image_url)
                if cached:
                    artist_image_served = (
                        f"http://{get_external_host()}:{HTTP_PORT}/artwork/{cached}"
                    )
                    metadata["artist_image"] = artist_image_served
                    # Last resort: use artist_image as artwork if nothing else found
                    if not metadata.get("artwork"):
                        logger.info(
                            "No album artwork for %s - %s, using artist image",
                            metadata.get("artist"),
                            metadata.get("album"),
                        )
                        metadata["artwork"] = artist_image_served
                        artwork_source = "artist_image"

        metadata["artwork_source"] = artwork_source

    # ──────────────────────────────────────────────
    # Main polling loop
    # ──────────────────────────────────────────────

    async def poll_loop(self) -> None:
        """Main loop: poll Snapserver, enrich metadata, broadcast to clients."""
        loop = asyncio.get_running_loop()
        consecutive_errors = 0
        server_info_counter = 0

        while True:
            try:
                server = await loop.run_in_executor(None, self.get_server_status)
                if not server:
                    await asyncio.sleep(5)
                    continue

                # Mark this iteration as a healthy round-trip with snapserver.
                # /health uses this timestamp to differentiate "container alive
                # AND talking to snapserver" from "container alive, snapserver
                # silent for N seconds". `time` already imported at module top.
                self.last_successful_poll_at = time.time()

                # Rebuild client → stream mapping (only if changed)
                new_map = self._build_client_stream_map(server)
                if new_map != self._client_stream_map:
                    self._client_stream_map = new_map

                # Update subscribed clients' stream_id, track switches
                stream_switched_clients: list[SubscribedClient] = []
                for sc in ws_clients.copy():
                    if sc.is_stream_subscriber:
                        continue  # Fixed stream_id; _resolve_client_stream("") must not be called
                    resolved = self._resolve_client_stream(sc.client_id)
                    if resolved and resolved != sc.stream_id:
                        logger.info(
                            f"Client '{sc.client_id}' switched: "
                            f"{sc.stream_id} -> {resolved}"
                        )
                        sc.stream_id = resolved
                        stream_switched_clients.append(sc)
                    elif resolved:
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
                        mpd_meta = await loop.run_in_executor(
                            None, self.get_mpd_metadata
                        )
                        if mpd_meta.get("playing"):
                            if not mpd_meta.get("title") and mpd_meta.get(
                                "station_name"
                            ):
                                mpd_meta["title"] = mpd_meta["station_name"]
                            metadata = mpd_meta

                    # Enrich non-MPD streams with position data
                    if metadata.get("source") != "MPD":
                        track_key = (
                            f"{metadata.get('title', '')}|{metadata.get('artist', '')}"
                        )
                        is_playing = metadata.get("playing", False) and track_key != "|"

                        if stream_id == "Spotify" and is_playing:
                            # Accurate position from go-librespot API
                            spotify_pos = await loop.run_in_executor(
                                None, self.get_spotify_position
                            )
                            if spotify_pos is not None:
                                metadata["elapsed"] = spotify_pos[0]
                                metadata["duration"] = spotify_pos[1]

                        # AirPlay, Tidal, etc.: estimate from local clock
                        estimated = self._estimate_elapsed(
                            stream_id, track_key, is_playing
                        )
                        if is_playing and metadata.get("elapsed", 0) <= 0:
                            metadata["elapsed"] = estimated

                    # Enrich with artwork and tags
                    await loop.run_in_executor(None, self.enrich_artwork, metadata)
                    await loop.run_in_executor(None, self.enrich_tags, metadata)

                    # Check for changes
                    changed = self._metadata_changed(metadata, sm.current)
                    volatile_changed = not changed and any(
                        metadata.get(f) != sm.current.get(f)
                        for f in self._VOLATILE_FIELDS
                    )

                    if changed:
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
                            logger.error(
                                f"Failed to write metadata for {stream_id}: {e}"
                            )
                            try:
                                tmp_file.unlink(missing_ok=True)
                            except Exception:
                                pass

                        # Broadcast to subscribed clients
                        await self._broadcast_to_stream(stream_id, metadata, server)

                # Send current metadata to clients that just switched streams
                stream_switch_failures: set[SubscribedClient] = set()
                for sc in stream_switched_clients:
                    sm = self.streams.get(sc.stream_id)
                    if sm and sm.current:
                        volume_info = self._find_client_volume(server, sc.client_id)
                        output = {
                            **self._output_metadata(sm.current),
                            "volume": volume_info.get("percent", 100),
                            "muted": volume_info.get("muted", False),
                        }
                        try:
                            await sc.websocket.send(json.dumps(output))
                        except Exception:
                            stream_switch_failures.add(sc)
                if stream_switch_failures:
                    async with ws_clients_lock:
                        ws_clients.difference_update(stream_switch_failures)

                server_info_counter += 1
                if server_info_counter >= 20:  # ~60s at 3s poll interval
                    server_info_counter = 0
                    await self._broadcast_server_info(server)

                consecutive_errors = 0

            except Exception as e:
                consecutive_errors += 1
                if consecutive_errors >= _POLL_LOOP_MAX_ERRORS:
                    logger.critical(
                        f"Poll loop: {consecutive_errors} consecutive errors, exiting"
                    )
                    raise SystemExit(1)
                logger.error(
                    f"Poll loop error ({consecutive_errors}/{_POLL_LOOP_MAX_ERRORS}): {e}"
                )

            await asyncio.sleep(3)

    async def _broadcast_to_stream(
        self, stream_id: str, metadata: dict, server: dict
    ) -> None:
        """Broadcast metadata to all clients subscribed to this stream."""
        output = self._output_metadata(metadata)
        clients_to_remove: set[SubscribedClient] = set()

        for sc in ws_clients.copy():
            if sc.stream_id != stream_id:
                continue

            # Stream subscribers get raw metadata; regular clients get per-client volume
            if sc.is_stream_subscriber:
                client_output = output
            else:
                volume_info = self._find_client_volume(server, sc.client_id)
                client_output = {
                    **output,
                    "volume": volume_info.get("percent", 100),
                    "muted": volume_info.get("muted", False),
                }

            try:
                await sc.websocket.send(json.dumps(client_output))
            except Exception:
                clients_to_remove.add(sc)

        # Mutate ws_clients under the lock — same invariant as
        # _broadcast_server_info / ws_handler.
        if clients_to_remove:
            async with ws_clients_lock:
                ws_clients.difference_update(clients_to_remove)

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
                # ws_clients is iterated under ws_clients_lock by
                # _broadcast_server_info; mutate under the same lock so
                # an iteration in flight cannot raise "Set changed size
                # during iteration".
                async with ws_clients_lock:
                    if sc:
                        ws_clients.discard(sc)
                    sc = SubscribedClient(websocket, client_id)
                    ws_clients.add(sc)
                logger.info(f"Client {client_addr} subscribed as '{client_id}'")

                # Resolve stream and send current metadata immediately
                if _service:
                    stream_id = _service._resolve_client_stream(client_id)
                    loop = asyncio.get_running_loop()
                    server = await loop.run_in_executor(
                        None, _service.get_server_status
                    )
                    if stream_id:
                        sc.stream_id = stream_id
                        sm = _service.streams.get(stream_id)
                        if sm and sm.current:
                            volume = (
                                _service._find_client_volume(server, client_id)
                                if server
                                else {}
                            )
                            output = {
                                **_service._output_metadata(sm.current),
                                "volume": volume.get("percent", 100),
                                "muted": volume.get("muted", False),
                            }
                            await websocket.send(json.dumps(output))
                    if server:
                        await websocket.send(
                            json.dumps(_service._build_server_info(server))
                        )
                continue

            # Stream subscription (controller clients — no client-ID resolution, no volume)
            if "subscribe_stream" in data:
                stream_name = str(data["subscribe_stream"])[:256]
                async with ws_clients_lock:
                    if sc:
                        ws_clients.discard(sc)
                    sc = SubscribedClient(websocket, stream_id_direct=stream_name)
                    ws_clients.add(sc)
                logger.info(
                    f"Client {client_addr} subscribed to stream '{stream_name}'"
                )
                if _service:
                    sm = _service.streams.get(stream_name)
                    if sm is None:
                        logger.warning(
                            f"Client {client_addr} subscribed to unknown stream '{stream_name}'"
                        )
                    elif sm.current:
                        await websocket.send(
                            json.dumps(_service._output_metadata(sm.current))
                        )
                    loop = asyncio.get_running_loop()
                    server = await loop.run_in_executor(
                        None, _service.get_server_status
                    )
                    if server:
                        await websocket.send(
                            json.dumps(_service._build_server_info(server))
                        )
                continue

            # Control commands (must be subscribed as a client, not a stream subscriber)
            if sc and not sc.is_stream_subscriber and _service and "cmd" in data:
                await _service.handle_control_command(sc.client_id, message)

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        if sc:
            async with ws_clients_lock:
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

    # Only serve image files (prevent leaking metadata_*.json)
    ext = filepath.suffix.lower()
    if ext not in {".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg"}:
        return web.Response(status=404)

    # Detect content type
    content_types = {
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".png": "image/png",
        ".gif": "image/gif",
        ".webp": "image/webp",
        ".svg": "image/svg+xml",
    }
    content_type = content_types.get(ext, "application/octet-stream")

    return web.FileResponse(
        filepath,
        headers={
            "Content-Type": content_type,
            "Cache-Control": "public, max-age=3600",
            "Access-Control-Allow-Origin": "*",
        },
    )


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
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }
    content_type = content_types.get(ext, "application/octet-stream")

    return web.FileResponse(
        filepath,
        headers={
            "Content-Type": content_type,
            "Cache-Control": "public, max-age=86400",
            "Access-Control-Allow-Origin": "*",
        },
    )


async def handle_metadata(request: web.Request) -> web.Response:
    """Serve metadata JSON for a specific stream or default."""
    stream_id = request.query.get("stream")

    if _service and stream_id and stream_id in _service.streams:
        sm = _service.streams[stream_id]
        output = (
            _service._output_metadata(sm.current) if sm.current else {"playing": False}
        )
    elif _service and _service.streams:
        # Default: first playing stream, or first stream
        playing = [s for s in _service.streams.values() if s.current.get("playing")]
        sm = playing[0] if playing else next(iter(_service.streams.values()))
        output = (
            _service._output_metadata(sm.current) if sm.current else {"playing": False}
        )
    else:
        output = {"playing": False}

    return web.json_response(
        output,
        headers={
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        },
    )


async def handle_health(request: web.Request) -> web.Response:
    """Health check endpoint.

    Returns 200 only if the poll_loop has had a successful round-trip with
    snapserver in the recent past. Otherwise returns 503 — Docker's
    healthcheck will mark the container unhealthy, surfacing the
    snapserver/RPC outage that a hardcoded 200 would have hidden.

    The threshold is generous (60 s) compared to the poll interval
    (~1 s healthy / 5 s on error) so brief snapserver restarts don't
    flap the metadata-service health.
    """
    base = {
        "status": "ok",
        "version": os.environ.get("SNAPMULTI_VERSION", "unknown"),
        "capabilities": ["subscribe_stream", "server_info"],
    }

    if _service is None:
        # Service hasn't initialised yet. Allow a short grace window;
        # Docker healthcheck has start_period=10s in compose anyway.
        return web.json_response(
            {**base, "status": "starting"},
            status=200,
            headers={"Access-Control-Allow-Origin": "*"},
        )

    last = _service.last_successful_poll_at
    if last == 0.0:
        # Process started but never managed a successful snapserver poll.
        # Could be: snapserver not yet up, RPC port firewall, host=wrong.
        return web.json_response(
            {**base, "status": "snapserver_unreachable", "last_poll_age_s": None},
            status=503,
            headers={"Access-Control-Allow-Origin": "*"},
        )

    age = time.time() - last
    base["last_poll_age_s"] = round(age, 1)
    if age > 60:
        return web.json_response(
            {**base, "status": "snapserver_stale"},
            status=503,
            headers={"Access-Control-Allow-Origin": "*"},
        )

    return web.json_response(
        base,
        headers={"Access-Control-Allow-Origin": "*"},
    )


# Cache latest version for 24h to avoid hammering GitHub API
_latest_version_cache: dict[str, str | float] = {"version": "", "checked_at": 0.0}


def _parse_version_tuple(version: str) -> tuple[int, ...] | None:
    """Parse 'v0.7.9.5' → (0, 7, 9, 5); None if any component is non-numeric."""
    if not version:
        return None
    try:
        return tuple(int(p) for p in version.lstrip("v").split("."))
    except ValueError:
        return None


async def handle_version(request: web.Request) -> web.Response:
    """Version check endpoint — returns current snapmulti_release, image_set, and latest from GitHub."""
    import time

    # SNAPMULTI_RELEASE is the git tag; SNAPMULTI_IMAGE_SET is the Docker tag; falls back to SNAPMULTI_VERSION on dev clones.
    snapmulti_release = os.environ.get("SNAPMULTI_RELEASE", "").strip()
    image_set = os.environ.get("SNAPMULTI_IMAGE_SET", "").strip() or os.environ.get(
        "SNAPMULTI_VERSION", "unknown"
    )
    current = snapmulti_release or image_set

    cache_ttl = 86400  # 24 hours
    latest = _latest_version_cache.get("version", "")
    checked_at = float(_latest_version_cache.get("checked_at", 0))

    if time.time() - checked_at > cache_ttl:
        # Claim the slot before await to prevent concurrent API calls (TOCTOU).
        _latest_version_cache["checked_at"] = time.time()
        try:
            import aiohttp as _aiohttp

            async with _aiohttp.ClientSession() as session:
                async with session.get(
                    "https://api.github.com/repos/lollonet/snapMULTI/releases/latest",
                    timeout=_aiohttp.ClientTimeout(total=10),
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        latest = data.get("tag_name", "").lstrip("v")
                        _latest_version_cache["version"] = latest
                    else:
                        logger.debug(
                            "GitHub API returned %d for version check", resp.status
                        )
                        _latest_version_cache["checked_at"] = (
                            0.0  # reset so next call retries
                        )
        except Exception as exc:
            logger.debug("Version check failed: %s", exc)
            _latest_version_cache["checked_at"] = 0.0  # reset so next call retries

    # "v" stripped uniformly: current arrives from .env with prefix, latest from GitHub without.
    current_clean = current.lstrip("v")
    latest_clean = (latest or current).lstrip("v")
    # Semver comparison: GitHub `releases/latest` only sees PUBLISHED releases,
    # so a tag-without-publish workflow can have current AHEAD of latest. Plain
    # `latest != current` then wrongly flags update_available=true and the
    # /status page renders the misleading "Update available: 0.7.9.5 -> 0.7.9.3".
    # Compare numeric tuples instead; fall back to `!=` only when one side is
    # unparseable (dev clone, pre-release tag, etc.).
    current_tuple = _parse_version_tuple(current_clean)
    latest_tuple = _parse_version_tuple(latest_clean) if latest else None
    if current_tuple is not None and latest_tuple is not None:
        update_available = latest_tuple > current_tuple
    else:
        update_available = bool(latest and latest != current_clean)

    return web.json_response(
        {
            "current": current_clean,
            "image_set": image_set,
            "latest": latest_clean,
            "update_available": update_available,
        },
        headers={"Access-Control-Allow-Origin": "*"},
    )


# ──────────────────────────────────────────────
# /status — system health page (issue #177)
# ──────────────────────────────────────────────

# Path inside the container — the host's /opt/snapmulti/audio is bind-mounted
# at /audio (already in compose). The systemd timer on the host writes the
# JSON snapshot here every 5 min.
STATUS_JSON_PATH = "/audio/system-status.json"

# Beginner-friendly grace period: when the snapshot file is older than this
# much after host boot, we still trust it; when it's MISSING entirely AND
# the container itself was started recently, we render "starting up" instead
# of "broken". This avoids the false-alarm fail screen during firstboot.
STATUS_BOOT_GRACE_SECONDS = 600  # 10 minutes


# ── Snapcast clients panel (#551) — live per-client state from the local
# snapserver's JSON-RPC API. Cached 30 s: clients change state (connect,
# disconnect, volume) faster than the 5-min snapshot timer can track.
SNAPCAST_RPC_URL = "http://127.0.0.1:1780/jsonrpc"
_SNAPCLIENTS_CACHE_TTL_SECONDS = 30
_snapclients_cache: dict[str, tuple[float, list[dict] | None]] = {}


def _parse_snapcast_clients(rpc_result: dict) -> list[dict]:
    """Extract flat client list from Server.GetStatus result.

    Snapcast result shape: result.server.groups[].clients[]. Each client carries
    connection state, host info, config (volume, stream), and last-seen timestamp.
    """
    clients: list[dict] = []
    server = rpc_result.get("server") if isinstance(rpc_result, dict) else None
    if not isinstance(server, dict):
        return []
    for group in server.get("groups") or []:
        if not isinstance(group, dict):
            continue
        group_name = str(group.get("name") or "")
        group_stream = str(group.get("stream_id") or "")
        for client in group.get("clients") or []:
            if not isinstance(client, dict):
                continue
            host = client.get("host") or {}
            config = client.get("config") or {}
            # Snapcast normally returns a non-null volume object, but old
            # servers / mid-state-transition can send `"volume": null` —
            # use isinstance instead of `or {}` so the null collapse doesn't
            # silently report muted=False / volume=0% for a real client.
            volume = (
                config.get("volume") if isinstance(config.get("volume"), dict) else {}
            )
            last_seen = client.get("lastSeen") or {}
            try:
                last_seen_sec = int(last_seen.get("sec", 0))
            except (TypeError, ValueError):
                last_seen_sec = 0
            try:
                volume_pct = int(volume.get("percent", 0))
            except (TypeError, ValueError):
                volume_pct = 0
            clients.append(
                {
                    "name": str(config.get("name") or host.get("name") or "?"),
                    "host": str(host.get("name") or "?"),
                    "ip": str(host.get("ip") or ""),
                    "connected": bool(client.get("connected")),
                    "muted": bool(volume.get("muted")),
                    "volume": volume_pct,
                    "stream": str(config.get("stream_id") or group_stream or ""),
                    "group": group_name,
                    "last_seen_sec": last_seen_sec,
                }
            )
    clients.sort(key=lambda c: (not c["connected"], c["name"].lower()))
    return clients


async def _fetch_snapcast_clients(timeout_s: float = 3.0) -> list[dict] | None:
    """POST `Server.GetStatus` to localhost snapserver; return clients or None on error."""
    now = time.time()
    cached = _snapclients_cache.get("data")
    if cached is not None and (now - cached[0]) < _SNAPCLIENTS_CACHE_TTL_SECONDS:
        return cached[1]

    payload = {"id": 1, "jsonrpc": "2.0", "method": "Server.GetStatus", "params": {}}
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                SNAPCAST_RPC_URL,
                json=payload,
                timeout=aiohttp.ClientTimeout(total=timeout_s),
            ) as resp:
                if resp.status != 200:
                    logger.debug("snapclients: RPC returned HTTP %d", resp.status)
                    _snapclients_cache["data"] = (now, None)
                    return None
                data = await resp.json()
    except Exception as exc:  # noqa: BLE001 — snapserver down is the common case.
        logger.debug("snapclients: RPC fetch failed: %s", exc)
        _snapclients_cache["data"] = (now, None)
        return None

    # JSON-RPC structured error — log so "API change" is distinguishable from
    # "snapserver down".
    rpc_error = data.get("error") if isinstance(data, dict) else None
    if rpc_error:
        logger.warning("snapclients: JSON-RPC error: %s", rpc_error)
        _snapclients_cache["data"] = (now, None)
        return None
    result = data.get("result") if isinstance(data, dict) else None
    if not isinstance(result, dict):
        _snapclients_cache["data"] = (now, None)
        return None
    clients = _parse_snapcast_clients(result)
    _snapclients_cache["data"] = (time.time(), clients)
    return clients


def _render_snapcast_clients_section(clients: list[dict] | None) -> str:
    """Render the Snapcast Clients section (#551)."""
    if clients is None:
        return (
            "<section><h2>Snapcast Clients</h2><ul>"
            '<li class="r-info"><span class="icon">ℹ</span>'
            "Snapserver JSON-RPC unreachable at 127.0.0.1:1780"
            "</li></ul></section>"
        )
    if not clients:
        return (
            "<section><h2>Snapcast Clients</h2><ul>"
            '<li class="r-info"><span class="icon">ℹ</span>'
            "No clients connected"
            "</li></ul></section>"
        )
    rows: list[str] = []
    for c in clients:
        if c["connected"]:
            icon_class, icon = "pass", "✓"
            state_label = "connected"
        else:
            icon_class, icon = "info", "ℹ"
            state_label = "disconnected"
        name = html.escape(c.get("name", "?"))
        ip = html.escape(c.get("ip", ""))
        stream = html.escape(c.get("stream", ""))
        group = html.escape(c.get("group", ""))
        # Parser already normalises volume to int, but defend against a
        # bypass path (future debug/test feeding the renderer directly):
        # graceful fallback to 0 instead of a 500 on the status page.
        try:
            vol = int(c.get("volume") or 0)
        except (TypeError, ValueError):
            vol = 0
        muted = " (muted)" if c.get("muted") else ""
        ip_part = f" · {ip}" if ip else ""
        stream_part = f" · stream {stream}" if stream else ""
        group_part = f" · group {group}" if group else ""
        rows.append(
            f'<li class="r-{icon_class}"><span class="icon">{icon}</span>'
            f"{name}{ip_part} — {state_label} · "
            f"volume {vol}%{muted}{stream_part}{group_part}</li>"
        )
    return (
        f"<section><h2>Snapcast Clients ({len(clients)})</h2>"
        f"<ul>{''.join(rows)}</ul></section>"
    )


_PROFILE_SERVICE_LIMITS: tuple[tuple[str, str], ...] = (
    ("snapserver", "SNAPSERVER_MEM_LIMIT"),
    ("airplay", "AIRPLAY_MEM_LIMIT"),
    ("spotify", "SPOTIFY_MEM_LIMIT"),
    ("mpd", "MPD_MEM_LIMIT"),
    ("mympd", "MYMPD_MEM_LIMIT"),
    ("metadata", "METADATA_MEM_LIMIT"),
    ("tidal", "TIDAL_MEM_LIMIT"),
)


def _get_resource_profile() -> dict | None:
    """Active profile from env vars set by deploy.sh / docker-compose.yml.

    Returns None when SNAPMULTI_PROFILE is empty (dev clone or manual
    `docker compose up` without deploy.sh): the section is hidden entirely
    rather than rendered with a misleading "unknown" placeholder.
    """
    name = os.environ.get("SNAPMULTI_PROFILE", "").strip()
    if not name:
        return None
    limits: list[tuple[str, str]] = []
    for label, var in _PROFILE_SERVICE_LIMITS:
        value = os.environ.get(var, "").strip()
        if value:
            limits.append((label, value))
    return {"name": name, "limits": limits}


def _render_resource_profile_section(profile: dict | None) -> str:
    """Render the Resource Profile section: name + per-service memory limits.

    Empty string when profile is None — the page omits the section entirely
    on dev clones. When the profile is set but no `*_MEM_LIMIT` env vars
    propagated (older deploys / partial wiring), render the name alone with
    an info row instead of an empty table.
    """
    if profile is None:
        return ""
    name = html.escape(profile["name"])
    limits: list[tuple[str, str]] = profile["limits"]
    head = (
        '<li class="r-pass"><span class="icon">✓</span>'
        f"Active profile: <strong>{name}</strong></li>"
    )
    if not limits:
        body = (
            '<li class="r-info"><span class="icon">ℹ</span>'
            "Per-service memory limits not propagated to this container."
            "</li>"
        )
    else:
        body = "".join(
            '<li class="r-info"><span class="icon">·</span>'
            f"{html.escape(svc)}: <code>{html.escape(lim)}</code></li>"
            for svc, lim in limits
        )
    return f"<section><h2>Resource Profile</h2><ul>{head}{body}</ul></section>"


def _read_status_snapshot() -> tuple[dict | None, float | None]:
    """Read the JSON snapshot file. Returns (data, age_seconds) or (None, None).

    Tolerant to:
      - missing file (timer not yet fired or never installed)
      - partial / unreadable file (concurrent write — atomic .tmp+mv on the
        timer side makes this rare, but defensively handle it anyway)
      - schema mismatch (unknown schema_version → still display, with banner)
    """
    try:
        st = os.stat(STATUS_JSON_PATH)
    except FileNotFoundError:
        return None, None
    except OSError:
        return None, None
    try:
        with open(STATUS_JSON_PATH) as f:
            data = json.load(f)
    except (json.JSONDecodeError, OSError):
        return None, None
    age = max(0.0, time.time() - st.st_mtime)
    return data, age


_SYSTEMD_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    # Pre-formatted check_timers.sh / check_systemd output. Group 1: unit,
    # group 2: literal state phrase, group 3: optional description.
    (
        re.compile(r"^(?:Timer|Path unit) (\S+) enabled and active(?: — (.+))?$"),
        "active",
    ),
    (re.compile(r"^systemd: (\S+) enabled and active$"), "active"),
    (
        re.compile(
            r"^(?:Timer|Path unit) (\S+) enabled but state is '([^']+)'(?: — (.+))?$"
        ),
        "broken",
    ),
    (re.compile(r"^(?:Timer|Path unit) (\S+) NOT installed(?: — (.+))?$"), "missing"),
    (re.compile(r"^(?:Timer|Path unit) (\S+) is '([^']+)'(?: — (.+))?$"), "disabled"),
)

_CONTAINER_PATTERN = re.compile(
    # Optional trailing description: ` — <text>` (unhealthy fail reason) and/or
    # ` (limit=<value>)` (HostConfig.Memory rendered by check_containers.sh).
    # Both are independent — `healthy (limit=64M)`, `unhealthy — probe failed`,
    # `unhealthy — probe failed (limit=128M)`, and plain `healthy` all match.
    # The state vocabulary is unchanged; only the trailing context is parsed
    # so the existing /status renderer can populate the `desc` column.
    r"^([a-z0-9][a-z0-9_-]+): "
    r"(healthy|unhealthy|starting|restarting|exited|created|paused|removing|dead)"
    r"(?:\s+—\s+(.+?))?"
    r"(?:\s+\(limit=([^)]+)\))?$"
)

_COMPOSE_NESTED_PATTERN = re.compile(r"^\s+(\w+)/(\S+) -> (\w+)$")


_NOISE_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"^\s*Per-HAT kernel module check skipped\b"),
    re.compile(r"^\s*Music mount checks: skipped\b"),
    re.compile(r"^\s*MPD state check skipped\b"),
    re.compile(r"^\s*No errors in systemd logs\b"),
    re.compile(r"^\s*No previous boot recorded in journal\b"),
    re.compile(r"^\s*No audio currently playing\b"),
)


def _is_noise_only_section(records: list[dict]) -> bool:
    """A section is "noise-only" if it contains only info/pass rows that
    match one of the known empty-confirmation patterns. Hiding these on
    a green page reduces scroll length without dropping signal — any
    real fail/warn or non-matching row keeps the section visible.

    Examples that ARE noise-only (hidden on green):
      Audio Modules: [info] Per-HAT kernel module check skipped (...)
      Recent Errors: [pass] No errors in systemd logs (last 10 min)
      Boot Health:   [info] No previous boot recorded in journal (...)
    """
    if not records:
        return True
    for r in records:
        status = r.get("status", "info")
        if status not in {"info", "pass"}:
            return False
        msg = r.get("msg", "")
        if not any(pat.match(msg) for pat in _NOISE_PATTERNS):
            return False
    return True


def _structured_systemd_row(section: str, msg: str) -> tuple[str, str, str, str] | None:
    """Parse a smoke record into (unit, state_label, state_class, desc) for
    tabular rendering. Returns None when the row should fall through to the
    default flat <li>NAME message</li> form.

    state_class is the CSS modifier ("" / "fail" / "warn") applied to the
    badge span — keep distinct from the row-level r-pass/r-fail/r-warn so a
    PASS row about a HEALTHY service can still get a green badge while a
    WARN row about a STARTING container gets an amber one.
    """
    if section in {"Timers", "Systemd"}:
        for pattern, kind in _SYSTEMD_PATTERNS:
            m = pattern.match(msg)
            if not m:
                continue
            unit = m.group(1)
            if kind == "active":
                # match form: "(Timer|Path unit|systemd:) NAME enabled and active[ — DESC]"
                desc = (m.group(2) if m.lastindex and m.lastindex >= 2 else "") or ""
                return unit, "enabled · active", "", desc
            if kind == "broken":
                state = m.group(2)
                desc = (m.group(3) or "") if m.lastindex and m.lastindex >= 3 else ""
                return unit, f"enabled · {state}", "fail", desc
            if kind == "missing":
                desc = (m.group(2) or "") if m.lastindex and m.lastindex >= 2 else ""
                return unit, "not installed", "fail", desc
            if kind == "disabled":
                state = m.group(2)
                desc = (m.group(3) or "") if m.lastindex and m.lastindex >= 3 else ""
                return unit, state, "warn", desc
        return None
    if section == "Containers":
        m = _CONTAINER_PATTERN.match(msg)
        if m:
            unit, state = m.group(1), m.group(2)
            state_class = {
                "healthy": "",
                "starting": "warn",
                "restarting": "warn",
                "paused": "warn",
                "removing": "warn",
                "created": "warn",
            }.get(state, "fail")
            extra = (m.group(3) or "").strip()
            limit = (m.group(4) or "").strip()
            # Join the fail reason and the limit value into a single desc
            # column so the renderer doesn't need two cells. "limit 64M"
            # uses the same dot-prefix the systemd unit rows use for
            # auxiliary context.
            parts = []
            if extra:
                parts.append(extra)
            if limit:
                parts.append(f"limit {limit}")
            return unit, state, state_class, " · ".join(parts)
        return None
    if section == "Compose":
        m = _COMPOSE_NESTED_PATTERN.match(msg)
        if m:
            group, unit, state = m.group(1), m.group(2), m.group(3)
            state_class = (
                ""
                if state == "healthy"
                else ("warn" if state in {"starting", "restarting"} else "fail")
            )
            return f"{group}/{unit}", state, state_class, ""
        return None
    return None


def _status_to_html(
    data: dict | None,
    age_s: float | None,
    snapclients: list[dict] | None = None,
    show_snapclients: bool = False,
) -> str:
    """Render the snapshot to a beginner-friendly HTML page.

    All content is escaped via html.escape — message text from device-smoke
    can contain anything (paths, error messages from journalctl, etc.) and
    we never want to interpret it as HTML.
    """
    import html

    # Boot-grace overlay: nothing to show yet AND container is fresh
    container_age = time.time() - _SERVICE_START_AT if _SERVICE_START_AT else 0
    if data is None and container_age < STATUS_BOOT_GRACE_SECONDS:
        return _render_html_shell(
            verdict_class="starting",
            verdict_icon="⏳",
            verdict_text="System is starting up…",
            subtext=(
                "snapMULTI is still bringing up its containers and running "
                "the first health check. This page refreshes every minute."
            ),
            sections_html="",
            footer="(no snapshot yet — usually appears within ~3 minutes of first boot)",
        )

    if data is None:
        return _render_html_shell(
            verdict_class="fail",
            verdict_icon="✗",
            verdict_text="No status snapshot available",
            subtext=(
                "The status timer has not produced a snapshot yet. "
                "Check that snapmulti-status.timer is enabled: "
                "<code>systemctl status snapmulti-status.timer</code>"
            ),
            sections_html="",
            footer="",
        )

    # Schema sanity
    schema = data.get("schema_version", 0)
    schema_banner = ""
    if schema != 1:
        schema_banner = (
            f'<div class="banner">⚠ Unknown snapshot schema (v{html.escape(str(schema))}). '
            f"This page may not display all fields correctly. Update the dashboard.</div>"
        )

    overall = data.get("status", "fail")
    failures = int(data.get("failures", 0))
    warnings = int(data.get("warnings", 0))
    hostname = data.get("hostname", "?")
    mode = data.get("mode", "?")

    if overall == "ok":
        verdict_class = "ok"
        verdict_icon = "✓"
        verdict_text = "All systems healthy"
        subtext = f"snapMULTI is running normally on <strong>{html.escape(hostname)}</strong> ({html.escape(mode)} mode)."
    elif overall == "warn":
        verdict_class = "warn"
        verdict_icon = "⚠"
        verdict_text = f"{warnings} warning(s) — non-critical"
        subtext = (
            "snapMULTI is running but some checks emitted warnings. "
            "Review below for details — these usually self-resolve."
        )
    else:
        verdict_class = "fail"
        verdict_icon = "✗"
        verdict_text = f"{failures} issue(s) need attention"
        subtext = "Some checks failed. The details below describe what to fix."

    # Group records by section
    records = data.get("records", [])
    sections: dict[str, list[dict]] = {}
    for r in records:
        sections.setdefault(r.get("section", "other"), []).append(r)

    # Resource profile is folded into the Containers section as a single
    # header row. The per-service limit sub-list that used to live in its
    # own bottom section is now redundant — each container row already
    # carries its own `limit XYZ` badge from check_containers.sh.
    profile = _get_resource_profile()
    profile_row = ""
    if profile is not None:
        profile_row = (
            '<li class="r-pass"><span class="icon">✓</span>'
            f"Active profile: <strong>{html.escape(profile['name'])}</strong>"
            "</li>"
        )

    sec_html_parts = []
    for sec_name, recs in sections.items():
        # Skip noise-only sections: when a section has nothing but
        # known "skipped" / "No errors found" confirmation rows, hide
        # it entirely. The check itself still ran and would have
        # surfaced any real fail/warn — those rows don't match the
        # noise patterns so the section stays visible. Net effect:
        # the reader doesn't scroll past silent positive confirmations.
        if _is_noise_only_section(recs):
            continue
        rows = []
        if sec_name == "Containers" and profile_row:
            rows.append(profile_row)
        for r in recs:
            status = r.get("status", "info")
            raw_msg = r.get("msg", "")
            # Decode systemd-escape `\xNN` sequences so unit names like
            # `media-nfs\x2dmusic.automount` render as
            # `media-nfs-music.automount`. The bytes come from
            # systemd-escape on a mount path containing `-` and are
            # opaque without decoding. Restricted to `\xNN` (2 hex
            # digits) to avoid touching legitimate backslash content.
            raw_msg = re.sub(
                r"\\x([0-9a-fA-F]{2})",
                lambda m: chr(int(m.group(1), 16)),
                raw_msg,
            )
            icon = {"pass": "✓", "fail": "✗", "warn": "⚠", "info": "ℹ"}.get(status, "•")
            structured = _structured_systemd_row(sec_name, raw_msg)
            if structured is not None:
                unit, state_label, state_class, desc = structured
                badge_class = f"state-badge {state_class}".strip()
                desc_html = (
                    f'<span class="desc">{html.escape(desc)}</span>' if desc else ""
                )
                rows.append(
                    f'<li class="r-{status} row-systemd">'
                    f'<span class="icon">{icon}</span>'
                    f'<span class="unit">{html.escape(unit)}</span>'
                    f'<span class="{badge_class}">{html.escape(state_label)}</span>'
                    f"{desc_html}"
                    f"</li>"
                )
            else:
                msg = html.escape(raw_msg)
                rows.append(
                    f'<li class="r-{status}"><span class="icon">{icon}</span>{msg}</li>'
                )
        sec_html_parts.append(
            f"<section><h2>{html.escape(sec_name)}</h2><ul>{''.join(rows)}</ul></section>"
        )

    # Snapcast clients (#551) — appended whenever we have a live snapshot,
    # so the operator sees per-client state alongside the aggregate counts
    # already in the Compose / Snapcast sections.
    if show_snapclients:
        sec_html_parts.append(_render_snapcast_clients_section(snapclients))

    # NOTE: the Resource Profile section was folded into Containers above —
    # _render_resource_profile_section() is still exported for the unit test
    # but no longer called from the rendering path. Container rows already
    # carry the per-service limit value from check_containers.sh.

    if age_s is not None:
        if age_s < 60:
            age_label = f"{int(age_s)}s ago"
        elif age_s < 3600:
            age_label = f"{int(age_s / 60)}m ago"
        else:
            age_label = f"{int(age_s / 3600)}h ago"
        finished_at = (data or {}).get("finished_at", "")
        if finished_at:
            try:
                ts = datetime.fromisoformat(
                    finished_at.replace("Z", "+00:00")
                ).astimezone()
                abs_label = ts.strftime("%Y-%m-%d %H:%M %Z")
                footer = f"Snapshot taken <strong>{abs_label}</strong> ({age_label}). Snapshot updates every 5 min; this page auto-refreshes every minute."
            except (ValueError, TypeError):
                footer = f"Snapshot taken <strong>{age_label}</strong>. Snapshot updates every 5 min; this page auto-refreshes every minute."
        else:
            footer = f"Snapshot taken <strong>{age_label}</strong>. Snapshot updates every 5 min; this page auto-refreshes every minute."
    else:
        footer = ""

    return _render_html_shell(
        verdict_class=verdict_class,
        verdict_icon=verdict_icon,
        verdict_text=verdict_text,
        subtext=schema_banner + subtext,
        sections_html="".join(sec_html_parts),
        footer=footer,
        embedded_json=json.dumps(data).replace("</", "<\\/"),
    )


def _render_html_shell(
    *,
    verdict_class: str,
    verdict_icon: str,
    verdict_text: str,
    subtext: str,
    sections_html: str,
    footer: str,
    embedded_json: str = "{}",
) -> str:
    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>snapMULTI status</title>
<style>
  /* Dark theme — matches the snapMULTI fb-display aesthetic (dark TV/DAC look).
     Designed for high contrast in a living-room context where the page might
     be shown on a TV-connected Pi alongside the snapcast web UI. */
  :root {{
    --bg:           #15181c;
    --panel:        #1f242b;
    --border:       #2c333d;
    --text:         #e6e8eb;
    --text-dim:     #97a0ad;
    --text-faint:   #5a6271;
    --accent-ok:    #4ade80;  /* mint green */
    --accent-warn:  #fbbf24;  /* amber */
    --accent-fail:  #f87171;  /* coral */
    --accent-info:  #60a5fa;  /* sky */
    --accent-boot:  #a78bfa;  /* violet */
  }}
  * {{ box-sizing: border-box; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", sans-serif;
    max-width: 820px; margin: 0 auto; padding: 1.5rem;
    color: var(--text); background: var(--bg);
    line-height: 1.5;
  }}
  h1 {{ margin: 0 0 .4rem; font-size: 1.45rem; font-weight: 600; }}
  .verdict {{
    padding: 1.1rem 1.3rem; border-radius: .6rem; margin-bottom: 1.2rem;
    background: var(--panel); border-left: 6px solid var(--text-faint);
  }}
  .verdict .icon {{ font-size: 1.6rem; margin-right: .55rem; vertical-align: -2px; }}
  .verdict.ok       {{ border-left-color: var(--accent-ok);   }}
  .verdict.ok       .icon {{ color: var(--accent-ok);         }}
  .verdict.warn     {{ border-left-color: var(--accent-warn); }}
  .verdict.warn     .icon {{ color: var(--accent-warn);       }}
  .verdict.fail     {{ border-left-color: var(--accent-fail); }}
  .verdict.fail     .icon {{ color: var(--accent-fail);       }}
  .verdict.starting {{ border-left-color: var(--accent-boot); }}
  .verdict.starting .icon {{ color: var(--accent-boot);       }}
  .verdict h1 {{ display: inline; }}
  .verdict p  {{ margin: .5rem 0 0; color: var(--text-dim); }}
  .banner {{
    padding: .7rem 1rem; background: rgba(251,191,36,.12);
    border-left: 4px solid var(--accent-warn);
    margin-bottom: 1rem; font-size: .92rem;
  }}
  section {{
    background: var(--panel); border: 1px solid var(--border);
    border-radius: .5rem; margin-bottom: 1rem; padding: .9rem 1.1rem;
  }}
  section h2 {{
    font-size: .82rem; margin: 0 0 .55rem; color: var(--text-dim);
    text-transform: uppercase; letter-spacing: .08em; font-weight: 600;
  }}
  ul {{ list-style: none; padding: 0; margin: 0; }}
  li {{
    padding: .35rem 0; border-bottom: 1px solid var(--border);
    font-size: .94rem;
  }}
  li:last-child {{ border-bottom: none; }}
  li .icon {{ display: inline-block; width: 1.6em; }}
  .r-pass {{ color: var(--text); }}
  .r-pass .icon {{ color: var(--accent-ok); }}
  .r-fail .icon {{ color: var(--accent-fail); }}
  .r-fail        {{ color: var(--text); }}
  .r-warn .icon {{ color: var(--accent-warn); }}
  .r-warn        {{ color: var(--text); }}
  .r-info .icon {{ color: var(--accent-info); }}
  .r-info        {{ color: var(--text-dim); }}
  /* Tabular rendering for systemd unit / container rows. Three-column
     grid: name (monospace) | state badge | description. Falls back to
     a stacked layout on narrow viewports. */
  li.row-systemd {{
    display: grid;
    grid-template-columns: 1.6em minmax(0, 17em) min-content 1fr;
    gap: .55rem;
    align-items: baseline;
  }}
  li.row-systemd .unit {{
    font-family: "SF Mono", Menlo, Consolas, monospace;
    font-size: .88em; color: var(--text);
    white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  }}
  li.row-systemd .state-badge {{
    font-size: .68rem; text-transform: uppercase; letter-spacing: .05em;
    padding: .12rem .5rem; border-radius: .3rem; white-space: nowrap;
    background: rgba(74,222,128,.18); color: var(--accent-ok);
    font-weight: 600;
  }}
  li.row-systemd .state-badge.fail {{ background: rgba(248,113,113,.18); color: var(--accent-fail); }}
  li.row-systemd .state-badge.warn {{ background: rgba(251,191,36,.18); color: var(--accent-warn); }}
  li.row-systemd .desc {{ color: var(--text-dim); font-size: .9em; }}
  @media (max-width: 600px) {{
    li.row-systemd {{
      grid-template-columns: 1.6em 1fr min-content;
      grid-template-areas: "icon unit badge" ".    desc desc";
    }}
    li.row-systemd .icon  {{ grid-area: icon; }}
    li.row-systemd .unit  {{ grid-area: unit; }}
    li.row-systemd .state-badge {{ grid-area: badge; }}
    li.row-systemd .desc  {{ grid-area: desc; }}
  }}
  code {{
    background: rgba(255,255,255,.06); color: var(--text);
    padding: .12rem .4rem; border-radius: .25rem;
    font-size: .88em; font-family: "SF Mono", Menlo, Consolas, monospace;
  }}
  strong {{ color: var(--text); font-weight: 600; }}
  footer {{
    margin-top: 1.5rem; font-size: .82rem;
    color: var(--text-faint); text-align: center;
  }}
  footer strong {{ color: var(--text-dim); }}
</style>
</head><body>
<div class="verdict {verdict_class}">
  <h1><span class="icon">{verdict_icon}</span>{verdict_text}</h1>
  <p>{subtext}</p>
</div>
{sections_html}
<footer>{footer}</footer>
<script id="status-data" type="application/json">{embedded_json}</script>
</body></html>"""


async def handle_status(request: web.Request) -> web.Response:
    """System status page — issue #177.

    Default content: HTML for browsers (the issue's primary audience).
    Programmatic clients can request JSON via `?format=json` or by parsing
    the embedded `<script id="status-data">` block in the HTML.

    Security note: the JSON response carries hostname, mount-point paths,
    and recent journalctl snippets. Other endpoints on this service expose
    artwork / metadata that browsers fetch from the snapcast Web UI, hence
    the `Access-Control-Allow-Origin: *` header — but the status snapshot
    is operational/diagnostic information and the same header would let
    any web page on the LAN read it just by knowing the host. We do NOT
    set CORS on `/status` (HTML or JSON): browsers can still fetch their
    own origin (the snapMULTI host's own pages), but third-party sites
    cannot exfiltrate the diagnostic payload.
    """
    data, age_s = _read_status_snapshot()
    fmt = request.query.get("format", "")
    if fmt == "json":
        if data is None:
            return web.json_response(
                {"status": "no_snapshot"},
                status=503,
                headers={"Cache-Control": "no-store"},
            )
        return web.json_response(
            data,
            headers={"Cache-Control": "no-store"},
        )
    # Fetch live snapcast client state only when we already have a snapshot to
    # render (during the boot grace window the page is the "starting up"
    # placeholder — no point doing the RPC then).
    snapclients = await _fetch_snapcast_clients() if data is not None else None
    body = _status_to_html(
        data, age_s, snapclients=snapclients, show_snapclients=data is not None
    )
    return web.Response(
        text=body,
        content_type="text/html",
        charset="utf-8",
        headers={"Cache-Control": "no-store"},
    )


async def handle_root_redirect(request: web.Request) -> web.Response:
    """`GET /` → landing page listing every snapMULTI server endpoint."""
    # IPv6 Host headers are bracketed (`[::1]:8083` or bare `[::1]`); rsplit on a bare `[::1]` would yield `"[:"`. Handle that first.
    host_hdr = request.host or "localhost"
    if host_hdr.startswith("["):
        close = host_hdr.find("]")
        bare_host = host_hdr[: close + 1] if close > 0 else host_hdr
    elif ":" in host_hdr:
        bare_host = host_hdr.rsplit(":", 1)[0]
    else:
        bare_host = host_hdr

    # Browser-clickable (HTTP GET, returns HTML or JSON the user can read).
    web_services = [
        (
            "Snapweb",
            f"http://{bare_host}:1780",
            "Per-room volume, group speakers, switch source",
        ),
        ("myMPD", f"http://{bare_host}:8180", "Browse and play your music library"),
        (
            "Status page",
            f"http://{bare_host}:8083/status",
            "Containers, audio chain, network, mDNS",
        ),
        (
            "Version",
            f"http://{bare_host}:8083/version",
            "Release tag + image set (JSON)",
        ),
        (
            "Metadata (JSON)",
            f"http://{bare_host}:8083/metadata.json",
            "Current track info (JSON)",
        ),
        ("Health probe", f"http://{bare_host}:8083/health", "Liveness check (JSON)"),
    ]
    # Programmatic only (POST or WebSocket — not browser-navigable).
    api_endpoints = [
        (
            "Snapcast JSON-RPC",
            f"http://{bare_host}:1780/jsonrpc",
            "Programmatic Snapcast control (POST)",
        ),
        (
            "Metadata WebSocket",
            f"ws://{bare_host}:8082",
            "Live track + cover-art stream",
        ),
    ]

    items = "\n".join(
        f'    <li><a href="{html.escape(url)}"><strong>{html.escape(name)}</strong></a>'
        f' <span class="desc">{html.escape(desc)}</span></li>'
        for name, url, desc in web_services
    )
    api_items = "\n".join(
        f"    <li><code>{html.escape(url)}</code>"
        f' <span class="desc"><strong>{html.escape(name)}</strong> — {html.escape(desc)}</span></li>'
        for name, url, desc in api_endpoints
    )

    body = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>snapMULTI — {html.escape(bare_host)}</title>
<style>
  body {{ font-family: -apple-system, BlinkMacSystemFont, system-ui, "Segoe UI", sans-serif;
         max-width: 720px; margin: 0 auto; padding: 1.5rem;
         color: #e6e8eb; background: #15181c; line-height: 1.5; }}
  h1 {{ font-size: 1.45rem; margin: 0 0 .3rem; color: #ffa218; }}
  p.sub {{ color: #97a0ad; margin: 0 0 1.5rem; font-size: .9rem; }}
  ul {{ list-style: none; padding: 0; margin: 0; }}
  li {{ background: #1f242b; border: 1px solid #2c333d; border-radius: .5rem;
        padding: .9rem 1.1rem; margin-bottom: .6rem; }}
  a {{ color: #60a5fa; text-decoration: none; font-size: 1.05rem; }}
  a:hover {{ text-decoration: underline; }}
  strong {{ color: #e6e8eb; }}
  .desc {{ display: block; color: #97a0ad; font-size: .88rem; margin-top: .15rem; }}
  code {{ font-family: "SF Mono", Menlo, Consolas, monospace; font-size: .92em;
          background: rgba(255,255,255,.06); padding: .1rem .4rem; border-radius: .25rem; }}
  h2 {{ font-size: .82rem; margin: 1.4rem 0 .55rem; color: #97a0ad;
        text-transform: uppercase; letter-spacing: .08em; font-weight: 600; }}
  footer {{ margin-top: 2rem; color: #5a6271; font-size: .82rem; text-align: center; }}
  footer a {{ color: #5a6271; }}
</style>
</head><body>
<h1>snapMULTI</h1>
<p class="sub">Server endpoints on <code>{html.escape(bare_host)}</code></p>
<h2>Web interfaces</h2>
<ul>
{items}
</ul>
<h2>APIs (programmatic)</h2>
<ul>
{api_items}
</ul>
<footer>
  <a href="https://github.com/lollonet/snapMULTI">github.com/lollonet/snapMULTI</a>
</footer>
</body></html>
"""
    return web.Response(text=body, content_type="text/html", charset="utf-8")


# Track service start time for the boot-grace overlay logic
_SERVICE_START_AT = time.time()


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
    logger.info(f"  External host: {get_external_host()}")
    try:
        if ipaddress.ip_address(socket.gethostbyname(get_external_host())).is_loopback:
            logger.warning(
                "EXTERNAL_HOST resolved to loopback after auto-detection failed — "
                "remote clients won't be able to fetch artwork. "
                "Set EXTERNAL_HOST=<lan-ip> in /opt/snapmulti/.env if you have clients on other hosts."
            )
    except (socket.gaierror, ValueError):
        pass
    logger.info(f"  MPD: {MPD_HOST}:{MPD_PORT}")
    logger.info(f"  WebSocket port: {WS_PORT}")
    logger.info(f"  HTTP port: {HTTP_PORT}")
    logger.info(f"  Artwork dir: {ARTWORK_DIR}")

    # Start WebSocket server
    ws_server = await websockets.serve(ws_handler, "0.0.0.0", WS_PORT)  # noqa: F841 — prevents GC
    logger.info(f"WebSocket server listening on port {WS_PORT}")

    # Start HTTP server
    app = web.Application()
    app.router.add_get("/artwork/{filename}", handle_artwork)
    app.router.add_get("/defaults/{filename}", handle_defaults)
    app.router.add_get("/metadata.json", handle_metadata)
    app.router.add_get("/health", handle_health)
    app.router.add_get("/version", handle_version)
    app.router.add_get("/status", handle_status)
    # Landing page redirects to /status — beginners just type the host:port
    # in a browser and get the health dashboard, no endpoint guessing.
    app.router.add_get("/", handle_root_redirect)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", HTTP_PORT)
    await site.start()
    logger.info(f"HTTP server listening on port {HTTP_PORT}")

    # Start polling loop
    await _service.poll_loop()


async def _async_main() -> None:
    """Async entry point with asyncio-aware signal handlers.

    Without explicit handlers, SIGTERM from `docker stop` is queued by
    Python but never processed: under `asyncio.run(main())` the loop
    spends its time inside `await` points where Python only checks
    signals between bytecode instructions. Docker waits stop_grace_period
    (default 10 s) then SIGKILLs, but the host-visible PID lingers as
    defunct while systemd-shutdown waits DefaultTimeoutStopSec (~90 s)
    per zombie. On a `both` install (server+client on the same Pi)
    that's three Python containers: fb-display, audio-visualizer, and
    this metadata-service — each adding ~90 s to reboot.

    `loop.add_signal_handler()` routes the signal through the loop so
    a clean SystemExit unwinds asyncio.run() promptly.
    """

    def _shutdown(*_):
        sys.exit(0)

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _shutdown)
    await main()


if __name__ == "__main__":
    asyncio.run(_async_main())
