"""Static checks for patches/meta_mpd.py (baked into the snapserver image).

The plugin imports mpd / dbus / gi, which are not available in CI, so these
tests inspect the source instead of importing it.
"""

import ast
from pathlib import Path

PATCH = Path(__file__).resolve().parent.parent / "patches" / "meta_mpd.py"
SOURCE = PATCH.read_text(encoding="utf-8")
TREE = ast.parse(SOURCE)


def _function(name: str) -> ast.FunctionDef:
    for node in ast.walk(TREE):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError(f"{name} not found")


def test_musicbrainz_lookup_is_opt_in():
    """The synchronous lookup on the GLib loop must be off unless enabled."""
    assert 'os.environ.get(\n    "META_MPD_MUSICBRAINZ", "")' in SOURCE
    body = ast.get_source_segment(SOURCE, _function("get_albumart"))
    assert "if cached or not MUSICBRAINZ_LOOKUP:" in body


def test_all_musicbrainz_errors_are_caught():
    """NetworkError (not just ResponseError) must not escape into GLib."""
    body = ast.get_source_segment(SOURCE, _function("get_albumart"))
    assert "musicbrainzngs.WebServiceError" in body
    assert "except musicbrainzngs.musicbrainz.ResponseError" not in body


def test_lookup_uses_bounded_socket_timeout_and_restores_it():
    body = ast.get_source_segment(SOURCE, _function("get_albumart"))
    assert "socket.setdefaulttimeout(MUSICBRAINZ_TIMEOUT)" in body
    assert "socket.setdefaulttimeout(previous_timeout)" in body


def test_send_properties_guards_album_art_lookup():
    body = ast.get_source_segment(SOURCE, _function("_send_properties"))
    assert "except Exception as e:" in body
    assert "self.get_albumart(snapstatus['metadata'], False)" in body
