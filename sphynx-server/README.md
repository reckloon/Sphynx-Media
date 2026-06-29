# Sphynx Server

The reference implementation of a **Sphynx media-meta-server** — built with
[Hummingbird 2](https://github.com/hummingbird-project/hummingbird).

Sphynx indexes media living on remote storage or CDNs, identifies and enriches it
(TMDB), manages users and playstate, and hands clients a **direct playback
location**. It **never** transcodes, proxies, or stores media bytes — it only ever
describes *where* the bytes are. The server is "brain, not muscle".

The wire contract it speaks lives in the sibling [`sphynx-protocol`](../sphynx-protocol)
package, which this package depends on via a local path. Request/response bodies
*are* the protocol's value types, so the server cannot drift from the wire format.

> **Docs:** the [complete guide](https://reckloon.github.io/Sphynx-Media/) covers
> setup, the full walkthrough, and how the server is built; the
> [API reference](../docs/API.md) lists every endpoint.

## Requirements

- Swift 6 toolchain (macOS via Xcode, or Linux).
- The sibling `sphynx-protocol` package checked out next to this one.
- (Optional) Docker, for the Linux build/test/run loop.

## Build, test, run

```sh
swift build
swift test
# Set an admin password, or omit it and copy the random one printed to the log.
SPHYNX_ADMIN_PASSWORD=changeme swift run SphynxServer   # serves on http://0.0.0.0:9410
curl http://localhost:9410/v1/info
```

### Configuration (environment variables)

| Variable                | Default                    | Purpose                          |
|-------------------------|----------------------------|----------------------------------|
| `SPHYNX_HOST`           | `0.0.0.0`                  | Bind address                     |
| `SPHYNX_PORT`           | `9410`                     | Bind port                        |
| `SPHYNX_SERVER_NAME`    | `Sphynx Reference Server`  | Name reported by `/v1/info`      |
| `SPHYNX_SERVER_ID`      | `srv_reference`            | Stable id reported by `/v1/info`  |
| `SPHYNX_VERSION`        | `0.1.1`                    | Version reported by `/v1/info`   |
| `SPHYNX_DB_PATH`        | `data/sphynx.sqlite`       | SQLite path (`:memory:` = ephemeral) |
| `SPHYNX_ADMIN_USERNAME` | `admin`                    | Bootstrap admin (first run only) |
| `SPHYNX_ADMIN_PASSWORD` | *(none)*                   | Bootstrap admin password. Unset ⇒ a strong random one is generated + printed once to the log |
| `SPHYNX_ACCESS_TTL`     | `3600`                     | Access-token lifetime (seconds)  |
| `SPHYNX_REFRESH_TTL`    | `2592000`                  | Refresh-token lifetime (seconds) |
| `SPHYNX_TMDB_API_KEY`   | *(empty)*                  | TMDB v3 key; empty disables identification/enrichment. Initial **seed** only — also settable in the admin GUI (Settings, `GET`/`PATCH /v1/admin/tmdb`), persisted in the DB; a change applies on the next restart |
| `SPHYNX_ENRICH_TTL`     | `7776000` (90d)            | Server-owned enrichment freshness; re-fetched by maintenance |
| `SPHYNX_METADATA_LANGUAGE` | `en-US`                 | TMDB metadata language (`language-COUNTRY`); normalizes enriched titles/overviews. Runtime-tunable in Settings |
| `SPHYNX_AVATAR_MAX_BYTES` | `2000000` (2 MB)         | Max accepted user-avatar upload size (bytes) |
| `SPHYNX_MARKERS_ACCESS` | `readwrite`                | Marker access: `none` \| `read` \| `readwrite` (writes still granted per-user) |
| `SPHYNX_MARKERS_STALE_AFTER` | `604800` (7d)         | Age after which markers are reported `stale` for client refresh |
| `SPHYNX_PLAYSTATE_RETENTION` | `31536000` (365d)     | Playstate retention; older entries purged by maintenance |
| `SPHYNX_MAINTENANCE_INTERVAL`| `86400` (1d)          | Background maintenance interval; `0` disables it |
| `SPHYNX_PLAYSTATE_REPORT_INTERVAL` | `5`              | Preferred client progress-report cadence (seconds), advertised in `/v1/info` |
| `SPHYNX_EVENTS_HEARTBEAT`    | `15`                      | Keep-alive ping interval for the `/v1/events` SSE stream (seconds) |
| `SPHYNX_PASSKEY_RP_ID`       | *(empty)*                 | Passkey (WebAuthn) Relying Party id — the bare domain the server is reached at (no scheme/port). Empty disables passkeys (`capabilities.passkeys=false`) |
| `SPHYNX_PASSKEY_RP_NAME`     | *(server name)*           | Display name shown by the authenticator during enrollment |
| `SPHYNX_PASSKEY_ORIGIN`      | `https://<RP_ID>`         | Expected client origin (with scheme) for ceremony verification |

Only the **startup/secret** vars (`SPHYNX_HOST`, `SPHYNX_PORT`, `SPHYNX_DB_PATH`,
`SPHYNX_ADMIN_*`, `SPHYNX_TMDB_API_KEY`) are read every boot. Note `SPHYNX_TMDB_API_KEY`
is read at boot but isn't an immutable boot secret: it's GUI-manageable and
DB-persisted (Settings tab / `GET`/`PATCH /v1/admin/tmdb`), seeded from the env var on
first boot, after which a change applies on the next restart. The rest are
**runtime settings**: the env var seeds them on first run, after which they're
stored in the database and edited via `GET`/`PATCH /v1/admin/settings` (env
changes for those keys no longer take effect). See the
[guide → Configuration](https://reckloon.github.io/Sphynx-Media/#config).

### Quick API tour (login → manual entry → resolve)

```sh
# 1. Log in as the bootstrapped admin → returns accessToken + refreshToken.
curl -sX POST localhost:9410/v1/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"changeme"}'

# 2. Manually add an item pointing at a direct media URL (admin only).
curl -sX POST localhost:9410/v1/admin/items -H "Authorization: Bearer <accessToken>" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Big Buck Bunny","container":"mp4",
       "sourceKey":"https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"}'

# 3. Resolve it to a direct, playable location (the client streams this itself).
curl -s localhost:9410/v1/resolve/<itemId> -H "Authorization: Bearer <accessToken>"
```

Clients send a stable per-install `X-Sphynx-Device` header so one device can be
revoked without logging out the others.

### Linux (via Docker)

Most users should just run the **published image** — see the
[2-minute setup](../README.md#the-2-minute-setup-docker-compose) in the root
README, or pull it directly: `ghcr.io/reckloon/sphynx-server:latest` (multi-arch,
amd64 + arm64). To build and run from source instead:

```sh
./scripts/test-linux.sh                                  # runs `swift test` inside swift:6.3-noble
docker compose -f docker-compose.build.yml up --build    # builds and runs the server image
```

The Docker build context is the **parent** directory (it needs both packages);
the provided `Dockerfile` and `docker-compose.build.yml` handle this for you.
(The plain `docker-compose.yml` runs the published image rather than building.)

## Subsystem map

Code is organised along the subsystem seams — Sources, Indexer, Identifier,
Enricher, Catalog, Resolver, Users/Auth, Playstate, API (see the
[guide → How the server is built](https://reckloon.github.io/Sphynx-Media/#architecture)).
For v1 they live in one process.
