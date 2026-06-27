# Sphynx Protocol

**Status:** Draft / malleable — names, shapes, and units below are starting points, not commitments.

An open wire protocol for a **media-meta-server**: a server that indexes media living on remote storage or CDNs, enriches it with metadata, and hands clients a **direct playback URL** plus everything needed to play and track it — without ever proxying, transcoding, or storing the media bytes.

Sphynx is provider-neutral and identified by **TMDB ids** wherever possible, so any client (or third-party server) can implement either side. Ocelot consumes it through a single `SymbioteChild` adapter; nothing in this document is Ocelot-specific.

---

## 1. Principles

- **Control plane only.** The server resolves *where* the media is; the client streams it directly. Bytes never flow through Sphynx.
- **TMDB-centric identity.** Items carry a TMDB id where one exists. This is the join key for artwork, intro markers, and cross-server interoperability.
- **Neutral units, documented once.** Time is **seconds** (floating point) on the wire. Clients convert to whatever internal unit they use.
- **Self-describing, forward-compatible JSON.** Unknown fields are ignored; new optional fields and new enum-like string values may appear at any time. Clients must not break on values they don't recognize.
- **Open metadata, neutral fields.** Every canonical field has a fixed meaning and unit; a client only maps the *name* to whatever it calls the field internally. All fields are optional — a server sends only what it has. Beyond the canonical set, an item may carry an **`extra`** object of arbitrary server-defined metadata (§5.6); a client reads the keys it understands and ignores the rest. This is what lets a server (or a server extension) **serve whatever metadata it wants** while older clients keep working.
- **Stateless transport, stateful data.** Each request is independently authenticated; per-user state (playstate) lives server-side, scoped to the authenticated user.

---

## 2. Transport & conventions

- HTTPS only. JSON request/response bodies (`application/json`).
- Base path versioned: `/<version>/…` (e.g. `/v1/…`). Breaking changes bump the version; additive changes do not.
- IDs are opaque strings unless stated otherwise. A client must treat them as cookies, not parse them.
- Timestamps (wall-clock) are RFC 3339 / ISO 8601 strings. Media positions and durations are **seconds** (number).
- Pagination, where present, is cursor-based (`cursor` in, `nextCursor` out). Absent `nextCursor` means the end.
- Errors use a consistent envelope (§9) and standard HTTP status codes.

---

## 3. Authentication

A boring, proven shape. No custom crypto.

- `POST /v1/auth/login` — body `{ username, password }` → `{ accessToken, refreshToken, expiresIn, user }`.
- `POST /v1/auth/refresh` — body `{ refreshToken }` → a new token pair. Refresh tokens rotate on use; the old one is invalidated.
- `POST /v1/auth/logout` — revokes the presented refresh token (and optionally the whole device).
- `POST /v1/auth/password` — body `{ currentPassword, newPassword }` → **204**; change your own password.
- `GET /v1/auth/me` — `{ user, permissions, metadata }`: the caller's effective permission keys (e.g. `library.read`, `metadata.markers.write`) and per-field metadata access. The server advertises its capability in `/v1/info`; this is what *this user* may do. Treat unknown permission keys as opaque.
- All other endpoints require `Authorization: Bearer <accessToken>`.

Conventions (malleable, but recommended):

- Tokens are **device-scoped**. The client sends a stable per-install device id (header `X-Sphynx-Device`, opaque). This lets a server revoke one device without logging out the others, and avoids cross-session token invalidation.
- Access tokens are short-lived; refresh tokens are long-lived and revocable server-side.
- Password storage is argon2id/bcrypt; transport is TLS; per-user data is row-scoped to the token's subject. Authorization = "you can only ever touch your own rows."
- Rate limiting on `login`, `refresh`, and any write/submit endpoint.

```jsonc
// POST /v1/auth/login  →  200
{
  "accessToken": "…",
  "refreshToken": "…",
  "expiresIn": 3600,                  // seconds
  "user": { "id": "u_…", "displayName": "Mike", "avatarURL": "https://…" }
}
```

---

## 4. Discovery

So a client can confirm "this URL is a Sphynx server" before showing any credential UI, and learn the server's capabilities.

- `GET /v1/info` (unauthenticated) → identity + capability flags.

```jsonc
// GET /v1/info  →  200
{
  "product": "Sphynx",
  "serverName": "Mike's Library",
  "id": "srv_…",                       // stable server identity
  "version": "1.0",
  "protocol": ["v1"],                  // supported protocol versions
  "capabilities": {                    // optional feature advertisement; absent = unsupported
    "search": true,
    "playstate": true,
    "candidates": false,               // does /resolve return ranked fallbacks?
    "metadata": {                      // bi-directional access policy (see below)
      "markers": "readwrite",          // none | read | readwrite (open enum)
      "images":  "read"
    }
  }
}
```

A client treats unknown capability keys as ignorable and missing booleans as
`false`. **`metadata`** declares, per field/category, what a client may read and
contribute: `none` | `read` | `readwrite`. A field absent from the map is `none`
(readable if the server includes it on an item, but not contributable). This is
what makes the protocol **bi-directional and server-configurable** — one server
accepts marker contributions, another serves posters read-only, etc. Contribution
endpoints live under the item (e.g. `PUT /v1/items/<id>/markers`); see
`EXTENDING.md` for the client-write (TheIntroDB) and server-write (detector)
patterns.

---

## 5. Browse & metadata

Mirrors a phased "paint fast, enrich later" flow: cheap skeletons first, full detail on demand. A server may implement the phases as distinct endpoints (below) or fold them into one richer response — the client only needs the fields it asks for.

### 5.1 Libraries

- `GET /v1/libraries` → the top-level collections a user can browse.

```jsonc
{
  "libraries": [
    { "id": "lib_movies", "title": "Movies", "kind": "movies" },
    { "id": "lib_tv", "title": "TV", "kind": "tvShows" }
  ]
}
```

`kind` is an open string enum (`movies`, `tvShows`, `homeVideos`, `musicVideos`, `boxSets`, `collection`, `other`, …). Clients map unknown kinds to a neutral default.

### 5.2 Items in a container

- `GET /v1/items?parent=<id>&limit=<n>&cursor=<c>&detail=<skeleton|full>` → children of a library, season, series, or collection.

`detail=skeleton` returns the minimal fields needed to render a tile and decide playability; `detail=full` returns enrichment (overview, genres, ratings, cast). A skeleton is distinguished by the absence of enrichment fields.

### 5.3 Single item

- `GET /v1/items/<id>?detail=full` → one item with full enrichment.

### 5.4 The Item shape

All fields except `id`, `title`, and `type` are optional. A server sends what it has.

```jsonc
{
  "id": "it_…",                        // opaque server id (stable)
  "type": "movie",                     // movie|series|season|episode|person|collection|other
  "title": "Blade Runner 2049",
  "tmdbId": "335984",                  // string; the cross-system join key when present
  "overview": "…",
  "year": 2017,
  "runtime": 9840.0,                   // seconds

  "images": {                          // neutral image references; all optional
    "primary": "https://…",            // poster
    "backdrop": "https://…",
    "thumb": "https://…"
  },
  "placeholder": {                     // cheap low-res placeholder, self-describing (see §5.5)
    "blurHash": "LEHV6nWB…"
  },

  // Series/episode positioning (present as applicable)
  "seriesId": "it_…",
  "seriesTitle": "…",
  "seasonIndex": 1,
  "episodeIndex": 3,
  "childCount": 10,

  // Enrichment (present at detail=full)
  "genres": ["Sci-Fi", "Drama"],
  "communityRating": 8.0,
  "officialRating": "R",
  "cast": [
    {
      "id": "pe_…",
      "name": "Ryan Gosling",
      "role": "K",
      "imageURL": "https://…",
      "placeholder": { "blurHash": "…" }
    }
  ],

  // Per-user state, folded in when known (also available via §7)
  "resumePosition": 1342.5,            // seconds; absent or 0 means "from start"

  // Last change to client-rendered data (RFC 3339); max of the server's
  // per-field change times. Excludes per-user playstate. For cache diffing.
  "updatedAt": "2026-06-27T12:00:00Z",

  // Open, server-defined metadata beyond the canonical fields (see §5.6)
  "extra": { "tagline": "…", "imdbId": "tt…" }
}
```

### 5.5 Placeholder (low-res poster)

A `placeholder` object is **self-describing** and carries exactly one form. New forms may be added; a client uses the first form it understands and otherwise falls back to a plain background.

```jsonc
{ "blurHash": "LEHV6nWB…" }     // a BlurHash string, decoded client-side
// — or —
{ "url": "https://…/tiny.jpg" } // a pre-sized low-res image URL
```

The form is **open**: a server may store *any* low-res representation — a BlurHash, a small pre-sized image URL, or a future form — and a client ignores forms it doesn't recognize (rendering a plain background).

**Client requirement:** support **both** `blurHash` (decode locally) and `url` (load the small image) for now, using whichever form the server sent.

The reference server emits the **`url`** form — a small pre-sized image link — so it stores and processes no image bytes, keeping the server lightweight. A different server may store a `blurHash` instead; the wire contract is identical either way.

### 5.6 Open metadata (`extra`)

The canonical Item fields are the neutral contract — fixed meaning, fixed units,
all optional. For anything outside that set, an item may carry an `extra` object
of arbitrary server-defined metadata:

```jsonc
"extra": {
  "tagline": "In space no one can hear you scream.",
  "imdbId": "tt0078748",
  "chapters": [ { "start": 0.0, "title": "Intro" } ]
}
```

A client reads the keys it understands and ignores the rest; `extra` is omitted
when empty. Combined with forward-compatible decoding (unknown top-level fields
ignored, unknown enum strings tolerated), this lets a server — or a third-party
server extension — expose whatever metadata it wants without breaking clients
that predate it. Values are arbitrary JSON.

---

## 6. Resolve (the handoff)

The core of Sphynx: turn an item into a **direct, playable location** plus the hints a player needs. Called **late**, at play time — never cached from a browse response — because direct locations may be time-bounded.

- `GET /v1/resolve/<itemId>` → a playback descriptor.

```jsonc
{
  "url": "https://cdn.example/…/movie.mkv",   // DIRECT location; client streams this itself
  "headers": {                                 // headers the client must send when fetching `url`
    "Authorization": "…"
  },
  "container": "mkv",                           // source container hint (probe budgeting); optional
  "ttl": 300,                                   // seconds this descriptor is valid; absent = no expiry
  "preResolved": true,                          // if true, client skips its own redirect resolution

  "tracks": {                                   // optional selection hints; all indices source-relative
    "preferredAudio": 1,
    "copyableAudio": 1,
    "preferredSubtitle": 4
  },

  "markers": {                                  // optional; e.g. sourced from TheIntroDB by tmdbId
    "intro":   { "start": 75.0,  "end": 145.0 },
    "credits": { "start": 9120.0 }
  },

  // Optional ranked fallbacks. Present only if /info advertised capabilities.candidates.
  "candidates": [
    { "url": "https://cdn-b.example/…", "headers": {}, "priority": 1 }
  ]
}
```

Notes (malleable):

- If the server can only offer one location, it omits `candidates` and the client uses `url`.
- `markers` are convenience data; a client that doesn't show skip UI ignores them.
- The server never streams or redirects bytes itself — it only describes where they are.

---

## 7. Playstate (resume tracking)

Per-user position, scoped to the authenticated subject. Three lifecycle signals mirror a typical player: started, periodic progress, stopped.

- `POST /v1/playstate/<itemId>/start` — `{ position }`
- `POST /v1/playstate/<itemId>/progress` — `{ position, paused }`
- `POST /v1/playstate/<itemId>/stop` — `{ position, failed }`
- `GET  /v1/playstate/<itemId>` — `{ position, updatedAt }` (single item)
- `GET  /v1/playstate?items=<id,id,…>` — batch read (optional convenience)

```jsonc
// POST /v1/playstate/it_…/progress
{ "position": 1342.5, "paused": false }   // seconds
```

Conventions:

- On `stop` with `failed: true`, the server must **not** overwrite a good resume point with a bogus position.
- Position is authoritative server-side; clients may optimistically mirror locally between syncs.
- "Continue watching" / "next up" feeds are a server concern; expose them as ordinary item lists if desired (e.g. `GET /v1/home/continue`). Left intentionally open here.

---

## 8. Search (optional)

- `GET /v1/search?q=<query>&limit=<n>` → results, optionally pre-categorized.

```jsonc
{
  "movies":   [ /* Item */ ],
  "shows":    [ /* Item */ ],
  "people":   [ /* Item */ ],
  "episodes": [ /* Item */ ]
}
```

A simpler server may return a flat `{ "items": [...] }`; clients should accept either.

---

## 9. Errors

```jsonc
// non-2xx
{
  "error": {
    "code": "unauthorized",            // stable, machine-readable string
    "message": "Token expired.",       // human-readable; may change
    "retryable": false
  }
}
```

Suggested codes: `unauthorized`, `forbidden`, `not_found`, `no_media_source`, `rate_limited`, `server_error`, `unavailable`. Clients key behavior off `code`, not `message`.

---

## 10. Open questions (intentionally unresolved)

These are left to the implementation and may shape future versions:

- **Direct-location lifetime.** Whether `ttl` is advisory or enforced, and how a client re-resolves mid-session on a stream drop.
- **Candidate selection.** Whether the client or server owns failover ordering when multiple locations exist.
- **Image sizing.** Whether the server accepts size hints (`?w=600`) or always returns one canonical size per role.
- **Marker provenance.** Whether `markers` are inlined in `/resolve` or fetched from a dedicated `/v1/items/<id>/markers` endpoint.
- **Identity beyond TMDB.** Fallback identifiers (IMDB, TVDB, content hash) for media TMDB can't resolve.
- **Wire encoding.** JSON is the baseline; a binary encoding (CBOR/protobuf) on the hot path is an open optimization, not a requirement.

---

## 11. Mapping to a client adapter (informative)

For reference, a client that already models media internally needs only a thin translation layer:

| Protocol field | Typical client mapping |
| --- | --- |
| `resolve.url` + `headers` | a pre-resolved playback request (skip redirect resolution) |
| position fields (seconds) | convert to the client's internal unit at the boundary |
| `placeholder.{blurHash,url}` | a self-describing low-res placeholder type |
| `playstate/*` | the client's playback-reporting hooks (start/progress/stop) |
| `markers.intro` | a "Skip Intro" affordance |

Nothing above requires the client to expose its internal types; the protocol is the only contract.
