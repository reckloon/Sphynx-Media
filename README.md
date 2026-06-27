<div align="center">

# Sphynx

**An open media-meta-server and wire protocol.**

Index media that lives on remote storage or CDNs, identify and enrich it against
TMDB, and hand clients a **direct, playable URL** — without ever proxying,
transcoding, or storing a single media byte.

*The server is brain, not muscle: it resolves **where** the media is; the client streams it directly.*

</div>

---

## What is this?

Sphynx is a drop-in alternative to the *backend* role that Jellyfin/Plex play —
minus the media byte plane. It does library indexing, content identification,
metadata enrichment, users/auth, playstate, and intro-marker lookup, then resolves
an item to a direct location the client fetches itself.

The single differentiator: **Sphynx assumes the media is remote and
direct-streamable**, so the entire transcode/segment/serve subsystem those servers
carry simply doesn't exist here. No bytes ever transit the server.

It was designed side-by-side with **Ocelot**, a native Apple media player whose
direct-stream-only engine consumes Sphynx through a thin adapter — but the
protocol is provider-neutral and client-agnostic. Items are keyed by **TMDB id**
wherever possible, so any client or third-party server can implement either side.

## Repository layout

This is a monorepo containing two Swift packages plus the specs:

| Path | What it is |
|------|------------|
| [`sphynx-protocol/`](sphynx-protocol) | The wire contract as **pure, dependency-free** Swift value types (Foundation-only). Builds for every Apple platform + Linux. Shared by the server and any client. |
| [`sphynx-server/`](sphynx-server) | The reference server — a [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) app. Uses the protocol types directly as request/response bodies, so it can't drift from the wire format. |
| [`docs/`](docs) | The [protocol spec](docs/Sphynx-Protocol.md), [server design](docs/Sphynx-Server.md), [endpoint reference](docs/API.md), and the [extension guide](docs/EXTENDING.md). |

## Core principles

- **Control plane only.** `/resolve` describes *where* the bytes are (direct URL +
  headers + ttl), called late at play time, never cached from a browse response.
- **TMDB-centric identity.** The join key for artwork, intro markers, and
  cross-server interoperability.
- **Forward-compatible JSON.** Unknown fields are ignored; new enum-like string
  values decode to an `.unknown` case rather than breaking older clients.
- **Neutral units.** Time is **seconds** (floating point) on the wire everywhere.
- **Boring, proven auth.** Password hashing, short access token + rotating
  refresh token, device-scoped sessions, per-user row scoping.

## Quickstart

Requires a **Swift 6** toolchain (macOS via Xcode, or Linux). Optional: Docker for
the Linux build/run loop.

```sh
git clone https://github.com/reckloon/Sphynx-Media.git
cd Sphynx-Media/sphynx-server

swift run SphynxServer            # serves on http://0.0.0.0:8080
```

Then exercise the full **login → resolve → play** path:

```sh
# Confirm it's a Sphynx server (unauthenticated discovery).
curl -s localhost:8080/v1/info

# Log in as the bootstrapped admin (default admin / changeme — change it!).
curl -sX POST localhost:8080/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}'

# Add an item pointing at a direct media URL (admin only), then resolve it.
curl -sX POST localhost:8080/v1/admin/items -H "Authorization: Bearer <accessToken>" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Big Buck Bunny","container":"mp4",
       "sourceKey":"https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"}'

curl -s localhost:8080/v1/resolve/<itemId> -H "Authorization: Bearer <accessToken>"
# → { "url": "https://…/BigBuckBunny_320x180.mp4", "preResolved": true, … }
```

See [`sphynx-server/README.md`](sphynx-server/README.md) for configuration and the
Docker workflow, and [`docs/API.md`](docs/API.md) for the full endpoint reference.

## Status

Built spine-first. Working today:

- **Discovery & auth** — `GET /v1/info`; password login with short access tokens +
  rotating refresh tokens; device-scoped sessions.
- **Browse** — libraries and items (skeleton/full), cursor pagination, single-item
  detail.
- **Identity & enrichment** — items identified against TMDB with posters,
  overview, genres, rating, runtime, and cast (movies).
- **Resolve** — direct, time-bounded playback location + headers (never proxied).
- **Playstate** — resume tracking (start/progress/stop) with failed-stop
  protection, `resumePosition` folded into browse, and a continue-watching feed.
- **Bi-directional metadata** — server-configurable, per-field read/write access;
  contributable intro/credit markers; an open `extra` bag for arbitrary
  server-defined metadata. See the [extension guide](docs/EXTENDING.md).

Roadmap: watched/favorites + sort/filter, TV (series/season/episode), search,
ranked resolve fallbacks, and more source drivers.

## Building / testing

```sh
# In either package directory:
swift build
swift test
./scripts/test-linux.sh          # runs the tests in a Swift Linux container (needs Docker)
```

CI runs `swift test` for both packages on macOS and a Swift Linux container on
every push.

> **Note on consuming the protocol package.** Because this is a monorepo, the
> `sphynx-protocol` package isn't at the repository root, so it can't be added as
> a SwiftPM *URL* dependency directly. Clients (e.g. Ocelot) consume it via a
> local path dependency against a checkout. If a standalone distribution becomes
> necessary, the package can be mirrored to its own repo.

## License

[MIT](LICENSE).
