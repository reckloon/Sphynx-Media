# Sphynx Protocol

The **Sphynx** wire contract expressed as pure, dependency-free Swift value types.

Sphynx is an open protocol for a *media-meta-server*: a server that indexes media
living on remote storage or CDNs, enriches it with metadata, and hands clients a
**direct playback URL** plus everything needed to play and track it — without ever
proxying, transcoding, or storing the media bytes. See [`Sphynx-Protocol.md`](../docs/Sphynx-Protocol.md)
for the full specification (the source of truth).

This package is the shared contract consumed by **both** the reference server
(`sphynx-server`) and the Ocelot client app. It is therefore intentionally:

- **Foundation-only** — zero third-party dependencies.
- **Cross-platform** — builds for every Apple platform and Linux.
- **Forward-compatible** — unknown JSON fields are ignored and unrecognised
  enum-like string values decode to an `.unknown(value)` case instead of throwing
  (see `OpenEnum`). New optional fields and new string values may appear at any
  time without breaking older clients.

## Design notes

- **Time is `Double` seconds** on the wire everywhere (positions, runtime, ttl).
- **Open string enums** (`ItemType`, `LibraryKind`, `ErrorCode`) carry their known
  cases plus an `.unknown(String)` fallback and round-trip unknown values verbatim.
- The test suite is the contract's guardrail: it round-trips every type through
  JSON and proves that future/unknown payloads decode without throwing.

## Build & test

```sh
swift build
swift test
```

### Linux (via Docker)

```sh
./scripts/test-linux.sh        # runs `swift test` inside swift:6.3-noble
```

## Status

Milestone 1: discovery types (`ServerInfo`, `Capabilities`), the error envelope,
the open-enum machinery, and the forward-compatibility guardrail. The remaining
protocol types (auth, items, browse, resolve, playstate, search) land as the
server milestones reach them.
