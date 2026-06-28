#!/usr/bin/env bash
# Run the server package's tests inside a Swift Linux container — the local half
# of the cross-platform safety net.
#
# Uses `docker build --target test` rather than a bind mount: the build context
# is streamed to the daemon as a host-side tar, sidestepping the
# Docker-Desktop-for-Mac virtiofs "Resource deadlock avoided" failures that
# corrupt bind-mounted source. The build context is the PARENT directory so the
# sibling sphynx-protocol package is included (see Dockerfile header).
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PARENT_DIR="$(cd "$SERVER_DIR/.." && pwd)"

echo "==> Testing sphynx-server on Linux (swift:6.3-noble)"
# --no-cache keeps the run honest: tests always execute, never serve a stale
# cached layer. Drop it for a faster inner loop if you prefer.
docker build \
    --no-cache \
    --progress=plain \
    --target test \
    -t sphynx-server-test \
    -f "$SERVER_DIR/Dockerfile" \
    "$PARENT_DIR"
echo "==> Linux tests passed."

# Reusing the tag above means each run replaces the previous image rather than
# orphaning an ~8GB untagged one. Sweep any now-dangling predecessor so repeated
# runs don't accumulate disk.
docker image prune -f >/dev/null 2>&1 || true
