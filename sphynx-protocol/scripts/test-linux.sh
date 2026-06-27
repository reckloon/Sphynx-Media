#!/usr/bin/env bash
# Run the protocol package's tests inside a Swift Linux container — the local
# half of the cross-platform safety net.
#
# Uses `docker build` rather than a bind mount: the build context is streamed to
# the daemon as a host-side tar, sidestepping the Docker-Desktop-for-Mac
# virtiofs "Resource deadlock avoided" failures that corrupt bind-mounted source.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Testing sphynx-protocol on Linux (swift:6.3-noble)"
# --no-cache keeps the run honest: tests always execute, never a stale layer.
docker build \
    --no-cache \
    --progress=plain \
    --target test \
    -f "$DIR/Dockerfile.test" \
    "$DIR"
echo "==> Linux tests passed."
