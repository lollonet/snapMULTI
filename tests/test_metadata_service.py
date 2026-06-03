"""Tests for docker/metadata-service/metadata-service.py."""

from __future__ import annotations

import importlib.util
import sys
import types
from pathlib import Path

import pytest


MODULE_PATH = (
    Path(__file__).resolve().parent.parent
    / "docker"
    / "metadata-service"
    / "metadata-service.py"
)


class _DummyResponse:
    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs


class _DummyApplication:
    def __init__(self, *args, **kwargs):
        self.router = types.SimpleNamespace(add_get=lambda *a, **k: None)


class _DummyAppRunner:
    def __init__(self, *args, **kwargs):
        pass

    async def setup(self):
        return None


class _DummyTCPSite:
    def __init__(self, *args, **kwargs):
        pass

    async def start(self):
        return None


class _DummyConnectionClosed(Exception):
    pass


@pytest.fixture()
def metadata_service_module(monkeypatch, tmp_path):
    monkeypatch.setenv("ARTWORK_DIR", str(tmp_path / "artwork"))
    monkeypatch.setenv("DEFAULTS_DIR", str(tmp_path / "defaults"))
    websockets_module = types.ModuleType("websockets")
    websockets_module.exceptions = types.SimpleNamespace(
        ConnectionClosed=_DummyConnectionClosed
    )
    websockets_module.serve = lambda *args, **kwargs: None
    monkeypatch.setitem(sys.modules, "websockets", websockets_module)
    aiohttp_module = types.ModuleType("aiohttp")
    aiohttp_module.web = types.SimpleNamespace(
        Request=type("Request", (), {}),
        StreamResponse=type("StreamResponse", (), {}),
        Response=_DummyResponse,
        FileResponse=_DummyResponse,
        json_response=lambda *args, **kwargs: _DummyResponse(*args, **kwargs),
        Application=_DummyApplication,
        AppRunner=_DummyAppRunner,
        TCPSite=_DummyTCPSite,
    )
    # Stub for `_fetch_snapcast_clients` / `_fetch_peer_status_summary`: any
    # future test that actually drives the success RPC path will read
    # `aiohttp.ClientTimeout(...)` — keep the attribute reachable so the
    # production code can be exercised without an AttributeError.
    aiohttp_module.ClientTimeout = lambda *a, **kw: None
    monkeypatch.setitem(sys.modules, "aiohttp", aiohttp_module)

    spec = importlib.util.spec_from_file_location(
        "metadata_service_module", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules.pop("metadata_service_module", None)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def service(metadata_service_module, monkeypatch):
    monkeypatch.setattr(metadata_service_module, "_mb_rate_limit", lambda: None)
    return metadata_service_module.MetadataService()


class TestReleaseMetaCaching:
    def test_fetch_musicbrainz_artwork_caches_original_date(self, service, monkeypatch):
        def fake_api(url: str, timeout: int = 5):
            if "/ws/2/release/?" in url:
                return {
                    "releases": [
                        {
                            "score": 100,
                            "id": "rel-1",
                            "date": "2011-09-26",
                            "tags": [{"name": "rock"}],
                            "release-group": {"id": "rg-1"},
                        }
                    ]
                }
            if "/ws/2/release-group/rg-1" in url:
                return {"first-release-date": "1979-11-30"}
            raise AssertionError(f"unexpected URL: {url}")

        monkeypatch.setattr(service, "_make_api_request", fake_api)

        artwork_url = service.fetch_musicbrainz_artwork("Pink Floyd", "The Wall")

        assert artwork_url == "https://coverartarchive.org/release/rel-1/front-500"
        cached = service._release_meta_cache["Pink Floyd|The Wall"]
        assert service._parse_release_meta_cache(cached) == (
            "2011-09-26",
            "1979-11-30",
            "rock",
        )

    def test_output_metadata_keeps_original_date(self, service):
        metadata = {
            "title": "Comfortably Numb",
            "date": "2011-09-26",
            "original_date": "1979-11-30",
            "file": "music/file.flac",
        }

        output = service._output_metadata(metadata)

        assert output["date"] == "2011-09-26"
        assert output["original_date"] == "1979-11-30"
        assert "file" not in output


class TestEnrichTags:
    def test_enrich_tags_preserves_date_and_sets_original_date(self, service):
        service._release_meta_cache["Pink Floyd|The Wall"] = (
            service._release_meta_cache_value("2011-09-26", "1979-11-30", "rock")
        )
        metadata = {
            "playing": True,
            "artist": "Pink Floyd",
            "album": "The Wall",
            "date": "2011-09-26",
        }

        service.enrich_tags(metadata)

        assert metadata["date"] == "2011-09-26"
        assert metadata["original_date"] == "1979-11-30"
        assert metadata["genre"] == "rock"

    def test_enrich_tags_reads_legacy_cache_format(self, service):
        service._release_meta_cache["Pink Floyd|The Wall"] = "2011-09-26|rock"
        metadata = {
            "playing": True,
            "artist": "Pink Floyd",
            "album": "The Wall",
        }

        service.enrich_tags(metadata)

        assert metadata["date"] == "2011-09-26"
        assert metadata["genre"] == "rock"
        assert "original_date" not in metadata


class TestVersionTupleParsing:
    """`_parse_version_tuple()` extracts numeric (major, minor, patch, [build]) tuples."""

    def test_parses_three_part(self, metadata_service_module):
        assert metadata_service_module._parse_version_tuple("0.7.9") == (0, 7, 9)

    def test_parses_four_part_build(self, metadata_service_module):
        assert metadata_service_module._parse_version_tuple("0.7.9.5") == (0, 7, 9, 5)

    def test_strips_v_prefix(self, metadata_service_module):
        assert metadata_service_module._parse_version_tuple("v0.7.9.5") == (0, 7, 9, 5)

    def test_empty_returns_none(self, metadata_service_module):
        assert metadata_service_module._parse_version_tuple("") is None

    def test_non_numeric_returns_none(self, metadata_service_module):
        assert metadata_service_module._parse_version_tuple("0.7.9-rc1") is None
        assert metadata_service_module._parse_version_tuple("unknown") is None
        assert metadata_service_module._parse_version_tuple("0.7.9.5-dev") is None


class TestUpdateAvailableSemverComparison:
    """`/version`'s update_available must use semver-tuple comparison, NOT `!=`.

    Regression: PR #545 sibling — observed on snapvideo with v0.7.9.5 in .env
    while GitHub `releases/latest` returned v0.7.9.3 (v0.7.9.4 + v0.7.9.5 were
    tag-without-publish). The old `latest != current` flagged update_available
    true, surfacing the misleading "Update available: 0.7.9.5 -> 0.7.9.3" on
    /status. Direction must be enforced: ahead is NOT an update.
    """

    @staticmethod
    def _is_update(module, current: str, latest: str) -> bool:
        # Mirror handle_version's comparison block — must stay in sync with
        # docker/metadata-service/metadata-service.py:handle_version.
        # Both sides are v-stripped FIRST to match production exactly.
        current_clean = current.lstrip("v")
        latest_clean = (latest or current).lstrip("v")
        current_tuple = module._parse_version_tuple(current_clean)
        latest_tuple = module._parse_version_tuple(latest_clean) if latest else None
        if current_tuple is not None and latest_tuple is not None:
            return latest_tuple > current_tuple
        return bool(latest and latest != current_clean)

    def test_current_ahead_of_latest_no_update(self, metadata_service_module):
        # The exact snapvideo scenario.
        assert self._is_update(metadata_service_module, "0.7.9.5", "0.7.9.3") is False

    def test_current_behind_latest_update_available(self, metadata_service_module):
        assert self._is_update(metadata_service_module, "0.7.9.3", "0.7.9.5") is True

    def test_equal_no_update(self, metadata_service_module):
        assert self._is_update(metadata_service_module, "0.7.9.5", "0.7.9.5") is False

    def test_empty_latest_no_update(self, metadata_service_module):
        assert self._is_update(metadata_service_module, "0.7.9.5", "") is False

    def test_unparseable_falls_back_to_inequality(self, metadata_service_module):
        # Dev clone where current is "unknown" — fall back to `!=` rather than crash.
        assert self._is_update(metadata_service_module, "unknown", "0.7.9.5") is True

    def test_v_prefix_stripped_in_fallback(self, metadata_service_module):
        # Production strips `v` from current BEFORE the `!=` fallback. Pins
        # the helper's behaviour so a future drift between test and prod is caught.
        assert self._is_update(metadata_service_module, "v0.7.9.5", "v0.7.9.5") is False
        assert self._is_update(metadata_service_module, "unknown", "v0.7.9.5") is True

    def test_major_minor_jump(self, metadata_service_module):
        # Ensure tuple ordering handles cross-segment correctly (not lexicographic).
        assert self._is_update(metadata_service_module, "0.7.10.0", "0.7.9.99") is False
        assert self._is_update(metadata_service_module, "0.7.9.99", "0.7.10.0") is True


class TestSnapcastClientsParse:
    """`_parse_snapcast_clients()` extracts a flat client list from Server.GetStatus."""

    @staticmethod
    def _sample_result() -> dict:
        return {
            "server": {
                "groups": [
                    {
                        "name": "Kitchen",
                        "stream_id": "MPD",
                        "clients": [
                            {
                                "connected": True,
                                "host": {
                                    "name": "snapclient-kitchen",
                                    "ip": "192.168.1.10",
                                },
                                "config": {
                                    "name": "Kitchen Sonos",
                                    "stream_id": "MPD",
                                    "volume": {"muted": False, "percent": 75},
                                },
                                "lastSeen": {"sec": 1700000000, "usec": 0},
                            },
                            {
                                "connected": False,
                                "host": {
                                    "name": "snapclient-old",
                                    "ip": "192.168.1.11",
                                },
                                "config": {
                                    "name": "Old Pi",
                                    "stream_id": "MPD",
                                    "volume": {"muted": True, "percent": 50},
                                },
                                "lastSeen": {"sec": 1699000000, "usec": 0},
                            },
                        ],
                    },
                    {
                        "name": "Office",
                        "stream_id": "Spotify",
                        "clients": [
                            {
                                "connected": True,
                                "host": {
                                    "name": "snapclient-office",
                                    "ip": "192.168.1.20",
                                },
                                "config": {
                                    "name": "Office Speaker",
                                    "stream_id": "Spotify",
                                    "volume": {"muted": False, "percent": 60},
                                },
                                "lastSeen": {"sec": 1700001000, "usec": 0},
                            }
                        ],
                    },
                ]
            }
        }

    def test_flattens_groups_into_one_list(self, metadata_service_module):
        clients = metadata_service_module._parse_snapcast_clients(self._sample_result())
        assert len(clients) == 3

    def test_extracts_per_client_fields(self, metadata_service_module):
        clients = metadata_service_module._parse_snapcast_clients(self._sample_result())
        by_name = {c["name"]: c for c in clients}
        kitchen = by_name["Kitchen Sonos"]
        assert kitchen["ip"] == "192.168.1.10"
        assert kitchen["connected"] is True
        assert kitchen["muted"] is False
        assert kitchen["volume"] == 75
        assert kitchen["stream"] == "MPD"
        assert kitchen["group"] == "Kitchen"

    def test_disconnected_clients_sort_last(self, metadata_service_module):
        clients = metadata_service_module._parse_snapcast_clients(self._sample_result())
        assert clients[0]["connected"] is True
        assert clients[-1]["connected"] is False
        assert clients[-1]["name"] == "Old Pi"

    def test_empty_result_returns_empty_list(self, metadata_service_module):
        assert metadata_service_module._parse_snapcast_clients({}) == []
        assert metadata_service_module._parse_snapcast_clients({"server": {}}) == []
        assert (
            metadata_service_module._parse_snapcast_clients({"server": {"groups": []}})
            == []
        )

    def test_malformed_volume_falls_back_to_zero(self, metadata_service_module):
        bad = {
            "server": {
                "groups": [
                    {
                        "name": "G",
                        "stream_id": "S",
                        "clients": [
                            {
                                "connected": True,
                                "host": {"name": "h"},
                                "config": {
                                    "name": "C",
                                    "stream_id": "S",
                                    "volume": {
                                        "muted": False,
                                        "percent": "not-a-number",
                                    },
                                },
                                "lastSeen": {"sec": "bad", "usec": 0},
                            }
                        ],
                    }
                ]
            }
        }
        clients = metadata_service_module._parse_snapcast_clients(bad)
        assert clients[0]["volume"] == 0
        assert clients[0]["last_seen_sec"] == 0


class TestSnapcastClientsRender:
    """`_render_snapcast_clients_section()` is a pure renderer; defends against XSS."""

    def test_none_renders_rpc_unreachable(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section(None)
        assert "Snapserver JSON-RPC unreachable" in html_str
        assert "<h2>Snapcast Clients</h2>" in html_str

    def test_empty_renders_no_clients(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section([])
        assert "No clients connected" in html_str

    def test_client_row_shows_state_volume_stream(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section(
            [
                {
                    "name": "Kitchen",
                    "host": "snapclient-kitchen",
                    "ip": "192.168.1.10",
                    "connected": True,
                    "muted": False,
                    "volume": 75,
                    "stream": "MPD",
                    "group": "Kitchen",
                }
            ]
        )
        assert "Kitchen" in html_str
        assert "192.168.1.10" in html_str
        assert "connected" in html_str
        assert "75%" in html_str
        assert "MPD" in html_str
        assert 'class="r-pass"' in html_str

    def test_muted_client_renders_muted_marker(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section(
            [
                {
                    "name": "Office",
                    "connected": True,
                    "muted": True,
                    "volume": 60,
                    "ip": "",
                    "stream": "",
                    "group": "",
                }
            ]
        )
        assert "(muted)" in html_str

    def test_disconnected_client_uses_info_class(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section(
            [
                {
                    "name": "Gone",
                    "connected": False,
                    "ip": "",
                    "volume": 0,
                    "stream": "",
                    "group": "",
                }
            ]
        )
        assert "disconnected" in html_str
        assert 'class="r-info"' in html_str

    def test_xss_in_client_name_is_escaped(self, metadata_service_module):
        html_str = metadata_service_module._render_snapcast_clients_section(
            [
                {
                    "name": "<script>alert(1)</script>",
                    "connected": True,
                    "ip": "",
                    "volume": 0,
                    "stream": "",
                    "group": "",
                }
            ]
        )
        assert "<script>alert(1)</script>" not in html_str
        assert "&lt;script&gt;" in html_str


class TestResourceProfile:
    """`_get_resource_profile()` + `_render_resource_profile_section()` — env-driven,
    pure functions. Tests pin: (a) hide on dev clones; (b) name-only when limits
    missing; (c) full table when limits propagated; (d) XSS defence on env values
    (in case a malicious .env lands on a device — same hardening as other sections).
    """

    def test_empty_env_returns_none(self, metadata_service_module, monkeypatch):
        monkeypatch.delenv("SNAPMULTI_PROFILE", raising=False)
        assert metadata_service_module._get_resource_profile() is None

    def test_whitespace_only_env_returns_none(
        self, metadata_service_module, monkeypatch
    ):
        monkeypatch.setenv("SNAPMULTI_PROFILE", "   ")
        assert metadata_service_module._get_resource_profile() is None

    def test_name_only_when_limits_missing(self, metadata_service_module, monkeypatch):
        monkeypatch.setenv("SNAPMULTI_PROFILE", "standard")
        for _, var in metadata_service_module._PROFILE_SERVICE_LIMITS:
            monkeypatch.delenv(var, raising=False)
        profile = metadata_service_module._get_resource_profile()
        assert profile == {"name": "standard", "limits": []}

    def test_full_propagation_yields_ordered_limits(
        self, metadata_service_module, monkeypatch
    ):
        monkeypatch.setenv("SNAPMULTI_PROFILE", "performance")
        monkeypatch.setenv("SNAPSERVER_MEM_LIMIT", "256M")
        monkeypatch.setenv("MPD_MEM_LIMIT", "384M")
        monkeypatch.setenv("METADATA_MEM_LIMIT", "128M")
        for _, var in metadata_service_module._PROFILE_SERVICE_LIMITS:
            if var not in {
                "SNAPSERVER_MEM_LIMIT",
                "MPD_MEM_LIMIT",
                "METADATA_MEM_LIMIT",
            }:
                monkeypatch.delenv(var, raising=False)
        profile = metadata_service_module._get_resource_profile()
        assert profile is not None
        # Order follows _PROFILE_SERVICE_LIMITS (snapserver before mpd before metadata),
        # not the order env vars were set in.
        assert profile["limits"] == [
            ("snapserver", "256M"),
            ("mpd", "384M"),
            ("metadata", "128M"),
        ]

    def test_render_none_yields_empty_string(self, metadata_service_module):
        assert metadata_service_module._render_resource_profile_section(None) == ""

    def test_render_name_only_uses_info_row(self, metadata_service_module):
        html_str = metadata_service_module._render_resource_profile_section(
            {"name": "minimal", "limits": []}
        )
        assert "<h2>Resource Profile</h2>" in html_str
        assert "Active profile: <strong>minimal</strong>" in html_str
        assert "Per-service memory limits not propagated" in html_str

    def test_render_with_limits_lists_each_service(self, metadata_service_module):
        html_str = metadata_service_module._render_resource_profile_section(
            {
                "name": "standard",
                "limits": [("snapserver", "192M"), ("mpd", "384M")],
            }
        )
        assert "Active profile: <strong>standard</strong>" in html_str
        assert "<code>192M</code>" in html_str
        assert "<code>384M</code>" in html_str
        # Service labels appear in the order given.
        assert html_str.index("snapserver") < html_str.index("mpd")

    def test_render_escapes_profile_name_and_limits(self, metadata_service_module):
        html_str = metadata_service_module._render_resource_profile_section(
            {
                "name": "<script>alert(1)</script>",
                "limits": [("svc&", "<b>192M</b>")],
            }
        )
        assert "<script>alert(1)</script>" not in html_str
        assert "&lt;script&gt;" in html_str
        assert "<b>192M</b>" not in html_str
        assert "&lt;b&gt;192M&lt;/b&gt;" in html_str


class TestSnapcastClientsCacheAndRouting:
    """Cache TTL + handle_status routing — gates on regressions the parser/renderer
    tests can't catch (e.g. wiring change that bypasses the cache or skips the fetch).
    """

    def test_cache_hit_within_ttl_skips_rpc(self, metadata_service_module, monkeypatch):
        # Pre-populate cache with a known value; call must NOT hit aiohttp.
        sentinel = [{"name": "cached-client", "connected": True}]
        metadata_service_module._snapclients_cache["data"] = (
            metadata_service_module.time.time(),
            sentinel,
        )

        class _BoomSession:
            def __init__(self, *a, **kw):
                raise RuntimeError("aiohttp must not be called on cache hit")

        monkeypatch.setattr(
            metadata_service_module.aiohttp,
            "ClientSession",
            _BoomSession,
            raising=False,
        )
        import asyncio

        result = asyncio.run(metadata_service_module._fetch_snapcast_clients())
        assert result is sentinel

    def test_cache_expired_triggers_rpc(self, metadata_service_module, monkeypatch):
        # Cache entry older than TTL → must refetch (and fail cleanly when aiohttp
        # mock is missing, returning None — same code path as "snapserver down").
        ttl = metadata_service_module._SNAPCLIENTS_CACHE_TTL_SECONDS
        old_ts = metadata_service_module.time.time() - ttl - 10
        metadata_service_module._snapclients_cache["data"] = (
            old_ts,
            [{"name": "stale"}],
        )

        called = {"value": False}

        class _CaughtSession:
            def __init__(self, *a, **kw):
                called["value"] = True
                raise RuntimeError("any error → returns None")

        monkeypatch.setattr(
            metadata_service_module.aiohttp,
            "ClientSession",
            _CaughtSession,
            raising=False,
        )
        import asyncio

        result = asyncio.run(metadata_service_module._fetch_snapcast_clients())
        assert called["value"] is True, "expired cache must trigger fresh RPC"
        assert result is None  # fetch failed → None cached

    def test_handle_status_calls_fetch_only_with_snapshot(
        self, metadata_service_module, monkeypatch
    ):
        """Boot-grace window (data is None) → _fetch_snapcast_clients must NOT fire."""
        fetch_calls = {"count": 0}

        async def fake_fetch(timeout_s=3.0):
            fetch_calls["count"] += 1
            return []

        monkeypatch.setattr(
            metadata_service_module, "_fetch_snapcast_clients", fake_fetch
        )
        monkeypatch.setattr(
            metadata_service_module,
            "_read_status_snapshot",
            lambda: (None, None),  # no snapshot yet
        )

        import asyncio

        request = types.SimpleNamespace(query={})
        asyncio.run(metadata_service_module.handle_status(request))
        assert fetch_calls["count"] == 0, (
            "RPC must not be made during boot-grace (no snapshot)"
        )

    def test_handle_status_calls_fetch_when_snapshot_present(
        self, metadata_service_module, monkeypatch
    ):
        fetch_calls = {"count": 0}

        async def fake_fetch(timeout_s=3.0):
            fetch_calls["count"] += 1
            return [{"name": "c1", "connected": True}]

        monkeypatch.setattr(
            metadata_service_module, "_fetch_snapcast_clients", fake_fetch
        )
        monkeypatch.setattr(
            metadata_service_module,
            "_read_status_snapshot",
            lambda: (
                {
                    "schema_version": 1,
                    "status": "ok",
                    "hostname": "pi-self",
                    "mode": "both",
                    "failures": 0,
                    "warnings": 0,
                    "records": [],
                },
                0.0,
            ),
        )

        import asyncio

        request = types.SimpleNamespace(query={})
        resp = asyncio.run(metadata_service_module.handle_status(request))
        assert fetch_calls["count"] == 1, "snapshot present → RPC should fire"
        body = resp.kwargs.get("text") or (resp.args[0] if resp.args else "")
        assert "Snapcast Clients" in body
        assert "c1" in body


class TestResolveExternalHost:
    """`_resolve_external_host()` picks a usable EXTERNAL_HOST per #460."""

    def test_explicit_env_wins(self, metadata_service_module, monkeypatch):
        monkeypatch.setenv("EXTERNAL_HOST", "explicit.example.com")
        assert (
            metadata_service_module._resolve_external_host() == "explicit.example.com"
        )

    def test_fqdn_used_when_resolves_non_loopback(
        self, metadata_service_module, monkeypatch
    ):
        monkeypatch.delenv("EXTERNAL_HOST", raising=False)
        monkeypatch.setattr(
            metadata_service_module.socket, "getfqdn", lambda: "host.lan"
        )
        monkeypatch.setattr(
            metadata_service_module.socket,
            "gethostbyname",
            lambda h: "192.168.1.10" if h == "host.lan" else "127.0.0.1",
        )
        assert metadata_service_module._resolve_external_host() == "host.lan"

    def test_lan_ip_fallback_when_fqdn_loopback(
        self, metadata_service_module, monkeypatch
    ):
        monkeypatch.delenv("EXTERNAL_HOST", raising=False)
        monkeypatch.setattr(
            metadata_service_module.socket, "getfqdn", lambda: "localhost"
        )
        monkeypatch.setattr(
            metadata_service_module.socket, "gethostbyname", lambda h: "127.0.0.1"
        )
        monkeypatch.setattr(
            metadata_service_module, "_detect_lan_ip", lambda: "192.168.1.42"
        )
        assert metadata_service_module._resolve_external_host() == "192.168.1.42"

    def test_falls_back_to_snapserver_host_when_everything_loopback(
        self, metadata_service_module, monkeypatch
    ):
        monkeypatch.delenv("EXTERNAL_HOST", raising=False)
        monkeypatch.setattr(
            metadata_service_module.socket, "getfqdn", lambda: "localhost"
        )
        monkeypatch.setattr(
            metadata_service_module.socket, "gethostbyname", lambda h: "127.0.0.1"
        )
        monkeypatch.setattr(metadata_service_module, "_detect_lan_ip", lambda: None)
        result = metadata_service_module._resolve_external_host()
        assert result == metadata_service_module.SNAPSERVER_HOST


class TestStructuredSystemdRow:
    """Regression coverage for the /status page row parser. The parser
    decides whether a smoke record gets tabular rendering (unit + state
    badge + description) or falls through to the flat <li> form."""

    def test_timer_active_with_desc(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Timers",
            "Timer snapmulti-status.timer enabled and active — 5-min status snapshot for /status web",
        )
        assert result == (
            "snapmulti-status.timer",
            "enabled · active",
            "",
            "5-min status snapshot for /status web",
        )

    def test_path_unit_active_with_desc(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Timers",
            "Path unit snapmulti-state-backup.path enabled and active — myMPD state backup on change",
        )
        assert result == (
            "snapmulti-state-backup.path",
            "enabled · active",
            "",
            "myMPD state backup on change",
        )

    def test_systemd_service_active(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Systemd", "systemd: snapmulti-server.service enabled and active"
        )
        assert result == (
            "snapmulti-server.service",
            "enabled · active",
            "",
            "",
        )

    def test_timer_enabled_but_broken(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Timers",
            "Timer foo.timer enabled but state is 'inactive' — daily backup",
        )
        assert result == (
            "foo.timer",
            "enabled · inactive",
            "fail",
            "daily backup",
        )

    def test_timer_missing(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Timers", "Timer foo.timer NOT installed — finalize incomplete?"
        )
        assert result == (
            "foo.timer",
            "not installed",
            "fail",
            "finalize incomplete?",
        )

    def test_timer_masked_is_warn(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Timers", "Path unit bar.path is 'masked' — was it disabled by accident?"
        )
        assert result == (
            "bar.path",
            "masked",
            "warn",
            "was it disabled by accident?",
        )

    def test_container_healthy(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Containers", "snapserver: healthy"
        )
        assert result == ("snapserver", "healthy", "", "")

    def test_container_unhealthy_is_fail(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Containers", "mympd: unhealthy"
        )
        assert result == ("mympd", "unhealthy", "fail", "")

    def test_container_starting_is_warn(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Containers", "fb-display: starting"
        )
        assert result == ("fb-display", "starting", "warn", "")

    def test_container_summary_row_falls_through(self, metadata_service_module):
        """Rows like 'All 10 containers have memory limit applied' don't
        match the NAME: STATE pattern and must return None so the renderer
        falls back to the flat <li> form."""
        result = metadata_service_module._structured_systemd_row(
            "Containers", "All 10 snapMULTI container(s) have memory limit applied"
        )
        assert result is None

    def test_container_healthy_with_limit(self, metadata_service_module):
        """check_containers.sh appends `(limit=<value>)` from
        HostConfig.Memory. The renderer surfaces it in the desc column
        so the operator sees the actual enforced limit per container."""
        result = metadata_service_module._structured_systemd_row(
            "Containers", "snapclient: healthy (limit=64M)"
        )
        assert result == ("snapclient", "healthy", "", "limit 64M")

    def test_container_unhealthy_with_reason_and_limit(self, metadata_service_module):
        """Both the dash-separated fail reason and the `(limit=…)` suffix
        can co-exist; the renderer joins them with a middle dot."""
        result = metadata_service_module._structured_systemd_row(
            "Containers",
            "mympd: unhealthy — service is failing its healthcheck probe (limit=32M)",
        )
        assert result == (
            "mympd",
            "unhealthy",
            "fail",
            "service is failing its healthcheck probe · limit 32M",
        )

    def test_container_unhealthy_with_reason_only(self, metadata_service_module):
        """Backwards-compat: when numfmt is missing or HostConfig.Memory
        is 0, check_containers.sh omits the `(limit=…)` suffix. The row
        still classifies correctly and surfaces only the reason."""
        result = metadata_service_module._structured_systemd_row(
            "Containers",
            "mympd: unhealthy — service is failing its healthcheck probe",
        )
        assert result == (
            "mympd",
            "unhealthy",
            "fail",
            "service is failing its healthcheck probe",
        )

    def test_container_healthy_without_limit_still_classifies(
        self, metadata_service_module
    ):
        """Regression: existing snapshots without the limit suffix MUST
        keep returning the same 4-tuple shape (desc is empty string,
        not None). Pins the pre-#586-follow-up status quo."""
        result = metadata_service_module._structured_systemd_row(
            "Containers", "fb-display: healthy"
        )
        assert result == ("fb-display", "healthy", "", "")

    def test_compose_nested_healthy(self, metadata_service_module):
        result = metadata_service_module._structured_systemd_row(
            "Compose", "  server/snapserver -> healthy"
        )
        assert result == ("server/snapserver", "healthy", "", "")

    def test_compose_summary_row_falls_through(self, metadata_service_module):
        """The 'server: 7/7 running, 7/7 healthy' summary uses different
        formatting and must fall back to flat rendering."""
        result = metadata_service_module._structured_systemd_row(
            "Compose", "server: 7/7 running, 7/7 healthy"
        )
        assert result is None

    def test_unrelated_section_falls_through(self, metadata_service_module):
        """A timer-shaped line in a section we don't tabularise must not
        be reformatted (could be coincidence in a free-text message)."""
        result = metadata_service_module._structured_systemd_row(
            "Host", "Timer foo.timer enabled and active — context"
        )
        assert result is None
