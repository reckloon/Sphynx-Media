# Sphynx Server

**Status:** Draft / malleable — a structural map, not a spec. Names, boundaries, and storage choices below are starting points meant to be reshaped as the build reveals what's real.

Sphynx is an open-source **media-meta-server**: a drop-in replacement for the role Jellyfin/Plex play as a backend, minus the media byte plane. It indexes media living on remote storage or CDNs, identifies and enriches it, manages users and playstate, and hands clients a **direct playback location**. It never transcodes, proxies, or stores media bytes.

This document describes the server's own internals. The wire contract it speaks is in **Sphynx-Protocol.md**; the two are designed side by side.

---

## 1. What it is and isn't

**Is:** library indexing, content identification, metadata enrichment, user/auth, playstate, intro-marker lookup, and direct-location resolution.

**Isn't:** a transcoder, a byte proxy, a storage warehouse, or a player. The bytes live elsewhere (CDN / object storage / HTTP); Sphynx only ever describes *where* they are.

The single differentiator from Jellyfin/Plex: **it assumes the media is remote and direct-streamable**, so the entire transcode/segment/serve subsystem those servers carry simply doesn't exist here.

---

## 2. Subsystems (the shape)

```
                ┌──────────────────────────────────────────────┐
   admin ─────► │  Sources       remote locations to index      │
                └───────────────┬──────────────────────────────┘
                                │ scan
                ┌───────────────▼──────────────────────────────┐
                │  Indexer       enumerate → detect changes      │
                └───────────────┬──────────────────────────────┘
                                │ raw entries
                ┌───────────────▼──────────────────────────────┐
                │  Identifier    filename/metadata → TMDB id     │
                └───────────────┬──────────────────────────────┘
                                │ identified items
                ┌───────────────▼──────────────────────────────┐
                │  Enricher      TMDB metadata, artwork, intros  │
                └───────────────┬──────────────────────────────┘
                                │
                ┌───────────────▼──────────────────────────────┐
                │  Catalog       the queryable item store        │
                └───────┬───────────────────────┬──────────────┘
                        │                        │
        ┌───────────────▼──────┐     ┌──────────▼──────────────┐
        │  Resolver            │     │  Users / Playstate       │
        │  item → direct URL   │     │  accounts, auth, resume  │
        └───────────────┬──────┘     └──────────┬──────────────┘
                        │                        │
                ┌───────▼────────────────────────▼──────────────┐
                │  API           the Sphynx Protocol surface     │
                └────────────────────────────────────────────────┘
```

Each box is a seam, not a mandated service — they can collapse into one process or split out later.

---

## 3. Sources

A **Source** is an admin-configured place media lives and the credentials/rules to reach it. This is the analog of "point Jellyfin at a folder," except the folder is remote.

What a Source carries (malleable):

- An id and a human label.
- A **driver** identifying the backend kind (e.g. `http`, `s3`, `webdav`, `smb`, …). Drivers are pluggable; each knows how to *enumerate* and *resolve to a direct URL* for its kind.
- Connection config + secrets (kept out of logs, encrypted at rest).
- Optional scoping (which library a source feeds, path filters, include/exclude rules).

The driver interface is the extension point: a new backend = a new driver implementing "list entries" and "give me a direct, fetchable URL for this entry." Everything upstream is driver-agnostic.

> Open: whether a source maps to exactly one library or many; whether drivers live in-process or as plugins. Left undecided.

---

## 4. Indexer

Walks each Source's driver to produce **raw entries** (a path/key, size, container hint, timestamps), then diffs against what the Catalog already holds to detect **adds / removes / changes**. Cheap, metadata-only passes that never touch media bytes.

- Runs on a schedule and/or on demand.
- Produces a change set, not a full rewrite, so large libraries stay cheap.
- Carries enough hint data forward (container, filename) for the Identifier to do its job.

> Open: incremental vs full scans, change-detection signal (mtime / etag / size), concurrency limits per source.

---

## 5. Identifier *(the load-bearing subsystem)*

Turns a raw entry into a confident **TMDB id** (+ season/episode for TV). This is the perennial hard part of every media server — "why did it match the wrong movie" — and here it's load-bearing because **everything downstream keys off a correct TMDB id**: artwork, intro markers, dedup, cross-server identity.

Shape of the problem (tactics left open):

- Parse title/year/season/episode from filename and any embedded metadata.
- Query TMDB; rank candidates; pick or defer when ambiguous.
- Record confidence and provenance so low-confidence matches can be surfaced for manual correction.
- Support an admin override that pins an entry to a specific TMDB id.

> Open: matching heuristics, the ambiguity threshold, whether to lean on an existing parser library, fallback identity (IMDB / TVDB / hash) when TMDB can't resolve. This is where the real engineering judgment goes — keep it swappable.

---

## 6. Enricher

Given a TMDB id, fetch and cache the metadata the protocol exposes:

- Overview, year, runtime, genres, ratings, cast (with image refs).
- Artwork URLs (poster/backdrop/thumb) and a cheap **placeholder** (a generated BlurHash or a small thumbnail URL — the protocol carries either).
- **Intro/credit markers** via TheIntroDB, keyed by the same TMDB id. Cached server-side and shared across all clients so the upstream API isn't hammered; carry an API key; tolerate "no data" gracefully.

Enrichment is cache-with-TTL: refresh periodically, serve stale-but-present immediately.

**Manual edits are authoritative.** An admin (or anyone with `metadata.edit`) can
edit a field via `PATCH /v1/admin/items/{id}`, which **locks** that field: every
subsequent scan, TTL refresh, and forced enrich skips locked fields, so the edit
survives. This generalizes the per-item `identityPinned` / `markersAuthoritative`
provenance to every field. Unlocking a field re-enables automatic refresh.

> Open: TTLs per field class, artwork hosting (proxy-and-cache vs. hotlink refs), placeholder generation strategy.

---

## 7. Catalog

The queryable store the API reads from: libraries, items, their identity, enrichment, and parent/child structure. Backed by a normal database (SQLite for single-box simplicity; Postgres when multi-tenant).

Responsibilities:

- Hold items keyed by stable server id, carrying their TMDB id and enrichment.
- Answer browse queries (children of a container) cheaply, skeleton vs. full.
- Track parent/child links (series → season → episode, collection → items).
- Be the diff target for the Indexer.

> Open: schema specifics, whether skeleton/full are separate projections or one row, search backing (DB `LIKE` vs. FTS vs. external index).

---

## 8. Resolver

The late-bound handoff. Given an item, ask its Source's driver for a **direct, fetchable URL** (plus any required request headers and a TTL), and assemble the playback descriptor the protocol returns — including track hints and any intro markers.

- Called at play time, not during browse, so time-bounded URLs stay fresh.
- May return a single location or a ranked set of candidates (driver-dependent).
- Pure description: it resolves *where*, never moves bytes.

> Open: whether the resolver probes the source for track layout or trusts indexed hints; how candidates/failover are ordered; TTL enforcement.

---

## 9. Users, auth & security

The "basic but strong, proven" tier. Nothing bespoke.

- **Accounts:** username + password (argon2id/bcrypt). **Exactly one admin** — the
  bootstrap account, created on first run. It holds every permission implicitly and
  is the only admin: `createUser` always makes a non-admin, no account can be
  promoted, and the admin can't be demoted or deleted.
- **Sessions:** short-lived access token + rotating, revocable refresh token; **device-scoped** so one device can be revoked alone.
- **Authorization:** two layers.
  - *Per-user data* (playstate, contributions) is row-scoped to the token subject —
    a user can only ever read/write their own rows.
  - *Capabilities* are an **open per-user permission set** the admin grants: string
    keys, stored uniformly, forward-compatible (unknown keys tolerated). Well-known
    keys: `library.read` (browse + resolve/play), `metadata.markers.write`,
    `metadata.images.write`, `metadata.edit` (edit + lock fields). A key may be
    scoped to one library with a `:<libraryId>` suffix. Each gated action checks the
    caller's effective permission; the admin always passes. `GET /v1/auth/me`
    returns the user's effective permissions; `GET /v1/info` is the server-wide
    capability.
- **Self-service:** a user may change their own password (`POST /v1/auth/password`).
- **Transport:** TLS only; secrets encrypted at rest; rate limiting on auth and write endpoints; no secrets in logs.

> Open: whether to add OAuth/OIDC for SSO, invite vs. open registration.

---

## 10. Playstate

Per-user resume positions, written from the player's start/progress/stop lifecycle, read back into browse responses ("resume" / "continue watching").

- Stored as `(userId, itemId) → position, updatedAt`.
- A failed stop must not clobber a good resume point.
- Server is authoritative; clients mirror optimistically between syncs.

> Open: history/analytics retention, multi-device conflict policy (last-write-wins vs. furthest-position-wins), "watched" state and next-up derivation.

---

## 11. API layer

A thin HTTP surface implementing **Sphynx-Protocol.md**. It owns request auth, validation, the JSON envelope, and pagination — and delegates everything else to the subsystems above. Reusing the protocol's data types directly here keeps server and wire format from drifting.

Recommended (malleable) stack: a Swift server runtime (so the protocol value types can be shared with a client adapter) on mac + linux; or any HTTP framework if a smaller static binary matters more than type-sharing.

---

## 12. Deployment posture

- Single self-hosted box is the default unit (one admin, their sources, their users). SQLite + local process.
- Stateless API + external DB when it needs to scale horizontally.
- No media bytes ever transit the server, so resource needs are modest and bandwidth-light — the server is "brain, not muscle."

> Open: packaging (container vs. binary), config format, backup story for the Catalog + user DB.

---

## 13. Build order (suggested, not binding)

A spine-first path that yields something playable early:

1. **Auth + a single HTTP source driver + manual item entry** → end-to-end `login → resolve → play` against one known URL.
2. **Indexer + Catalog** → real browse from a scanned source.
3. **Identifier + Enricher (TMDB)** → posters, overview, correct identity.
4. **Playstate** → resume across sessions.
5. **Intro markers (TheIntroDB)** → skip UI lights up.
6. **More drivers, search, candidates, refinements** → breadth.

The two subsystems that deserve the most care, and the most room to change, are the **Identifier** (§5) and the **Source/driver model** (§3). Everything else is well-trodden.
