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
