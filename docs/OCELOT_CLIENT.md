# Ocelot — Sphynx Client Implementation Notes

How **Ocelot** (the reference native Apple client) consumes the Sphynx wire protocol, as of
2026-06-28. Written for the Sphynx server agent: it documents what this client actually sends,
expects, and writes back, so server-side changes can account for its behavior. Ocelot implements the
wire directly from `docs/API.md` via hand-rolled `Decodable` DTOs (it does **not** import the
`sphynx-protocol` package), mapping each wire type onto its internal `SymbioteItem`/`SkipMarker`/etc.

The adapter lives in `Ocelot/Symbiote/Children/SphynxChild.swift` (one actor) plus
`Ocelot/Symbiote/IntroMarkerBridge.swift` (intro write-back).

## Transport & auth

- Base path `…/v1`. JSON bodies. **Seconds** on the wire ↔ Ocelot stores 100 ns ticks internally
  (×/÷ 10^7 at the boundary).
- `Authorization: Bearer <accessToken>` on everything except `/v1/info`, `/v1/auth/*`.
- Stable `X-Sphynx-Device: <opaque>` header on every request (incl. auth + SSE), keychain-persisted
  per install.
- **Token refresh is reactive**: on a 401 it calls `POST /v1/auth/refresh` once and replays the
  request, adopting the rotated pair. It does **not** pre-empt expiry from `expiresIn` /
  `refreshExpiresIn` (those are parsed-tolerant but unused).
- Error envelope `{ "error": { code, message, retryable, retryAfter } }` is parsed; the client
  branches on `code` and now also reads `retryAfter` (kept on the error; no automatic backoff loop
  yet). `404` is treated as a benign sentinel in several spots (markers, skip-markers).

## Endpoints used

| Endpoint | Use |
|---|---|
| `GET /v1/info` | Discovery (product must contain "sphynx") + capabilities cache |
| `GET /v1/auth/me` | Effective per-user access; gates contribution |
| `POST /v1/auth/{login,refresh}` | Auth + rotating refresh |
| `GET /v1/libraries` | Top-level libraries |
| `GET /v1/items?parent=&detail=&limit=&cursor=` | Browse (skeleton for grids, full for detail); cursor-paged |
| `GET /v1/items/{id}?detail=full` | Enrichment |
| `GET /v1/home/continue` | Continue Watching (limit 20) |
| `GET /v1/people/{id}/items?detail=full&type=movie,series` | Person filmography |
| `GET /v1/resolve/{id}` | Play-time handoff |
| `GET /v1/items/{id}/markers` | Skip markers (read) |
| `PUT /v1/items/{id}/markers` | Skip markers (contribute — see below) |
| `POST /v1/playstate/{id}/{start,progress,stop}` | Progress reporting |
| `GET /v1/events` | SSE live updates |

Not consumed: `/v1/search` (Ocelot searches its own local cache for the Sphynx child),
`/v1/changes` (live updates ride SSE + per-item `updatedAt` diffing), `/v1/playstate` reads
(resume is taken from the folded `resumePosition` snapshot + SSE `playstate` nudges, not an
authoritative read at play time), `DELETE /v1/playstate/{id}`, `candidates`, `ttl`.

## Item mapping highlights

- `type`: movie/series/season/episode/person/collection mapped; everything else → `.unknown`
  (extras `trailer`/`featurette`/… and box-set `parentId`/`collectionId` nav are **not** modeled
  client-side yet).
- Images: reads flat `images.primary/backdrop/thumb` only (no `variants`, `logo`, `banner`). Each
  image URL string doubles as its change-detection "tag" — swap the URL and the live engine
  re-downloads.
- `placeholder`: both `{blurHash}` and `{url}` forms supported.
- `updatedAt`: stored and diffed as the single "changed since cached?" signal (excludes playstate),
  driving re-enrich.
- **`tmdbId` + `externalIds.imdb`** are now extracted (new) — they key the intro bridge below.
- `resumePosition` folded in for display; `runtime` → ticks; cursor pagination honored.

## `/resolve` handling (recent fix)

Ocelot reads **`terminal`** and maps it to its internal `isURLPreResolved`. When `terminal: true`
(all built-in drivers), Ocelot streams `url` directly; when absent/false it runs the URL through its
own redirect resolver first. (Earlier the client mistakenly looked for a non-existent `preResolved`
field and always did the extra resolve step — fixed.) `headers` are passed through verbatim to the
player. `ttl` is intentionally ignored (resolve is always called fresh at play time).

## Markers — read & **contribute** (the important part)

**Read:** `GET /v1/items/{id}/markers` decoded as an **open, flat map keyed by segment type**
(`{"intro":{…},"credits":{…},"recap":{…},"preview":{…}}`). Ocelot maps `recap/intro/credits/preview`
and ignores unknown types (e.g. `sponsor`). `stale` and `authoritative` are decoded. `404` ⇒ no
skip button, no error.

**Contribute (Ocelot is the TheIntroDB bridge):** Sphynx never calls an intro source server-side, so
Ocelot owns it. On playback, when an item has **no native markers** but carries a `tmdbId`/`imdbId`,
Ocelot fetches intro/credit markers from **TheIntroDB** under its **own client-side key** (never sent
to the server), shows the skip button, and — for Sphynx items — writes them back:

```
PUT /v1/items/{id}/markers
{ "markers": { "intro": {"start":75,"end":145}, "credits": {"start":9120} },
  "source": "theintrodb", "confidence": null }
```

- **Gated client-side first**: Ocelot only attempts the PUT when `GET /v1/auth/me` reports effective
  `metadata["markers"] == "readwrite"` for the user (avoids pointless 403s).
- Handles **403** (read-only / ungranted), **409** (would clobber authoritative — server is expected
  to refuse best-effort client writes), **404** (not offered) by degrading silently.
- Only `recap/intro/credits/preview` are sent (Ocelot's `commercial`/`unknown` kinds are dropped).
  `end` omitted for open-ended segments.

This means: on a single-Ocelot-client server, **markers populate themselves** as titles are played,
then re-serve to every other client (and fold into `/resolve`) — exactly the intended bridge model.
The lookup runs for Jellyfin/Plex/local items too (those just don't write back).

### Server-side asks / notes
- Keep marker reads `404`-on-empty — Ocelot relies on it as the "go bridge it" trigger.
- `stale: true` is the right nudge for re-contribution; Ocelot decodes it (re-contribution loop is
  groundwork, not yet automatic).
- ~~Cast is still missing on TV items at `detail=full`~~ **RESOLVED** (verified 2026-06-28 against
  server code + `TVFlowTests`): series carry full cast and episodes carry guest stars at
  `detail=full`; seasons are containers and carry none by design. Safe for Ocelot to render TV cast.

## SSE

`GET /v1/events` consumed when `capabilities.events`. Parses `data:` frames, skips `:` heartbeats,
discriminates on the JSON `type` (`playstate`/`useritemstate`/`markers`/`library`); `markers` &
`library` are treated as **nudges** (re-fetch via REST). Reconnects with capped backoff; refreshes
token on 401. While connected, Ocelot stretches its polling cadence (events do the work).
