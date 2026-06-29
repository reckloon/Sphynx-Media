# Sphynx reference server — Linux container image.
#
# IMPORTANT: the server depends on the sibling `sphynx-protocol` package via the
# local path `../sphynx-protocol`. The Docker build context must therefore be the
# PARENT directory that contains BOTH packages, not the server folder alone.
# Build it with:
#
#   docker build -f sphynx-server/Dockerfile -t sphynx-server ..
#
# or just use the provided docker-compose.build.yml, which sets the context for
# you. (The plain docker-compose.yml runs the published GHCR image instead of
# building from source.) CI builds this same file as a multi-arch image and
# pushes it to ghcr.io/reckloon/sphynx-server on each version tag.
#
# Targets:
#   --target test     run `swift test` (used by scripts/test-linux.sh + CI)
#   (default)         build a slim runtime image that runs the server

# ---- Base: both packages in their sibling layout ---------------------------
FROM swift:6.3-noble AS base
# GRDB links the system SQLite; install its headers for the build.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
# Copy via the build context (streamed as a host-side tar), NOT a bind mount —
# this avoids the Docker-Desktop-for-Mac virtiofs "Resource deadlock avoided"
# failures that plague mounted source.
COPY sphynx-protocol ./sphynx-protocol
COPY sphynx-server ./sphynx-server
WORKDIR /build/sphynx-server

# ---- Test stage: the Linux half of the cross-platform safety net -----------
FROM base AS test
RUN swift test

# ---- Build stage -----------------------------------------------------------
FROM base AS build
# Build once, then resolve the bin path a single time and reuse it. Each extra
# `swift build --show-bin-path` re-runs build planning, so caching it in a shell
# variable keeps staging to one resolution instead of two.
RUN swift build -c release --product SphynxServer \
    && BINDIR="$(swift build -c release --show-bin-path)" \
    && mkdir -p /staging \
    && cp "$BINDIR/SphynxServer" /staging/ \
    && find "$BINDIR" -name '*.resources' -exec cp -r {} /staging/ \; 2>/dev/null || true

# ---- Runtime stage ---------------------------------------------------------
FROM swift:6.3-noble-slim AS runtime
# Runtime needs the SQLite shared lib; ca-certificates for future outbound TLS;
# ffmpeg ships `ffprobe` so the media-probe extension (audio/subtitle tracks,
# embedded chapters) works out of the box — MediaProber finds it on $PATH at
# /usr/bin/ffprobe with no operator setup.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates ffmpeg \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN useradd --create-home --shell /usr/sbin/nologin sphynx
COPY --from=build /staging /app
# Pre-create the data dir owned by the runtime user. When a FRESH (empty) named
# volume is mounted here, Docker copies this directory's contents AND ownership
# into the volume — so `docker compose up` / `-v sphynx-data:/data` boots
# writable as the non-root `sphynx` user with no manual chown. Without this the
# server crashes on first boot: the volume defaults to root-owned and the
# non-root process hits "SQLite error 14: unable to open database file".
# (Bind mounts do NOT get this copy behaviour — host must own the dir as 1001.)
RUN mkdir -p /data && chown sphynx:sphynx /data
USER sphynx
EXPOSE 9410
ENV SPHYNX_HOST=0.0.0.0 SPHYNX_PORT=9410
ENTRYPOINT ["/app/SphynxServer"]
