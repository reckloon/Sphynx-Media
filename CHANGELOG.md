# Changelog

All notable changes to Sphynx are recorded here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut by pushing a `vX.Y.Z` git tag, which builds and publishes the
multi-arch server image to `ghcr.io/reckloon/sphynx-server` (see the
[guide's Docker section](https://reckloon.github.io/Sphynx-Media/#docker)).

## [Unreleased]

### Added

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

### Fixed

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

[Unreleased]: https://github.com/reckloon/Sphynx-Media/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/reckloon/Sphynx-Media/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/reckloon/Sphynx-Media/releases/tag/v0.1.0
