# Sphynx Protocol

The **Sphynx** wire contract expressed as pure, dependency-free Swift value types.

Sphynx is an open protocol for a *media-meta-server*: a server that indexes media
living on remote storage or CDNs, enriches it with metadata, and hands clients a
**direct playback URL** plus everything needed to play and track it — without ever
proxying, transcoding, or storing the media bytes. See the
[Sphynx guide](https://reckloon.github.io/Sphynx-Media/) for the full protocol
reference and the [API reference](../docs/API.md) for the live endpoints.

This package is the **canonical definition** of the wire types. The reference
server uses it directly (so it can't drift from the spec); a client **may** reuse
it to get the types for free, but isn't required to — the wire is plain JSON, so a
client can implement the protocol straight from the docs with its own small
`Decodable` types (Ocelot does the latter). It is therefore intentionally:

- **Foundation-only** — zero third-party dependencies.
- **Cross-platform** — builds for every Apple platform and Linux.
- **Forward-compatible** — unknown JSON fields are ignored and unrecognised
  enum-like string values decode to an `.unknown(value)` case instead of throwing
  (see `OpenEnum`). New optional fields and new string values may appear at any
  time without breaking older clients.

## Design notes

- **Time is `Double` seconds** on the wire everywhere (positions, runtime, ttl).
- **Open string enums** (`ItemType`, `LibraryKind`, `ErrorCode`) carry their known
  cases plus an `.unknown(String)` fallback and round-trip unknown values verbatim.
- The test suite is the contract's guardrail: it round-trips every type through
  JSON and proves that future/unknown payloads decode without throwing.

## Build & test

```sh
swift build
swift test
```

### Linux (via Docker)

```sh
./scripts/test-linux.sh        # runs `swift test` inside swift:6.3-noble
```

## Status

The wire contract as built today: discovery (`ServerInfo`, `Capabilities`), auth +
per-user permissions (`TokenResponse`, `MeResponse`, `PasswordChangeRequest`,
self-service `ProfileUpdateRequest` + server-hosted avatars, `PlaystateResetResponse`
for a full watch-history reset, `SessionInfo`/`SessionsResponse` for per-device
sign-out, optional passkey/WebAuthn sign-in (`capabilities.passkeys`,
`PasskeyInfo`/`PasskeyListResponse`/`PasskeyRenameRequest`; the ceremony payloads
themselves are standard W3C WebAuthn JSON and intentionally not modelled here)), the
`Item` model (images incl. per-image `ItemImages.variants`/`ImageInfo`, placeholder
one-of, cast, TV positioning, `parentId`/`collectionId`, open `extra`), browse +
pagination, the typed home feed (`HomeResponse`, `Shelf`, `ShelfKind`/`ShelfAspect`),
resolve (`ResolveDescriptor`, tracks, candidates), playstate, bi-directional markers
(`MarkerContribution`, `MarkersInfo`), the error envelope, and the open-enum
machinery. The test suite round-trips every type and proves unknown payloads decode
without throwing.

### Permissions on the wire

`MeResponse.permissions` is an **open set of string keys** describing what the
signed-in user may do. Well-known keys:

| Key | Meaning |
|---|---|
| `library.read` | Browse libraries and resolve/play their items |
| `metadata.markers.write` | Contribute intro/credit markers (`PUT /v1/items/{id}/markers`) |
| `metadata.images.write` | Contribute artwork *(reserved — no endpoint yet)* |
| `metadata.edit` | Read/edit item metadata and lock fields (admin correction surface) |

Any key may be **scoped to a single library or item** with a `:<id>` suffix
(`library.read:lib_abc`, `metadata.edit:it_123`). A client should treat the set as
opaque and forward-compatible — match the keys it understands, ignore the rest, and
never reject an unknown key. The keys gate server features; clients use them only to
decide which affordances to show (e.g. show a "fix metadata" button when the user
holds `metadata.edit`). `MeResponse.metadata` is the narrower per-field contribute
view (server policy ∩ the user's write permissions).

#### Handling "permission denied"

A permission-gated action the caller isn't allowed to perform returns **`403`** with
`error.code = "forbidden"` (the [error envelope](#errors)). **Clients MUST surface
this cleanly** — show a short "you don't have permission to do that" message (or
disable/hide the affordance up front based on `GET /v1/auth/me`), and treat it as a
**terminal, non-retryable** outcome. Do **not** let the action silently do nothing,
spin, or look like a network failure: a `403` is a definitive "no", distinct from
`401` (re-authenticate) and `5xx`/timeouts (retry). Because permissions are granted
per-user and can be scoped per-library/per-item, the same action may be allowed for
one item and denied for another — decide per target from `/v1/auth/me`, and still
handle a `403` gracefully if the grant changed since.
