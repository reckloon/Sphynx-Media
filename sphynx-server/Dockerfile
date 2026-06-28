# Sphynx reference server — Linux container image.
#
# IMPORTANT: the server depends on the sibling `sphynx-protocol` package via the
# local path `../sphynx-protocol`. The Docker build context must therefore be the
# PARENT directory that contains BOTH packages, not the server folder alone.
# Build it with:
#
#   docker build -f sphynx-server/Dockerfile -t sphynx-server ..
#
# or just use the provided docker-compose.yml, which sets the context for you.
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
RUN swift build -c release --product SphynxServer
# Collect the binary and any runtime resource bundles into a staging dir.
RUN mkdir -p /staging \
    && cp "$(swift build -c release --show-bin-path)/SphynxServer" /staging/ \
    && find "$(swift build -c release --show-bin-path)" -name '*.resources' -exec cp -r {} /staging/ \; 2>/dev/null || true

# ---- Runtime stage ---------------------------------------------------------
FROM swift:6.3-noble-slim AS runtime
# Runtime needs the SQLite shared lib; ca-certificates for future outbound TLS.
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
RUN useradd --create-home --shell /usr/sbin/nologin sphynx
COPY --from=build /staging /app
USER sphynx
EXPOSE 9410
ENV SPHYNX_HOST=0.0.0.0 SPHYNX_PORT=9410
ENTRYPOINT ["/app/SphynxServer"]
