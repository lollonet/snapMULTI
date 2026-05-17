# Third-Party Notices

snapMULTI is licensed under [GPL-3.0-only](LICENSE).

snapMULTI ships container images that build on, link to, or run the
following third-party software. Each component is the property of its
respective copyright holder(s), distributed under the licenses listed
below. Where snapMULTI builds Docker images on top of these projects
(rather than just running them), the resulting derived images inherit
the upstream license — see the individual `Dockerfile.*` for the build
recipe.

## Audio core

### Snapcast — multiroom synchronisation server / client

- Project: <https://github.com/badaix/snapcast>
- Author: Johannes Pohl
- License: GPL-3.0-or-later
- Version pinned: `v0.35.0` (see `Dockerfile.snapserver` `ARG SNAPCAST_TAG`)
- snapMULTI usage: built into `lollonet/snapmulti-server` (server side) and
  `snapclient` from Debian apt (client side)

### MPD — Music Player Daemon

- Project: <https://www.musicpd.org/> · <https://github.com/MusicPlayerDaemon/MPD>
- License: GPL-2.0-or-later
- Version: distribution-pinned to Alpine 3.23 (`apk add mpd` in `Dockerfile.mpd`)
- snapMULTI usage: built into `lollonet/snapmulti-mpd`

### myMPD — modern web UI for MPD

- Project: <https://github.com/jcorporation/myMPD>
- Author: jcorporation
- License: GPL-2.0-or-later
- Version: upstream `ghcr.io/jcorporation/mympd/mympd:latest` (image used as-is,
  not rebuilt by snapMULTI)

## Streaming sources

### shairport-sync — AirPlay 1 receiver

- Project: <https://github.com/mikebrady/shairport-sync>
- Author: Mike Brady
- License: MIT
- Version: distribution-pinned to Alpine 3.23 (`apk add shairport-sync` in
  `Dockerfile.shairport-sync`)
- snapMULTI usage: built into `lollonet/snapmulti-airplay`

### go-librespot — Spotify Connect (Spotify Premium required)

- Project: <https://github.com/devgianlu/go-librespot>
- Author: devgianlu
- License: LGPL-3.0
- Version pinned: `v0.7.1` (`ghcr.io/devgianlu/go-librespot:v0.7.1` in
  `docker-compose.yml`, image used as-is, not rebuilt)
- Note: Spotify Connect protocol is reverse-engineered; snapMULTI does not
  bundle any Spotify proprietary code

### tidal-connect — Tidal Connect receiver (ARM only, enabled by default on ARM installs)

- Project: <https://github.com/edgecrush3r/tidal-connect-docker>
- Upstream binary: `ifi-companion` (proprietary, distributed by upstream image)
- Author of Docker wrapper: edgecrush3r
- License of the Docker wrapper: GPL-3.0
- Base image: `edgecrush3r/tidal-connect:latest` (ARM only)
- snapMULTI build: `Dockerfile.tidal` extends the upstream image with
  `libasound2-plugins` and `tmux`; the result is published as
  `lollonet/snapmulti-tidal` (linux/arm64 only)
- **Distribution disclosure**: `lollonet/snapmulti-tidal` is a derived
  image. It contains the proprietary `ifi-companion` binary inherited
  from the upstream layer — snapMULTI does not extract, modify, or
  re-package the binary, but the published image layer set does include
  it. Users pulling `lollonet/snapmulti-tidal` are receiving the same
  binary that ships in `edgecrush3r/tidal-connect:latest`, with snapMULTI's
  runtime additions on top
- **Default profile**: Tidal is **enabled by default on ARM installs**.
  `scripts/deploy.sh` writes `COMPOSE_PROFILES=tidal` to
  `/opt/snapmulti/.env` on Pi 3 B+ / 4 / 5, so the `tidal` profile is
  active out of the box. The service is still gated by the Compose
  profile, but the gate is open by default. To opt out, remove `tidal`
  from `COMPOSE_PROFILES` in `/opt/snapmulti/.env` and restart
  `snapmulti-server.service`
- **For a 100 % free-software stack**: opt out of the `tidal` profile as
  described above. The other six containers (snapserver, mpd,
  shairport-sync, go-librespot, metadata, mympd) ship from sources
  without proprietary binaries. A future release will track issue #432
  ("make Tidal truly opt-in") to flip this default

## Display & visualisation

### audio-visualizer — FFT spectrum analyzer

- Built fresh in snapMULTI (`client/common/docker/audio-visualizer/`)
- License: GPL-3.0-only (inherits from snapMULTI)
- Dependencies: `numpy`, `aiohttp`, `websockets` (all permissive licenses,
  installed via `pip` in the Dockerfile)

### fb-display — framebuffer renderer for cover art + spectrum

- Built fresh in snapMULTI (`client/common/docker/fb-display/`)
- License: GPL-3.0-only (inherits from snapMULTI)
- Dependencies: `Pillow`, `aiohttp`, `websockets` (permissive)

## Build infrastructure

- **Alpine Linux** 3.23 (base image for snapserver, mpd, shairport-sync,
  metadata, tidal) — license: mixed (mostly MIT/BSD/permissive); see
  <https://www.alpinelinux.org/> for details
- **Debian** Bookworm (host OS for Pi installs, also base for tidal upstream
  image) — see <https://www.debian.org/legal/licenses/>
- **Python 3.14** (metadata-service base image) — PSF License, see
  <https://docs.python.org/3/license.html>
- **Node.js 24 / Alpine** (snapweb build stage, image discarded after build) —
  MIT

## How to verify

Each of the upstream projects above maintains its own license file; users
who want to audit the full chain should clone the upstream repository at
the pinned version and consult its `LICENSE` / `COPYING`. snapMULTI's
`Dockerfile.*` files declare exact versions and apt/apk package origins
where applicable.

## How to report a license issue

If you believe snapMULTI is violating an upstream license, please open an
issue at <https://github.com/lollonet/snapMULTI/issues> with the
specific component, the alleged violation, and a citation of the
upstream license clause. The project will respond within seven days; if
the violation is confirmed, the offending change will be reverted in the
next patch release.

## Updating this file

When bumping any of the pinned versions above, please update the
corresponding entry here AND in `CHANGELOG.md`.
