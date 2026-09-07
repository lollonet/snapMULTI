"""Regression tests for deterministic metadata-service client identity routing."""

from __future__ import annotations

import importlib.util
import sys
import threading
import types
from pathlib import Path

import pytest


MODULE_PATH = (
    Path(__file__).resolve().parent.parent
    / "docker"
    / "metadata-service"
    / "metadata-service.py"
)


@pytest.fixture()
def metadata_service_module(monkeypatch):
    """Import the service with web dependencies stubbed and no runtime startup."""
    websockets_module = types.ModuleType("websockets")
    websockets_module.exceptions = types.SimpleNamespace(ConnectionClosed=Exception)
    websockets_module.serve = lambda *args, **kwargs: None
    monkeypatch.setitem(sys.modules, "websockets", websockets_module)

    aiohttp_module = types.ModuleType("aiohttp")
    aiohttp_module.web = types.SimpleNamespace(
        Request=type("Request", (), {}),
        StreamResponse=type("StreamResponse", (), {}),
        Response=type("Response", (), {}),
        FileResponse=type("FileResponse", (), {}),
        json_response=lambda *args, **kwargs: None,
        Application=type("Application", (), {}),
        AppRunner=type("AppRunner", (), {}),
        TCPSite=type("TCPSite", (), {}),
    )
    monkeypatch.setitem(sys.modules, "aiohttp", aiohttp_module)
    monkeypatch.setitem(sys.modules, "aiohttp.web", aiohttp_module.web)

    spec = importlib.util.spec_from_file_location(
        "metadata_client_identity", MODULE_PATH
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules.pop("metadata_client_identity", None)
    spec.loader.exec_module(module)
    return module


@pytest.fixture()
def service(metadata_service_module):
    """Avoid MetadataService.__init__, which performs host discovery."""
    instance = object.__new__(metadata_service_module.MetadataService)
    instance._client_stream_map = {}
    instance._snap_lock = threading.Lock()
    instance._snap_sock = None
    instance._last_snap_response = 0.0
    instance._snap_stale_threshold = 30.0
    return instance


def _client(client_id: str, hostname: str, volume: int) -> dict:
    return {
        "id": client_id,
        "host": {"name": hostname},
        "config": {"name": hostname, "volume": {"percent": volume, "muted": False}},
    }


def _server(clients: list[tuple[str, dict]]) -> dict:
    return {
        "groups": [
            {"stream_id": stream_id, "clients": [client]}
            for stream_id, client in clients
        ]
    }


@pytest.mark.parametrize("reverse", [False, True])
def test_raw_id_wins_over_prefix_alias_in_every_client_order(service, reverse):
    alias_client = _client("client-a", "room", 15)
    raw_client = _client("snapclient-room", "other-room", 85)
    clients = [("stream-a", alias_client), ("stream-b", raw_client)]
    server = _server(list(reversed(clients)) if reverse else clients)

    service._client_stream_map = service._build_client_stream_map(server)
    assert service._resolve_client_stream("snapclient-room") == "stream-b"
    assert service._find_client_volume(server, "snapclient-room") == {
        "percent": 85,
        "muted": False,
    }

    calls: list[tuple[str, dict | None]] = []
    service._get_snap_socket = lambda: object()

    def rpc(_sock, method, params=None):
        calls.append((method, params))
        if method == "Server.GetStatus":
            return {"result": {"server": server}}
        return {"result": {}}

    service.send_rpc_request = rpc
    assert service.set_client_volume("snapclient-room", 60) is True
    assert calls[-1] == (
        "Client.SetVolume",
        {"id": "snapclient-room", "volume": {"percent": 60, "muted": False}},
    )


def test_exact_raw_id_wins_over_same_text_hostname_alias(service):
    server = _server(
        [
            ("stream-a", _client("client-a", "room", 15)),
            ("stream-b", _client("room", "other-room", 85)),
        ]
    )

    service._client_stream_map = service._build_client_stream_map(server)
    assert service._resolve_client_stream("room") == "stream-b"
    assert service._find_client_volume(server, "room")["percent"] == 85


def test_prefixed_direct_and_stripped_alias_collision_cannot_write(service):
    server = _server(
        [
            ("stream-a", _client("client-a", "snapclient-room", 15)),
            ("stream-b", _client("client-b", "room", 85)),
        ]
    )
    service._client_stream_map = service._build_client_stream_map(server)

    assert service._resolve_client_stream("snapclient-room") is None
    assert service._find_client_volume(server, "snapclient-room")["percent"] == 100

    calls: list[str] = []
    service._get_snap_socket = lambda: object()
    service.send_rpc_request = lambda _sock, method, _params=None: (
        calls.append(method) or {"result": {"server": server}}
        if method == "Server.GetStatus"
        else pytest.fail(f"unexpected RPC: {method}")
    )

    assert service.set_client_volume("snapclient-room", 60) is False
    assert calls == ["Server.GetStatus"]


def test_same_client_overlapping_direct_and_generated_aliases_resolve(service):
    server = _server([("stream-a", _client("room", "snapclient-room", 15))])
    service._client_stream_map = service._build_client_stream_map(server)

    assert service._resolve_client_stream("snapclient-room") == "stream-a"
    assert service._find_client_volume(server, "snapclient-room")["percent"] == 15


def test_duplicate_raw_id_reserves_key_against_alias_fallback(service):
    server = _server(
        [
            ("stream-a", _client("duplicate", "room-a", 15)),
            ("stream-b", _client("duplicate", "room-b", 85)),
            ("stream-c", _client("client-c", "duplicate", 40)),
        ]
    )
    service._client_stream_map = service._build_client_stream_map(server)

    assert service._resolve_client_stream("duplicate") is None
    assert service._find_client_volume(server, "duplicate")["percent"] == 100

    calls: list[str] = []
    service._get_snap_socket = lambda: object()
    service.send_rpc_request = lambda _sock, method, _params=None: (
        calls.append(method) or {"result": {"server": server}}
        if method == "Server.GetStatus"
        else pytest.fail(f"unexpected RPC: {method}")
    )

    assert service.set_client_volume("duplicate", 60) is False
    assert calls == ["Server.GetStatus"]


@pytest.mark.parametrize("client_id", ["room", "missing", ""])
def test_ambiguous_or_missing_alias_cannot_read_or_write_a_client(service, client_id):
    server = _server(
        [
            ("stream-a", _client("client-a", "room", 15)),
            ("stream-b", _client("client-b", "room", 85)),
        ]
    )
    service._client_stream_map = service._build_client_stream_map(server)

    assert service._resolve_client_stream(client_id) is None
    assert service._find_client_volume(server, client_id) == {
        "percent": 100,
        "muted": False,
    }

    calls: list[str] = []
    service._get_snap_socket = lambda: object()

    def rpc(_sock, method, params=None):
        calls.append(method)
        if method == "Server.GetStatus":
            return {"result": {"server": server}}
        pytest.fail(f"unexpected RPC: {method} {params}")

    service.send_rpc_request = rpc
    assert service.set_client_volume(client_id, 60) is False
    assert calls == ["Server.GetStatus"]
