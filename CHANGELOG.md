# Changelog

All notable changes to Sphynx are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut by pushing a `vX.Y.Z` git tag, which builds and publishes the
multi-arch server image to `ghcr.io/reckloon/sphynx-server` (see the
[guide's Docker section](https://reckloon.github.io/Sphynx-Media/#docker)).

## [Unreleased]

_Nothing yet._

## [0.2.1] — 2026-06-29

### Added

- **Re-map a source to different libraries after creating it.** Each source in
  **Libraries → Storage sources** gets an **Edit** button to change which libraries it
  feeds (Movies / TV Shows) — so after deleting and re-adding the Movies library you
  can point an existing source back at it (`PATCH /v1/admin/sources/{id}` already
  supported this; the UI now exposes it). Re-scan to import into the re-mapped library.

### Fixed

- **A metadata-language change now applies without a restart.** The TMDB client baked
  the language in at boot, so changing it and re-enriching kept the old language. The
  language is now read **live**, so saving a new language and clicking **Reset
  enrichment** re-fetches titles/overviews/posters in the new language. (Watch history
  is preserved — items are re-enriched in place, not purged.)

- **Deleting a library no longer strands its extras/featurettes.** Bonus content nests
  under a movie/show via `parentId` and carries `libraryId` nil, so a library deletion
  (scoped by `libraryId`) left those rows behind — still counted, with no library or
  source. `deleteLibrary` now sweeps the orphaned descendants, and a startup pass
  (`pruneOrphans`) clears any already stranded by an earlier delete.

### Documentation

- Reconciled the guide, `docs/API.md`, and the READMEs with everything shipped through
  0.2.0–0.2.1 (three-agent audit): documented `POST /v1/admin/restart`, the media-probe
  `maxPerMinute` rate limit, the live-`metadataLanguage` + Reset-enrichment behavior,
  the source library re-map, and the profile-picker setting; added the
  `SPHYNX_SIGN_IN_USER_LIST` and `SPHYNX_WEB_REDIRECT_ALLOWLIST` env rows; bumped all
  version strings to 0.2.1 and fixed a stale `/v1/info` example and a broken README link.

## [0.2.0] — 2026-06-29

### Added

- **"Reset enrichment" button** (Libraries → Storage sources, next to *Scan all now*)
  — force-re-fetches metadata and artwork for every identified title from TMDB,
  ignoring the freshness window (locked 🔒 fields are kept); progress shows in the
  Activity panel. Also: changing **Settings → Metadata language** now flags that the
  new language applies only to titles enriched from now on and points to *Reset
  enrichment* to re-translate the existing library.

### Fixed

- **Series now get their title logo (clearlogo), not just movies.** The TV details
  fetch never requested TMDB's `images`, so a series carried no `logo` (or wide
  `banner`) — only movies, whose details fetch already asked for them. `tvDetails`
  now appends `images` with `include_image_language=en,null`, the series enrichment
  fields carry the logo/banner, and `apply()` persists them on the series record
  (gated by the `images` lock, like every other artwork field).

- **The Restart button now actually restarts — it used to just stop the server.** It
  signalled `SIGTERM` and relied on a supervisor's restart policy to relaunch, which
  exists in the Docker setup but not when running from source — so the process simply
  exited. The executable now **re-execs itself in place** once it has shut down
  cleanly, so restart works everywhere (and no longer even depends on the container's
  `restart:` policy).

- **Home genre shelves now work in non-English metadata languages.** The admin Home
  tab's one-click starter chips (and "Loaded the built-in starter set") hardcoded
  English genre names like `Action`, so with a non-English metadata language they
  matched none of the localized genres actually stored (`Боевик`, …) and the shelves
  came back empty. The starter genre chips now come from the operator's real genres
  (`GET /v1/admin/genres`), so they match whatever language the library is enriched in.

### Changed

- **WebDAV scanning is dramatically faster.** The listing used to crawl the folder
  tree one directory at a time — a serial `PROPFIND Depth:1` per folder, so a large
  library meant hundreds of round-trips back to back. Now it first tries a single
  `PROPFIND Depth:infinity` (Nextcloud/ownCloud, Apache `mod_dav`, … return the whole
  subtree in one request); if the server rejects or ignores it, it falls back to a
  **bounded-concurrency** depth-1 walk (several `PROPFIND`s in flight instead of one).
  Concurrency is capped so it doesn't trip rate limits, and the fetcher still retries
  any `429`/`5xx` with `Retry-After` back-off. A listing is all-or-nothing (a partial
  list would make the indexer delete the unseen items), so a failed directory aborts
  the scan rather than silently dropping titles.
- **Scanning is now per-source, with live feedback.** The **Activity** panel names
  the source being scanned ("Scanning Tom's WebDAV") and each source in the Libraries
  list shows a **spinner** while it runs (driven by `scanningSources` in
  `GET /v1/admin/status`). The per-source **Scan** and **Scan all now** buttons remain;
  the per-library **Refresh** button was removed (scanning is a source operation), and
  "Scan all" now reports clearly instead of a bare count when sources are already busy.

## [0.1.8] — 2026-06-29

### Fixed

- **Empty/orphaned containers are pruned on scan.** The duplicate-item heal removed
  duplicate leaf items (episodes/movies) but left their now-empty container shells —
  e.g. duplicate **empty seasons** and series — behind. A scan now prunes any
  `season`/`series` with no remaining children (cascading: emptying a season can empty
  its series), which both heals those leftover shells and removes a container whose
  children all vanished from the source.
- **Saved sources now load with the page.** The Libraries tab only fetched the source
  list after an add/scan/delete, so existing active sources didn't appear until you
  pressed Scan. The list is now loaded on sign-in like the rest of the page.

## [0.1.7] — 2026-06-29

### Fixed

- **Duplicate items from overlapping scans.** A source had no concurrency guard, so a
  second scan starting before the first finished (common with a slow source + an
  auto-refresh interval, or a manual "Scan"/"Refresh" during one) each snapshotted the
  pre-scan item set and both re-inserted every file — producing a duplicate row per
  title. Scans are now **serialized per source** (a second scan of a source in flight
  is rejected with `409`; "Scan all"/"Refresh"/auto-refresh skip a busy source instead
  of failing). The indexer also **self-heals** existing duplicates: on the next scan,
  leftover duplicate-`sourceKey` rows are removed so the catalog converges to one item
  per file.

### Added

- **Restart button** (Settings → below the TMDB API key) and `POST /v1/admin/restart`.
  Restarts the server process (graceful `SIGTERM`; the container's restart policy
  relaunches it) so a changed **TMDB API key** — which is only read at startup — can
  take effect without shell access. Library and settings are preserved.

### Changed

- **Activity panel: clearer + snappier.** The "Next runs" indicator now shows **live
  progress** for the running task where it's measurable (e.g. `Media probe: running
  133 / 476`), and a manual-only task that has just been given an interval flips out of
  "manual only" within ~5s instead of up to 30s (`idlePollTick` 30 → 5; surfaced via
  new `total`/`done` on each `schedule` entry in `GET /v1/admin/status`).
- **Storage sources are now listed at the top of the Libraries tab** — an always-visible
  "Your sources" list (every driver) with Scan/Delete, so you can manage connected
  sources without opening a driver tab. Added explanatory **tooltips** to the main
  action buttons (Scan, Scan all, Refresh, Re-enrich, Run probe pass, Generate now,
  Restart) so it's clear what each does.

## [0.1.6] — 2026-06-29

### Added

- **Media-probe rate limit (`maxPerMinute`).** The background probe pass now caps how
  many per-item source resolves it issues a minute, so it stays under the provider's
  request budget and leaves headroom for live playback. Each probed title costs one
  resolve (a TorBox `requestdl` is one of **300/min**, shared with playback), so the
  unthrottled pass could trip TorBox rate limiting (`429`s). A new **Max probes per
  minute** field in **Extensions → Media probe** (and `maxPerMinute` on
  `GET`/`PATCH /v1/admin/extensions/media-probe`) governs it — applied live, `0` ⇒
  unlimited, **default 120**. Workers wait on a shared spacing limiter before each
  resolve, so concurrency no longer bursts past the cap.

## [0.1.5] — 2026-06-29

### Fixed

- **Media-probe background pass no longer stalls on a slow or offline source.** With
  only two workers and no timeout anywhere, a couple of items whose resolve or
  `ffprobe` hung (common for remote/TorBox links) could occupy both slots forever, so
  the probe count plateaued (e.g. "stuck at 488/939") while still reporting
  *running*. Now: `ProcessRunner` enforces a hard timeout and kills an overrunning
  `ffprobe`; the prober passes `-rw_timeout` so a stalled network read fails fast;
  each item gets a **90s overall budget** (resolve + probe) after which it's dropped
  to a future pass instead of parking a worker; a server-supplied `Retry-After` is
  capped at the normal max back-off; background concurrency is raised 2 → 4; and a
  skipped/timed-out item is now logged at `info` (was hidden at `debug`) so the
  reason a pass doesn't reach 100% is visible.

### Added

- **Passkey sign-in on the web authorization page.** The hosted OAuth-style web
  sign-in page (`GET /v1/auth/web/start`, used by clients that can't add the server
  to an Associated Domains entitlement) now offers **Sign in with a passkey**
  alongside the username/password form — so the web login path matches `/user` and
  `/link`. It runs the discoverable passkey ceremony (no username needed), then
  finishes the flow through a new secured `POST /v1/auth/web/authorize/session`,
  which issues the same single-use code+redirect from the signed-in session. The
  button appears only when the browser supports WebAuthn and falls back cleanly when
  passkeys aren't enabled.

### Documentation

- **Media probe: document the playback-speed benefit.** The web admin **Extensions
  → Media probe** panel, the guide, and `docs/API.md` now explain that pre-indexing
  each title's audio/subtitle tracks lets a player start playback without first
  probing the file itself — so clients that rely on the advertised `tracks` (e.g.
  Ocelot) load dramatically faster — and recommend running a background pass over the
  library when such a client is in use.

## [0.1.3] — 2026-06-29

### Added

- **Per-extension schedules + a "Next runs" indicator.** Each background task now
  carries its own interval instead of sharing one cleanup cadence. **Low-res images**
  and **Media probe** each gain an interval setting (seconds, fractional allowed; `0`
  = manual-only) plus a **"Run now"** button, configured in their own Extensions
  sections. **Media probe** also becomes a background pass like BlurHash generation —
  it probes every not-yet-probed title on its interval (opt-in: off by default), with
  bounded concurrency, alongside the existing per-item probe. All task intervals are
  read **live**, so changes apply without a restart. The admin **Activity** panel
  gains a **Next runs** row showing when each task (enrichment refresh, library index,
  BlurHash generation, media probe) fires next, backed by a new `schedule` block on
  `GET /v1/admin/status`. New endpoints: `POST /v1/admin/extensions/placeholders/run`
  and `POST /v1/admin/extensions/media-probe/run`; both config endpoints gain
  `intervalSeconds`, and media-probe reports background-pass `probing` progress.

- **BlurHashes for every image, generated by a lazy background pass.** The low-res
  `placeholder` (the blur-up stand-in clients paint before artwork loads) now gets a
  real BlurHash for **every** image the server serves — poster, backdrop, episode
  still, logo, banner, and each cast face — across movies, series, seasons, episodes,
  and people, not just the poster. Generation is **decoupled from enrichment**: a new
  background `BlurHashBackfillService` hashes only what's still missing, with **bounded
  concurrency** (≤4 image fetches in flight, so it never hammers the image source),
  resuming across passes until everything is hashed. Hashes persist **without** bumping
  an item's `updatedAt`, so the backfill never invalidates every client's cache at
  once — fresh fetches get the hash immediately, existing caches adopt it on their next
  refresh. The **Extensions → Low-res images** tab shows a live generation-progress
  indicator, and `GET /v1/admin/extensions/placeholders` now returns a `hashing`
  block (`running`/`total`/`done`/`lastCompletedAt`) in `blurhash` mode. Per-role
  hashes ride in a new `{role: hash}` map; each `CastMember`'s placeholder now also
  honors the mode (previously it always emitted a URL form, even when set to `off`).
  Stored cast per item increased 15 → 30.

- **Passkey sign-in on the device-approval page (`/link`).** The browser page you
  land on after scanning a TV's QR now offers **Sign in with a passkey** alongside
  the username/password form, so you can approve a device without typing a password.
  It reuses the existing public passkey endpoints
  (`POST /v1/auth/passkeys/authenticate/{begin,finish}`) with discoverable
  credentials — no username needed — then drops straight into the approve step. The
  button only appears when the browser supports WebAuthn, and falls back cleanly when
  passkeys aren't enabled on the server.

### Fixed

- **The Collections library now shows its contents in the web admin too.** A
  `collection`-kind library is a cross-library view whose box-set tiles physically
  live in their movie/TV libraries; the client browse aggregated them, but the admin
  item browser did a literal `libraryId` match and came back empty, so the web UI
  showed the Collections library as empty while clients (e.g. Ocelot) showed it
  populated. The admin browser now aggregates collection-kind libraries the same way,
  scoped to the libraries the caller may edit.

- **No more empty progress bar for a Collections library in the Activity panel.** The
  "Items per library" breakdown skipped no libraries, so a `collection`-kind library —
  which holds no items of its own (its tiles are counted under the owning movie/TV
  library) — rendered a meaningless `0 / 0` bar. Collection-kind libraries are now
  omitted from that per-library breakdown; the real `collection` tally still shows
  under "Enriched by category".

- **Transparent logos no longer get a BlurHash.** A logo PNG is mostly transparent, so
  BlurHashing it produced a muddy box behind the artwork. Logo images are now skipped
  by the BlurHash pass and fall back to no placeholder.

### Documentation

- Added **[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)** — the licenses of the
  Swift dependencies (all permissive: Apache-2.0 / MIT / Unlicense) and of the
  `ffmpeg`/`ffprobe` bundled in the Docker image. Notes that `ffprobe` is invoked
  as a separate process, so its GPL terms are mere aggregation and don't extend to
  Sphynx's MIT code; points to the in-image `copyright` and upstream source.

## [0.1.2] — 2026-06-29

### Added

- **Web authorization flow (OAuth-style).** A browser/redirect sign-in path for web
  and embedded clients — `GET /v1/auth/web/start` → `POST /v1/auth/web/authorize` →
  `POST /v1/auth/web/token` — with PKCE, a single-use ~60-second code, and a
  `redirect_uri` allowlist (`SPHYNX_WEB_REDIRECT_ALLOWLIST`). Advertised via
  `capabilities.webAuth`.

- **Collections library (cross-library box-set view).** A library of kind
  `collection` now actually populates: browsing it aggregates every box-set tile
  across the server — movie and series collections alike — instead of showing
  empty. The tiles still live in their own movie/TV library (alongside their
  members); the Collections library is a read-through view over them, scoped to
  the libraries you're allowed to read. Previously the kind was selectable but
  never filled, so collections looked enriched yet the library stayed empty.

- **Low-res images extension (`blurhash` / `url` / `off`).** The low-res image
  `placeholder` that tiles blur up from is now a configurable **Extensions →
  Low-res images** module instead of a fixed behaviour. `blurhash` (**the new
  default**) sends a [BlurHash](https://blurha.sh) the client paints instantly with
  no extra request — generated and cached during enrichment (the server fetches,
  decodes, and encodes the poster), with a transparent fall back to `url` until a
  hash exists; `url` sends a tiny image link; `off` sends no placeholder. The mode
  is read live, so `off`/`url` apply immediately and `blurhash` serves whatever
  hashes are already cached. Configure it via
  `GET`/`PATCH /v1/admin/extensions/placeholders`.

- **Manual collections (box sets), including for series.** Group movies or series
  into your own collections by hand, in addition to the ones auto-discovered from
  TMDB (TMDB has no collection data for TV, so series box sets are always manual).
  Curate them on the **Collections** tab of the admin page, or — once granted the new
  **Manage collections** (`collections.edit`) permission — the **Collections** panel
  on `/user`. A manual collection obeys the same per-library minimum
  (`collectionThreshold`) as an auto one: it surfaces as a tile only once it has
  enough members, and below that its titles show individually. Deleting a collection
  keeps its titles and just removes the grouping.

- **Configurable home screen.** The home feed (`GET /v1/home`) is no longer three
  fixed rows — it is now driven by a layout of ordered shelves. Two new shelf
  kinds, `genre` and `releaseDecade`, let a row be "Action" or "the 1980s"
  (the parameter rides in `Shelf.id`, e.g. `genre:Action` / `decade:1980`; both
  are open-enum additions, so older clients degrade gracefully).
  - **Admin → Home tab** sets the *default* layout every user sees, with a
    one-click starter set of popular genres and decades (`GET`/`PUT /v1/admin/home`,
    genres from `GET /v1/admin/genres`).
  - **/user → Home screen rows** lets each user build their own layout by genre and
    decade; it replaces the default for them, with a **Reset to default** button
    (`GET`/`PUT`/`DELETE /v1/home/config`).
  - Genre/decade rows are paginated via `GET /v1/home/genre?name=` and
    `GET /v1/home/decade?start=`. Empty rows (a genre or decade with nothing in the
    library) are omitted automatically.

- **Profile-picker sign-in on `/user`** (opt-in). A Jellyfin-style "who's
  watching" chooser: the page shows everyone's avatar and name, you tap a face to
  pick the account (no username typing), then enter a password or sign in with a
  passkey. Backed by a new pre-auth endpoint `GET /v1/auth/directory` (plus
  `…/directory/{id}/avatar` for the pictures), gated by a new `signInUserList`
  setting — **off by default**, since it lists accounts before sign-in. Enable it
  in **Settings → "Show a profile picker on the sign-in page"** (or seed
  `SPHYNX_SIGN_IN_USER_LIST=true`). When off, the page falls back to manual
  username entry exactly as before. This also wires up **passwordless passkey
  sign-in** in the web UI (previously only passkey *enrollment* existed there).

### Changed

- **`ffprobe` now ships in the Docker image.** The runtime image bundles `ffmpeg`,
  so the **Media probe** extension (real audio/subtitle tracks, external subtitle
  files, embedded chapters) works the moment you enable it — no custom image or
  manual install. Running from source still needs `ffmpeg` on the server's `PATH`.
  The server reports `0.1.2` from `/v1/info`.

- **The home "Recently Added" row now respects the collection minimum.** A
  sub-threshold box set no longer appears there as a one-item tile — its member
  titles surface individually instead, exactly as they already did when browsing the
  library. Collection tiles are also no longer mistakenly re-enriched as movies.

### Fixed

- **Episodes named `Show.5x09.mkv` are no longer misidentified as movies.** The
  extension stripper treated a trailing `NxNN` token (`.5x09`) as a second file
  extension — it's short, alphanumeric, and contains an `x` — so it was dropped,
  the season/episode marker vanished, and the file fell through to movie parsing.
  Two-digit forms (`.12x09`) happened to survive on length alone. A `\d+x\d+`
  token is now never stripped as an extension. Also, a yearless scene release
  (`Lunar.Monolith.2160p.REMUX.TrueHD.Atmos-YTS.mkv`) no longer leaks the release
  group into the title: with no year to bound the title, it is cut at the first
  release-junk token instead of merely filtering junk tokens out.

- **Title matching no longer loses to longer, padded titles.** The candidate
  ranker stripped `&` entirely (rather than reading it as "and") and gave a longer
  title that merely *contained* the query the same weight as an exact hit — so
  `Love.and.Death` matched "Stories About Love and Death" instead of "Love &
  Death". Normalization now canonicalises `&`→`and` and folds diacritics
  (`Pokémon` == `Pokemon`), and both the movie and TV rankers score by
  token-overlap that rewards covering the query while penalising padded
  candidates, with a known release year as a strong confirm/demote signal. A
  re-scan or per-item re-identify corrects already-mismatched titles.

- **Passkey registration from the web UI.** The `/user` page's `register/finish`
  request was malformed — it posted the raw authenticator credential at the top
  level, omitting the required `challengeId` and the `credential` wrapper the server
  decodes (`PasskeyRegistrationFinishRequest`). The authenticator created and saved
  the passkey, then enrollment always failed server-side with `400`. The client now
  sends `{ challengeId, credential }`, so passkeys actually enroll.

### Documentation

- New **[docs/passkeys-help.md](docs/passkeys-help.md)** — a passkey implementer's
  guide: server Relying-Party setup, the WebAuthn ceremony model, and per-platform
  client methods (browser `navigator.credentials`, Apple `AuthenticationServices`,
  Android Credential Manager, security keys), plus troubleshooting.
- Reconciled the guide and `docs/API.md` with everything shipped this cycle — the
  web authorization flow, the configurable home layout (genre/decade rows + admin
  default + per-user override), manual collections (`collections.edit`), the
  profile-picker sign-in, and the low-res-images placeholder modes — and corrected
  the `placeholder` default (now `blurhash`) and version strings.

## [0.1.1] — 2026-06-28

A documentation-accuracy and consistency pass over 0.1.0 — no API or behavior
changes. A three-agent QA sweep over the server code, the wire contract, and every
doc surface found the implementation clean; only documentation drift, now fixed.

### Fixed

- **Device-authorization error codes** in the protocol doc-comment now match what
  the server actually emits — `authorization_pending` / `expired_token` /
  `invalid_grant`. The previously-listed `slow_down` / `access_denied` were never
  sent.
- **Stale version strings.** The server now reports `0.1.1` from `/v1/info`, and the
  drifted references were corrected to match — notably the server README's
  `SPHYNX_VERSION` default (which still read `1.0`) and the guide's `/v1/info`
  example.

### Documentation

- Documented two runtime settings missing from the guide's settings table:
  `SPHYNX_METADATA_LANGUAGE` and `SPHYNX_AVATAR_MAX_BYTES`.
- Reconciled the guide, the three READMEs, and `docs/API.md` against the shipped
  code — capabilities, advertised `fields`, the driver list, and environment
  variables — so the docs and the server agree end to end.
- Refreshed the guide's **Roadmap / Coming Soon**: shipped features no longer sit
  under "planned" — the published Docker image, passkeys, QR / device-code sign-in,
  multiple versions/editions, and the typed browse contract moved to "working
  today" (with the TorBox driver added to the list); the roadmap now lists only
  genuinely-pending work.

## [0.1.0] — 2026-06-28

First public release. Sphynx is a featherweight **metadata server** for a
movie/TV collection: it keeps the catalog and tells player apps *where each file
lives*, but never touches the video bytes itself. This release ships the open
**v1 protocol**, a complete **reference server**, a no-terminal **web admin**, and
a **published Docker image**.

### Protocol (the open `v1` wire format)

- Full `v1` contract: **discovery** (`/v1/info`), **authentication**, **browse**,
  **resolve**, **playstate**, a standard **error** shape, and a canonical
  **Item** model — defined once in the `sphynx-protocol` package so clients and
  servers can't disagree.
- **Forward-compatibility rules**: additive changes never bump the version;
  unknown fields/types are ignored. Servers advertise coverage via
  `capabilities.fields` and `capabilities.browse` so clients can adapt instead of
  guessing.
- **Capabilities** for optional features: `search`, `playstate`, `candidates`,
  `events`, `passkeys`, `deviceAuth`, and per-field metadata access policy.
- **Multi-version / editions**: one title backed by several files (4K + 1080p,
  Director's Cut + Theatrical) collapses into a single item with a best-first
  `versions` picker, resolved via `?version=<id>`.
- **Music & audiobooks** are fully modeled in the protocol (artist→album→track,
  audiobook→chapter, lossless/hi-res stream descriptors) for other servers to
  implement — the reference server itself is film/TV only.
- **Clients need no package dependency** — the docs are the contract; any app can
  implement the wire directly.

### Reference server — catalog & identification

- **Movies and TV**: series → season → episode identification, enrichment, and
  tree; **collections / box sets** (with a per-library grouping threshold); and
  **extras** (trailers, deleted scenes) nested under their title rather than
  listed as standalone movies.
- **Person filmography** endpoint (`GET /v1/people/{personId}/items`).
- **Identifier & parser** built for any language: titles/years and
  season/episode numbers are recovered from the **full path** (folder authority),
  including messy scene-release folders and `[release-group]` tags.
- **Metadata enrichment** via TMDB — posters, descriptions, cast, episode art,
  official content rating, per-image placeholder/aspect variants — with retry +
  backoff on 429/5xx, and configurable refresh cadence.
- **Manual corrections** persist with **per-field locks** so a re-scan never
  overwrites a hand-edited title; items can be re-identified, re-enriched, and
  **re-mapped** to a different library/parent/season.

### Reference server — users, state & sync

- **Single admin + per-user permissions** (global or per-library), with the
  ability to delegate **scanning** and **metadata correction** to trusted
  non-admins.
- **Per-user state**: Continue Watching, watch history, home feeds, resume
  positions, per-user ratings, and playback-completion thresholds (95% marks
  watched and clears resume; a 5% floor avoids accidental progress).
- **Delta sync**: a changes/tombstones feed plus `Item.updatedAt` for efficient
  client-side cache diffing.
- **Real-time updates**: a Server-Sent Events stream (`GET /v1/events`), scoped
  per subject/library so delivery stays fail-closed.

### Reference server — storage drivers

- Pluggable **source-driver framework** with a registry and per-source config.
- Drivers: **Local** (test-only — Sphynx serves no bytes), **HTTP**, **WebDAV**,
  **SMB**, **FTP**, and **TorBox** debrid (list + resolve, no `.strm`/mount).
- Multiple sources per library, mixed drivers, with content-type routing
  (movies vs TV) and per-source auto-refresh.

### Authentication

- Token login with **refresh tokens** (advertised lifetime), self-service
  session listing and revocation.
- **Passkeys (WebAuthn)** for passwordless sign-in, gated on a configured
  relying-party origin.
- **QR / device-authorization** sign-in for TVs and other input-limited devices.

### Web admin & user pages (no terminal, no config files)

- **/admin** control panel: a global activity dashboard (coverage broken down by
  library and category), **Libraries** that own their storage sources, a full
  **permission editor**, an **Items** file-browser for corrections, a **Users**
  grid, plain-English **Settings**, and an **Extensions** area.
- **Extensions framework** with a **media-probe** (ffprobe) extension that reads
  real audio/subtitle tracks, external subtitle files, and embedded chapters.
- **Diagnostics**: an in-UI database browser and logs.
- **/user** self-service page: profile, avatar upload, passkeys, signed-in
  devices, watch-history reset, and a library-correction panel for users granted
  the edit-metadata permission.

### Configuration

- Runtime configuration is **persisted and edited via the admin Settings tab**;
  environment variables only **seed** values on first boot.
- Default port is **9410**.
- Database defaults to a persistent on-disk SQLite file (WAL); schema upgrades
  run forward automatically on startup.

### Distribution

- **Published multi-arch Docker image** (`linux/amd64` + `linux/arm64`) to GHCR,
  built and pushed by CI on each `v*` tag after the macOS and Linux test suites
  pass.
- Docs lead with the **pull-the-image** path (`docker compose up -d`, no clone,
  no compiling); building from source moved to `docker-compose.build.yml`.
- CI runs `swift test` for both packages on macOS and in a Swift Linux container.

### Security

- **Fail-closed library reads** (`canReadLibrary`) — resolve no longer fails open.
- **SSRF / path-traversal guards**: the fetcher is **http(s)-only** and local
  paths are contained.
- **No default admin password** — an unset password generates a strong random one
  printed once to the log, rather than shipping a known credential.

### Documentation

- Complete **[guide](https://reckloon.github.io/Sphynx-Media/)** (served via
  GitHub Pages): protocol reference, "build a client / build a server" walkthroughs,
  the parser, driver authoring, and a full FAQ.
- **[API.md](docs/API.md)** endpoint reference and
  **[Ocelot client notes](docs/OCELOT_CLIENT.md)**.
- A **plain-English, GUI-first** root README.

[Unreleased]: https://github.com/reckloon/Sphynx-Media/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/reckloon/Sphynx-Media/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/reckloon/Sphynx-Media/compare/v0.1.8...v0.2.0
[0.1.2]: https://github.com/reckloon/Sphynx-Media/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/reckloon/Sphynx-Media/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/reckloon/Sphynx-Media/releases/tag/v0.1.0
