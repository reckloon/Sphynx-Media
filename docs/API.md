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
  `/v1/auth/{login,refresh,logout}`
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
    "events": true,
    "metadata": { "markers": "readwrite", "images": "read" },
    "fields": ["id", "type", "title", "tmdbId", "year", "images", "placeholder",
               "dateAdded", "updatedAt", "seriesId", "seriesTitle", "seasonIndex",
               "episodeIndex", "childCount", "parentId", "collectionId", "collectionTitle",
               "extra", "overview", "runtime", "genres", "communityRating", "officialRating",
               "cast", "originalTitle", "sortTitle", "tagline", "status", "premiereDate",
               "endDate", "studios", "directors", "writers", "countries", "tags", "trailers",
               "externalIds", "resumePosition", "watched", "playCount", "isFavorite",
               "lastPlayedAt"],
    "playstateReportInterval": 5
  }
}
```
`playstateReportInterval` (seconds) is the server's preferred client playback-report
cadence: a client that reports progress periodically SHOULD `POST` to
`/v1/playstate/{id}/progress` this often (default ~5s if absent). **Push-only** —
the server stores what the client sends and never polls the client. Reporting is
optional for the client; progress reports don't bump `Item.updatedAt`.
`events` advertises the additive server→client event stream (see [Events](#events-server-sent)).
Absent ⇒ `false`: the client falls back to polling.
A client treats unknown capability keys as ignorable and missing booleans as
`false`. **`metadata`** is the bi-directional access policy: a per-field map of
`none` | `read` | `readwrite` (open enum). A field absent from the map is `none`
— readable if served, but not contributable. See the [guide → Extending](https://reckloon.github.io/Sphynx-Media/#extending).

**`fields`** is the server's **coverage advertisement**: the canonical [`Item`](#item-shape)
field names it can populate (distinct from `metadata`, which is the read/write
*access* policy). It is **highly recommended** that:

- a **server lists every field it can serve** in `fields`, so clients know its
  coverage up front rather than discovering it by inspecting items, and
- a **client uses it to inform the user of unsupported features** — e.g. greying out
  a "Trailers" affordance when `fields` omits `trailers`.

An **absent or empty** `fields` means the server doesn't advertise coverage; a
client must then assume nothing and simply render whatever each item actually
carries. (The reference server advertises the full list above and deliberately
omits `criticRating` and `chapters`, which it does not populate — see
[Item shape](#item-shape).)

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
  "refreshExpiresIn": 2592000,
  "user": { "id": "u_…", "displayName": "admin" }
}
```
`expiresIn` is the **access**-token lifetime in seconds; `refreshExpiresIn`
(optional) is the **refresh**-token lifetime, so a client can pre-empt a forced
re-login instead of failing on first use. Both `login` and `refresh` return them.

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
| `sort` | `added` | A library's top level: `added` \| `name` \| `rating` |
| `order` | *(by sort)* | `asc` \| `desc` (default: name asc, added/rating desc) |
| `genre` | — | Top level only: keep items carrying this genre |
| `unwatched` | — | `true` ⇒ drop items the caller has marked watched |

Items fold the caller's per-user state: `resumePosition`, `watched`, `playCount`,
`isFavorite`, `lastPlayedAt` (see [Item shape](#item-shape)). `sort`/`genre` apply
to a library's top level; children of an item (seasons/episodes) keep their
natural order.

**200**
```json
{ "items": [ { "id": "it_…", "type": "movie", "title": "…", "year": 2008 } ],
  "nextCursor": "b2Zmc2V0OjUw" }
```
An absent `nextCursor` means the end of the list.

### `GET /v1/items/{itemId}?detail=full` — auth required

A single item. **404** `not_found` if absent. See [Item shape](#item-shape).

### Extras / bonus content

Trailers, featurettes, deleted scenes, behind-the-scenes clips, and interviews are
detected from the folder layout: any media under an extras bucket (`Featurettes/`,
`Extras/`, `Trailers/`, `Deleted Scenes/`, `Behind The Scenes/`, `Bonus/`,
`Interviews/`) is classified as the matching `type` (`trailer`, `featurette`,
`deletedScene`, `behindTheScenes`) rather than a standalone movie, and **nested
under its parent** via `parentId` — the enclosing title (a `Title (Year)/` folder
resolves to a movie, a bare `Title/` folder to a show). Extras don't appear in a
library's top-level grid; a client lists a title's extras with
`GET /v1/items?parent=<parentId>` (alongside a show's seasons).

### Collections / box sets

When a movie belongs to a TMDB collection, the server creates (or reuses, deduped
by collection id) a `collection`-typed item in that movie's library and links the
movie to it via `collectionId`/`collectionTitle` **and** the generic `parentId`. The
collection then appears at the library's top level; its members are browsed with the
existing `GET /v1/items?parent=<collectionId>`. No new endpoint — a collection is
just another container. Libraries may use the `boxSets`/`collection` kinds.

### `GET /v1/people/{personId}/items` — auth required

A person's filmography: the distinct movies and series the person is **credited in
the cast of**, for a client's person-detail screen (the inverse of an item's `cast`
array). `personId` is a cast-entry id of the form `pe_<tmdbId>`.

Returns the standard `ItemsResponse` (`{ items, nextCursor }`) with the normal item
projection (including `images.primary`), cursor-paginated, gated by the same
per-library read permissions as the other browse endpoints. Items are sorted
**newest-first** by premiere/production date (`premiereDate` when present, else
`year`), falling back to title — matching the Jellyfin client's `PremiereDate desc`
ordering, so both backends present a filmography identically.

- The lookup is **cast-only**: crew (directors/writers) are stored as plain names
  without a person id, so they aren't returned.
- A well-formed `pe_…` id always returns **200** with a possibly-empty `items` list
  (the server keeps no person registry, so "unknown person" and "known person with
  no credits" are indistinguishable). **404** is reserved for a malformed id.

---

## Changes (incremental sync)

### `GET /v1/changes` — auth required

Incremental sync without re-listing the library. Returns the items that changed
since a timestamp, plus **tombstones** for deletions.

| Param | Default | Meaning |
|-------|---------|---------|
| `since` | `0` (full sync) | Epoch seconds **or** an RFC 3339 timestamp — the `until` from a previous call |
| `cursor` | — | Opaque pagination cursor |
| `limit` | `50` | Page size |
| `detail` | `skeleton` | `skeleton` or `full` |

**200**
```json
{
  "changes": [ { "id": "it_…", "type": "movie", "title": "…" } ],
  "tombstones": [ { "id": "it_…", "deletedAt": "2026-06-28T12:00:00.000Z" } ],
  "until": "2026-06-28T12:00:01.234Z",
  "nextCursor": "b2Zmc2V0OjUw"
}
```

- `changes` are items whose **client-rendered** data changed after `since` (the same
  `updatedAt` notion — title/images/enrichment/markers; **not** per-user playstate),
  in change-time order, **permission-filtered** to libraries the caller can read.
- `tombstones` are deletions in the same window (`{ id, deletedAt }`), returned in
  full (not paginated). They're **id-only and not permission-filtered** — the item
  is already gone, so there's nothing to leak, and a client must see every deletion
  to stay consistent. Drop that id from your local cache.
- **The sync loop:** start at `since=0`; drain all pages of a window by following
  `nextCursor` while keeping the **same** `since`; then store `until` and pass it as
  the next `since`. `until` carries sub-second precision, so the loop is gap-free and
  never re-delivers boundary items.

---

## Markers (bi-directional)

Timeline-segment markers are **item-level** (shared across a server's clients) and
gated by `capabilities.metadata["markers"]`. See the
[guide → Extending](https://reckloon.github.io/Sphynx-Media/#extending) for the
contribution model (e.g. a client bridging TheIntroDB).

A marker maps a **segment type** to a `{ start, end }` window (seconds; `end`
optional for open-ended). The four well-known types are `recap`, `intro`,
`credits`, and `preview`. The type space is **open** — a server or extension may
contribute any segment type (e.g. `sponsor`); clients ignore types they don't
recognise. On the wire it's a flat object keyed by type.

### `GET /v1/items/{itemId}/markers` — auth; requires markers ≥ `read`

**200**
```json
{ "markers": { "recap": {"start":0,"end":30}, "intro": {"start":75,"end":145},
               "credits": {"start":9120}, "preview": {"start":9150,"end":9180} },
  "source": "theintrodb", "confidence": 0.95, "authoritative": false,
  "updatedAt": "2026-06-27T12:00:00Z", "stale": false }
```
**404** if the server doesn't offer markers, or none are stored for the item.

`stale: true` means the markers are older than the server's freshness window and a
client with a data source should re-fetch and `PUT` updated ones (see
[guide → Freshness](https://reckloon.github.io/Sphynx-Media/#ext-freshness)).
Authoritative markers are never stale.

### `PUT /v1/items/{itemId}/markers` — auth; requires markers == `readwrite`

**Body** `{ "markers": { "recap": {…}, "intro": {…}, "credits": {…}, "preview": {…} }, "source": "…", "confidence": 0.9 }`
→ **200** with the stored [MarkersInfo]. Any segment type is accepted, including
custom ones beyond the four well-known.

- **403** `forbidden` if the server is read-only for markers, **or the user
  hasn't been granted `metadata.markers.write`** for the item's owning library
  (per-user; a global or `:<libraryId>`-scoped grant both satisfy it, scoped like
  `metadata.edit`; admins always have it). Check `GET /v1/auth/me`.
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
  "terminal": true
}
```
- `url` — DIRECT location; the client streams this itself. Resolved fresh on every
  call and **never stored** — the server keeps only the item's source reference.
- `headers` — headers the client must send when fetching `url`.
- `terminal` — if true, `url` is the driver's final location: fetch it directly,
  with no further Sphynx resolve step. The driver's own assertion about what it
  produced, *not* a probe of the origin — it says nothing about ordinary HTTP
  redirects (the client's HTTP stack follows those) or timing (resolution is
  always fresh at play time). Absent/false means resolve `url` yourself first.
- `ttl` (time-to-live, seconds) — *optional.* When the source returns a time-bounded link (e.g. a signed
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

### `DELETE /v1/playstate/{itemId}`
**Clear resume / remove from Continue Watching.** Deletes the caller's stored
playstate for the item, so its `resumePosition` reads back as 0 and it drops out of
`GET /v1/home/continue`. **204 No Content**; idempotent (deleting when nothing is
stored is still 204). Only ever affects the caller's own row.

> `resumePosition` is also folded into item responses (browse list + single item)
> for the authenticated user as a convenience snapshot — but it does **not** move
> `Item.updatedAt`, so a cached value can be stale. `/v1/playstate` is the
> authoritative source; read it (single or batch) when you need the current
> position (e.g. to resume playback), and use the folded `resumePosition` for
> display hints only.

## Home feed

### `GET /v1/home` — auth required

The **typed home feed**: the ordered shelves that make up the user's home screen.
**200** → `{ "shelves": [ { "id", "title", "kind", "aspect", "items": [...] } ] }`.

Each shelf carries a `kind` (open enum: `continueWatching`, `recentlyAdded`,
`favorites`) and an `aspect` (`portrait` | `landscape` | `square`) telling the
client the tile shape — so which rows are landscape is **contract, not
convention**. `continueWatching` is `landscape` (backdrops / episode stills);
the rest are `portrait`. Empty shelves are omitted. Each shelf shows a capped
preview (20 items); page a full row via the per-row endpoints below.

> **Continue Watching is unified — there is no separate "Next Up".** The next
> unwatched episode of a show you're partway through is merged *into*
> `continueWatching` alongside in-progress movies and episodes, as one
> recency-ordered list. There is deliberately **no `nextUp` shelf kind**, and a
> client must not expect one to appear. Render a single "Continue Watching" /
> "Up Next" row.

### `GET /v1/home/continue` — auth required

The full, paginated **Continue Watching** row: the user's in-progress items
(stored position > 0) **plus the next unwatched episode** of each show they've
started — one unified list, **most-recently-played first**. `resumePosition` is
folded in (`0` for a next-up episode — a fresh start, not a resume).
Cursor-paginated; `detail` selects skeleton/full. Returns the same
`ItemsResponse` shape as `/v1/items`.

Next-up rules: a show with an **in-progress** episode is represented by that
episode (resume wins — its next-up is suppressed); a show whose latest watched
episode is finished is represented by its **next regular-season episode**
(specials, season 0, don't generate a next-up). A finished movie does not
reappear.

The server only stores and exposes the data (per-user position + `updatedAt`,
ordered by recency) — **the client owns presentation and policy**: it has each
item's runtime, so it decides what counts as "finished", whether to hide it, how
to sort, etc. A client that wants raw timestamps for its own logic can read them
via `GET /v1/playstate?items=…` (each entry carries `updatedAt`).

### `GET /v1/home/recent` — auth required

**Recently Added**: top-level items (movies + series) newest first, per-user state
folded in. Cursor-paginated; `detail` selects skeleton/full. Same `ItemsResponse`
shape.

### `GET /v1/home/favorites` — auth required

The caller's favourited items, most-recently-played first. Cursor-paginated; same
`ItemsResponse` shape.

## Per-user state

### `PUT /v1/items/{itemId}/state` — auth required

Set the caller's state for an item (row-scoped to the subject). **Body** (any
subset) `{ "watched": true, "isFavorite": true }` → **200** with the item, the new
state folded in. `403` if the caller can't read the item's library. Play count and
last-played are tracked server-side from playback (a non-failed
`POST /v1/playstate/{id}/stop` bumps them); `watched` / `isFavorite` are explicit
here.

---

## Events (server-sent)

### `GET /v1/events` — auth required

An **additive** server→client event stream over [Server-Sent Events](https://developer.mozilla.org/docs/Web/API/Server-sent_events)
(`Content-Type: text/event-stream`). Purely a live-update convenience: it lets a
client keep UI fresh (continue-watching, now-playing, watched/favorite sync)
without polling, and never replaces the access-controlled REST endpoints. Advertised
by `capabilities.events`; a client that ignores it (or a server that doesn't offer
it) keeps working by polling.

The connection is scoped to the authenticated subject, and **each event is
filtered by access**: per-user events (`playstate`, `useritemstate`) go only to the
subject's own connections; item/library events (`markers`, `library`) reach only
connections that may read that library (a `null` library is admin-only — the same
fail-closed rule as item reads). The server sends a comment heartbeat (`: ping`)
roughly every 15s (`SPHYNX_EVENTS_HEARTBEAT`) to keep the connection warm; clients
reconnect with the browser `EventSource` default behaviour.

Each non-comment frame is `event: <type>` + a one-line JSON `data:` payload with a
stable `type` discriminator and `ts` (epoch seconds). Unknown `type`s and unknown
fields are ignorable, so new event kinds are forward-compatible. Nil fields are
omitted.

```
: connected

event: playstate
data: {"type":"playstate","itemId":"it_42","position":531.0,"ts":1719536400.12}

event: useritemstate
data: {"type":"useritemstate","itemId":"it_42","watched":true,"isFavorite":false,"playCount":3,"ts":1719536402.55}

event: markers
data: {"type":"markers","itemId":"it_42","libraryId":"lib_tv","ts":1719536410.0}

event: library
data: {"type":"library","libraryId":"lib_tv","action":"scanned","ts":1719536500.0}

: ping
```

| `type` | Audience | Emitted when | Key fields |
|---|---|---|---|
| `playstate` | subject | `start` / `progress` / `stop` reported | `itemId`, `position` |
| `useritemstate` | subject | watched/favorite set, or a play recorded on stop | `itemId`, `watched`, `isFavorite`, `playCount` |
| `markers` | library readers | a marker contribution is stored | `itemId`, `libraryId` |
| `library` | library readers | a scan completes, or a library is added/updated/removed | `libraryId`, `action` (`scanned` \| `added` \| `updated` \| `removed`) |
| `heartbeat` | — | keep-alive | sent as an SSE comment, not a `data:` frame |

`markers` / `library` are **nudges**: on receipt a client re-fetches via the normal
access-controlled endpoint (e.g. `GET /v1/home/recent`, `GET /v1/items/{id}/markers`)
rather than trusting the event as data. The stream is a transport for *liveness*,
not a second source of truth.

---

## Admin (server-specific, not part of the wire protocol)

Catalog setup, indexing, manual entry, and server settings. **Auth required**, and
the **admin role** unless noted — the item-edit `PATCH` is gated by the
`metadata.edit` permission instead. `403 forbidden` otherwise.

### `GET /v1/admin/settings`

The current persisted runtime settings (configured here rather than via env vars;
env vars only seed them on first run). **200** →
```json
{ "serverName": "…", "serverID": "…", "accessTokenTTL": 3600,
  "refreshTokenTTL": 2592000, "enrichmentTTL": 7776000, "markersAccess": "readwrite",
  "markersStaleAfter": 604800, "playstateRetention": 31536000, "maintenanceInterval": 86400 }
```

### `PATCH /v1/admin/settings`

Update any subset of the runtime settings. **Body** e.g.
`{ "serverName": "My Library", "markersAccess": "read", "enrichmentTTL": 1209600 }`
→ **200** with the full updated settings. Persisted; applies on the next restart.
**400** if `markersAccess` isn't `none`/`read`/`readwrite`. Startup/secret values
(host, port, DB path, admin bootstrap, TMDB key) remain environment variables.

### `POST /v1/admin/libraries`

**Body** `{ "title": "Movies", "kind": "movies" }` (`kind` defaults to `other`).
**200** → `{ "id": "lib_…", "title": "Movies", "kind": "movies" }`.

### `GET /v1/admin/libraries`

List all libraries. **200** → `{ "libraries": [ { "id": "lib_…", "title": "…", "kind": "…" }, … ] }`.

### `PATCH /v1/admin/libraries/{libraryId}`

Update a library. **Body** (any subset) `{ "title": "…", "kind": "…" }` → **200**
with the updated library.

### `DELETE /v1/admin/libraries/{libraryId}`

**Cascade.** Deletes the library and every item it holds, then **unbinds** it from
any source that feeds it — a source that also feeds another library survives (with
this library removed from its routing); a source left feeding no library at all is
deleted. **204** on success.

### `POST /v1/admin/sources`

**Body**
```json
{ "label": "My CDN", "driver": "http", "baseURL": "https://cdn.example",
  "headers": { "Authorization": "…" },
  "libraryMap": { "movie": "lib_movies", "tv": "lib_tv" },
  "manifestURL": "https://cdn.example/manifest.json",
  "refreshInterval": 1800 }
```
`driver` defaults to `http`. `manifestURL` points to a JSON document (the *manifest*) that lists the entries to index — metadata only, never the media bytes.
`refreshInterval` (seconds, `0` = manual only) sets this source's **auto-refresh**:
a background loop re-scans the source on its own cadence. `SourceResponse` echoes
`refreshInterval` and `lastScannedAt`; `PATCH` accepts `refreshInterval` too. (The
web admin shows it in minutes.)

A source feeds a library by content **category**: `libraryMap` routes each item
to a library by type (`movie` / `tv`), so **one source + one scan** fills a Movies
library and a TV library from the same folder — a single driver walk, items split
by detected type (movies → `/movie`, TV → `/tv` enrichment). `libraryId` (single
library) is still accepted and acts as the fallback for any unmapped category.

**200** → `{ "id": "src_…", "label": "...", "driver": "http", "config": { … },
"libraryId": …, "libraryMap": { … } }` — only non-secret fields are returned.

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

### `GET /v1/admin/sources`

List all sources (non-secret fields only). **200** →
`{ "sources": [ { "id": "src_…", "label": "…", "driver": "http", "config": { … } }, … ] }`.

### `PATCH /v1/admin/sources/{sourceId}`

Update a source. **Body** (any subset)
`{ "label": "…", "baseURL": "…", "manifestURL": "…", "libraryId": "…", "libraryMap": {…}, "headers": {…}, "config": {…}, "secrets": {…} }`
— any map given (`libraryMap`/`headers`/`config`/`secrets`) replaces the stored
one. **200** → the updated source (secrets withheld).

### `DELETE /v1/admin/sources/{sourceId}`

**Cascade.** Deletes the source, the items it produced, and any series/season
containers those items leave empty. **204** on success.

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
`{ "sourceId": "src_…", "scanned": 12, "added": 3, "updated": 1, "removed": 0, "enriched": 3 }`
(`enriched` is the count identified+enriched during the scan; `0` when TMDB isn't configured).

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
`?force=true` ignores the freshness TTL and re-fetches **every** identified item —
use it to backfill new artwork roles after a server upgrade ("refresh all artwork").

> The three enrichment endpoints require TMDB to be configured
> (`SPHYNX_TMDB_API_KEY`); otherwise they return **400** `bad_request`.

### `POST /v1/admin/items`

**Body**
```json
{ "title": "Big Buck Bunny", "type": "movie", "container": "mp4",
  "sourceId": "src_…", "sourceKey": "path/or/absolute-url", "tmdbId": "...",
  "libraryId": "lib_…", "parentId": "it_…", "year": 2008,
  "extra": { "anything": [1, 2, 3] } }
```
- `title` and `sourceKey` are the only required fields.
- `sourceKey` — an absolute URL (self-contained) **or** a key relative to the
  source's `baseURL`.
- `sourceId` — optional; omit it when `sourceKey` is an absolute URL.
- `type` defaults to `movie`.
- `libraryId` — optional; the library this item belongs to (top-level browse membership).
- `parentId` — optional; a parent item id to nest under (e.g. an episode under a season).
- `year` — optional release year.
- `extra` — optional open map of server-defined metadata, stored and projected onto the item's `extra`.

**200** → the created [`Item`](#item-shape).

### `DELETE /v1/admin/items/{itemId}`

**Cascade.** Deletes the item and its whole subtree (a series takes its seasons +
episodes), then prunes any container the deletion leaves empty. **204** on success.
An item still listed by its source reappears on the next scan — the source is the
source of truth.

### Diagnostics — all `GET`, admin-only

These power the web admin's activity dashboard, log viewer, and database browser.
They are server-specific (not part of the wire protocol).

- **`GET /v1/admin/status`** → an activity snapshot (current parse/enrich activity
  and recent counters).
- **`GET /v1/admin/logs?after=<seq>&limit=<n>&level=<level>`** → recent diagnostics
  log lines: `{ "lines": [ … ], "latestSeq": <n> }`. `after` pages by sequence
  (default-ish `limit` 200, max 1000); `level` filters by log level.
- **`GET /v1/admin/db/tables`** → `{ "tables": [ { "name": "item", "rowCount": 42 } ] }`
  for the user tables.
- **`GET /v1/admin/db/query?table=<name>&limit=<n>&offset=<n>`** → a read-only page of
  one table: `{ "table", "columns", "rows", "total", "limit", "offset", "redactedColumns" }`.
  The table name is whitelisted against the real schema (no SQL injection) and
  secret columns (credentials) are redacted. `limit` max 200.

### Extensions — admin-only

Extensions are optional, self-contained server capabilities outside the wire
protocol, each with its own config. The web admin "Extensions" tab renders one
module per entry. Server-specific — a client never needs these.

- **`GET /v1/admin/extensions`** → the registry the UI renders:
  `{ "extensions": [ { "id", "name", "description", "kind", "enabled", "available", "configurable" } ] }`.
  `kind` is `builtin` (always on, e.g. `diagnostics`) or `optional` (toggleable);
  `available` reflects whether prerequisites are met (e.g. `ffprobe` installed).

**Media probe** (`id: media-probe`) — inspects a title's tracks with ffmpeg's
`ffprobe`, surfacing the language / codec / channel detail the protocol's bare
`tracks` indices can't carry, plus sidecar subtitle files. Opt-in (disabled by
default); shelling out only happens when enabled and `ffprobe` is found.

- **`GET /v1/admin/extensions/media-probe`** → `{ "enabled", "ffprobePath", "resolvedPath", "available", "version" }`.
  `ffprobePath` is the admin-set path (blank ⇒ auto-discovered); `resolvedPath` is
  the path actually in use.
- **`PATCH /v1/admin/extensions/media-probe`** `{ "enabled"?, "ffprobePath"? }` →
  the updated config. Persisted; applied live (no restart).
- **`GET /v1/admin/extensions/media-probe/probe?itemId=<id>`** → resolves the item
  to its direct location (as a player would), runs `ffprobe`, and returns
  `{ "itemId", "probedURL", "prober", "formatName", "durationSeconds", "streams": [ { "index", "kind", "codec", "language", "title", "channels", "isDefault", "isForced" } ], "externalSubtitles": [ { "url", "language", "format" } ] }`.
  Returns **400** when the extension is disabled or `ffprobe` isn't available.

**Metadata / TMDB** (`id: tmdb`) — the TMDB v3 API key used for identification +
enrichment, configurable here instead of via the environment.

- **`GET /v1/admin/extensions/tmdb`** → `{ "configured", "keyHint", "appliesOnRestart" }`
  (the key itself is **never** returned — only whether one is set and a short hint).
- **`PATCH /v1/admin/extensions/tmdb`** `{ "apiKey" }` → stores the key (seeded once
  from `SPHYNX_TMDB_API_KEY`; DB-authoritative thereafter). Takes effect on the next
  server restart.

---

## Errors

Every non-2xx response uses this envelope:

```json
{ "error": { "code": "unauthorized", "message": "Token expired.", "retryable": false } }
```

Clients branch on `code`, not `message`. Codes in use:
`unauthorized`, `forbidden`, `not_found`, `no_media_source`, `rate_limited`,
`server_error`, `unavailable`, and the open values `bad_request` and `conflict`.
Unknown codes must be tolerated.

`error.retryAfter` (optional, seconds) is a **backoff hint** the client SHOULD wait
before retrying. It's set only where the server knows one — currently `rate_limited`
(HTTP 429) and `unavailable` (HTTP 503) — and omitted otherwise. When present, the
same value is also sent as the standard HTTP `Retry-After` header (integer seconds).
Prefer honoring it over guessing; treat its absence as "no specific guidance".

```json
{ "error": { "code": "rate_limited", "message": "Slow down.", "retryable": true, "retryAfter": 5 } }
```

---

## Item shape

All fields except `id`, `title`, `type` are optional; the server sends what it
has, and every field is omitted when empty. The canonical set is deliberately
broad — matching what mainstream clients display — so a client can rely on these
names; anything beyond them rides in `extra`. A *skeleton* item carries the tile
fields (images, placeholder, year, `dateAdded`) and omits the heavier enrichment
(overview, genres, ratings, cast, studios, …).

> **Skeleton contract.** Although `detail=` is a bandwidth hint, the reference
> server **guarantees** that a `detail=skeleton` item omits *every* enrichment
> field (overview, genres, ratings, cast, runtime, tagline, studios, directors,
> writers, countries, externalIds, …). Clients may therefore treat the absence of
> an enrichment field — e.g. `genres == null` — as a reliable "not yet enriched"
> signal and decide whether to fetch `detail=full`. A server that wants this to
> hold for its clients must do the same (never emit enrichment in a skeleton).

```json
{
  "id": "it_…",
  "type": "movie",
  "title": "Blade Runner 2049",
  "tmdbId": "335984",
  "originalTitle": "…", "sortTitle": "…", "tagline": "…",
  "overview": "…", "year": 2017, "runtime": 9840.0,
  "images": { "primary": "…", "backdrop": "…", "thumb": "…", "logo": "…", "banner": "…" },
  "placeholder": { "url": "…/tiny.jpg" },
  "seriesId": "…", "seriesTitle": "…", "seasonIndex": 1, "episodeIndex": 3, "childCount": 10,
  "parentId": "it_…", "collectionId": "it_…", "collectionTitle": "…",
  "genres": ["Sci-Fi"], "communityRating": 8.0, "criticRating": 88, "officialRating": "R",
  "cast": [ { "id": "pe_…", "name": "Ryan Gosling", "role": "K", "imageURL": "…", "placeholder": { "url": "…/tiny.jpg" } } ],
  "directors": ["…"], "writers": ["…"], "studios": ["…"], "countries": ["…"], "tags": ["…"],
  "trailers": ["https://…"], "chapters": [ { "start": 0.0, "title": "Intro" } ],
  "status": "Released", "premiereDate": "2017-10-06", "endDate": "…",
  "dateAdded": "2026-06-27T12:00:00Z",
  "externalIds": { "imdb": "tt1856101", "tvdb": "…" },
  "resumePosition": 1342.5, "watched": true, "playCount": 3, "isFavorite": true, "lastPlayedAt": "2026-06-27T12:00:00Z",
  "updatedAt": "2026-06-27T12:00:00Z",
  "extra": { "anything": [1, 2, 3] }
}
```

The example above shows the **full protocol shape** — every field is optional and
omitted when empty. The **reference server** currently populates the TMDB-derived
fields (overview, year, runtime, genres, `communityRating`, `officialRating`, cast
— including **TV** series/episodes — directors/writers, studios, countries, tagline,
status, premiereDate/endDate, `externalIds.imdb`, `sortTitle`, `tags`, `trailers`,
images incl. `logo`/`banner`) plus `parentId`/`collectionId` and per-user state. It
does **not** populate `criticRating` or `chapters` — those are reserved for richer
servers or extensions (or ride in `extra`); clients must render fine without them.
(See `capabilities.fields` in [`/v1/info`](#-get-v1info--unauthenticated) for the
machine-readable coverage list.)

#### Image roles

`images` carries neutral roles, all optional — a server sends the forms it has, a
client uses the ones it recognises. Each role has a defined **orientation**, so a
client knows which to reach for when laying out a portrait tile vs a landscape one:

| Role | Orientation | Intended use |
|------|-------------|--------------|
| `primary` | **Portrait** poster (~2:3). **Exception:** an **episode**'s `primary` is its **landscape** still (episodes have no poster). | The main poster / tile |
| `backdrop` | **Landscape** (~16:9), large | Full-bleed hero / background |
| `thumb` | **Landscape** (~16:9), card-sized | Horizontal tiles & rows (e.g. **Continue Watching**) |
| `logo` | Transparent title logo (wide) | Title art overlaid on a backdrop |
| `banner` | Wide banner strip | Banner-style headers |

**`thumb` is a landscape card image, not a small poster.** A client building a
horizontal row (Continue Watching, Up Next) uses `thumb` (card-sized) or `backdrop`
(full-bleed); a portrait grid uses `primary`. The reference server fills:

- **movies / series** → `primary` (poster) + `backdrop` and `thumb` (both from the
  TMDB backdrop — large and card-sized) + `logo`/`banner` when TMDB has them;
- **seasons** → `primary` (season poster) + `backdrop`/`thumb` inherited from the
  show's wide art;
- **episodes** → `primary` and `thumb` from the episode **still** (already
  landscape) + `backdrop` from the show.

So every enriched item carries both a **portrait** option (`primary`, except
episodes) and a **landscape** option (`thumb` + `backdrop`). `placeholder` (top
level) is a tiny low-res stand-in for the item's `primary` image while it loads.

**Per-image variants.** Alongside the flat URL fields, `images.variants` is an
optional map keyed by role name carrying **per-image** metadata, so a client can
blur-up and lay out *each* image independently — not just the poster:

```json
"images": {
  "primary": "…/w500/poster.jpg",      // flat fields unchanged (back-compat)
  "backdrop": "…/w1280/back.jpg",
  "thumb": "…/w780/back.jpg",
  "variants": {
    "primary":  { "url": "…/w500/poster.jpg", "placeholder": { "url": "…/w92/poster.jpg" }, "aspect": 0.667 },
    "backdrop": { "url": "…/w1280/back.jpg",  "placeholder": { "url": "…/w300/back.jpg" },  "aspect": 1.778 },
    "thumb":    { "url": "…/w780/back.jpg",   "placeholder": { "url": "…/w300/back.jpg" },  "aspect": 1.778 }
  }
}
```

Each `ImageInfo` carries `url`, an optional `placeholder` (same one-of as the
top-level one — the reference server sends the `url` form), and an optional
`aspect` (width ÷ height: ~`0.667` portrait, ~`1.778` landscape). `width`/`height`
are reserved (absent unless the server knows exact dimensions). The map is **open**
— clients tolerate role keys they don't recognise. The flat role fields remain the
URL source of truth, so a client that only reads `images.primary` keeps working.

`parentId` is the generic up-link: the container an item nests under when it isn't
the TV season/series relationship — a bonus/extra under its movie or show, or a
movie under its collection. Browse an item's children with `?parent=<id>`.
`collectionId`/`collectionTitle` mark box-set membership (the collection itself is a
`collection`-typed item). `sortTitle`, `tags`, and `trailers` are sent at
`detail=full`; `logo`/`banner` and the collection fields ride along at any detail.

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

Defined in the protocol but not yet implemented by the reference server:

- `GET /v1/search` (`capabilities.search`).
- Ranked `candidates` in the `/resolve` descriptor (`capabilities.candidates`).

All five source drivers now both resolve **and** list: `local`, `http`
(JSON manifest), `webdav` (`PROPFIND` over the built-in HTTP client), `smb` (via
`smbclient`), and `ftp` (via `curl`). SMB/FTP listing needs `smbclient`/`curl` on
the server's `PATH`; resolve/playback work without them. Configure sources in the
web admin's **Extensions → Storage** tabs (one per driver) or via
`POST /v1/admin/sources`.
