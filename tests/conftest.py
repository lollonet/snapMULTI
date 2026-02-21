"""Shared fixtures for meta_tidal tests."""

import json
import sys
from pathlib import Path

import pytest

# Allow `import meta_tidal` from tests/
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import meta_tidal  # noqa: E402


@pytest.fixture(autouse=True)
def _reset_module_state():
    """Reset meta_tidal global state between every test."""
    meta_tidal.metadata = {
        "title": "",
        "artist": [],
        "album": "",
        "artUrl": "",
        "duration": 0.0,
    }
    meta_tidal.playback_status = "unknown"
    meta_tidal.debug_mode = False
    yield


@pytest.fixture()
def capture_stdout(monkeypatch):
    """Capture JSON-RPC messages sent to stdout.

    Returns a list; each element is one parsed JSON object that was printed.
    """
    sent: list[dict] = []

    def _fake_print(text, **_kwargs):
        sent.append(json.loads(text))

    monkeypatch.setattr("builtins.print", _fake_print)
    return sent
