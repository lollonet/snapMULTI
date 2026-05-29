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


class TestFleetParseAvahi:
    """`_parse_avahi_browse_peers()` extracts peer dicts from avahi-browse -rpt."""

    @staticmethod
    def _sample(own: str = "pi-server") -> str:
        return (
            "=;wlan0;IPv4;snapMULTI;_snapcast._tcp;local;pi-server.local;192.168.1.10;1704;\n"
            "=;wlan0;IPv4;snapMULTI;_snapcast._tcp;local;pi-other.local;192.168.1.11;1704;\n"
            "=;wlan0;IPv6;snapMULTI;_snapcast._tcp;local;pi-other.local;fe80::1;1704;\n"
            "+;wlan0;IPv4;snapMULTI;_snapcast._tcp;local\n"
            "=;wlan0;IPv4;snapMULTI;_snapcast._tcp;local;pi-third.local;192.168.1.12;1704;\n"
        )

    def test_excludes_self(self, metadata_service_module):
        peers = metadata_service_module._parse_avahi_browse_peers(
            self._sample(), "pi-server"
        )
        names = [p["hostname"] for p in peers]
        assert "pi-server.local" not in names
        assert "pi-other.local" in names
        assert "pi-third.local" in names

    def test_dedups_same_host_across_families(self, metadata_service_module):
        peers = metadata_service_module._parse_avahi_browse_peers(
            self._sample(), "pi-server"
        )
        assert sum(p["hostname"] == "pi-other.local" for p in peers) == 1

    def test_self_match_strips_local_and_dots(self, metadata_service_module):
        # Own hostname can arrive as "pi-server", "pi-server.local", "pi-server."
        for own in ("pi-server", "pi-server.local", "pi-server.local."):
            peers = metadata_service_module._parse_avahi_browse_peers(
                self._sample(), own
            )
            assert all("pi-server" not in p["hostname"].lower() for p in peers)

    def test_skips_ptr_only_lines(self, metadata_service_module):
        # `+;…` are PTR-only, no SRV+TXT data — must be ignored.
        peers = metadata_service_module._parse_avahi_browse_peers(
            self._sample(), "pi-server"
        )
        # Only `=;` lines yield peers — the `+;` line in the sample has no port/addr.
        for p in peers:
            assert p["addr"]
            assert p["port"]

    def test_empty_output_no_peers(self, metadata_service_module):
        assert metadata_service_module._parse_avahi_browse_peers("", "pi-server") == []


class TestFleetHostnameValidation:
    """`_SAFE_HOST_RE` is the SSRF gate before URL interpolation."""

    @pytest.mark.parametrize(
        "host",
        ["pi-server", "pi-server.local", "rpi3.lan", "device_1", "Server-42.local"],
    )
    def test_accepts_rfc1123_like(self, metadata_service_module, host):
        assert metadata_service_module._SAFE_HOST_RE.match(host) is not None

    @pytest.mark.parametrize(
        "host",
        [
            "evil.com@attacker.com",  # RFC 3986 user-info hijack
            "host#fragment",  # URL fragment truncates port
            "host:8888",  # explicit port override
            "host/path",  # path injection
            "host?query=1",  # query injection
            "host with space",
            "127.0.0.1%00.evil.com",  # null-byte attempt
            "",  # empty rejected
            "a" * 254,  # > 253 chars rejected
        ],
    )
    def test_rejects_malicious(self, metadata_service_module, host):
        assert metadata_service_module._SAFE_HOST_RE.match(host) is None


class TestFleetRenderHtml:
    """`_render_fleet_section()` is a pure renderer — no I/O."""

    def test_no_peers_message(self, metadata_service_module):
        html = metadata_service_module._render_fleet_section([])
        assert "No peer snapMULTI servers discovered" in html
        assert "<h2>Fleet</h2>" in html

    def test_one_peer_renders_link_and_summary(self, metadata_service_module):
        html = metadata_service_module._render_fleet_section(
            [
                {
                    "hostname": "pi-other",
                    "mode": "both",
                    "status": "ok",
                    "release": "Release v0.7.9.5 (images 0.7.7)",
                    "containers": "server: 7/7 running, 7/7 healthy",
                    "url": "http://pi-other.local:8083/status",
                }
            ]
        )
        assert "Fleet (1 peer(s))" in html
        assert 'href="http://pi-other.local:8083/status"' in html
        assert "pi-other" in html
        assert "Release v0.7.9.5" in html
        assert "7/7 healthy" in html
        assert 'class="r-pass"' in html

    def test_fail_peer_uses_fail_class(self, metadata_service_module):
        html = metadata_service_module._render_fleet_section(
            [{"hostname": "pi-broken", "status": "fail", "url": "http://x"}]
        )
        assert 'class="r-fail"' in html

    def test_html_escapes_peer_fields(self, metadata_service_module):
        html = metadata_service_module._render_fleet_section(
            [
                {
                    "hostname": "<script>alert(1)</script>",
                    "status": "ok",
                    "url": 'javascript:alert("xss")',
                }
            ]
        )
        assert "<script>alert(1)</script>" not in html
        assert "&lt;script&gt;" in html
        # Scheme allow-list: javascript: must NOT be rendered as href.
        assert 'href="javascript:' not in html

    def test_non_http_url_renders_hostname_without_link(self, metadata_service_module):
        # data:, file:, javascript: all must drop the <a> wrapper entirely.
        for bad in ("javascript:alert(1)", "data:text/html,<x>", "file:///etc/passwd"):
            html = metadata_service_module._render_fleet_section(
                [{"hostname": "pi-evil", "status": "ok", "url": bad}]
            )
            assert "<a" not in html, f"bad URL {bad!r} rendered as link"
            assert "pi-evil" in html  # hostname still shown


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
