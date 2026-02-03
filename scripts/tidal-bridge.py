#!/usr/bin/env python3
"""
tidal-bridge.py — Stream Tidal audio to Snapcast via ffmpeg

Bridges Tidal streaming service to snapMULTI by fetching stream URLs via tidalapi
and piping decoded PCM audio to snapserver's TCP input.

Usage:
    tidal-bridge.py login           # One-time OAuth setup (opens browser)
    tidal-bridge.py play <url>      # Play track/album/playlist by Tidal URL or ID
    tidal-bridge.py stop            # Stop current playback
    tidal-bridge.py status          # Show current playback status
    tidal-bridge.py search <query>  # Search for tracks/albums/artists

Requires: tidalapi, ffmpeg
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Optional

try:
    import tidalapi
    from tidalapi import Quality
except ImportError:
    print("Error: tidalapi not installed. Run: pip install tidalapi", file=sys.stderr)
    sys.exit(1)

# --- Configuration ---
SESSION_FILE = Path(os.environ.get("TIDAL_SESSION_FILE", "/config/tidal-session.json"))
SNAPSERVER_HOST = os.environ.get("SNAPSERVER_HOST", "127.0.0.1")
SNAPSERVER_PORT = int(os.environ.get("SNAPSERVER_PORT", "4953"))
AUDIO_QUALITY = os.environ.get("TIDAL_QUALITY", "high_lossless")  # low_96k, low_320k, high_lossless, hi_res_lossless

# PCM format for snapserver (must match snapserver.conf sampleformat)
SAMPLE_RATE = 48000
SAMPLE_BITS = 16
CHANNELS = 2

# --- Global state ---
current_process: Optional[subprocess.Popen] = None
current_track: Optional[str] = None
playback_lock = threading.Lock()


def get_quality() -> Quality:
    """Map quality string to tidalapi Quality enum."""
    qualities = {
        "low_96k": Quality.low_96k,
        "low_320k": Quality.low_320k,
        "high_lossless": Quality.high_lossless,
        "hi_res_lossless": Quality.hi_res_lossless,
    }
    return qualities.get(AUDIO_QUALITY, Quality.high_lossless)


def create_session() -> tidalapi.Session:
    """Create and configure a Tidal session."""
    session = tidalapi.Session()
    session.audio_quality = get_quality()
    return session


def login(session: tidalapi.Session) -> bool:
    """
    Perform PKCE login flow.
    Opens browser for OAuth, saves session to file.
    """
    SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)

    if SESSION_FILE.exists():
        print(f"Loading existing session from {SESSION_FILE}")
        try:
            session.login_session_file(SESSION_FILE, do_pkce=True)
            if session.check_login():
                print(f"Logged in as: {session.user.first_name} {session.user.last_name}")
                return True
        except Exception as e:
            print(f"Session expired or invalid: {e}")

    print("Starting PKCE login flow...")
    print("A browser window will open. Please log in to Tidal.")

    try:
        session.login_session_file(SESSION_FILE, do_pkce=True)
        if session.check_login():
            print(f"Login successful! Session saved to {SESSION_FILE}")
            print(f"Logged in as: {session.user.first_name} {session.user.last_name}")
            return True
    except Exception as e:
        print(f"Login failed: {e}", file=sys.stderr)
        return False

    return False


def parse_tidal_url(url_or_id: str) -> tuple[str, str]:
    """
    Parse Tidal URL or ID into (type, id).

    Supports:
        - https://tidal.com/browse/track/12345
        - https://listen.tidal.com/album/12345
        - track:12345
        - 12345 (assumes track)

    Returns: (type, id) where type is 'track', 'album', or 'playlist'
    """
    # URL patterns
    url_pattern = r"(?:https?://)?(?:listen\.)?tidal\.com/(?:browse/)?(\w+)/([a-f0-9-]+)"
    match = re.match(url_pattern, url_or_id, re.IGNORECASE)
    if match:
        return match.group(1).lower(), match.group(2)

    # type:id pattern
    if ":" in url_or_id:
        parts = url_or_id.split(":", 1)
        return parts[0].lower(), parts[1]

    # Bare ID (assume track)
    if url_or_id.isdigit():
        return "track", url_or_id

    # UUID (likely playlist)
    if re.match(r"^[a-f0-9-]{36}$", url_or_id, re.IGNORECASE):
        return "playlist", url_or_id

    raise ValueError(f"Cannot parse Tidal URL or ID: {url_or_id}")


def get_stream_url(track: tidalapi.Track) -> tuple[str, bool]:
    """
    Get stream URL for a track.

    Returns: (url, is_hls) where is_hls indicates HLS/DASH stream vs direct URL
    """
    stream = track.get_stream()
    manifest = stream.get_stream_manifest()

    if stream.is_mpd:
        # HiRes uses MPEG-DASH, convert to HLS for ffmpeg
        hls = manifest.get_hls()
        return hls, True
    elif stream.is_bts:
        # Direct URL (FLAC or M4A)
        urls = manifest.get_urls()
        return urls[0] if urls else None, False
    else:
        raise ValueError(f"Unknown stream type for track {track.id}")


def play_track(track: tidalapi.Track) -> subprocess.Popen:
    """
    Play a single track by piping through ffmpeg to snapserver.

    Returns the ffmpeg subprocess.
    """
    global current_track

    url, is_hls = get_stream_url(track)
    if not url:
        raise ValueError(f"Could not get stream URL for track {track.id}")

    current_track = f"{track.artist.name} - {track.name}"
    print(f"Playing: {current_track}")
    print(f"  Album: {track.album.name}")
    print(f"  Quality: {AUDIO_QUALITY}")

    # Build ffmpeg command
    # Input: HLS playlist or direct URL
    # Output: raw PCM s16le at 48kHz stereo to TCP
    ffmpeg_cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "warning",
        "-y",  # Overwrite output
    ]

    if is_hls:
        # HLS input needs protocol whitelist
        ffmpeg_cmd.extend([
            "-protocol_whitelist", "file,http,https,tcp,tls,crypto",
            "-i", "pipe:0",  # Read HLS manifest from stdin
        ])
    else:
        ffmpeg_cmd.extend(["-i", url])

    ffmpeg_cmd.extend([
        "-vn",  # No video
        "-acodec", "pcm_s16le",
        "-ar", str(SAMPLE_RATE),
        "-ac", str(CHANNELS),
        "-f", "s16le",
        f"tcp://{SNAPSERVER_HOST}:{SNAPSERVER_PORT}",
    ])

    if is_hls:
        # For HLS, we pipe the manifest to ffmpeg stdin
        proc = subprocess.Popen(
            ffmpeg_cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        proc.stdin.write(url.encode())
        proc.stdin.close()
    else:
        proc = subprocess.Popen(
            ffmpeg_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    return proc


def play_tracks(tracks: list[tidalapi.Track]) -> None:
    """Play a list of tracks sequentially."""
    global current_process

    for i, track in enumerate(tracks):
        with playback_lock:
            if current_process is None:
                # Playback was stopped
                break

            print(f"\n[{i + 1}/{len(tracks)}]", end=" ")
            try:
                proc = play_track(track)
                current_process = proc
            except Exception as e:
                print(f"Error playing track {track.id}: {e}", file=sys.stderr)
                continue

        # Wait for track to finish
        proc.wait()

        # Check for errors
        if proc.returncode != 0:
            stderr = proc.stderr.read().decode() if proc.stderr else ""
            if "Connection refused" in stderr:
                print(f"Error: Cannot connect to snapserver at {SNAPSERVER_HOST}:{SNAPSERVER_PORT}")
                print("Make sure snapserver is running and TCP source is configured.")
                break
            elif stderr:
                print(f"ffmpeg warning: {stderr[:200]}", file=sys.stderr)


def cmd_play(session: tidalapi.Session, url_or_id: str) -> int:
    """Handle play command."""
    global current_process

    if not session.check_login():
        print("Not logged in. Run: tidal-bridge.py login", file=sys.stderr)
        return 1

    try:
        content_type, content_id = parse_tidal_url(url_or_id)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    print(f"Loading {content_type}: {content_id}")

    try:
        if content_type == "track":
            track = session.track(content_id)
            tracks = [track]
        elif content_type == "album":
            album = session.album(content_id)
            print(f"Album: {album.name} by {album.artist.name}")
            tracks = album.tracks()
        elif content_type == "playlist":
            playlist = session.playlist(content_id)
            print(f"Playlist: {playlist.name}")
            tracks = playlist.tracks()
        else:
            print(f"Unknown content type: {content_type}", file=sys.stderr)
            return 1
    except Exception as e:
        print(f"Error loading content: {e}", file=sys.stderr)
        return 1

    if not tracks:
        print("No tracks found.", file=sys.stderr)
        return 1

    print(f"Loaded {len(tracks)} track(s)")

    # Stop any existing playback
    cmd_stop()

    # Start playback in background thread
    with playback_lock:
        current_process = True  # Placeholder to indicate playback starting

    play_thread = threading.Thread(target=play_tracks, args=(list(tracks),), daemon=True)
    play_thread.start()

    # Wait for playback to complete (or Ctrl+C)
    try:
        play_thread.join()
    except KeyboardInterrupt:
        print("\nStopping playback...")
        cmd_stop()

    return 0


def cmd_stop() -> int:
    """Stop current playback."""
    global current_process, current_track

    with playback_lock:
        if current_process and isinstance(current_process, subprocess.Popen):
            current_process.terminate()
            try:
                current_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                current_process.kill()
        current_process = None
        current_track = None

    print("Playback stopped.")
    return 0


def cmd_status() -> int:
    """Show current playback status."""
    if current_track:
        print(f"Playing: {current_track}")
    else:
        print("Not playing.")
    return 0


def cmd_search(session: tidalapi.Session, query: str) -> int:
    """Search Tidal for tracks, albums, artists."""
    if not session.check_login():
        print("Not logged in. Run: tidal-bridge.py login", file=sys.stderr)
        return 1

    print(f"Searching for: {query}\n")

    results = session.search(query, limit=5)

    if results.tracks:
        print("=== Tracks ===")
        for track in results.tracks[:5]:
            print(f"  track:{track.id}  {track.artist.name} - {track.name}")
        print()

    if results.albums:
        print("=== Albums ===")
        for album in results.albums[:5]:
            print(f"  album:{album.id}  {album.artist.name} - {album.name}")
        print()

    if results.artists:
        print("=== Artists ===")
        for artist in results.artists[:5]:
            print(f"  {artist.name} (ID: {artist.id})")
        print()

    if results.playlists:
        print("=== Playlists ===")
        for playlist in results.playlists[:5]:
            print(f"  playlist:{playlist.id}  {playlist.name}")
        print()

    return 0


def cmd_login(session: tidalapi.Session) -> int:
    """Handle login command."""
    return 0 if login(session) else 1


def signal_handler(sig, frame):
    """Handle Ctrl+C gracefully."""
    print("\nInterrupted.")
    cmd_stop()
    sys.exit(0)


def main():
    parser = argparse.ArgumentParser(
        description="Stream Tidal audio to Snapcast",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
    %(prog)s login                              # Authenticate with Tidal
    %(prog)s play track:12345                   # Play a track by ID
    %(prog)s play https://tidal.com/browse/album/77646169  # Play album by URL
    %(prog)s search "pink floyd"                # Search for content
    %(prog)s stop                               # Stop playback

Environment variables:
    TIDAL_SESSION_FILE  Session file path (default: /config/tidal-session.json)
    TIDAL_QUALITY       Audio quality: low_96k, low_320k, high_lossless, hi_res_lossless
    SNAPSERVER_HOST     Snapserver hostname (default: 127.0.0.1)
    SNAPSERVER_PORT     Snapserver TCP port (default: 4953)
        """,
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # login
    subparsers.add_parser("login", help="Authenticate with Tidal (one-time setup)")

    # play
    play_parser = subparsers.add_parser("play", help="Play track/album/playlist")
    play_parser.add_argument("url", help="Tidal URL or ID (track:123, album:456, playlist:uuid)")

    # stop
    subparsers.add_parser("stop", help="Stop current playback")

    # status
    subparsers.add_parser("status", help="Show playback status")

    # search
    search_parser = subparsers.add_parser("search", help="Search Tidal")
    search_parser.add_argument("query", help="Search query")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 1

    # Setup signal handler
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Create session
    session = create_session()

    # For commands that need auth, try to load session
    if args.command in ("play", "search", "status"):
        if SESSION_FILE.exists():
            try:
                session.login_session_file(SESSION_FILE, do_pkce=True)
            except Exception:
                pass  # Will be caught in command handler

    # Dispatch command
    if args.command == "login":
        return cmd_login(session)
    elif args.command == "play":
        return cmd_play(session, args.url)
    elif args.command == "stop":
        return cmd_stop()
    elif args.command == "status":
        return cmd_status()
    elif args.command == "search":
        return cmd_search(session, args.query)

    return 1


if __name__ == "__main__":
    sys.exit(main())
