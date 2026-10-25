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
import concurrent.futures
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
import urllib.error
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
# resolvers, blocking every pytest import). Runtime Pi hosts hit LAN DNS so
# cost is sub-millisecond.
#
# Re-resolved with a TTL instead of once per process: the container can start
# before DHCP/WiFi has an address (every artwork URL would then say
# 127.0.0.1 until restart) and the LAN IP can change on a DHCP renewal. A
# loopback result is retried sooner. An explicit EXTERNAL_HOST is never
# re-resolved.
_EXTERNAL_HOST: str | None = None
_EXTERNAL_HOST_AT: float = 0.0
_EXTERNAL_HOST_TTL = 60.0
_EXTERNAL_HOST_LOOPBACK_TTL = 10.0
_external_host_lock = threading.Lock()


def _is_loopback_host(host: str) -> bool:
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "localhost"


def get_external_host() -> str:
    global _EXTERNAL_HOST, _EXTERNAL_HOST_AT
    explicit = os.environ.get("EXTERNAL_HOST", "")
    if explicit:
        return explicit
    with _external_host_lock:
        now = time.monotonic()
        if _EXTERNAL_HOST is not None:
            ttl = (
                _EXTERNAL_HOST_LOOPBACK_TTL
                if _is_loopback_host(_EXTERNAL_HOST)
                else _EXTERNAL_HOST_TTL
            )
            if now - _EXTERNAL_HOST_AT < ttl:
                return _EXTERNAL_HOST
        host = _resolve_external_host()
        if _EXTERNAL_HOST is not None and host != _EXTERNAL_HOST:
            logger.info("External host changed: %s -> %s", _EXTERNAL_HOST, host)
        _EXTERNAL_HOST = host
        _EXTERNAL_HOST_AT = now
        return host


_POLL_LOOP_MAX_ERRORS = 30

# MusicBrainz rate limiter (1 request per 1.1 seconds, shared across threads)
_mb_last_request: float = 0.0
_mb_lock = threading.Lock()

# Lock for OrderedDict cache reads/mutations. enrich_artwork / enrich_tags
# run as background tasks on a small thread pool (one task per stream/track,
# so several can run at once): OrderedDict's internal doubly-linked list
# pointers can be corrupted by concurrent move_to_end / popitem, with crashes
# (KeyError) hard to reproduce.
_cache_lock = threading.Lock()

# Negative-cache TTLs. A lookup that answered "no match" is retried after
# _NEG_TTL_MISS; a lookup that failed (timeout, 5xx, DNS) after _NEG_TTL_ERROR.
_NEG_TTL_MISS = 3600.0
_NEG_TTL_ERROR = 600.0
_NEG_PREFIX = "|failed|"

# Failed artwork downloads: a transient failure (timeout, 5xx, blocked
# address that may become trusted after a DHCP change) is retried after
# _FAIL_TTL_TRANSIENT; a permanent one (404/410, bad scheme, oversized) after
# _FAIL_TTL_PERMANENT. Never "forever" — a single CAA timeout used to hide an
# album's cover until the container restarted.
_FAIL_TTL_TRANSIENT = 600.0
_FAIL_TTL_PERMANENT = 6 * 3600.0

# Artwork directory cap. AirPlay writes one file per track; on read-only
# installs the directory lives in RAM. Pruned at runtime, oldest first.
_ARTWORK_MAX_FILES = 300
_ARTWORK_MAX_BYTES = 50_000_000
_ARTWORK_PRUNE_INTERVAL = 30.0

# Max redirects followed by any external fetch (each hop is re-validated).
_MAX_REDIRECTS = 5


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


# ──────────────────────────────────────────────
# MPD protocol (line-based, binary-safe)
# ──────────────────────────────────────────────


class MPDProtocolError(Exception):
    """Malformed/truncated MPD reply or connection closed mid-reply."""


class MPDCommandError(Exception):
    """MPD answered a command with `ACK ...`."""


class MPDConnection:
    """Minimal MPD protocol reader over a connected socket.

    Parses replies line by line on the text part only: `key: value` lines
    until `OK` or a line starting with `ACK `. A `binary: N` line is followed
    by exactly N raw bytes plus a trailing newline, read by length — never
    scanned for markers. Substring checks on the raw stream (`b"ACK" in
    data`, `b"OK\\n" in data`) used to stop early on image bytes or tag values
    such as "BACK IN BLACK", truncating artwork and replies.
    """

    _MAX_LINE = 65536

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.buf = bytearray()
        self.version: tuple[int, ...] = ()

    def _fill(self) -> None:
        chunk = self.sock.recv(65536)
        if not chunk:
            raise MPDProtocolError("connection closed")
        self.buf += chunk

    def read_line(self) -> bytes:
        while True:
            idx = self.buf.find(b"\n")
            if idx >= 0:
                line = bytes(self.buf[:idx])
                del self.buf[: idx + 1]
                return line
            if len(self.buf) > self._MAX_LINE:
                raise MPDProtocolError("reply line too long")
            self._fill()

    def read_exact(self, size: int) -> bytes:
        while len(self.buf) < size:
            self._fill()
        data = bytes(self.buf[:size])
        del self.buf[:size]
        return data

    def read_greeting(self) -> str:
        line = self.read_line()
        if not line.startswith(b"OK MPD "):
            raise MPDProtocolError(f"unexpected greeting {line[:40]!r}")
        version = line[7:].decode("ascii", errors="replace").strip()
        try:
            self.version = tuple(int(p) for p in version.split("."))
        except ValueError:
            self.version = ()
        return version

    def command(
        self, cmd: str, max_binary: int = 0
    ) -> tuple[list[tuple[str, str]], bytes | None]:
        """Send one command; return (key/value pairs, binary payload or None).

        Raises MPDCommandError on ACK, MPDProtocolError on a malformed reply,
        OSError/TimeoutError on socket failure.
        """
        self.sock.sendall(cmd.encode("utf-8") + b"\n")
        pairs: list[tuple[str, str]] = []
        binary: bytes | None = None
        while True:
            line = self.read_line()
            if line == b"OK":
                return pairs, binary
            if line.startswith(b"ACK "):
                raise MPDCommandError(line.decode("utf-8", errors="replace"))
            key, sep, value = line.partition(b": ")
            if not sep:
                raise MPDProtocolError(f"malformed reply line {line[:80]!r}")
            if key == b"binary":
                try:
                    size = int(value)
                except ValueError as e:
                    raise MPDProtocolError(f"bad binary size {value[:20]!r}") from e
                if size < 0 or size > max_binary:
                    raise MPDProtocolError(f"binary chunk size {size} out of range")
                binary = self.read_exact(size)
                if self.read_exact(1) != b"\n":
                    raise MPDProtocolError("missing newline after binary chunk")
                continue
            pairs.append(
                (
                    key.decode("utf-8", errors="replace"),
                    value.decode("utf-8", errors="replace"),
                )
            )


# ──────────────────────────────────────────────
# SSRF guard shared by every external fetch
# ──────────────────────────────────────────────


class BlockedURLError(urllib.error.URLError):
    """URL rejected by the SSRF guard (scheme, restricted address)."""


def _is_restricted_ip(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    )


def _resolve_public_ip(url: str) -> str:
    """Return a public IP for url's host, or raise BlockedURLError/OSError.

    Used for redirect hops, where no local/trusted exemption applies: a
    crowd-sourced favicon URL that 30x-redirects to 192.168.x.x or to this
    host's own services must not be followed.
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise BlockedURLError(f"scheme {parsed.scheme!r} not allowed")
    infos = socket.getaddrinfo(parsed.hostname or "", None, socket.AF_UNSPEC)
    if not infos:
        raise BlockedURLError(f"no address for {parsed.hostname!r}")
    for _family, _, _, _, sockaddr in infos:
        if _is_restricted_ip(ipaddress.ip_address(sockaddr[0])):
            raise BlockedURLError(f"redirect to restricted address {sockaddr[0]}")
    return infos[0][4][0]


class SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Re-validate every redirect hop with the SSRF guard and cap the count.

    urllib follows 30x anywhere by default, so validating only the first
    hostname let a public URL bounce the fetch into the LAN.
    """

    max_redirections = _MAX_REDIRECTS

    def redirect_request(self, req, fp, code, msg, headers, newurl):  # type: ignore[override]
        _resolve_public_ip(newurl)
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None:
            # A pinned-IP first hop sets an explicit Host header. Keep it on a
            # redirect that stays on that address (a relative Location);
            # it must not leak onto a different host.
            old_netloc = urllib.parse.urlparse(req.full_url).netloc
            if urllib.parse.urlparse(newurl).netloc != old_netloc:
                new_req.remove_header("Host")
        return new_req


_safe_opener = urllib.request.build_opener(SafeRedirectHandler())


def safe_urlopen(req: urllib.request.Request, timeout: float):
    """urlopen() replacement used for all external fetches."""
    return _safe_opener.open(req, timeout=timeout)


class StreamMetadata:
    """Metadata state for a single stream."""

    def __init__(self, stream_id: str) -> None:
        self.stream_id = stream_id
        # Last published snapshot (what clients have seen).
        self.current: dict[str, Any] = {}
        # Latest text/position metadata from the poll (no network enrichment).
        self.base: dict[str, Any] = {}
        # Background enrichment (artwork + tags) for the track identified by
        # enrich_key. enriched holds the fields it added/changed; None while
        # the first lookup for that key is still running.
        self.enrich_key: str = ""
        self.enriched: dict[str, Any] | None = None
        self.enrich_task: asyncio.Task | None = None
        self.enrich_done_at: float = 0.0
        # Serialises compose+broadcast between the poll loop and enrichment
        # completions so a slower sender can't deliver an older snapshot last.
        self.publish_lock = asyncio.Lock()


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
        # url/cache_key -> monotonic expiry of the "don't retry" window
        self._failed_downloads: collections.OrderedDict[str, float] = (
            collections.OrderedDict()
        )
        self._release_meta_cache: collections.OrderedDict[str, str] = (
            collections.OrderedDict()
        )

        self._cache_limit = _MAX_CACHE_ENTRIES

        # Trusted IPs: local interfaces + snapserver — artwork from these is allowed
        # even though they're private IPs (SSRF exemption for co-located services,
        # e.g. the AirPlay cover served by meta_shairport on the LAN IP).
        # Refreshed with a TTL: the container may start before DHCP, and the
        # LAN IP can change at runtime.
        self._trusted_ips: set[str] = {"127.0.0.1", "::1"}
        self._trusted_ips_at: float = 0.0
        self._trusted_ips_lock = threading.Lock()
        self._refresh_trusted_ips()
        logger.info(f"Trusted IPs for artwork: {self._trusted_ips}")

        # Background enrichment runs on its own small pool so slow WAN
        # lookups can never starve the poll loop's snapserver round-trips
        # (and with them the /health heartbeat).
        self._enrich_executor = concurrent.futures.ThreadPoolExecutor(
            max_workers=3, thread_name_prefix="enrich"
        )
        self._last_server: dict = {}
        self._artwork_last_prune: float = 0.0

        # Shared Server.GetStatus snapshot for WebSocket subscribe bursts.
        self._status_cache: tuple[float, dict] | None = None
        self._status_lock = asyncio.Lock()

        # Snapserver persistent socket
        self._snap_sock: socket.socket | None = None
        self._snap_buffer: bytes = b""
        self._snap_lock = threading.Lock()
        self._rpc_id: int = 0
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
        # {stream_id: {"key": "title|artist", "start": monotonic,
        #              "accumulated": float, "calibrated": bool}}
        # "calibrated" is True only when we observed the track-change event
        # in real time. False for the first track ever seen on a stream (it
        # was already there when the service started) — in that case our
        # local-clock estimate would be offset by however much we missed.
        self._track_timers: dict[str, dict[str, Any]] = {}

        # Dedup: emit one log per (stream, track, source) transition — not per 3-s poll.
        self._last_artwork_log_key: dict[str, tuple[str, str]] = {}

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

    def _mark_failed(self, url: str, permanent: bool = False) -> None:
        """Record a failed download with a retry TTL, bounded to _MAX_CACHE_ENTRIES."""
        ttl = _FAIL_TTL_PERMANENT if permanent else _FAIL_TTL_TRANSIENT
        with _cache_lock:
            self._failed_downloads[url] = time.monotonic() + ttl
            self._failed_downloads.move_to_end(url)
            while len(self._failed_downloads) > self._cache_limit:
                self._failed_downloads.popitem(last=False)

    def _is_failed(self, url: str) -> bool:
        """True while url is inside its failure TTL window."""
        with _cache_lock:
            expiry = self._failed_downloads.get(url)
            if expiry is None:
                return False
            if time.monotonic() >= expiry:
                del self._failed_downloads[url]
                return False
            return True

    @staticmethod
    def _cache_get(cache: collections.OrderedDict, key: str) -> str | None:
        """LRU read with negative-entry expiry. Thread-safe.

        Returns None when the key is unknown or its negative entry expired
        (caller should look it up), "" for a live negative entry, else the
        cached value.
        """
        with _cache_lock:
            value = cache.get(key)
            if value is None:
                return None
            if value.startswith(_NEG_PREFIX):
                try:
                    expiry = float(value[len(_NEG_PREFIX) :])
                except ValueError:
                    expiry = 0.0
                if time.monotonic() >= expiry:
                    del cache[key]
                    return None
                cache.move_to_end(key)
                return ""
            cache.move_to_end(key)
            return value

    @classmethod
    def _cache_set_negative(
        cls, cache: collections.OrderedDict, key: str, ttl: float
    ) -> None:
        """Cache a miss/error that expires after ttl seconds."""
        cls._cache_set(cache, key, f"{_NEG_PREFIX}{time.monotonic() + ttl}")

    def _refresh_trusted_ips(self, force: bool = False) -> set[str]:
        """Recompute local/snapserver IPs (TTL 60 s, or forced at most every 5 s)."""
        with self._trusted_ips_lock:
            age = time.monotonic() - self._trusted_ips_at
            if self._trusted_ips_at and age < (5.0 if force else 60.0):
                return self._trusted_ips
            ips: set[str] = {"127.0.0.1", "::1"}
            try:
                for _fam, _, _, _, sa in socket.getaddrinfo(
                    self.snapserver_host, None, socket.AF_UNSPEC
                ):
                    ips.add(sa[0])
            except (socket.gaierror, OSError):
                pass
            # Get all local interface IPs (hostname resolution misses them on Debian)
            try:
                result = subprocess.run(
                    ["hostname", "-I"], capture_output=True, text=True, timeout=5
                )
                for ip_str in result.stdout.split():
                    ips.add(ip_str.strip())
            except (subprocess.SubprocessError, OSError) as e:
                logger.warning("Could not get hostname IPs for trusted list: %s", e)
            if self._trusted_ips_at and ips != self._trusted_ips:
                logger.info("Trusted IPs for artwork changed: %s", ips)
            self._trusted_ips = ips
            self._trusted_ips_at = time.monotonic()
            return ips

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
        """Send one JSON-RPC request and return the reply carrying its id.

        Every request gets a fresh id and the reader skips notifications and
        replies with other ids. On timeout / socket error the connection is
        closed: a late reply left in the stream would otherwise be consumed
        as the answer to the NEXT request, desynchronising every call after.
        """
        self._rpc_id = (getattr(self, "_rpc_id", 0) % 1_000_000_000) + 1
        req_id = self._rpc_id
        request = {
            "id": req_id,
            "jsonrpc": "2.0",
            "method": method,
            "params": params or {},
        }
        try:
            sock.sendall((json.dumps(request) + "\r\n").encode())
        except OSError as e:
            logger.warning(f"Failed to send RPC request: {e}")
            self._drop_rpc_socket(sock)
            return None

        deadline = time.monotonic() + 15.0
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
                if not isinstance(msg, dict):
                    continue
                self._last_snap_response = time.monotonic()
                if msg.get("id") == req_id:
                    return msg
                if "id" in msg:
                    logger.debug(
                        "Skipping JSON-RPC reply for id %r (waiting for %d)",
                        msg.get("id"),
                        req_id,
                    )
                # else: notification — ignore
            if time.monotonic() > deadline:
                logger.warning(f"Snapserver reply to {method} timed out")
                self._drop_rpc_socket(sock)
                return None
            try:
                chunk = sock.recv(8192)
                if not chunk:
                    self._drop_rpc_socket(sock)
                    return None
                self._snap_buffer += chunk
            except TimeoutError:
                logger.warning("Snapserver socket timeout")
                self._drop_rpc_socket(sock)
                return None
            except OSError as e:
                logger.warning(f"Snapserver socket error: {e}")
                self._drop_rpc_socket(sock)
                return None

    def _drop_rpc_socket(self, sock: socket.socket) -> None:
        """Close the persistent snapserver socket after a failed exchange."""
        if sock is self._snap_sock:
            self._close_snap_socket()
        else:
            try:
                sock.close()
            except Exception:
                pass
            self._snap_buffer = b""

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

    def _build_client_lookup(self, server: dict) -> dict[str, tuple[dict, str] | None]:
        """Index raw IDs and aliases to one client, or reserve them as ambiguous."""
        raw_ids: dict[str, dict[int, tuple[dict, str]]] = {}
        aliases: dict[str, dict[int, tuple[dict, str]]] = {}

        for group in server.get("groups", []):
            stream_id = group.get("stream_id", "")
            for client in group.get("clients", []):
                candidate = (client, stream_id)
                raw_id = client.get("id", "")
                if raw_id:
                    raw_ids.setdefault(raw_id, {})[id(client)] = candidate

                direct_aliases = {
                    client.get("host", {}).get("name", ""),
                    client.get("config", {}).get("name", ""),
                } - {""}
                generated_aliases = {
                    f"snapclient-{identifier}"
                    for identifier in direct_aliases | {raw_id}
                    if identifier
                }
                for alias in direct_aliases | generated_aliases:
                    aliases.setdefault(alias, {})[id(client)] = candidate

        lookup: dict[str, tuple[dict, str] | None] = {}
        for raw_id, candidates in raw_ids.items():
            # Raw keys are always reserved. A duplicate must never fall back
            # to an alias on a different client.
            lookup[raw_id] = (
                next(iter(candidates.values())) if len(candidates) == 1 else None
            )
        for alias, candidates in aliases.items():
            if alias not in raw_ids:
                lookup[alias] = (
                    next(iter(candidates.values())) if len(candidates) == 1 else None
                )
        return lookup

    def _build_client_stream_map(self, server: dict) -> dict[str, str]:
        """Build the stream cache from the canonical client lookup."""
        return {
            identifier: candidate[1]
            for identifier, candidate in self._build_client_lookup(server).items()
            if candidate is not None
        }

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

    def _match_client_id(self, client_id: str, server: dict) -> dict | None:
        """Return the client from the same canonical lookup as stream routing."""
        if not client_id:
            return None
        candidate = self._build_client_lookup(server).get(client_id)
        return candidate[0] if candidate is not None else None

    def _resolve_client_stream(self, client_id: str) -> str | None:
        """Resolve a CLIENT_ID to its stream_id using cached mapping.

        Resolution order:
          1. Exact match on `_client_stream_map` (the snapserver-reported
             client identifier).
          2. An unambiguous host/config alias, including the documented
             `snapclient-<hostname>` convention.

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
        if client_id in self._client_stream_map:
            return self._client_stream_map[client_id]
        logger.debug(
            "No stream match for client '%s' (registered: %s). "
            "Rename to match exactly or use 'snapclient-<id>' prefix.",
            client_id,
            list(self._client_stream_map.keys()),
        )
        return None

    def _find_client_volume(self, server: dict, client_id: str) -> dict:
        """Find volume info for a specific client."""
        client = self._match_client_id(client_id, server)
        if client:
            return client.get("config", {}).get(
                "volume", {"percent": 100, "muted": False}
            )
        return {"percent": 100, "muted": False}

    # ──────────────────────────────────────────────
    # MPD metadata
    # ──────────────────────────────────────────────

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

            conn = MPDConnection(sock)
            conn.read_greeting()
            status = dict(conn.command("status")[0])

            if status.get("state", "stop") != "play":
                return {"playing": False, "source": "MPD"}

            elapsed = float(status.get("elapsed", 0))
            duration = float(status.get("duration", 0))

            song = dict(conn.command("currentsong")[0])

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

            date = song.get("Date", "")
            # OriginalDate is a standard MPD tag. When the file has no
            # separate original-release tag, its Date is the best local
            # answer — otherwise enrich_tags fired two MusicBrainz calls for
            # nearly every tagged album just to fill this one field.
            original_date = song.get("OriginalDate", "")
            if not original_date and codec != "RADIO":
                original_date = date

            return {
                "playing": True,
                "title": title,
                "artist": artist,
                "album": album,
                "date": date,
                "original_date": original_date,
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

    # Bigger images are pointless on 320-1080 px displays and cost a Pi Zero
    # client ~2x their size in RAM while decoding.
    _MAX_MPD_ARTWORK_BYTES = 5_000_000
    # readpicture chunk size requested via `binarylimit` (MPD >= 0.22.4).
    _MPD_BINARY_LIMIT = 1_048_576

    @staticmethod
    def _image_extension(data: bytes) -> str:
        if len(data) >= 8 and data[:8] == b"\x89PNG\r\n\x1a\n":
            return ".png"
        if len(data) >= 3 and data[:3] == b"GIF":
            return ".gif"
        if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            return ".webp"
        return ".jpg"

    def _write_artwork_file(self, filename: str, data: bytes) -> bool:
        """Atomically write an artwork file; prune the directory afterwards."""
        local_path = self.artwork_dir / filename
        tmp_path = local_path.parent / (local_path.name + ".tmp")
        try:
            with open(tmp_path, "wb") as f:
                f.write(data)
            tmp_path.rename(local_path)
        except Exception as e:
            logger.warning(f"Artwork write/rename failed: {e}")
            try:
                tmp_path.unlink(missing_ok=True)
            except Exception:
                pass
            return False
        self._prune_artwork_dir()
        return True

    def _find_cached_artwork(self, art_hash: str) -> str:
        """Return an existing artwork_<hash>.* filename (touching it for LRU) or ""."""
        for ext in (".jpg", ".png", ".gif", ".webp"):
            cached = self.artwork_dir / f"artwork_{art_hash}{ext}"
            try:
                if cached.stat().st_size > 0:
                    try:
                        os.utime(cached)
                    except OSError:
                        pass
                    return cached.name
            except OSError:
                continue
        return ""

    def _prune_artwork_dir(self, force: bool = False) -> None:
        """Keep the newest _ARTWORK_MAX_FILES / _ARTWORK_MAX_BYTES artwork files.

        Previously the directory was only pruned at boot (30-day mtime); an
        AirPlay session writes one file per track and on read-only installs
        the directory lives in RAM.
        """
        now = time.monotonic()
        if not force and now - self._artwork_last_prune < _ARTWORK_PRUNE_INTERVAL:
            return
        self._artwork_last_prune = now
        entries: list[tuple[float, int, Path]] = []
        try:
            for path in self.artwork_dir.glob("artwork_*"):
                if path.suffix not in (".jpg", ".png", ".gif", ".webp"):
                    continue
                try:
                    st = path.stat()
                except OSError:
                    continue
                entries.append((st.st_mtime, st.st_size, path))
        except OSError as e:
            logger.debug("Artwork prune scan failed: %s", e)
            return
        entries.sort(key=lambda e: e[0], reverse=True)
        total = 0
        removed = 0
        for index, (_mtime, size, path) in enumerate(entries):
            total += size
            if index < _ARTWORK_MAX_FILES and total <= _ARTWORK_MAX_BYTES:
                continue
            try:
                path.unlink()
                removed += 1
            except OSError:
                pass
        if removed:
            logger.info("Pruned %d old artwork file(s)", removed)

    def fetch_mpd_artwork(self, file_path: str) -> str:
        """Fetch embedded cover art from MPD via readpicture. Returns artwork filename or "".

        Nothing is written unless the whole picture was received: a partial
        image cached under artwork_<md5> would be served forever.
        """
        if not file_path:
            return ""

        art_hash = hashlib.md5(f"mpd:{file_path}".encode()).hexdigest()
        cached = self._find_cached_artwork(art_hash)
        if cached:
            return cached

        # Skip artwork fetch if MPD is known to be down
        if not self._mpd_was_connected and self._mpd_last_fail > 0:
            if time.monotonic() - self._mpd_last_fail < self._mpd_retry_interval:
                return ""

        if any(c in file_path for c in "\n\r\t\x00"):
            logger.warning("Rejected file path with control characters")
            return ""
        safe_path = file_path.replace("\\", "\\\\").replace('"', '\\"')

        sock = self._create_socket(
            self.mpd_host, self.mpd_port, timeout=2, log_errors=False
        )
        if not sock:
            return ""

        try:
            sock.settimeout(10)
            conn = MPDConnection(sock)
            conn.read_greeting()
            if conn.version >= (0, 22, 4):
                try:
                    conn.command(f"binarylimit {self._MPD_BINARY_LIMIT}")
                except MPDCommandError:
                    pass  # unsupported — default 8 KiB chunks

            image = bytearray()
            total: int | None = None
            while True:
                try:
                    pairs, chunk = conn.command(
                        f'readpicture "{safe_path}" {len(image)}',
                        max_binary=self._MAX_MPD_ARTWORK_BYTES,
                    )
                except MPDCommandError as e:
                    if image:
                        logger.warning(f"MPD readpicture aborted mid-image: {e}")
                    return ""
                if chunk is None:
                    # No embedded picture (bare OK). Mid-image = protocol error.
                    if image:
                        logger.warning("MPD readpicture ended before full image")
                    return ""
                fields = dict(pairs)
                try:
                    size = int(fields.get("size", "0"))
                except ValueError:
                    size = 0
                if size <= 0 or not chunk:
                    logger.warning("MPD readpicture returned an invalid chunk")
                    return ""
                if size > self._MAX_MPD_ARTWORK_BYTES:
                    logger.warning(
                        f"MPD artwork exceeded size limit ({self._MAX_MPD_ARTWORK_BYTES} bytes)"
                    )
                    return ""
                if total is None:
                    total = size
                elif size != total:
                    logger.warning("MPD artwork size changed between chunks")
                    return ""
                image += chunk
                if len(image) >= total:
                    break

            if len(image) != total:
                logger.warning("MPD artwork length mismatch, discarding")
                return ""

            data = bytes(image)
            filename = f"artwork_{art_hash}{self._image_extension(data)}"
            if not self._write_artwork_file(filename, data):
                return ""
            logger.info(f"Got MPD artwork ({len(data)} bytes) for {file_path}")
            return filename
        except (MPDProtocolError, OSError) as e:
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
        """GET a JSON API. Returns None on ANY failure (treated as transient).

        Every musicbrainz.org call goes through the shared 1 req/s limiter
        here, so no call site can forget it.
        """
        try:
            if urllib.parse.urlparse(url).hostname == "musicbrainz.org":
                _mb_rate_limit()
            req = urllib.request.Request(url, headers={"User-Agent": self.user_agent})
            with safe_urlopen(req, timeout=timeout) as response:
                return json.loads(response.read().decode())
        except Exception as e:
            logger.debug(f"API request failed for {url}: {e}")
            return None

    def fetch_radio_logo(self, station_name: str, stream_url: str) -> str:
        if not station_name or len(station_name) > 200:
            return ""

        cache_key = f"radio|{station_name}"
        cached = self._cache_get(self.artwork_cache, cache_key)
        if cached is not None:
            return cached

        clean_name = station_name
        for sep in ("(", "[", "-"):
            if sep in clean_name:
                candidate = clean_name.split(sep)[0].strip()
                if len(candidate) >= 3:
                    clean_name = candidate

        query = urllib.parse.quote(clean_name)
        url = f"https://de1.api.radio-browser.info/json/stations/byname/{query}?limit=20&order=votes&reverse=true"
        data = self._make_api_request(url)
        if data is None or not isinstance(data, list):
            self._cache_set_negative(self.artwork_cache, cache_key, _NEG_TTL_ERROR)
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
            if not isinstance(entry, dict):
                continue
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
        else:
            self._cache_set_negative(self.artwork_cache, cache_key, _NEG_TTL_MISS)
        return best_url

    @staticmethod
    def _clean_album(album: str) -> str:
        """Remove a truncated parenthetical suffix ("Version 2.0 (20th Annivers")."""
        if "(" in album and ")" not in album:
            return album[: album.rfind("(")].rstrip()
        return album

    def fetch_musicbrainz_artwork(self, artist: str, album: str) -> str | None:
        """Return a Cover Art Archive URL, "" when MusicBrainz has no match,
        or None when the lookup itself failed (retry sooner)."""
        query = urllib.parse.quote(f'artist:"{artist}" AND release:"{album}"')
        url = f"https://musicbrainz.org/ws/2/release/?query={query}&fmt=json&limit=5"
        data = self._make_api_request(url)
        cache_key = f"{artist}|{self._clean_album(album)}"
        if not data or not isinstance(data, dict):
            return None
        for release in data.get("releases", []):
            if not isinstance(release, dict):
                continue
            score = release.get("score", 0)
            if score < 80:
                continue
            # Cache release metadata (date, genre) for enrich_tags()
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
        if self._cache_get(self._release_meta_cache, cache_key) is None:
            # Authoritative "no match": spare enrich_tags the same query.
            self._cache_set_negative(self._release_meta_cache, cache_key, _NEG_TTL_MISS)
        return ""

    def fetch_musicbrainz_release_group_first_date(self, release_group_id: str) -> str:
        """Fetch the earliest known release date for a release group."""
        if not release_group_id:
            return ""
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

        clean_album = self._clean_album(album)
        cache_key = f"{artist}|{clean_album}"
        cached = self._cache_get(self._release_meta_cache, cache_key)
        if cached == "":
            return  # live negative entry

        if cached is None:
            # No cached data — trigger a MusicBrainz lookup
            query = urllib.parse.quote(f'artist:"{artist}" AND release:"{clean_album}"')
            url = (
                f"https://musicbrainz.org/ws/2/release/?query={query}&fmt=json&limit=5"
            )
            data = self._make_api_request(url)
            if not data or not isinstance(data, dict):
                self._cache_set_negative(
                    self._release_meta_cache, cache_key, _NEG_TTL_ERROR
                )
                return
            for release in data.get("releases", []):
                if isinstance(release, dict) and release.get("score", 0) >= 80:
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
                        original_date = self.fetch_musicbrainz_release_group_first_date(
                            release_group_id
                        )
                    cached = self._release_meta_cache_value(date, original_date, genre)
                    self._cache_set(self._release_meta_cache, cache_key, cached)
                    break
            if cached is None:
                self._cache_set_negative(
                    self._release_meta_cache, cache_key, _NEG_TTL_MISS
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
        if not artist:
            return ""
        cached = self._cache_get(self.artist_image_cache, artist)
        if cached is not None:
            return cached

        def _miss(transient: bool) -> str:
            self._cache_set_negative(
                self.artist_image_cache,
                artist,
                _NEG_TTL_ERROR if transient else _NEG_TTL_MISS,
            )
            return ""

        query = urllib.parse.quote(f'artist:"{artist}"')
        url = f"https://musicbrainz.org/ws/2/artist/?query={query}&fmt=json&limit=1"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return _miss(transient=True)
        artists = data.get("artists", [])
        if not artists or not isinstance(artists[0], dict):
            return _miss(transient=False)

        artist_mbid = artists[0].get("id")
        if not artist_mbid:
            return _miss(transient=False)

        url = f"https://musicbrainz.org/ws/2/artist/{artist_mbid}?inc=url-rels&fmt=json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return _miss(transient=True)

        wikidata_id = self._get_wikidata_id_from_relations(data.get("relations", []))
        if not wikidata_id:
            return _miss(transient=False)

        url = f"https://www.wikidata.org/wiki/Special:EntityData/{wikidata_id}.json"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return _miss(transient=True)

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

        return _miss(transient=False)

    def _album_art_candidates(self, artist: str, album: str):
        """Yield (url, source) album-art candidates lazily, best first.

        Each provider's lookup result is cached separately (misses/errors
        with a TTL), so when a candidate's DOWNLOAD fails the caller simply
        moves on to the next provider: a MusicBrainz release without a CAA
        front image (404) now falls through to iTunes instead of straight to
        the artist photo.
        """
        if not artist or not album:
            return
        providers = (
            ("musicbrainz", self.fetch_musicbrainz_artwork),
            ("itunes", self._fetch_itunes_artwork),
        )
        for source, lookup in providers:
            cache_key = f"{source}|{artist}|{album}"
            url = self._cache_get(self.artwork_cache, cache_key)
            if url is None:
                url = lookup(artist, album)
                if url:
                    self._cache_set(self.artwork_cache, cache_key, url)
                    logger.info("Found %s artwork for %s - %s", source, artist, album)
                else:
                    self._cache_set_negative(
                        self.artwork_cache,
                        cache_key,
                        _NEG_TTL_ERROR if url is None else _NEG_TTL_MISS,
                    )
            if url:
                yield url, source

    def _fetch_itunes_artwork(self, artist: str, album: str) -> str | None:
        """Return a 600x600 artwork URL, "" for no match, None on lookup failure."""
        query = urllib.parse.quote(f"{artist} {album}")
        url = f"https://itunes.apple.com/search?term={query}&media=music&entity=album&limit=10"
        data = self._make_api_request(url)
        if not data or not isinstance(data, dict):
            return None
        if data.get("resultCount", 0) == 0:
            return ""

        album_lower = album.lower().strip()
        artist_lower = artist.lower().strip()
        for result in data.get("results", []):
            if not isinstance(result, dict):
                continue
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

    # 5 MB: bigger covers are pointless on 320-1080 px displays and cost a
    # Pi Zero client ~2x their size in RAM to decode (peak ~20 MB here at
    # the old 10 MB cap, in a 128M container).
    _MAX_ARTWORK_BYTES = 5_000_000

    # HTTP statuses that will not fix themselves within minutes.
    _PERMANENT_HTTP_ERRORS = {400, 401, 403, 404, 405, 410, 414, 451}

    def _check_artwork_host(self, hostname: str) -> tuple[str | None, bool]:
        """SSRF guard for the FIRST hop. Returns (ip_to_connect, allowed).

        Private/loopback addresses are only allowed when they belong to this
        host or the snapserver (co-located services such as meta_shairport's
        cover server). Redirect hops get the stricter SafeRedirectHandler
        check with no local exemption.
        """
        infos = socket.getaddrinfo(hostname or "", None, socket.AF_UNSPEC)
        for attempt in (0, 1):
            trusted = self._refresh_trusted_ips(force=attempt == 1)
            blocked_addr = None
            for _family, _, _, _, sockaddr in infos:
                addr = sockaddr[0]
                if not _is_restricted_ip(ipaddress.ip_address(addr)):
                    return addr, True
                if addr in trusted:
                    logger.debug(f"Allowing artwork from trusted local IP: {addr}")
                    return addr, True
                blocked_addr = addr
                break
            if blocked_addr is None:
                return None, False
            # Maybe our own address changed (DHCP renew, late WiFi) — retry
            # once with a freshly computed trusted list.
        logger.warning(f"Blocked artwork download to restricted IP: {blocked_addr}")
        return None, False

    def download_artwork(self, url: str, cache_key: str = "") -> str:
        """Download artwork, save to artwork dir. Returns filename or "".

        Args:
            url: The URL to download from.
            cache_key: Optional override for the cache hash. Use when the same
                URL serves different content (e.g. shairport-sync /cover.jpg).

        Failures are remembered with a TTL (transient: timeout/5xx/blocked;
        permanent: 404 & co.) so a broken URL isn't hammered every poll, but
        is retried later instead of never.
        """
        fail_key = cache_key or url
        if not url or self._is_failed(fail_key):
            return ""

        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            logger.warning(f"Rejected artwork URL with scheme: {parsed.scheme}")
            self._mark_failed(fail_key, permanent=True)
            return ""

        url_hash = hashlib.md5((cache_key or url).encode()).hexdigest()
        # Check if already downloaded with any extension
        existing = self._find_cached_artwork(url_hash)
        if existing:
            return existing

        # Block private/loopback IPs (SSRF protection).
        # Resolve once and connect to the resolved IP to prevent DNS rebinding
        try:
            resolved_ip, allowed = self._check_artwork_host(parsed.hostname or "")
        except (socket.gaierror, ValueError, OSError) as e:
            logger.warning(f"Cannot resolve artwork host {parsed.hostname}: {e}")
            self._mark_failed(fail_key)
            return ""
        if not allowed:
            self._mark_failed(fail_key)
            return ""

        try:
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
            with safe_urlopen(req, timeout=5) as response:
                data = bytearray()
                dl_start = time.monotonic()
                while len(data) <= self._MAX_ARTWORK_BYTES:
                    if time.monotonic() - dl_start > 15:
                        logger.warning("Artwork download total timeout (15s)")
                        self._mark_failed(fail_key)
                        return ""
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    data += chunk

            if len(data) > self._MAX_ARTWORK_BYTES:
                logger.warning(
                    f"Artwork exceeded size limit ({self._MAX_ARTWORK_BYTES} bytes)"
                )
                self._mark_failed(fail_key, permanent=True)
                return ""
            if not data:
                logger.warning("Downloaded empty artwork")
                self._mark_failed(fail_key)
                return ""

            payload = bytes(data)
            filename = f"artwork_{url_hash}{self._image_extension(payload)}"
            if not self._write_artwork_file(filename, payload):
                return ""
            logger.info(f"Downloaded artwork ({len(payload)} bytes) to {filename}")
            return filename
        except urllib.error.HTTPError as e:
            permanent = e.code in self._PERMANENT_HTTP_ERRORS
            logger.warning(f"Artwork download HTTP {e.code} for {url}")
            self._mark_failed(fail_key, permanent=permanent)
            return ""
        except BlockedURLError as e:
            logger.warning(f"Artwork redirect blocked for {url}: {e.reason}")
            self._mark_failed(fail_key)
            return ""
        except Exception as e:
            logger.error(f"Failed to download artwork: {e}")
            self._mark_failed(fail_key)
            return ""

    # ──────────────────────────────────────────────
    # Playback control (bidirectional)
    # ──────────────────────────────────────────────

    def toggle_playback(self, client_id: str) -> bool:
        """Toggle play/pause on the stream the client's group is playing.

        Routed through snapserver `Stream.Control` so it reaches whichever
        source is actually active (MPD, Spotify, ...). It used to toggle MPD
        unconditionally, starting MPD on top of an AirPlay/Spotify session.
        Streams that don't advertise control (AirPlay, Tidal) are ignored.
        """
        with self._snap_lock:
            sock = self._get_snap_socket()
            if not sock:
                return False
            status = self.send_rpc_request(sock, "Server.GetStatus")
            server = (status or {}).get("result", {}).get("server")
            if not server:
                return False

            candidate = self._build_client_lookup(server).get(client_id)
            if candidate is None:
                logger.warning(f"toggle_play: client '{client_id}' not found")
                return False
            stream_id = candidate[1]
            stream = next(
                (s for s in server.get("streams", []) if s.get("id") == stream_id),
                None,
            )
            props = (stream or {}).get("properties", {}) or {}
            if not (
                props.get("canControl")
                and (props.get("canPause") or props.get("canPlay"))
            ):
                logger.info(
                    f"toggle_play ignored: stream '{stream_id}' does not accept "
                    "playback control"
                )
                return False

            sock = self._get_snap_socket()
            if not sock:
                return False
            response = self.send_rpc_request(
                sock, "Stream.Control", {"id": stream_id, "command": "playPause"}
            )
            if response and "result" in response:
                logger.info(f"toggle_play: playPause sent to stream '{stream_id}'")
                return True
            logger.warning(f"toggle_play on '{stream_id}' failed: {response}")
            return False

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
            client = self._match_client_id(client_id, server)
            snap_client_id = client.get("id") if client else None

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
    ) -> int | None:
        """Estimate elapsed seconds for sources without native position reporting.

        Returns:
            int: estimated elapsed seconds when the timer is calibrated, i.e.
                 we watched the stream switch to this track in real time.
            None: for the first track ever seen on a stream — it was already
                  there when metadata-service started polling, so we have no
                  anchor for "track start" and any local-clock estimate would
                  be wrong. Clients should treat None as "elapsed unknown"
                  and render the progress bar accordingly.

        A startup grace window used to mark first sightings as calibrated,
        but the first poll always lands <1 s after start, so after a
        mid-track restart every stream emitted elapsed counting from 0.

        Tracks play/pause transitions per stream. Resets when track_key changes.
        """
        now = time.monotonic()
        timer = self._track_timers.get(stream_id)

        if timer is None or timer["key"] != track_key:
            # Calibrated only if we saw a different track (or "no track")
            # on this stream before — i.e. the change happened while we
            # were watching.
            calibrated = timer is not None
            self._track_timers[stream_id] = {
                "key": track_key,
                "start": now if is_playing else 0.0,
                "accumulated": 0.0,
                "calibrated": calibrated,
            }
            return 0 if calibrated else None

        # Existing timer — return either calibrated elapsed or None.
        if not timer.get("calibrated", True):
            return None

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

        Priority chain — every step that yields a URL is downloaded right
        away and, if the download fails, the chain CONTINUES (a failing
        Spotify/AirPlay URL or a CAA 404 no longer ends the search):
        1. Snapcast artUrl from the source plugin (Spotify, AirPlay, ...)
        2. Embedded art (MPD readpicture)
        3. MusicBrainz Cover Art Archive (album-specific, score >= 80)
        4. iTunes Search API (album-specific, validated)
        5. Radio-Browser logo (radio streams only)
        6. Default radio placeholder (radio streams only)
        7. artist_image (generic artist photo — last resort)
        """
        if not metadata.get("playing"):
            return

        source_url = metadata.get("artwork", "") or ""
        is_radio = metadata.get("codec") == "RADIO"
        artwork_source = ""
        local_file = ""
        metadata["artwork"] = ""

        # 1. Source-provided URL
        if source_url:
            cache_key = ""
            if "/cover.jpg" in source_url and metadata.get("title"):
                # meta_shairport serves every track at /cover.jpg (newer
                # builds add a per-picture ?v= query); keying on the track
                # as well keeps two tracks from sharing one cached file.
                cache_key = (
                    f"{source_url}|{metadata.get('title', '')}"
                    f"|{metadata.get('artist', '')}"
                )
            local_file = self.download_artwork(source_url, cache_key=cache_key)
            if local_file:
                artwork_source = "snapcast"

        # 2. MPD embedded cover art
        if not local_file and metadata.get("source") == "MPD" and not is_radio:
            local_file = self.fetch_mpd_artwork(metadata.get("file", ""))
            if local_file:
                artwork_source = "embedded"

        if not local_file:
            logger.debug(
                "No artwork from source for %s - %s (%s), trying fallback",
                metadata.get("artist"),
                metadata.get("album"),
                metadata.get("source"),
            )
            if is_radio:
                # 5. Radio-Browser logo
                if metadata.get("station_name"):
                    logo_url = self.fetch_radio_logo(
                        metadata["station_name"], metadata.get("file", "")
                    )
                    if logo_url:
                        local_file = self.download_artwork(logo_url)
                        if local_file:
                            artwork_source = "radio-browser"
            else:
                # 3./4. Album lookups, next provider on download failure
                for url, source in self._album_art_candidates(
                    metadata.get("artist", ""), metadata.get("album", "")
                ):
                    local_file = self.download_artwork(url)
                    if local_file:
                        artwork_source = source
                        break

        if local_file:
            metadata["artwork"] = self._artwork_url(local_file)
        elif is_radio:
            # 6. Final radio fallback
            metadata["artwork"] = (
                f"http://{get_external_host()}:{HTTP_PORT}/defaults/default-radio.png"
            )
            artwork_source = "default"

        # 7. Artist image (not for radio) — download through SSRF-safe pipeline
        if not is_radio and metadata.get("artist"):
            artist_image_url = self.fetch_artist_image(metadata["artist"])
            if artist_image_url:
                cached = self.download_artwork(artist_image_url)
                if cached:
                    artist_image_served = self._artwork_url(cached)
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
        self._log_artwork_chain_hit(metadata, artwork_source)

    def _log_artwork_chain_hit(self, metadata: dict[str, Any], source: str) -> None:
        """Emit one INFO log per (stream, track, source) transition; skip snapcast/empty."""
        if not source or source == "snapcast":
            return
        stream = metadata.get("source", "?")
        track_key = (
            f"{metadata.get('artist', '')}|"
            f"{metadata.get('album', '')}|"
            f"{metadata.get('title', '')}"
        )
        log_key = (track_key, source)
        if self._last_artwork_log_key.get(stream) == log_key:
            return
        self._last_artwork_log_key[stream] = log_key
        logger.info(
            "Artwork served via %s: %s - %s (%s) [%s]",
            source,
            metadata.get("artist", "?"),
            metadata.get("album", "?"),
            metadata.get("title", "?"),
            stream,
        )

    # ──────────────────────────────────────────────
    # Main polling loop
    # ──────────────────────────────────────────────

    async def poll_loop(self) -> None:
        """Main loop: poll Snapserver, broadcast text metadata, enrich in background."""
        consecutive_errors = 0
        self._server_info_counter = 0

        while True:
            try:
                if not await self._poll_once():
                    await asyncio.sleep(5)
                    continue
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

    async def _poll_once(self) -> bool:
        """One poll cycle. Returns False when snapserver could not be reached.

        Only fast, local work happens here (snapserver status, MPD status,
        go-librespot position). Artwork/tag enrichment — which can take
        5-30 s on a slow WAN — runs as a background task per stream/track
        and re-broadcasts when it lands, so title/artist are pushed at once
        and the /health heartbeat never waits on the internet.
        """
        loop = asyncio.get_running_loop()
        server = await loop.run_in_executor(None, self.get_server_status)
        if not server:
            return False

        # Mark this iteration as a healthy round-trip with snapserver.
        # /health uses this timestamp to differentiate "container alive
        # AND talking to snapserver" from "container alive, snapserver
        # silent for N seconds". `time` already imported at module top.
        self.last_successful_poll_at = time.time()
        self._last_server = server
        self._status_cache = (time.monotonic(), server)

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
                    f"Client '{sc.client_id}' switched: {sc.stream_id} -> {resolved}"
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

            metadata = self._extract_stream_metadata(stream)

            # Enrich MPD stream with richer metadata
            if metadata.get("source") == "MPD":
                mpd_meta = await loop.run_in_executor(None, self.get_mpd_metadata)
                if mpd_meta.get("playing"):
                    if not mpd_meta.get("title") and mpd_meta.get("station_name"):
                        mpd_meta["title"] = mpd_meta["station_name"]
                    metadata = mpd_meta

            # Enrich non-MPD streams with position data
            if metadata.get("source") != "MPD":
                track_key = f"{metadata.get('title', '')}|{metadata.get('artist', '')}"
                is_playing = metadata.get("playing", False) and track_key != "|"

                if stream_id == "Spotify" and is_playing:
                    # Accurate position from go-librespot API
                    spotify_pos = await loop.run_in_executor(
                        None, self.get_spotify_position
                    )
                    if spotify_pos is not None:
                        metadata["elapsed"] = spotify_pos[0]
                        metadata["duration"] = spotify_pos[1]

                # AirPlay, Tidal, etc.: estimate from local clock.
                # estimated is None when the track was already playing
                # before metadata-service started — we have no reliable
                # anchor for "track start" so emitting a wrong elapsed
                # would mislead the client UI (progress bar at 0:00
                # when the song is half-way through). Drop the field
                # entirely so the client renders elapsed as unknown.
                estimated = self._estimate_elapsed(stream_id, track_key, is_playing)
                if is_playing and metadata.get("elapsed", 0) <= 0:
                    if estimated is None:
                        metadata.pop("elapsed", None)
                    else:
                        metadata["elapsed"] = estimated

            # No await between storing the base and publishing it: an
            # enrichment completing in between would otherwise be
            # overwritten by an older snapshot.
            sm.base = metadata
            self._schedule_enrichment(sm)
            await self._publish_stream(sm, server)

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

        self._server_info_counter = getattr(self, "_server_info_counter", 0) + 1
        if self._server_info_counter >= 20:  # ~60s at 3s poll interval
            self._server_info_counter = 0
            await self._broadcast_server_info(server)
        return True

    # ──────────────────────────────────────────────
    # Background enrichment
    # ──────────────────────────────────────────────

    # A finished enrichment that found no artwork is retried after this many
    # seconds while the same track keeps playing (failure caches have TTLs).
    _ENRICH_RETRY_SEC: float = 120.0

    @staticmethod
    def _enrich_key(metadata: dict[str, Any]) -> str:
        """Identity of the track as far as enrichment is concerned."""
        return "\x1f".join(
            str(metadata.get(k, ""))
            for k in (
                "source",
                "title",
                "artist",
                "album",
                "artwork",
                "file",
                "station_name",
                "codec",
            )
        )

    def _enrich_sync(self, base: dict[str, Any]) -> dict[str, Any]:
        """Run artwork + tag enrichment on a copy; return only what changed."""
        enriched = dict(base)
        self.enrich_artwork(enriched)
        self.enrich_tags(enriched)
        return {k: v for k, v in enriched.items() if k not in base or base.get(k) != v}

    def _schedule_enrichment(self, sm: StreamMetadata) -> None:
        """Start (at most) one background enrichment for sm's current track."""
        base = sm.base
        if not base.get("playing"):
            return
        key = self._enrich_key(base)
        if sm.enrich_key == key:
            if sm.enrich_task is not None and not sm.enrich_task.done():
                return  # already in flight for this track
            if sm.enriched is not None:
                has_artwork = bool({**base, **sm.enriched}.get("artwork"))
                recent = time.monotonic() - sm.enrich_done_at < self._ENRICH_RETRY_SEC
                if has_artwork or recent:
                    return
            # Finished without artwork long enough ago — retry (keep the
            # previous result visible meanwhile).
        else:
            if sm.enrich_task is not None and not sm.enrich_task.done():
                sm.enrich_task.cancel()
            sm.enrich_key = key
            sm.enriched = None
        sm.enrich_task = asyncio.create_task(self._run_enrichment(sm, key, dict(base)))

    async def _run_enrichment(
        self, sm: StreamMetadata, key: str, base: dict[str, Any]
    ) -> None:
        loop = asyncio.get_running_loop()
        try:
            delta = await loop.run_in_executor(
                self._enrich_executor, self._enrich_sync, base
            )
        except asyncio.CancelledError:
            raise
        except Exception as e:
            logger.warning(f"[{sm.stream_id}] Enrichment failed: {e}")
            delta = {}
        if sm.enrich_key != key:
            return  # track changed while we were looking — drop stale result
        sm.enriched = delta
        sm.enrich_done_at = time.monotonic()
        if sm.base and self._enrich_key(sm.base) == key:
            await self._publish_stream(sm, self._last_server)

    def _compose_metadata(self, sm: StreamMetadata) -> dict[str, Any]:
        """Current snapshot = latest poll data + enrichment for that track."""
        base = sm.base
        if not base.get("playing"):
            return dict(base)
        if sm.enriched is not None and sm.enrich_key == self._enrich_key(base):
            return {**base, **sm.enriched}
        # Enrichment pending: don't leak the raw source artUrl (LAN-only
        # plugin URLs, not yet re-hosted); clients show artwork once ready.
        pending = dict(base)
        pending["artwork"] = ""
        return pending

    async def _publish_stream(self, sm: StreamMetadata, server: dict) -> None:
        """Compose, detect changes, persist and broadcast one stream's state."""
        async with sm.publish_lock:
            metadata = self._compose_metadata(sm)
            stream_id = sm.stream_id

            # Check for changes
            changed = self._metadata_changed(metadata, sm.current)
            volatile_changed = not changed and any(
                metadata.get(f) != sm.current.get(f) for f in self._VOLATILE_FIELDS
            )
            if not (changed or volatile_changed):
                return

            if changed:
                title = metadata.get("title", "N/A")
                artist = metadata.get("artist", "N/A")
                logger.info(f"[{stream_id}] Updated: {title} - {artist}")

            # elapsed ticks every poll while playing — broadcast it, but only
            # rewrite metadata_<stream>.json when something else changed.
            write_file = changed or any(
                metadata.get(f) != sm.current.get(f)
                for f in self._VOLATILE_FIELDS - {"elapsed"}
            )
            sm.current = metadata
            if write_file:
                self._write_stream_file(stream_id, metadata)

            # Broadcast to subscribed clients
            await self._broadcast_to_stream(stream_id, metadata, server)

    def _write_stream_file(self, stream_id: str, metadata: dict) -> None:
        """Write per-stream metadata_<stream>.json (atomic)."""
        meta_file = self.artwork_dir / f"metadata_{stream_id}.json"
        tmp_file = meta_file.parent / (meta_file.name + ".tmp")
        try:
            with open(tmp_file, "w") as f:
                json.dump(self._output_metadata(metadata), f, indent=2)
            tmp_file.rename(meta_file)
        except Exception as e:
            logger.error(f"Failed to write metadata for {stream_id}: {e}")
            try:
                tmp_file.unlink(missing_ok=True)
            except Exception:
                pass

    async def get_server_status_throttled(self, max_age: float = 1.0) -> dict | None:
        """Server.GetStatus shared across callers, at most ~once per max_age.

        A burst of WebSocket subscribes (or a client spamming `subscribe`)
        used to trigger one snapserver round-trip each.
        """
        async with self._status_lock:
            cached = self._status_cache
            if cached is not None and time.monotonic() - cached[0] < max_age:
                return cached[1]
            loop = asyncio.get_running_loop()
            server = await loop.run_in_executor(None, self.get_server_status)
            if server:
                self._status_cache = (time.monotonic(), server)
            return server

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
            if not isinstance(cmd, dict):
                return
            cmd_type = cmd.get("cmd")
            logger.info(f"Control command from {client_id}: {cmd_type}")

            loop = asyncio.get_running_loop()

            if cmd_type == "toggle_play":
                await loop.run_in_executor(None, self.toggle_playback, client_id)
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
            # Valid JSON that isn't an object ("subscribe", 42, [...]) used
            # to raise TypeError on `"subscribe" in data` and kill the handler.
            if not isinstance(data, dict):
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
                    server = await _service.get_server_status_throttled()
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
                    server = await _service.get_server_status_throttled()
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

# Container-name → role mapping. Used to group rows in the Containers
# section under "server" / "client" sub-headers.
#
# Loaded from scripts/common/container-manifest.txt — the SSOT shared
# with scripts/smoke/check_containers.sh. Bind-mounted into the metadata
# container at /app/container-manifest.txt via docker-compose.yml. The
# hardcoded fallback below preserves rendering on dev clones or older
# deployments that did not stage the manifest; the invariant test
# tests/test_container_manifest.sh keeps the two sides aligned.
_CONTAINER_ROLE_FALLBACK: dict[str, str] = {
    "snapserver": "server",
    "mpd": "server",
    "mympd": "server",
    "metadata": "server",
    "shairport-sync": "server",
    "librespot": "server",
    "tidal-connect": "server",
    "snapclient": "client",
    "audio-visualizer": "client",
    "fb-display": "client",
}


def _load_container_role_manifest() -> dict[str, str]:
    """Parse `scripts/common/container-manifest.txt` (SSOT shared with smoke).

    Format: whitespace-separated `<name> <role>` rows, `#` comments + blank
    lines ignored. Honours `SNAPMULTI_CONTAINER_MANIFEST` env override so
    tests can point at sandboxed fixtures. Returns the hardcoded fallback
    when the file is missing or unparseable so /status keeps rendering on
    stripped/legacy deploys — the invariant test catches drift at CI time.
    """
    candidates: list[str] = []
    override = os.environ.get("SNAPMULTI_CONTAINER_MANIFEST", "").strip()
    if override:
        candidates.append(override)
    # /app/container-manifest.txt = bind-mount target in docker-compose.yml.
    # The repo-relative path covers dev clones running outside the container.
    candidates.append("/app/container-manifest.txt")
    candidates.append(
        os.path.join(
            os.path.dirname(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
            ),
            "scripts",
            "common",
            "container-manifest.txt",
        )
    )

    for path in candidates:
        if not path or not os.path.isfile(path):
            continue
        try:
            mapping: dict[str, str] = {}
            # encoding='utf-8' explicit: the manifest contains non-ASCII
            # characters in comments (em-dash, set-membership glyph). A
            # container started under POSIX/C locale defaults `open()` to
            # ASCII and raises UnicodeDecodeError BEFORE the `startswith
            # ("#")` skip — and the exception is a ValueError, not
            # OSError, so the loop's `except OSError: continue` would not
            # catch it and the metadata service would fail to import.
            # PR #590 review LOW.
            with open(path, encoding="utf-8") as f:
                for line in f:
                    stripped = line.strip()
                    if not stripped or stripped.startswith("#"):
                        continue
                    parts = stripped.split()
                    if len(parts) < 2:
                        continue
                    name, role = parts[0], parts[1]
                    if role not in ("server", "client"):
                        # Malformed file at runtime = partial deploy.
                        # Better to fall back than render garbage.
                        return dict(_CONTAINER_ROLE_FALLBACK)
                    mapping[name] = role
            if mapping:
                return mapping
        except OSError:
            continue
    return dict(_CONTAINER_ROLE_FALLBACK)


_CONTAINER_ROLE: dict[str, str] = _load_container_role_manifest()


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

        # Compose section: drop the per-service nested rows ("  server/X
        # -> healthy") — the Containers section is now the authoritative
        # per-container view and the duplication adds scroll without
        # information. Keep the aggregate count rows and the avahi-socket
        # mount confirmations, which are not container-health and stay
        # only in Compose.
        if sec_name == "Compose":
            recs = [
                r for r in recs if not _COMPOSE_NESTED_PATTERN.match(r.get("msg", ""))
            ]
            if not recs:
                continue

        # Containers section: pre-scan to group per-container rows by
        # role (server / client) under sub-headers. Aggregate rows ("No
        # active restart failures", "All N have memory limit applied",
        # "Metadata plugins inside snapserver") stay below at the end.
        if sec_name == "Containers":
            server_rows: list[dict] = []
            client_rows: list[dict] = []
            other_rows: list[dict] = []
            for r in recs:
                m = _CONTAINER_PATTERN.match(r.get("msg", ""))
                if m and m.group(1) in _CONTAINER_ROLE:
                    if _CONTAINER_ROLE[m.group(1)] == "server":
                        server_rows.append(r)
                    else:
                        client_rows.append(r)
                else:
                    other_rows.append(r)
            ordered: list[dict] = []
            if server_rows:
                ordered.append({"_group_header": "server", "_count": len(server_rows)})
                ordered.extend(server_rows)
            if client_rows:
                ordered.append({"_group_header": "client", "_count": len(client_rows)})
                ordered.extend(client_rows)
            ordered.extend(other_rows)
            recs = ordered

        rows = []
        if sec_name == "Containers" and profile_row:
            rows.append(profile_row)
        for r in recs:
            # Synthetic group header injected above for the Containers
            # section. Rendered as an info-class row with a chevron icon.
            if "_group_header" in r:
                rows.append(
                    '<li class="r-info row-group-header">'
                    '<span class="icon">▸</span>'
                    f"<strong>{html.escape(r['_group_header'])}</strong>"
                    f" ({r['_count']})</li>"
                )
                continue
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
        vitals_html=_extract_vitals(records),
        sections_html="".join(sec_html_parts),
        footer=footer,
        embedded_json=json.dumps(data).replace("</", "<\\/"),
    )


def _extract_vitals(records: list[dict]) -> str:
    """Build the compact System-vitals badge (temperature · CPU load · audio
    resync) shown at the top of the status page, next to the release info.

    The three values are collected host-side by device-smoke (check_thermal,
    check_system, check_audio_liveness) and land in `records` as info/pass
    messages — this reads them back by stable message prefix rather than
    re-collecting them (the metadata container is read-only and cannot read
    the host's sensors). Any vital that is absent renders as an em dash.
    """
    import html as _html
    import re

    temp: str | None = None
    load: str | None = None
    resync: str | None = None
    for r in records:
        msg = r.get("msg", "")
        if temp is None and "SoC" in msg:
            m = re.search(r"(\d+(?:\.\d+)?)\s*°C", msg)
            if m:
                temp = m.group(1)
        if load is None:
            m = re.match(r"CPU load:\s*([\d.]+)", msg)
            if m:
                load = m.group(1)  # 1-minute average
        if resync is None:
            m = re.match(r"Audio resync[^:]*:\s*(\d+)\b", msg)
            if m:
                resync = m.group(1)

    if temp is None and load is None and resync is None:
        return ""

    def _cell(icon: str, label: str, value: str | None) -> str:
        v = _html.escape(value) if value is not None else "—"
        return (
            f'<span class="vital">'
            f'<span class="v-icon">{icon}</span>'
            f'<span class="v-val">{v}</span>'
            f'<span class="v-label">{label}</span>'
            f"</span>"
        )

    return (
        '<div class="vitals" role="group" aria-label="System vitals">'
        + _cell("🌡", "°C", temp)
        + _cell("⚙", "load 1m", load)
        + _cell("♻", "resync 24h", resync)
        + "</div>"
    )


def _render_html_shell(
    *,
    verdict_class: str,
    verdict_icon: str,
    verdict_text: str,
    subtext: str,
    vitals_html: str = "",
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
  .vitals {{
    display: flex; gap: .55rem; flex-wrap: wrap; margin: -.4rem 0 1.2rem;
  }}
  .vital {{
    display: inline-flex; align-items: baseline; gap: .45rem;
    background: var(--panel); border: 1px solid var(--border);
    border-radius: .5rem; padding: .5rem .85rem;
  }}
  .vital .v-icon  {{ font-size: 1rem; align-self: center; }}
  .vital .v-val   {{ font-size: 1.05rem; font-weight: 600; color: var(--text); }}
  .vital .v-label {{
    font-size: .72rem; color: var(--text-dim);
    text-transform: uppercase; letter-spacing: .05em;
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
{vitals_html}
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
            "MPD HTTP stream",
            f"http://{bare_host}:8000",
            "Direct MP3 stream of the MPD source (browser/VLC, bypasses Snapcast)",
        ),
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
        (
            "MPD protocol",
            f"{bare_host}:6600",
            "Native MPD control for clients like mpc, ncmpcpp, MALP",
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
    _service._prune_artwork_dir(force=True)

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
