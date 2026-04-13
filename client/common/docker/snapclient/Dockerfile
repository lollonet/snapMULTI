FROM debian:bookworm-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    git \
    libasound2-dev \
    libboost-dev \
    libavahi-client-dev \
    libflac-dev \
    libogg-dev \
    libvorbis-dev \
    libopus-dev \
    libexpat1-dev \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone and build snapclient from upstream badaix/snapcast (default).
# CI passes SNAPCAST_REPO=lollonet/santcasp.git via workflow_dispatch for :dev builds.
ARG SNAPCAST_REPO=https://github.com/badaix/snapcast.git
ARG SNAPCAST_BRANCH=master
ARG SNAPCAST_TAG=
ARG SNAPCAST_SHA=latest
WORKDIR /build
RUN echo "snapcast repo: $SNAPCAST_REPO branch: ${SNAPCAST_TAG:-$SNAPCAST_BRANCH} sha: $SNAPCAST_SHA" && \
    git clone --depth 1 --branch "${SNAPCAST_TAG:-$SNAPCAST_BRANCH}" "$SNAPCAST_REPO" snapcast

WORKDIR /build/snapcast
RUN cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SERVER=OFF \
    -DBUILD_CLIENT=ON \
    -DBUILD_TESTS=OFF

RUN cmake --build build --parallel "$(nproc)"

# Runtime image
FROM debian:bookworm-slim

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    libasound2 \
    alsa-utils \
    libboost-system-dev \
    libboost-program-options-dev \
    libavahi-client3 \
    libflac12 \
    libogg0 \
    libvorbis0a \
    libopus0 \
    libexpat1 \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled snapclient binary
COPY --from=builder /build/snapcast/bin/snapclient /usr/bin/snapclient

RUN groupadd -r -g 1000 snapclient && useradd -r -u 1000 -g snapclient -d / -s /sbin/nologin snapclient

# Entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER snapclient

ENTRYPOINT ["/entrypoint.sh"]
