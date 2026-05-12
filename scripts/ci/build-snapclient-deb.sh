#!/usr/bin/env bash
# Build a snapclient .deb from upstream badaix/snapcast sources.
#
# Runs inside a debian:<codename>-slim container under QEMU
# (cross-arch) or natively (matching host arch). Produces a
# self-contained .deb that we host on GitHub releases, decoupling
# snapMULTI from badaix's bookworm-only .deb release schedule.
#
# Why a custom build instead of upstream:
#   - badaix ships .deb only for `bookworm` (declares libflac12).
#     Pi OS Trixie has libflac14, dpkg refuses to install.
#   - badaix's .deb name pattern is `*_bookworm.deb`; there is no
#     official `*_trixie.deb` asset on https://github.com/badaix/snapcast/releases.
#   - This script links against the system's Boost (1.83 on Trixie,
#     1.74 on Bookworm) instead of badaix's bundled Boost 1.90.
#     snapclient v0.35 builds cleanly against both per CMakeLists.
#
# Output: dist/snapclient_<version>-snapmulti1_<arch>_<codename>.deb
# Run via: scripts/ci/build-snapclient-deb.sh <codename> <arch> [snapcast_tag]
set -euo pipefail

CODENAME="${1:?codename required (trixie|bookworm)}"
ARCH="${2:?arch required (arm64|armhf|amd64)}"
SNAPCAST_TAG="${3:-v0.35.0}"
SNAPCAST_VERSION="${SNAPCAST_TAG#v}"
PKG_VERSION="${SNAPCAST_VERSION}-snapmulti1"

echo "==> Building snapclient ${SNAPCAST_TAG} for ${CODENAME}/${ARCH}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential cmake git ca-certificates curl \
    libasound2-dev libsoxr-dev libvorbis-dev libflac-dev \
    libopus-dev libavahi-client-dev libexpat1-dev libssl-dev \
    libboost-system-dev libboost-program-options-dev \
    alsa-utils debhelper file fakeroot

mkdir -p /tmp/snapcast-build
cd /tmp/snapcast-build
git clone --depth 1 --branch "${SNAPCAST_TAG}" https://github.com/badaix/snapcast.git src
cd src

# Configure: client only, release, no tests.
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SERVER=OFF \
    -DBUILD_CLIENT=ON \
    -DBUILD_TESTS=OFF
cmake --build build --parallel "$(nproc)"

# ── Package as .deb ──────────────────────────────────────────────
# Mirror the upstream layout: snapclient binary under /usr/bin,
# default config under /etc/default/snapclient, systemd unit
# under /lib/systemd/system, postinst creates the snapclient user.
cd /tmp/snapcast-build
PKG_ROOT=pkg
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/usr/bin" "$PKG_ROOT/DEBIAN" \
         "$PKG_ROOT/lib/systemd/system" "$PKG_ROOT/etc/default" \
         "$PKG_ROOT/usr/share/doc/snapclient"

install -m 755 src/bin/snapclient "$PKG_ROOT/usr/bin/snapclient"

cat > "$PKG_ROOT/DEBIAN/control" <<EOF
Package: snapclient
Source: snapcast
Version: ${PKG_VERSION}
Architecture: ${ARCH}
Maintainer: snapMULTI <noreply@github.com>
Installed-Size: $(find "$PKG_ROOT" -path "$PKG_ROOT/DEBIAN" -prune -o -type f -exec du -k {} + 2>/dev/null | awk '{s+=$1}END{print s+0}')
Depends: libc6, libstdc++6, libasound2 | libasound2t64, libavahi-client3, libavahi-common3, libflac12 | libflac14, libogg0, libopus0, libsoxr0, libssl3, libvorbis0a, libboost-system1.74.0 | libboost-system1.83.0, adduser, alsa-utils
Section: sound
Priority: optional
Homepage: https://github.com/badaix/snapcast
Description: Snapcast client v${SNAPCAST_VERSION} (snapMULTI build)
 Snapcast is a multiroom client-server audio player. This package
 contains the snapclient binary built from upstream
 badaix/snapcast at ${SNAPCAST_TAG}, packaged for ${CODENAME}
 by the snapMULTI project to bridge the gap until badaix ships
 trixie .deb assets.
EOF

cat > "$PKG_ROOT/DEBIAN/conffiles" <<EOF
/etc/default/snapclient
EOF

cat > "$PKG_ROOT/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
USERNAME=snapclient
HOMEDIR=/var/lib/snapclient
if [ "$1" = configure ]; then
    if ! getent passwd $USERNAME >/dev/null; then
        adduser --system --quiet --group --home $HOMEDIR --no-create-home --force-badname $USERNAME
        adduser $USERNAME audio
    fi
    if [ ! -d $HOMEDIR ]; then
        mkdir -m 0750 $HOMEDIR
        chown $USERNAME:$USERNAME $HOMEDIR
    fi
fi

if [ "$1" = "configure" ] || [ "$1" = "abort-upgrade" ]; then
    deb-systemd-helper unmask snapclient.service >/dev/null || true
    if deb-systemd-helper --quiet was-enabled snapclient.service; then
        deb-systemd-helper enable snapclient.service >/dev/null || true
    else
        deb-systemd-helper update-state snapclient.service >/dev/null || true
    fi
fi
POST
chmod 755 "$PKG_ROOT/DEBIAN/postinst"

cat > "$PKG_ROOT/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
# Stop the service on remove AND upgrade. Without the upgrade branch
# dpkg places the new binary on disk while the old one keeps running,
# so the .deb upgrade silently leaves stale code in memory until the
# operator restarts the unit manually.
if [ -d /run/systemd/system ] && { [ "$1" = remove ] || [ "$1" = upgrade ]; }; then
    deb-systemd-invoke stop snapclient.service >/dev/null || true
fi
PRE
chmod 755 "$PKG_ROOT/DEBIAN/prerm"

cat > "$PKG_ROOT/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ -d /run/systemd/system ]; then
    systemctl --system daemon-reload >/dev/null || true
fi
if [ "$1" = purge ]; then
    deb-systemd-helper purge snapclient.service >/dev/null || true
fi
POSTRM
chmod 755 "$PKG_ROOT/DEBIAN/postrm"

cat > "$PKG_ROOT/etc/default/snapclient" <<EOF
# Default options for snapclient (consumed by snapclient.service).
# snapMULTI overwrites this at first boot with target-specific
# audio device + mixer settings.
START_SNAPCLIENT=true
SNAPCLIENT_OPTS=""
EOF

cat > "$PKG_ROOT/lib/systemd/system/snapclient.service" <<EOF
[Unit]
Description=Snapcast client
Documentation=man:snapclient(1)
Wants=avahi-daemon.service
After=network-online.target time-sync.target sound.target avahi-daemon.service

[Service]
EnvironmentFile=-/etc/default/snapclient
ExecStart=/usr/bin/snapclient --logsink=system \$SNAPCLIENT_OPTS
User=snapclient
Group=snapclient
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat > "$PKG_ROOT/usr/share/doc/snapclient/copyright" <<EOF
Snapcast is licensed under the GPL-3.0-or-later license.
See https://github.com/badaix/snapcast/blob/${SNAPCAST_TAG}/LICENSE
EOF

# Build the .deb. Use --root-owner-group so the .deb lists
# root:root for every file regardless of fakeroot availability.
mkdir -p /workspace/dist
DEB_FILE="/workspace/dist/snapclient_${PKG_VERSION}_${ARCH}_${CODENAME}.deb"
dpkg-deb --root-owner-group --build "$PKG_ROOT" "$DEB_FILE"

sha256sum "$DEB_FILE"
dpkg-deb --info "$DEB_FILE" | head -20

echo "==> Built: $DEB_FILE"
