# Sphynx API Reference

The HTTP surface implemented by `sphynx-server`. This is the endpoint reference;
the full narrative — protocol, server design, and extending — is the
[complete guide](https://reckloon.github.io/Sphynx-Media/). This document reflects
**what is implemented today**; unimplemented protocol endpoints are listed under
[Planned](#planned).

- Base path: `/v1`
- Bodies: `application/json`
- Times/durations: **seconds** (floating point)
- Auth: `Authorization: Bearer <accessToken>` on everything except `/v1/info` and
  `/v1/auth/login`
- Device scoping: send a stable per-install `X-Sphynx-Device: <opaque>` header

## Conventions

| Aspect | Rule |
|--------|------|
| Unknown JSON fields | Ignored (forward-compatible) |
| Unknown enum strings | Decoded as an `.unknown` value, never an error |
| Errors | Consistent envelope (see [Errors](#errors)) + standard HTTP status |
| IDs | Opaque strings — treat as cookies, don't parse |

---

## Discovery

### `GET /v1/info` — unauthenticated

Confirm a URL is a Sphynx server and learn its capabilities.

**200**
```json
{
  "product": "Sphynx",
  "serverName": "Sphynx Reference Server",
  "id": "srv_reference",
  "version": "1.0",
  "protocol": ["v1"],
  "capabilities": {
    "search": false,
    "playstate": true,
    "candidates": false,
    "metadata": { "markers": "readwrite", "images": "read" }
  }
}
```
A client treats unknown capability keys as ignorable and missing booleans as
`false`. **`metadata`** is the bi-directional access policy: a per-field map of
`none` | `read` | `readwrite` (open enum). A field absent from the map is `none`
— readable if served, but not contributable. See the [guide → Extending](https://reckloon.github.io/Sphynx-Media/#extending).

---

## Authentication

### `POST /v1/auth/login` — unauthenticated

**Body** `{ "username": "...", "password": "..." }`
Optional header `X-Sphynx-Device`.

**200**
```json
{
  "accessToken": "…",
  "refreshToken": "…",
  "expiresIn": 3600,
  "user": { "id": "u_…", "displayName": "admin" }
}
```
**401** `unauthorized` — invalid username or password.

### `POST /v1/auth/refresh`

**Body** `{ "refreshToken": "..." }`

Returns a **new** token pair; the presented refresh token is **rotated** (the old
one is immediately invalidated). Same response shape as login.

**401** `unauthorized` — invalid, expired, or already-rotated refresh token.

### `POST /v1/auth/logout`

**Body** `{ "refreshToken": "...", "allDevices": false }`

Revokes the presented refresh token's session. `allDevices: true` revokes every
session on the same device id. **204 No Content** on success (idempotent).

### `GET /v1/auth/me` — auth required

The authenticated user plus **that user's effective** permissions. Where
`/v1/info` advertises what the *server* supports, this reflects what *this user*
may actually do (permissions are granted per-user by the admin).

**200**
```json
{ "user": { "id": "u_…", "displayName": "Bob" },
  "permissions": ["library.read", "metadata.markers.write"],
  "metadata": { "markers": "readwrite", "images": "read" } }
```

- **`permissions`** — the user's effective permission keys (see
  [Permissions](#permissions)). The admin holds all of them implicitly. Treat
  unknown keys as opaque and ignore them (forward-compatible).
- **`metadata`** — a per-field metadata-access view (server policy narrowed to
  this user's write permissions), kept for the contribute affordance.

A client should use this (not `/v1/info`) to decide which affordances to show
(browse, contribute markers, edit metadata, …).

### `POST /v1/auth/password` — auth required

Change the authenticated user's **own** password. **Body**
`{ "currentPassword": "…", "newPassword": "…" }`. **204** on success; **401** if
the current password is wrong. The presenting session stays valid.

---

## Browse

### `GET /v1/libraries` — auth required

The top-level collections a user can browse.

**200**
```json
{ "libraries": [ { "id": "lib_…", "title": "Movies", "kind": "movies" } ] }
```
`kind` is an open string enum (`movies`, `tvShows`, `homeVideos`, `musicVideos`,
`boxSets`, `collection`, `other`, …); clients map unknown kinds to a default.

### `GET /v1/items` — auth required

Children of a container. Query parameters:

| Param | Default | Meaning |
|-------|---------|---------|
| `parent` | *(required)* | A **library id** (top-level items) or an **item id** (its children) |
| `detail` | `skeleton` | `skeleton` (tile fields) or `full` (adds enrichment, once available) |
| `limit` | `50` | Page size (1–200) |
| `cursor` | — | Opaque pagination cursor from a previous `nextCursor` |

**200**
```json
{ "items": [ { "id": "it_…", "type": "movie", "title": "…", "year": 2008 } ],
  "nextCursor": "b2Zmc2V0OjUw" }
```
An absent `nextCursor` means the end of the list.

### `GET /v1/items/{itemId}?detail=full` — auth required

A single item. **404** `not_found` if absent. See [Item shape](#item-shape).

---

## Markers (bi-directional)

Intro/credit markers are **item-level** (shared across a server's clients) and
gated by `capabilities.metadata["markers"]`. See the
[guide → Extending](https://reckloon.github.io/Sphynx-Media/#extending) for the
contribution model (e.g. a client bridging TheIntroDB).

### `GET /v1/items/{itemId}/markers` — auth; requires markers ≥ `read`

**200**
```json
{ "markers": { "intro": {"start":75,"end":145}, "credits": {"start":9120} },
  "source": "theintrodb", "confidence": 0.95, "authoritative": false,
  "updatedAt": "2026-06-27T12:00:00Z", "stale": false }
```
**404** if the server doesn't offer markers, or none are stored for the item.

`stale: true` means the markers are older than the server's freshness window and a
client with a data source should re-fetch and `PUT` updated ones (see
[guide → Freshness](https://reckloon.github.io/Sphynx-Media/#ext-freshness)).
Authoritative markers are never stale.

### `PUT /v1/items/{itemId}/markers` — auth; requires markers == `readwrite`

**Body** `{ "markers": { "intro": {…}, "credits": {…} }, "source": "…", "confidence": 0.9 }`
→ **200** with the stored [MarkersInfo].

- **403** `forbidden` if the server is read-only for markers, **or the user
  hasn't been granted the `markers` write** (writes are per-user; admins always
  have it). Check `GET /v1/auth/me` for the caller's effective access.
- **409** `conflict` if authoritative markers exist and the caller isn't admin —
  a best-effort client contribution may not clobber server-detected/admin data.

Contributed markers also appear in the `/resolve` descriptor's `markers`.

---

## Resolve

### `GET /v1/resolve/{itemId}` — auth required

The late-bound handoff: turns an item into a direct, playable location. Called at
play time, never cached from browse.

**200**
```json
{
  "url": "https://cdn.example/movie.mkv",
  "headers": { },
  "container": "mkv",
  "preResolved": true
}
```
- `url` — DIRECT location; the client streams this itself. Resolved fresh on every
  call and **never stored** — the server keeps only the item's source reference.
- `headers` — headers the client must send when fetching `url`.
- `preResolved` — if true, the client skips its own redirect resolution.
- `ttl` — *optional.* When the source returns a time-bounded link (e.g. a signed
  CDN URL), how many seconds it stays valid; the server passes the driver's value
  straight through and never persists it. The built-in `http`/`local` drivers
  return plain, non-expiring URLs, so `ttl` is absent. Absent = no expiry.
- `tracks`, `markers`, `candidates` — optional; `tracks`/`candidates` absent in the
  current build.

**404** `not_found` (no such item) / `no_media_source` (item's source unavailable).

---

## Playstate

Per-user resume tracking, **row-scoped to the authenticated subject** — a user
only ever reads/writes their own state. Positions are in **seconds**. All require
auth.

### `POST /v1/playstate/{itemId}/start`
**Body** `{ "position": 12.5 }` → **204**.

### `POST /v1/playstate/{itemId}/progress`
**Body** `{ "position": 1342.5, "paused": false }` → **204**.

### `POST /v1/playstate/{itemId}/stop`
**Body** `{ "position": 1500.0, "failed": false }` → **204**.
On `failed: true` the server **does not overwrite** the stored resume point — a
misfire (the playhead never advanced past startup) can't clobber a good position.

### `GET /v1/playstate/{itemId}`
**200** → `{ "position": 1342.5, "updatedAt": "2026-06-27T16:35:30Z" }`.
No stored state → `{ "position": 0, … }` ("from start").

### `GET /v1/playstate?items=<id,id,…>`
Batch read. **200** → `{ "states": { "it_1": { "position": …, "updatedAt": … } } }`.
Items with no stored state are omitted.

> `resumePosition` is also folded into item responses (browse list + single item)
> for the authenticated user, so a "continue watching" UI needs no extra call.

### `GET /v1/home/continue` — auth required

The user's in-progress items (stored position > 0), **most-recently-played
first**, each with `resumePosition` folded in. Cursor-paginated; `detail`
selects skeleton/full. Returns the same `ItemsResponse` shape as `/v1/items`.

The server only stores and exposes the data (per-user position + `updatedAt`,
ordered by recency) — **the client owns presentation and policy**: it has each
item's runtime, so it decides what counts as "finished", whether to hide it, how
to sort, etc. A client that wants raw timestamps for its own logic can read them
via `GET /v1/playstate?items=…` (each entry carries `updatedAt`).

---

## Admin (server-specific, not part of the wire protocol)

Catalog setup, indexing, and manual entry. **Auth required + admin role**
(`403 forbidden` otherwise).

### `POST /v1/admin/libraries`

**Body** `{ "title": "Movies", "kind": "movies" }` (`kind` defaults to `other`).
**200** → `{ "id": "lib_…", "title": "Movies", "kind": "movies" }`.

### `POST /v1/admin/sources`

**Body**
```json
{ "label": "My CDN", "driver": "http", "baseURL": "https://cdn.example",
  "headers": { "Authorization": "…" }, "libraryId": "lib_…",
  "manifestURL": "https://cdn.example/manifest.json" }
```
`driver` defaults to `http`. `libraryId` is the library this source feeds;
`manifestURL` is where the indexer lists entries. **200** →
`{ "id": "src_…", "label": "...", "driver": "http", "config": { … } }` — only
non-secret fields are returned.

Drivers other than HTTP configure through two open maps: **`config`** for
non-secret, driver-specific settings, and **`secrets`** for credentials. Secrets
are stored but **never** returned by this endpoint or written to logs (for the
HTTP driver, request `headers` are treated the same way).

```json
{ "label": "NAS", "driver": "webdav", "libraryId": "lib_…",
  "config":  { "baseURL": "https://nas.example/remote.php/dav" },
  "secrets": { "username": "alice", "password": "•••" } }
```

For a `local` source, set `driver` to `local` and `config.rootPath` to a
directory path; the indexer walks that tree, deriving each item's identity from
the folder layout (`Title (Year)/file` for movies, `Show (Year)/Season N/file`
for TV). A re-scan re-walks the folder, so it doubles as the periodically-updated
source. `.strm` files are followed at resolve time to their contained URL — bytes
never pass through the server. See the
[guide → Source drivers](https://reckloon.github.io/Sphynx-Media/#ext-drivers) for
the full driver list and how to add a backend.

The manifest is a simple JSON document the indexer reads (metadata, not media):
```json
{ "items": [
    { "key": "BigBuckBunny_320x180.mp4", "title": "Big Buck Bunny", "type": "movie", "year": 2008 },
    { "key": "Breaking.Bad.S01E01.mkv", "container": "mkv" }
] }
```
`key` is resolved into a direct URL (relative to the source `baseURL`, or
absolute). `file://` manifest URLs are read from disk (useful for local setups).

**TV** is detected from the filename (`S01E02`, `1x05`, …): the indexer builds a
**series → season → episode** tree, deduping shared series/seasons, and (when TMDB
is configured) identifies the series and enriches series posters, season posters,
and episode stills/titles/overviews. Entries may instead carry explicit
`seriesTitle` / `season` / `episode` hints. Browse the tree via `parent=` —
library → series → seasons → episodes — with `seriesId`, `seasonIndex`,
`episodeIndex`, and `childCount` on each item.

### `POST /v1/admin/sources/{sourceId}/scan`

Index one source: fetch its manifest, diff against the catalog, apply
adds/updates/removes. **200** →
`{ "sourceId": "src_…", "scanned": 12, "added": 3, "updated": 1, "removed": 0 }`.

### `POST /v1/admin/scan`

Scan every source. **200** → `{ "sources": [ <scan summary>, … ] }`.

### Permissions

Authorization is a **single admin** (the bootstrap account, which holds every
permission implicitly and is the only admin) plus an **open per-user permission
set** the admin grants. Permissions are string keys, stored uniformly and
forward-compatible — unknown keys are tolerated. Well-known keys:

| Key | Grants |
|---|---|
| `library.read` | Browse libraries + resolve/play their items |
| `metadata.markers.write` | Contribute intro/credit markers |
| `metadata.images.write` | Contribute artwork |
| `metadata.edit` | Edit item metadata and lock fields against auto-refresh |

A key may be **scoped to one library** with a `:<libraryId>` suffix, e.g.
`library.read:lib_abc` grants read for that library only. Each gated action
checks the caller's effective permission; the admin always passes.

### `GET /v1/admin/users`

List all accounts. **200** → `{ "users": [ { "id": "u_…", "username": "bob",
"displayName": "Bob", "isAdmin": false, "permissions": ["library.read"] }, … ] }`.
The admin's `permissions` reflects the full implicit set.

### `POST /v1/admin/users`

Create a **non-admin** user (there is exactly one admin — any `isAdmin` in the
body is ignored). **Body**
`{ "username": "bob", "password": "…", "displayName": "Bob", "permissions": ["library.read"] }`.
`permissions` defaults to `["library.read"]` when omitted, so a new user can
browse and play immediately. **200** → the created user. **409** if the username
is taken.

### `PUT /v1/admin/users/{userId}/permissions`

Replace a user's permission set. **Body** `{ "permissions": ["library.read", "metadata.markers.write"] }`
→ **200** with the updated user. This is how the admin controls **per-user
access**. Setting the admin's permissions is rejected (it holds all implicitly).

### `DELETE /v1/admin/users/{userId}`

Delete a user and revoke all their sessions + per-user state. **204** on success.
The admin account cannot be deleted (**403**).

The scan summary includes an `enriched` count — items identified against TMDB and
enriched during the scan (0 when TMDB isn't configured).

### `PATCH /v1/admin/items/{itemId}` — `metadata.edit`

Edit an item's metadata and **lock** each edited field against auto-refresh.
Gated by the `metadata.edit` [permission](#permissions) (honoring per-library
scoping), not the admin role — so a non-admin editor can be granted it.

Every field is optional; each one **present is written and locked**. A locked
field survives every scan, TTL refresh, and forced enrich, so manual edits stick.
**Body**
```jsonc
{ "title": "…", "overview": "…", "year": 1999, "runtime": 8160,
  "genres": ["…"], "communityRating": 8.2, "officialRating": "PG-13",
  "images": { "primary": "https://…", "backdrop": "https://…", "thumb": "https://…" },
  "placeholder": "https://…",          // custom low-res placeholder (image URL)
  "unlock": ["overview"],               // remove specific locks (re-enable refresh)
  "unlockAll": false }                  // or clear every lock
```
**200** → `{ "item": <Item>, "lockedFields": ["overview", "title"] }`. To revert a
field to automatic TMDB data, `unlock` it (or `unlockAll`) and re-enrich.

### `POST /v1/admin/items/{itemId}/identity`

Admin override: pin an item to a specific TMDB id and re-enrich.
**Body** `{ "tmdbId": "603", "type": "movie" }`. **200** → the enriched [`Item`](#item-shape).

### `POST /v1/admin/items/{itemId}/enrich`

Force re-identification + enrichment of one item. **200** → the enriched item.

### `POST /v1/admin/enrich`

Enrich every item that needs it (new or stale). **200** → `{ "enriched": 7 }`.

> The three enrichment endpoints require TMDB to be configured
> (`SPHYNX_TMDB_API_KEY`); otherwise they return **400** `bad_request`.

### `POST /v1/admin/items`

**Body**
```json
{ "title": "Big Buck Bunny", "type": "movie", "container": "mp4",
  "sourceId": "src_…", "sourceKey": "path/or/absolute-url", "tmdbId": "..." }
```
- `sourceKey` — an absolute URL (self-contained) **or** a key relative to the
  source's `baseURL`.
- `sourceId` — optional; omit it when `sourceKey` is an absolute URL.
- `type` defaults to `movie`.

**200** → the created [`Item`](#item-shape).

---

## Errors

Every non-2xx response uses this envelope:

```json
{ "error": { "code": "unauthorized", "message": "Token expired.", "retryable": false } }
```

Clients branch on `code`, not `message`. Codes in use:
`unauthorized`, `forbidden`, `not_found`, `no_media_source`, `rate_limited`,
`server_error`, `unavailable`, and the open value `bad_request`. Unknown codes
must be tolerated.

---

## Item shape

All fields except `id`, `title`, `type` are optional; the server sends what it
has. A *skeleton* item omits enrichment (overview, genres, ratings, cast).

```json
{
  "id": "it_…",
  "type": "movie",
  "title": "Blade Runner 2049",
  "tmdbId": "335984",
  "overview": "…", "year": 2017, "runtime": 9840.0,
  "images": { "primary": "…", "backdrop": "…", "thumb": "…" },
  "placeholder": { "url": "…/tiny.jpg" },
  "seriesId": "…", "seriesTitle": "…", "seasonIndex": 1, "episodeIndex": 3, "childCount": 10,
  "genres": ["Sci-Fi"], "communityRating": 8.0, "officialRating": "R",
  "cast": [ { "id": "pe_…", "name": "Ryan Gosling", "role": "K", "imageURL": "…", "placeholder": { "url": "…/tiny.jpg" } } ],
  "resumePosition": 1342.5,
  "updatedAt": "2026-06-27T12:00:00Z",
  "extra": { "tagline": "…", "imdbId": "tt…", "anything": [1, 2, 3] }
}
```

`updatedAt` (RFC 3339) is the last change to **client-rendered** data for the item
(title, images, enrichment, markers, …) — the max of the server's per-field change
times. A client can diff this one value to decide "changed since I cached it?"
without comparing every field. It **excludes** per-user playstate
(`resumePosition`), so progress reports don't invalidate the cache. Present at both
`detail=skeleton` and `detail=full`, in list and single-item responses.

`placeholder` is a self-describing one-of that may carry **any** low-res form. The
**reference server emits the `url` form** — a small pre-sized image link — so it
stores and processes no image bytes; the protocol equally allows
`{ "blurHash": "…" }` or a future form. **Clients should support both `blurHash`
and `url`** (decode a BlurHash locally; load a `url` image), using whichever the
server sent, and fall back to a plain background for forms they don't recognize.

### Open metadata (`extra`)

The canonical fields above are the neutral contract: each has a fixed meaning and
unit; a client only maps the *name* to whatever it calls the field internally.
Everything is optional — **a server sends only what it has**.

For anything beyond the canonical set, an item may carry an **`extra`** object of
arbitrary server-defined metadata. A client reads the keys it understands and
ignores the rest. Together with the forward-compatibility rules (unknown
top-level fields ignored, unknown enum strings tolerated), this is what lets a
server — or a server extension — **serve whatever metadata it wants** while older
clients keep working. `extra` is omitted entirely when empty.

---

## Planned

Defined in the protocol or roadmap but not yet implemented:

- Per-user watched/favorite state; browse sort & filter.
- `GET /v1/search`.
- Ranked `candidates` in the `/resolve` descriptor.
