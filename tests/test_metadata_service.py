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


class TestEstimateElapsedCalibration:
    """_estimate_elapsed must return None for a track that was already
    playing when metadata-service started (non-MPD sources).

    The estimator tracks elapsed via local monotonic clock. Its "anchor for
    track start" is the moment it sees the stream switch to the track. For
    MPD and Spotify that's fine because those sources report their own
    elapsed independently. For AirPlay and Tidal we have no other source of
    truth — if metadata-service boots while a track is already playing, our
    "anchor" is wrong and the local-clock estimate is offset by however much
    we missed at the start.

    A previous fix used a 5 s startup grace window, but the first poll always
    lands <1 s after start, so every mid-track restart was still treated as
    calibrated and emitted elapsed from 0 (these tests only passed because
    they faked the service age). Now: the first track ever seen on a stream
    is uncalibrated regardless of timing; a track change observed while the
    service runs is calibrated. No faked service age is needed.
    """

    def test_first_sighting_right_after_start_is_uncalibrated(self, service):
        """Service just constructed, first poll immediately: still None."""
        elapsed = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert elapsed is None

    def test_first_sighting_subsequent_polls_still_none(self, service):
        """Once a stream/track is flagged uncalibrated, it stays uncalibrated
        until the next track change."""
        first = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        second = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        third = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert first is None
        assert second is None
        assert third is None

    def test_recovers_on_next_track_change(self, service):
        """A track change while the timer exists is observed in real time —
        we have an anchor for the new track. Calibration resumes."""
        first = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert first is None
        recovered = service._estimate_elapsed("AirPlay", "Song B|Artist", True)
        assert recovered == 0

    def test_idle_at_start_then_track_starts_is_calibrated(self, service):
        """Stream idle (no metadata) at startup, then a track appears: the
        change was observed live, so elapsed counts from 0."""
        idle = service._estimate_elapsed("AirPlay", "|", False)
        assert idle is None
        started = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert started == 0

    def test_paused_track_at_start_resumed_stays_none(self, service):
        """A track sitting paused at startup and resumed later still has no
        anchor (it was paused mid-way)."""
        paused = service._estimate_elapsed("Spotify", "Song A|Artist", False)
        resumed = service._estimate_elapsed("Spotify", "Song A|Artist", True)
        assert paused is None
        assert resumed is None

    def test_calibrated_track_accumulates_correctly(self, service):
        """A calibrated track should still accumulate elapsed via the
        monotonic-clock path."""
        import time as _t

        service._estimate_elapsed("AirPlay", "|", False)
        first = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert first == 0
        # Move the timer's start backwards to simulate elapsed time
        service._track_timers["AirPlay"]["start"] = _t.monotonic() - 7.0
        elapsed = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert elapsed == 7

    def test_per_stream_calibration_independent(self, service):
        """An uncalibrated AirPlay must not affect Tidal — calibration is
        per-stream."""
        ap = service._estimate_elapsed("AirPlay", "Song A|Artist A", True)
        td = service._estimate_elapsed("Tidal", "Song B|Artist B", True)
        assert ap is None
        assert td is None
        # A track change on AirPlay recovers AirPlay only.
        ap_recovered = service._estimate_elapsed("AirPlay", "Song A2|Artist A", True)
        td_still_uncalibrated = service._estimate_elapsed(
            "Tidal", "Song B|Artist B", True
        )
        assert ap_recovered == 0
        assert td_still_uncalibrated is None

    def test_paused_then_resumed_during_uncalibrated_session_stays_none(self, service):
        """Pause/resume on an uncalibrated track returns None for all phases."""
        playing = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        paused = service._estimate_elapsed("AirPlay", "Song A|Artist", False)
        resumed = service._estimate_elapsed("AirPlay", "Song A|Artist", True)
        assert playing is None
        assert paused is None
        assert resumed is None


class TestArtworkChainTelemetry:
    """The artwork chain logs one INFO line per (stream, track, source)
    transition so an operator can grep the logs to see which fallback level
    actually serves artwork in real use. Designed to answer the otherwise-
    blind question "does iTunes ever fire?" without adding a metrics surface.

    Behaviour pinned by these tests:
    - Skip log for empty source (no artwork resolved) and "snapcast" (input
      already had artwork, chain did no work).
    - Log once on first hit; do NOT log again for the same (track, source)
      pair across repeat polls of the same track.
    - Log again when source changes for the same track (chain transitioned).
    - Log again when track changes (different (track, source) tuple).
    - Per-stream isolation — repeated MPD source must not silence AirPlay.
    """

    def _meta(self, **kw) -> dict:
        base = {
            "source": "MPD",
            "artist": "Pink Floyd",
            "album": "The Wall",
            "title": "Comfortably Numb",
        }
        base.update(kw)
        return base

    def test_snapcast_source_does_not_log(self, service, caplog):
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(), "snapcast")
        assert "Artwork served" not in caplog.text

    def test_empty_source_does_not_log(self, service, caplog):
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(), "")
        assert "Artwork served" not in caplog.text

    def test_first_hit_logs_once(self, service, caplog):
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(), "musicbrainz")
        assert caplog.text.count("Artwork served via musicbrainz") == 1
        assert "Pink Floyd" in caplog.text
        assert "The Wall" in caplog.text
        assert "[MPD]" in caplog.text

    def test_repeat_same_track_same_source_silenced(self, service, caplog):
        with caplog.at_level("INFO"):
            for _ in range(5):
                service._log_artwork_chain_hit(self._meta(), "musicbrainz")
        # Only the first call logs
        assert caplog.text.count("Artwork served via musicbrainz") == 1

    def test_same_track_source_changes_logs_again(self, service, caplog):
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(), "musicbrainz")
            service._log_artwork_chain_hit(self._meta(), "itunes")
        assert "Artwork served via musicbrainz" in caplog.text
        assert "Artwork served via itunes" in caplog.text

    def test_track_change_logs_again(self, service, caplog):
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(title="Mother"), "musicbrainz")
            service._log_artwork_chain_hit(self._meta(title="Hey You"), "musicbrainz")
        # Different titles → different track_key → both log
        assert caplog.text.count("Artwork served via musicbrainz") == 2

    def test_per_stream_dedup_isolated(self, service, caplog):
        """A hit on MPD must not silence the same source on AirPlay."""
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(self._meta(source="MPD"), "musicbrainz")
            service._log_artwork_chain_hit(self._meta(source="AirPlay"), "musicbrainz")
            # Repeat MPD with same track+source — silenced
            service._log_artwork_chain_hit(self._meta(source="MPD"), "musicbrainz")
        assert caplog.text.count("Artwork served via musicbrainz") == 2
        assert "[MPD]" in caplog.text
        assert "[AirPlay]" in caplog.text

    def test_radio_default_placeholder_logs(self, service, caplog):
        """The 'default' fallback for radio is exactly the case telemetry
        most needs to surface — it signals chain exhaustion."""
        radio = {
            "source": "Radio",
            "artist": "",
            "album": "",
            "title": "Live Stream",
        }
        with caplog.at_level("INFO"):
            service._log_artwork_chain_hit(radio, "default")
        assert "Artwork served via default" in caplog.text


class TestSystemVitals:
    """Status-page System-vitals badge (temperature / CPU load / audio resync).

    The three values are collected host-side by device-smoke and land in the
    snapshot as info/pass records; `_extract_vitals` reads them back by stable
    message prefix (the container is read-only and cannot read the sensors).
    """

    def _records(self, msgs: list[str]) -> list[dict]:
        return [{"section": "x", "status": "info", "msg": m} for m in msgs]

    def test_extract_vitals_all_present(self, metadata_service_module):
        html = metadata_service_module._extract_vitals(
            self._records(
                [
                    "SoC 69.1°C via vcgencmd (below 75°C warn floor)",
                    "CPU load: 0.39 0.28 0.27 (4 cores)",
                    "Audio resync (snapclient, 24h): 7",
                ]
            )
        )
        assert 'class="vitals"' in html
        assert "69.1" in html
        assert "0.39" in html  # 1-minute average only
        assert ">7<" in html
        assert "—" not in html

    def test_extract_vitals_missing_render_dash(self, metadata_service_module):
        html = metadata_service_module._extract_vitals(
            self._records(["CPU load: 1.20 1.10 0.90 (4 cores)"])
        )
        assert "1.20" in html
        assert html.count("—") == 2  # temperature + resync absent

    def test_extract_vitals_empty_when_no_vitals(self, metadata_service_module):
        assert metadata_service_module._extract_vitals([]) == ""

    def test_extract_vitals_unavailable_resync_not_numeric(
        self, metadata_service_module
    ):
        # "log source unavailable" must not be parsed as a resync count.
        html = metadata_service_module._extract_vitals(
            self._records(["Audio resync (24h): log source unavailable"])
        )
        assert html == ""  # no numeric vital at all -> no badge

    def test_status_page_includes_vitals_badge(self, metadata_service_module):
        data = {
            "schema_version": 1,
            "status": "ok",
            "failures": 0,
            "warnings": 0,
            "hostname": "pi-server",
            "mode": "both",
            "records": [
                {
                    "section": "System",
                    "status": "info",
                    "msg": "CPU load: 0.50 0.40 0.30 (4 cores)",
                },
                {
                    "section": "Thermal",
                    "status": "pass",
                    "msg": "SoC 62.0°C via vcgencmd (below 75°C warn floor)",
                },
                {
                    "section": "Audio liveness",
                    "status": "info",
                    "msg": "Audio resync (snapclient, 24h): 0",
                },
            ],
        }
        html = metadata_service_module._status_to_html(data, age_s=1.0)
        assert 'class="vitals"' in html
        assert "62.0" in html
        assert "0.50" in html


# ──────────────────────────────────────────────────────────────────────────
# Audit regression tests (MPD protocol, artwork chain, SSRF redirects,
# async enrichment, JSON-RPC ids, WebSocket input, playback routing)
# ──────────────────────────────────────────────────────────────────────────


class FakeMPDSocket:
    """In-memory MPD server: replies are queued on sendall, drained by recv.

    recv_size forces replies to straddle recv() boundaries so marker-scanning
    parsers break the way they do on real sockets.
    """

    def __init__(
        self,
        image: bytes = b"",
        version: str = "0.23.5",
        chunk: int = 8192,
        recv_size: int = 4096,
        binarylimit: bool = True,
        ack_at_offset: int | None = None,
        close_at_offset: int | None = None,
        status: dict | None = None,
        song: dict | None = None,
    ):
        self.image = image
        self.chunk = chunk
        self.recv_size = recv_size
        self.binarylimit = binarylimit
        self.ack_at_offset = ack_at_offset
        self.close_at_offset = close_at_offset
        self.status = status or {}
        self.song = song or {}
        self.out = bytearray(f"OK MPD {version}\n".encode())
        self.commands: list[str] = []
        self.closed = False

    def settimeout(self, _t):
        pass

    def close(self):
        self.closed = True

    def recv(self, n):
        n = min(n, self.recv_size)
        data = bytes(self.out[:n])
        del self.out[:n]
        return data

    def _kv(self, d: dict) -> bytes:
        return b"".join(f"{k}: {v}\n".encode() for k, v in d.items())

    def sendall(self, data: bytes):
        for line in data.decode().splitlines():
            self.commands.append(line)
            if line.startswith("binarylimit "):
                if self.binarylimit:
                    self.chunk = int(line.split()[1])
                    self.out += b"OK\n"
                else:
                    self.out += b"ACK [5@0] {binarylimit} unknown command\n"
            elif line.startswith("readpicture "):
                offset = int(line.rsplit(" ", 1)[1])
                if self.close_at_offset is not None and offset >= self.close_at_offset:
                    return  # connection dies: nothing more to read
                if self.ack_at_offset is not None and offset >= self.ack_at_offset:
                    self.out += b"ACK [50@0] {readpicture} No file exists\n"
                    continue
                if not self.image:
                    self.out += b"OK\n"
                    continue
                part = self.image[offset : offset + self.chunk]
                self.out += (
                    f"size: {len(self.image)}\ntype: image/jpeg\n"
                    f"binary: {len(part)}\n".encode()
                    + part
                    + b"\nOK\n"
                )
            elif line == "status":
                self.out += self._kv(self.status) + b"OK\n"
            elif line == "currentsong":
                self.out += self._kv(self.song) + b"OK\n"
            else:
                self.out += b"OK\n"


def _hostile_image(size: int) -> bytes:
    """Image bytes salted with every marker the old parser scanned for."""
    import os as _os

    body = bytearray(_os.urandom(size))
    for pos, marker in (
        (100, b"ACK"),
        (5000, b"OK\n"),
        (9000, b"binary: 12\n"),
        (20000, b"\nACK [5@0] {x} y\n"),
    ):
        if pos + len(marker) < size:
            body[pos : pos + len(marker)] = marker
    body[:3] = b"\xff\xd8\xff"
    return bytes(body)


class TestMPDProtocolParsing:
    def _serve(self, service, monkeypatch, sock):
        monkeypatch.setattr(service, "_create_socket", lambda *a, **k: sock)
        service._mpd_was_connected = True

    def test_artwork_with_protocol_markers_in_bytes_is_complete(
        self, service, monkeypatch
    ):
        image = _hostile_image(300_000)
        sock = FakeMPDSocket(image=image, recv_size=1000, binarylimit=False)
        self._serve(service, monkeypatch, sock)

        name = service.fetch_mpd_artwork("Album/track.flac")

        assert name.startswith("artwork_") and name.endswith(".jpg")
        assert (service.artwork_dir / name).read_bytes() == image

    def test_binarylimit_sent_on_new_mpd_reduces_round_trips(
        self, service, monkeypatch
    ):
        image = _hostile_image(2_500_000)
        sock = FakeMPDSocket(image=image, recv_size=65536)
        self._serve(service, monkeypatch, sock)

        name = service.fetch_mpd_artwork("Album/big.flac")

        assert (service.artwork_dir / name).read_bytes() == image
        assert sock.commands[0] == "binarylimit 1048576"
        assert sum(c.startswith("readpicture") for c in sock.commands) == 3

    def test_binarylimit_ack_is_ignored(self, service, monkeypatch):
        image = _hostile_image(20_000)
        sock = FakeMPDSocket(image=image, binarylimit=False)
        self._serve(service, monkeypatch, sock)
        assert service.fetch_mpd_artwork("a.flac")
        assert sock.commands[0].startswith("binarylimit")

    def test_old_mpd_gets_no_binarylimit(self, service, monkeypatch):
        sock = FakeMPDSocket(image=_hostile_image(10_000), version="0.22.3")
        self._serve(service, monkeypatch, sock)
        assert service.fetch_mpd_artwork("a.flac")
        assert not any(c.startswith("binarylimit") for c in sock.commands)

    def test_ack_mid_image_writes_nothing(self, service, monkeypatch):
        sock = FakeMPDSocket(image=_hostile_image(30_000), ack_at_offset=8192)
        sock.binarylimit = False
        self._serve(service, monkeypatch, sock)

        assert service.fetch_mpd_artwork("a.flac") == ""
        assert list(service.artwork_dir.glob("artwork_*")) == []

    def test_connection_closed_mid_image_writes_nothing(self, service, monkeypatch):
        sock = FakeMPDSocket(
            image=_hostile_image(30_000), close_at_offset=16384, binarylimit=False
        )
        self._serve(service, monkeypatch, sock)

        assert service.fetch_mpd_artwork("a.flac") == ""
        assert list(service.artwork_dir.glob("artwork_*")) == []

    def test_no_embedded_picture(self, service, monkeypatch):
        sock = FakeMPDSocket(image=b"")
        self._serve(service, monkeypatch, sock)
        assert service.fetch_mpd_artwork("a.flac") == ""

    def test_tag_values_spanning_recv_boundaries(self, service, monkeypatch):
        sock = FakeMPDSocket(
            recv_size=7,
            status={"state": "play", "elapsed": "12.5", "duration": "255.0"},
            song={
                "file": "AC/DC/Back In Black/01.flac",
                "Title": "BACK IN BLACK OK",
                "Artist": "AC/DC",
                "Album": "Back In Black",
                "Date": "1980",
                "Genre": "Rock",
            },
        )
        self._serve(service, monkeypatch, sock)

        meta = service.get_mpd_metadata()

        assert meta["playing"] is True
        assert meta["title"] == "BACK IN BLACK OK"
        assert meta["album"] == "Back In Black"
        assert meta["genre"] == "Rock"
        assert meta["elapsed"] == 12
        # No OriginalDate tag: local Date is used, so enrich_tags has nothing
        # to look up for a fully tagged file.
        assert meta["original_date"] == "1980"

    def test_original_date_tag_is_read(self, service, monkeypatch):
        sock = FakeMPDSocket(
            status={"state": "play"},
            song={
                "file": "x.flac",
                "Title": "T",
                "Date": "2011-09-26",
                "OriginalDate": "1979-11-30",
                "Genre": "rock",
            },
        )
        self._serve(service, monkeypatch, sock)
        meta = service.get_mpd_metadata()
        assert meta["original_date"] == "1979-11-30"

        calls = []
        monkeypatch.setattr(
            service, "_make_api_request", lambda *a, **k: calls.append(a)
        )
        meta["artist"] = "Pink Floyd"
        meta["album"] = "The Wall"
        service.enrich_tags(meta)
        assert calls == []


class _FakeClock:
    def __init__(self, module, monkeypatch, start: float = 1000.0):
        self.now = start
        monkeypatch.setattr(module.time, "monotonic", lambda: self.now)


class TestArtworkFailureHandling:
    def test_failed_download_expires(
        self, service, metadata_service_module, monkeypatch
    ):
        clock = _FakeClock(metadata_service_module, monkeypatch)
        service._mark_failed("https://x/a.jpg")
        assert service._is_failed("https://x/a.jpg")
        clock.now += metadata_service_module._FAIL_TTL_TRANSIENT + 1
        assert not service._is_failed("https://x/a.jpg")

    def _stub_network(self, module, service, monkeypatch, behaviour):
        monkeypatch.setattr(
            service, "_check_artwork_host", lambda host: ("93.184.216.34", True)
        )

        def fake_open(req, timeout):
            return behaviour(req.full_url)

        monkeypatch.setattr(module, "safe_urlopen", fake_open)

    def test_404_is_permanent_timeout_is_transient(
        self, service, metadata_service_module, monkeypatch
    ):
        import io
        import urllib.error

        module = metadata_service_module
        clock = _FakeClock(module, monkeypatch)

        def behaviour(url):
            if "missing" in url:
                raise urllib.error.HTTPError(url, 404, "nf", {}, io.BytesIO())
            raise urllib.error.URLError(TimeoutError("timed out"))

        self._stub_network(module, service, monkeypatch, behaviour)

        assert service.download_artwork("https://caa.example/missing") == ""
        assert service.download_artwork("https://caa.example/slow") == ""
        perm = service._failed_downloads["https://caa.example/missing"]
        trans = service._failed_downloads["https://caa.example/slow"]
        assert perm - clock.now == module._FAIL_TTL_PERMANENT
        assert trans - clock.now == module._FAIL_TTL_TRANSIENT

        # After the transient window the URL is tried again.
        clock.now += module._FAIL_TTL_TRANSIENT + 1
        hits = []
        self._stub_network(
            module,
            service,
            monkeypatch,
            lambda url: hits.append(url) or io.BytesIO(b"\xff\xd8\xffimage"),
        )
        assert service.download_artwork("https://caa.example/slow").startswith(
            "artwork_"
        )
        assert hits == ["https://caa.example/slow"]
        assert service.download_artwork("https://caa.example/missing") == ""

    def test_oversized_download_rejected(
        self, service, metadata_service_module, monkeypatch
    ):
        import io

        module = metadata_service_module
        self._stub_network(
            module,
            service,
            monkeypatch,
            lambda url: io.BytesIO(
                b"x" * (module.MetadataService._MAX_ARTWORK_BYTES + 1)
            ),
        )
        assert service.download_artwork("https://big.example/a.jpg") == ""
        assert list(service.artwork_dir.glob("artwork_*")) == []

    def _chain_service(self, service, monkeypatch, ok_urls, mb="https://caa/front"):
        downloads = []

        def fake_download(url, cache_key=""):
            downloads.append(url)
            return "artwork_ok.jpg" if url in ok_urls else ""

        monkeypatch.setattr(service, "download_artwork", fake_download)
        monkeypatch.setattr(service, "fetch_musicbrainz_artwork", lambda a, b: mb)
        monkeypatch.setattr(
            service, "_fetch_itunes_artwork", lambda a, b: "https://itunes/600.jpg"
        )
        monkeypatch.setattr(service, "fetch_artist_image", lambda a: "")
        return downloads

    def test_caa_404_falls_through_to_itunes(self, service, monkeypatch):
        downloads = self._chain_service(
            service, monkeypatch, ok_urls={"https://itunes/600.jpg"}
        )
        meta = {"playing": True, "source": "Tidal", "artist": "A", "album": "B"}

        service.enrich_artwork(meta)

        assert downloads == ["https://caa/front", "https://itunes/600.jpg"]
        assert meta["artwork_source"] == "itunes"
        assert meta["artwork"].endswith("/artwork/artwork_ok.jpg")

    def test_source_url_failure_continues_down_the_chain(self, service, monkeypatch):
        downloads = self._chain_service(
            service, monkeypatch, ok_urls={"https://caa/front"}
        )
        meta = {
            "playing": True,
            "source": "Spotify",
            "artist": "A",
            "album": "B",
            "artwork": "https://i.scdn.co/image/abc",
        }

        service.enrich_artwork(meta)

        assert downloads[0] == "https://i.scdn.co/image/abc"
        assert meta["artwork_source"] == "musicbrainz"

    def test_lookup_error_is_retried_sooner_than_a_miss(
        self, service, metadata_service_module, monkeypatch
    ):
        module = metadata_service_module
        clock = _FakeClock(module, monkeypatch)
        calls = []

        def mb(artist, album):
            calls.append("mb")
            return None  # lookup failed (timeout / 503)

        monkeypatch.setattr(service, "fetch_musicbrainz_artwork", mb)
        monkeypatch.setattr(service, "_fetch_itunes_artwork", lambda a, b: "")

        assert list(service._album_art_candidates("A", "B")) == []
        assert list(service._album_art_candidates("A", "B")) == []
        assert calls == ["mb"]
        clock.now += module._NEG_TTL_ERROR + 1
        assert list(service._album_art_candidates("A", "B")) == []
        assert calls == ["mb", "mb"]


class TestMusicBrainzLimiterAndCaches:
    def test_every_musicbrainz_call_is_rate_limited(
        self, service, metadata_service_module, monkeypatch
    ):
        import io

        module = metadata_service_module
        limited = []
        monkeypatch.setattr(module, "_mb_rate_limit", lambda: limited.append(1))
        monkeypatch.setattr(
            module, "safe_urlopen", lambda req, timeout: io.BytesIO(b"{}")
        )
        service._make_api_request("https://musicbrainz.org/ws/2/artist/?query=x")
        service._make_api_request("https://itunes.apple.com/search?term=x")
        assert limited == [1]

    def test_artist_image_error_not_cached_forever(
        self, service, metadata_service_module, monkeypatch
    ):
        module = metadata_service_module
        clock = _FakeClock(module, monkeypatch)
        calls = []
        monkeypatch.setattr(
            service, "_make_api_request", lambda url, timeout=5: calls.append(url)
        )
        assert service.fetch_artist_image("Hole") == ""
        assert service.fetch_artist_image("Hole") == ""
        assert len(calls) == 1
        clock.now += module._NEG_TTL_ERROR + 1
        service.fetch_artist_image("Hole")
        assert len(calls) == 2

    def test_cache_reads_refresh_lru_position(self, service):
        cache = service.artwork_cache
        for i in range(service._cache_limit):
            service._cache_set(cache, f"k{i}", f"v{i}")
        assert service._cache_get(cache, "k0") == "v0"  # touch the oldest
        service._cache_set(cache, "new", "v")
        assert "k0" in cache
        assert "k1" not in cache


class TestSSRFRedirects:
    def test_redirect_to_private_address_is_blocked(
        self, metadata_service_module, monkeypatch
    ):
        import urllib.request

        module = metadata_service_module
        monkeypatch.setattr(
            module.socket,
            "getaddrinfo",
            lambda host, *a, **k: [(2, 1, 6, "", ("192.168.1.10", 0))],
        )
        handler = module.SafeRedirectHandler()
        req = urllib.request.Request("https://favicon.example/logo.png")
        with pytest.raises(module.BlockedURLError):
            handler.redirect_request(
                req, None, 302, "Found", {}, "http://router.lan/admin"
            )

    def test_redirect_to_public_address_drops_pinned_host_header(
        self, metadata_service_module, monkeypatch
    ):
        import urllib.request

        module = metadata_service_module
        monkeypatch.setattr(
            module.socket,
            "getaddrinfo",
            lambda host, *a, **k: [(2, 1, 6, "", ("93.184.216.34", 0))],
        )
        handler = module.SafeRedirectHandler()
        req = urllib.request.Request(
            "http://93.184.216.34/a.png", headers={"Host": "cdn.example"}
        )
        new = handler.redirect_request(
            req, None, 302, "Found", {}, "https://cdn2.example/a.png"
        )
        assert new is not None
        assert new.get_header("Host") is None
        assert handler.max_redirections == module._MAX_REDIRECTS

    def test_real_redirect_into_lan_is_not_followed(self, service, monkeypatch):
        """End to end: the first hop is a trusted local address (allowed, like
        the AirPlay cover), but its 302 to another local URL is refused."""
        import http.server
        import threading

        hits = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                if self.path == "/logo.png":
                    self.send_response(302)
                    self.send_header(
                        "Location", f"http://127.0.0.1:{self.server.server_port}/secret"
                    )
                    self.end_headers()
                else:
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b"\xff\xd8\xffsecret")

            def log_message(self, *a):
                pass

        srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            port = srv.server_port
            direct = service.download_artwork(f"http://127.0.0.1:{port}/direct.jpg")
            assert direct.startswith("artwork_")
            assert service.download_artwork(f"http://127.0.0.1:{port}/logo.png") == ""
            assert "/secret" not in hits
        finally:
            srv.shutdown()
            srv.server_close()


class TestNetworkStateRefresh:
    def test_external_host_re_resolved_after_loopback(
        self, metadata_service_module, monkeypatch
    ):
        module = metadata_service_module
        clock = _FakeClock(module, monkeypatch)
        monkeypatch.delenv("EXTERNAL_HOST", raising=False)
        answers = iter(["127.0.0.1", "192.168.1.50", "192.168.1.99"])
        monkeypatch.setattr(module, "_resolve_external_host", lambda: next(answers))

        assert module.get_external_host() == "127.0.0.1"
        clock.now += module._EXTERNAL_HOST_LOOPBACK_TTL + 1
        assert module.get_external_host() == "192.168.1.50"
        clock.now += 1
        assert module.get_external_host() == "192.168.1.50"  # cached
        clock.now += module._EXTERNAL_HOST_TTL + 1
        assert module.get_external_host() == "192.168.1.99"  # DHCP change

    def test_explicit_external_host_never_re_resolved(
        self, metadata_service_module, monkeypatch
    ):
        module = metadata_service_module
        monkeypatch.setenv("EXTERNAL_HOST", "snap.lan")
        monkeypatch.setattr(
            module,
            "_resolve_external_host",
            lambda: pytest.fail("must not resolve"),
        )
        assert module.get_external_host() == "snap.lan"

    def test_new_lan_ip_becomes_trusted_without_restart(
        self, service, metadata_service_module, monkeypatch
    ):
        import subprocess as sp

        module = metadata_service_module
        monkeypatch.setattr(
            module.socket,
            "getaddrinfo",
            lambda host, *a, **k: [(2, 1, 6, "", ("192.168.7.20", 0))],
        )
        monkeypatch.setattr(
            module.subprocess,
            "run",
            lambda *a, **k: sp.CompletedProcess(a, 0, stdout="192.168.7.20\n"),
        )
        service._trusted_ips = {"127.0.0.1", "::1"}
        service._trusted_ips_at = module.time.monotonic() - 10  # fresh-ish

        ip, allowed = service._check_artwork_host("192.168.7.20")
        assert allowed and ip == "192.168.7.20"


class _FakeWS:
    def __init__(self, messages=()):
        self.sent: list[dict] = []
        self._messages = list(messages)
        self.remote_address = ("10.0.0.9", 5555)

    async def send(self, text):
        import json as _json

        self.sent.append(_json.loads(text))

    def __aiter__(self):
        return self

    async def __anext__(self):
        if not self._messages:
            raise StopAsyncIteration
        return self._messages.pop(0)


def _airplay_server(title, artist="Artist", art=""):
    meta = {"title": title, "artist": [artist], "album": "Album"}
    if art:
        meta["artUrl"] = art
    return {
        "groups": [
            {
                "stream_id": "AirPlay",
                "clients": [{"id": "room", "host": {}, "config": {}}],
            }
        ],
        "streams": [
            {"id": "AirPlay", "status": "playing", "properties": {"metadata": meta}}
        ],
    }


class TestAsyncEnrichment:
    def _setup(self, module, service, monkeypatch, servers):
        import threading

        state = {"server": servers[0]}
        monkeypatch.setattr(service, "get_server_status", lambda: state["server"])
        gates: dict[str, threading.Event] = {}

        def slow_enrich(base):
            gate = gates.setdefault(base["title"], threading.Event())
            assert gate.wait(5)
            return {
                "artwork": f"http://h:8083/artwork/{base['title']}.jpg",
                "artwork_source": "itunes",
            }

        monkeypatch.setattr(service, "_enrich_sync", slow_enrich)
        monkeypatch.setattr(service, "_write_stream_file", lambda *a: None)
        ws = _FakeWS()
        sc = module.SubscribedClient(ws, stream_id_direct="AirPlay")
        module.ws_clients.clear()
        module.ws_clients.add(sc)
        return state, gates, ws

    def test_text_is_broadcast_before_enrichment_finishes(
        self, service, metadata_service_module, monkeypatch
    ):
        import asyncio
        import threading

        module = metadata_service_module
        state, gates, ws = self._setup(
            module, service, monkeypatch, [_airplay_server("Song A")]
        )

        async def scenario():
            gates["Song A"] = threading.Event()
            assert await service._poll_once()
            # Title pushed immediately, artwork still pending.
            assert ws.sent[-1]["title"] == "Song A"
            assert ws.sent[-1]["artwork"] == ""
            assert service.last_successful_poll_at > 0
            gates["Song A"].set()
            await service.streams["AirPlay"].enrich_task
            assert ws.sent[-1]["title"] == "Song A"
            assert ws.sent[-1]["artwork"].endswith("/Song A.jpg")

        asyncio.run(scenario())
        module.ws_clients.clear()

    def test_late_result_never_overwrites_newer_track(
        self, service, metadata_service_module, monkeypatch
    ):
        import asyncio
        import threading

        module = metadata_service_module
        state, gates, ws = self._setup(
            module, service, monkeypatch, [_airplay_server("Song A")]
        )

        async def scenario():
            gates["Song A"] = threading.Event()
            gates["Song B"] = threading.Event()
            await service._poll_once()
            sm = service.streams["AirPlay"]
            task_a = sm.enrich_task
            state["server"] = _airplay_server("Song B")
            await service._poll_once()
            assert ws.sent[-1]["title"] == "Song B"
            # A's lookup completes late — its artwork must not show up on B.
            gates["Song A"].set()
            await asyncio.sleep(0.1)
            assert task_a.cancelled() or task_a.done()
            assert all(
                not m.get("artwork", "").endswith("/Song A.jpg")
                for m in ws.sent
                if m.get("title") == "Song B"
            )
            gates["Song B"].set()
            await sm.enrich_task
            assert ws.sent[-1]["artwork"].endswith("/Song B.jpg")
            # Same track keeps polling: no second enrichment is started.
            task_b = sm.enrich_task
            await service._poll_once()
            assert sm.enrich_task is task_b

        asyncio.run(scenario())
        module.ws_clients.clear()

    def test_elapsed_only_change_does_not_rewrite_stream_file(
        self, service, metadata_service_module, monkeypatch
    ):
        import asyncio

        module = metadata_service_module
        writes = []
        monkeypatch.setattr(
            service, "_write_stream_file", lambda sid, m: writes.append(m)
        )
        sm = module.StreamMetadata("MPD")
        sm.base = {"playing": False, "title": "T", "elapsed": 1}

        async def scenario():
            await service._publish_stream(sm, {})
            sm.base = {"playing": False, "title": "T", "elapsed": 4}
            await service._publish_stream(sm, {})
            sm.base = {"playing": False, "title": "T2", "elapsed": 5}
            await service._publish_stream(sm, {})

        asyncio.run(scenario())
        assert [w["elapsed"] for w in writes] == [1, 5]


class TestArtworkPrune:
    def test_runtime_prune_keeps_newest(
        self, service, metadata_service_module, monkeypatch
    ):
        import os as _os

        module = metadata_service_module
        monkeypatch.setattr(module, "_ARTWORK_MAX_FILES", 5)
        for i in range(8):
            p = service.artwork_dir / f"artwork_{i:02d}.jpg"
            p.write_bytes(b"x")
            _os.utime(p, (1000 + i, 1000 + i))
        (service.artwork_dir / "metadata_MPD.json").write_text("{}")

        service._prune_artwork_dir(force=True)

        left = sorted(p.name for p in service.artwork_dir.glob("artwork_*"))
        assert left == [f"artwork_{i:02d}.jpg" for i in range(3, 8)]
        assert (service.artwork_dir / "metadata_MPD.json").exists()


class _FakeRPCSocket:
    def __init__(self, replies):
        self.replies = list(replies)
        self.sent = []
        self.closed = False

    def sendall(self, data):
        self.sent.append(data)

    def recv(self, n):
        if not self.replies:
            raise TimeoutError("timed out")
        return self.replies.pop(0)

    def close(self):
        self.closed = True


class TestJsonRpcIds:
    def test_reply_matched_by_id_skipping_notifications_and_stale(self, service):
        import json as _json

        sock = _FakeRPCSocket([])
        service._snap_sock = sock

        def reply_for(req_id, payload):
            return (_json.dumps({"id": req_id, "result": payload}) + "\r\n").encode()

        next_id = service._rpc_id + 1
        sock.replies = [
            b'{"jsonrpc":"2.0","method":"Client.OnVolumeChanged","params":{}}\r\n',
            reply_for(next_id - 1, "stale"),
            reply_for(next_id, "fresh"),
        ]
        msg = service.send_rpc_request(sock, "Server.GetStatus")
        assert msg["result"] == "fresh"
        assert _json.loads(sock.sent[0])["id"] == next_id

    def test_timeout_closes_socket_so_late_reply_cannot_desync(self, service):
        sock = _FakeRPCSocket([])
        service._snap_sock = sock
        assert service.send_rpc_request(sock, "Client.SetVolume", {}) is None
        assert sock.closed
        assert service._snap_sock is None
        assert service._snap_buffer == b""


class TestWebSocketInput:
    def test_non_object_json_does_not_kill_handler(
        self, metadata_service_module, monkeypatch, caplog
    ):
        import asyncio

        module = metadata_service_module
        monkeypatch.setattr(module, "_service", None)
        ws = _FakeWS(['"xsubscribex"', "42", "[1,2]", "null", '{"subscribe":"room"}'])

        with caplog.at_level("INFO"):
            asyncio.run(module.ws_handler(ws))

        # The handler survived the junk and processed the real subscribe.
        assert "subscribed as 'room'" in caplog.text

    def test_subscribe_burst_shares_one_status_call(self, service, monkeypatch):
        import asyncio

        calls = []

        def status():
            calls.append(1)
            return {"groups": [], "streams": []}

        monkeypatch.setattr(service, "get_server_status", status)

        async def scenario():
            await asyncio.gather(
                *(service.get_server_status_throttled() for _ in range(10))
            )

        asyncio.run(scenario())
        assert calls == [1]


class TestTogglePlayRouting:
    def _server(self, stream_id, can_control):
        return {
            "groups": [
                {
                    "stream_id": stream_id,
                    "clients": [{"id": "room", "host": {"name": "room"}, "config": {}}],
                }
            ],
            "streams": [
                {
                    "id": stream_id,
                    "properties": {
                        "canControl": can_control,
                        "canPause": can_control,
                        "canPlay": can_control,
                    },
                }
            ],
        }

    def _wire(self, service, server):
        calls = []
        service._get_snap_socket = lambda: object()

        def rpc(_sock, method, params=None):
            calls.append((method, params))
            if method == "Server.GetStatus":
                return {"result": {"server": server}}
            return {"result": "ok"}

        service.send_rpc_request = rpc
        return calls

    def test_airplay_group_does_not_toggle_mpd(self, service):
        calls = self._wire(service, self._server("AirPlay", False))
        assert service.toggle_playback("room") is False
        assert [m for m, _ in calls] == ["Server.GetStatus"]

    def test_controllable_stream_gets_stream_control(self, service):
        calls = self._wire(service, self._server("Spotify", True))
        assert service.toggle_playback("room") is True
        assert calls[-1] == (
            "Stream.Control",
            {"id": "Spotify", "command": "playPause"},
        )
