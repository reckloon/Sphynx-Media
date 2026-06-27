# Extending Sphynx

Sphynx is designed so that **metadata can grow without breaking anyone**. This
guide covers the three ways the system extends, in order of how often you'll
reach for them:

1. [Reading new metadata — no extension needed](#1-reading-new-metadata)
2. [Client-side contribution (write) — e.g. TheIntroDB](#2-client-side-contribution)
3. [Server-side extension (self-write) — e.g. an intro detector](#3-server-side-extension)

Underpinning all three is one idea: **the protocol's canonical fields are neutral
and optional, and everything else is open.** A server serves whatever metadata it
has; a client consumes what it understands and ignores the rest.

---

## 0. The access model

`GET /v1/info` advertises a per-field access policy:

```jsonc
"capabilities": {
  "playstate": true,
  "metadata": {
    "markers": "readwrite",   // clients may read AND contribute
    "images":  "read"         // clients may read only
  }
}
```

`MetadataAccess` is an **open enum**: `none` | `read` | `readwrite` (+ unknown
future values). A field **absent** from the map means `none` — the client may
still read whatever the server happens to include on an item, but there's no
contribution endpoint advertised. Each server decides its own policy (one server
allows marker contributions, another is read-only, etc.). The reference server
sets it from config (`SPHYNX_MARKERS_ACCESS`).

`capabilities.metadata` advertises what the **server** supports. Write access is
then granted **per user by an admin** (`POST /v1/admin/users/{id}/grants`), so two
users on the same server can have different write permissions. A client learns its
**own effective access** from `GET /v1/auth/me`:

```jsonc
// GET /v1/auth/me
{ "user": { "id": "u_…", "displayName": "Bob" },
  "metadata": { "markers": "readwrite", "images": "read" } }
```

A client should **check `/v1/auth/me` before offering a "fix this"/"contribute"
affordance** (not `/v1/info`, which is the server-wide capability), and gracefully
degrade when its effective access is `read`/`none`. Effective write =
server advertises the field `readwrite` **and** the user is granted it (admins are
always granted).

---

## 1. Reading new metadata

**Clients need no extension to read new metadata.** Two mechanisms guarantee it:

- **Canonical fields are optional and neutral.** When the server starts sending a
  field a client already models (say `officialRating`), the client just reads it.
  The field's meaning and unit are fixed by the protocol; the client only maps the
  *name* to its own internal model.
- **Open `extra` bag + forward-compatible decoding.** Anything outside the
  canonical set rides in `item.extra` (arbitrary JSON). Unknown top-level fields
  are ignored; unknown enum strings decode to `.unknown(...)`. So a server — or a
  third-party server extension — can expose *any* metadata and older clients keep
  working; newer clients opt in by reading the keys they care about.

```jsonc
// A server exposing data beyond the canonical schema:
{ "id": "it_1", "type": "movie", "title": "Alien",
  "extra": { "imdbId": "tt0078748", "tagline": "In space…", "dolbyVision": true } }
```

A client that knows `extra.dolbyVision` shows an HDR badge; one that doesn't
ignores it. **No versioning, no negotiation, no breakage.**

> Rule of thumb: if you only want to *read* a new field, you don't need an
> extension at all — just read it (canonical field) or read `extra.<key>`.

---

## 2. Client-side contribution

When a server advertises a field as `readwrite`, clients may **contribute**
metadata back. This is how data that must be sourced client-side reaches the
server and gets shared with everyone.

### Worked example: TheIntroDB → Sphynx

[TheIntroDB](https://theintrodb.org/docs) requires a **client-only** integration —
a *server* must not call it. Sphynx respects that by never fetching it
server-side. Instead the client bridges it:

1. Client plays an item with a `tmdbId`.
2. Client (per TheIntroDB's terms) fetches intro/credit markers from TheIntroDB.
3. Client checks `capabilities.metadata["markers"] == "readwrite"`.
4. Client contributes them to Sphynx:

   ```http
   PUT /v1/items/{itemId}/markers
   Authorization: Bearer <token>
   Content-Type: application/json

   { "markers": { "intro": {"start":75,"end":145}, "credits": {"start":9120} },
     "source": "theintrodb", "confidence": 0.95 }
   ```

5. Sphynx stores them **item-level**, so every other client on that server now
   gets the markers — in `GET /v1/items/{id}/markers` and folded into
   `GET /v1/resolve/{id}` — **without** each client having to call TheIntroDB.

The contribution carries **provenance** (`source`, `confidence`, and the
contributing user). Client contributions are best-effort: the server records them
but marks them non-`authoritative`, and **refuses to let a client overwrite
authoritative markers** (409 Conflict) — see §3.

### Adding a new contributable field (client side)

1. Confirm the server advertises it `readwrite` in `capabilities.metadata`.
2. `PUT` the field to its contribution endpoint (or, for open data, write to
   `extra` via the item — see the field's docs).
3. Handle `403` (read-only), `409` (would clobber authoritative), `404` (not
   offered) by degrading gracefully.

---

## 3. Server-side extension

A server (or a server *extension*) can **write metadata itself** — e.g. an
**intro detector** that analyses media and produces markers, or an enricher that
pulls from a source TheIntroDB-style integrations can't. These writes go through
the server's internal catalog API, not the public HTTP contribution endpoint, and
are marked **authoritative** so client contributions won't override them.

> The reference server does not ship an intro detector — this section documents
> the seam so one can be added as an extension.

### The seam

The reference server already separates "store markers" from "the HTTP endpoint":

- `ItemRecord` carries `markersJSON` + provenance (`markersSource`,
  `markersConfidence`, `markersAuthoritative`, `markersContributedBy`,
  `markersUpdatedAt`).
- `Catalog.updateItem(_:)` persists them.

A detector extension would:

1. Run after enrichment (it has the resolved media URL from a driver and the
   `tmdbId`).
2. Analyse audio/video to find the intro/credits windows.
3. Write them authoritatively:

   ```swift
   var item = try await catalog.item(id: itemId)!
   item.markersJSON = encode(Markers(intro: .init(start: 75, end: 145)))
   item.markersSource = "intro-detector"
   item.markersConfidence = 0.9
   item.markersAuthoritative = true        // server-detected → wins over client
   item.markersUpdatedAt = now
   try await catalog.updateItem(item)
   ```

Because `markersAuthoritative == true`, a later client `PUT` is rejected with
`409 Conflict` (only an admin can override). This is the precedence policy in one
sentence: **server-detected / admin-pinned beats best-effort client
contributions.** A server is free to implement a richer merge (per-field, voting,
recency) — the provenance fields are there to support it.

### Adding a new server-written field end to end

1. **Storage**: add column(s) to the relevant record + a migration.
2. **Access**: add the field to `AccessPolicy` (advertise `read` or `readwrite`).
3. **Read**: surface it on the item projection / a `GET` endpoint / `/resolve`.
4. **Write**: a contribution endpoint (if client-writable) and/or an internal
   write path for the extension.
5. **Provenance**: record source + authority so precedence stays sane.
6. **Docs**: note the field's meaning, unit, and access in `API.md`.

If the field is niche/server-specific, skip the canonical schema and use
`item.extra` instead — clients read it without any protocol change (§1).

---

## 4. Freshness & expiry

Metadata goes stale. Sphynx keeps it fresh along the **same ownership split** as
contribution — whoever can *fetch* the data is responsible for *refreshing* it:

### Server-owned data — the server refreshes it

Data the server can re-fetch itself (TMDB enrichment: posters, overview, cast)
carries a freshness window (`SPHYNX_ENRICH_TTL`, default **90 days**). A background
**maintenance pass** (`SPHYNX_MAINTENANCE_INTERVAL`, default daily) re-fetches
anything older. The client does nothing.

### Client-owned data — the server flags it, the client refreshes it

Data only a client can fetch (intro/credit markers from a client-only source like
TheIntroDB) can't be refreshed server-side. Instead the server **reports
staleness** and the client refreshes it:

- `GET /v1/items/{id}/markers` returns `stale: true` once markers pass
  `SPHYNX_MARKERS_STALE_AFTER` (default **7 days**). Absent markers simply 404.
- A client that has a data source should, on `stale: true` **or** 404, re-fetch
  and `PUT` updated markers — closing the loop. So a "skip intro" that didn't
  exist when the item was first added gets filled in the next time a capable
  client plays it, and a week-old marker gets refreshed the same way.

This is the freshness counterpart to §2/§3: clients refresh what only they can
fetch; the server refreshes what it can.

### …except when overwritten

Refresh never clobbers higher-authority data:

- The maintenance pass only touches **server-owned** fields — it never overwrites
  client contributions.
- **Authoritative** markers (server-detected / admin-pinned) are **never reported
  `stale`**, so clients don't try to refresh (or clobber) them.

### Retention

Per-user playstate untouched for `SPHYNX_PLAYSTATE_RETENTION` (default **365
days**) is purged by the maintenance pass — old "continue watching" entries
expire on their own.

---

## Summary

| You want to… | Do this | Need an extension? |
|---|---|---|
| Read a field the server added | Just read it (canonical) or `extra.<key>` | **No** |
| Contribute data the server allows | `PUT` to its endpoint when `readwrite` | Client-side only |
| Have the server generate data | Internal write path, marked authoritative | Server-side |

The throughline: **neutral, optional canonical fields + an open `extra` bag +
a per-field access policy** = servers and clients evolve independently without
breaking each other.
