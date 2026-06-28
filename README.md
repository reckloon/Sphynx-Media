<div align="center">

# Sphynx

**An open media-meta-server and wire protocol.**

Index media that lives on remote storage or CDNs, identify and enrich it against
TMDB, and hand clients a **direct, playable URL** — without ever proxying,
transcoding, or storing a single media byte.

*The server is brain, not muscle: it resolves **where** the media is; the client streams it directly.*

📖 **[Read the complete guide →](https://reckloon.github.io/Sphynx-Media/)** &nbsp;·&nbsp; [API reference](docs/API.md)

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
| [`sphynx-protocol/`](sphynx-protocol) | The wire contract as **pure, dependency-free** Swift value types (Foundation-only). Builds for every Apple platform + Linux. Used directly by the reference server; available for any client that prefers to reuse the types rather than hand-map the JSON. |
| [`sphynx-server/`](sphynx-server) | The reference server — a [Hummingbird 2](https://github.com/hummingbird-project/hummingbird) app. Uses the protocol types directly as request/response bodies, so it can't drift from the wire format. |
| [`docs/`](docs) | The [endpoint reference](docs/API.md). The full narrative — protocol, server design, and extending — is the **[complete guide](https://reckloon.github.io/Sphynx-Media/)** ([`Guide.html`](Guide.html)). |

## Core principles

- **Control plane only.** `/resolve` describes *where* the bytes are (a direct URL +
  headers, plus an optional expiry only for time-bounded source links), called late
  at play time. The server stores only the source reference, never a resolved URL,
  and resolves fresh on every play.
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

# Set an admin password (or omit it and copy the random one printed to the log).
SPHYNX_ADMIN_PASSWORD=changeme swift run SphynxServer   # serves on http://0.0.0.0:8080
```

Then exercise the full **login → resolve → play** path:

```sh
# Confirm it's a Sphynx server (unauthenticated discovery).
curl -s localhost:8080/v1/info

# Log in as the bootstrapped admin (the password you set above).
curl -sX POST localhost:8080/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}'

# Add an item pointing at a direct media URL (admin only), then resolve it.
curl -sX POST localhost:8080/v1/admin/items -H "Authorization: Bearer <accessToken>" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Big Buck Bunny","container":"mp4",
       "sourceKey":"https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"}'

curl -s localhost:8080/v1/resolve/<itemId> -H "Authorization: Bearer <accessToken>"
# → { "url": "https://…/BigBuckBunny_320x180.mp4", "terminal": true, … }
```

See [`sphynx-server/README.md`](sphynx-server/README.md) for configuration and the
Docker workflow, and [`docs/API.md`](docs/API.md) for the full endpoint reference.

## Status

Built spine-first. Working today:

- **Discovery & auth** — `GET /v1/info`; password login with short access tokens +
  rotating refresh tokens; device-scoped sessions.
- **Browse** — libraries and items (skeleton/full), cursor pagination, single-item
  detail.
- **Identity & enrichment** — movies and **TV** identified against TMDB. TV builds
  a series → season → episode tree (posters, season art, episode stills/titles).
- **Browse hierarchy** — libraries → series → seasons → episodes via `parent=`.
- **Resolve** — direct playback location + headers, resolved fresh per play and
  never stored (never proxied; optional expiry only for time-bounded source links).
- **Playstate & per-user state** — resume tracking (start/progress/stop) with
  failed-stop protection; watched / favorite / play-count / last-played; browse
  sort (name/added/rating) + genre/unwatched filter.
- **Typed home feed** — `GET /v1/home` returns ordered shelves with a `kind` and
  tile `aspect`. Continue Watching is **unified**: the next unwatched episode of a
  show you've started is merged into it — one row, never a separate "Next Up".
  Plus Recently Added and Favorites.
- **Bi-directional metadata** — server-configurable, per-field read/write access;
  contributable intro/credit markers; an open `extra` bag for arbitrary
  server-defined metadata. See the [complete guide](https://reckloon.github.io/Sphynx-Media/).
- **Web admin** — a built-in `/admin` page for settings, libraries, sources, and
  users, plus a live activity dashboard (items being parsed/enriched), a read-only
  database browser, and a diagnostics log.
- **Live updates** — an additive server→client SSE event stream (`GET /v1/events`)
  for playstate, per-user state, markers, and library changes; clients opt in via
  `capabilities.events` and otherwise poll.

### Roadmap

Two tracks: **content-model breadth** (what items exist and how they relate) and
**protocol contract hardening** (wire-contract additions clients can rely on). In
priority order:

- **Content & catalog** — extras / bonus content (trailers, featurettes, deleted
  scenes nested under their movie or show); collections / box sets (browsable via
  `items?parent=`); a person-filmography endpoint
  (`GET /v1/people/{id}/items`); artwork & metadata fills (logo/banner, trailers,
  tags, sortTitle).
- **High** — per-image placeholder & aspect metadata; track languages/labels +
  external subtitles in resolve; multiple versions/editions; a
  `GET /v1/changes?since=` delta feed with deletion tombstones.
- **Medium** — TV-friendly login (device-code / QR); advertised refresh-token
  lifetime; a typed browse sort/filter contract (+ `totalCount`); rate-limit
  backoff hints; a clear-resume action; the playstate source-of-truth rule in the
  types.
- **Lower / by-design** — typed search shape; a server-mediated co-watch/party
  channel (the one-way SSE event stream already ships — see Features above; only a
  bidirectional party channel is unbuilt); marker DELETE + per-segment provenance;
  `Accept-Language` negotiation; more source drivers.

A pre-built Docker image is also planned. The full roadmap lives in the
[complete guide](https://reckloon.github.io/Sphynx-Media/#roadmap).

## Building / testing

```sh
# In either package directory:
swift build
swift test
./scripts/test-linux.sh          # runs the tests in a Swift Linux container (needs Docker)
```

CI runs `swift test` for both packages on macOS and a Swift Linux container on
every push.

> **Note on consuming the protocol package.** `sphynx-protocol` is the canonical,
> dependency-free definition of the wire types, shared by the reference server so
> it can't drift from the spec. A client **may** consume it to reuse those types,
> but isn't required to — the wire is plain JSON, so a client can implement the
> protocol directly from the [docs](https://reckloon.github.io/Sphynx-Media/)
> (Ocelot does the latter, hand-mapping the JSON with its own `Decodable` types).
> Because this is a monorepo, the package isn't at the repository root, so a client
> that does consume it adds it via a local path dependency against a checkout; it
> can be mirrored to its own repo if standalone distribution is ever needed.

## License

[MIT](LICENSE).
