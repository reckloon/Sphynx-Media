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

> The built-in web admin UI is served at **`GET /admin`** (an HTML page, outside
> the `/v1` API surface) — not part of the JSON protocol described here. A
> matching **end-user self-service page is served at `GET /user`**, where any
> signed-in user manages their own display name, profile picture, password, and
> watch-history reset (it drives only the self-service `/v1/auth/*` and
> `/v1/playstate` endpoints — no admin rights). A user granted `metadata.edit`
> also gets a **Library correction** section there, since item correction is
> permission-gated rather than admin-only.

### `GET /v1/info` — unauthenticated

Confirm a URL is a Sphynx server and learn its capabilities.

**200**
```json
{
  "product": "Sphynx",
  "serverName": "Sphynx Reference Server",
  "id": "srv_reference",
  "version": "0.1.1",
  "protocol": ["v1"],
  "capabilities": {
    "search": false,
    "playstate": true,
    "candidates": true,
    "events": true,
    "passkeys": false,
    "deviceAuth": true,
    "webAuth": true,
    "metadata": { "markers": "readwrite", "images": "read" },
    "fields": ["id", "type", "title", "tmdbId", "year", "images", "placeholder",
               "dateAdded", "updatedAt", "seriesId", "seriesTitle", "seasonIndex",
               "episodeIndex", "childCount", "parentId", "collectionId", "collectionTitle",
               "extra", "overview", "runtime", "genres", "communityRating", "officialRating",
               "cast", "originalTitle", "sortTitle", "tagline", "status", "premiereDate",
               "endDate", "studios", "directors", "writers", "countries", "tags", "trailers",
               "externalIds", "chapters", "versions", "resumePosition", "watched", "playCount",
               "isFavorite", "userRating", "lastPlayedAt"],
    "browse": { "sorts": ["added", "name", "rating"], "filters": ["genre", "year", "unwatched"] },
    "playstateReportInterval": 5
  }
}
```
**`browse`** advertises what `GET /v1/items` supports — the valid `sort` keys and
filter params — so a client builds typed sort/filter affordances from the contract
rather than probing. Absent ⇒ the client offers no typed sort/filter UI.
`playstateReportInterval` (seconds) is the server's preferred client playback-report
cadence: a client that reports progress periodically SHOULD `POST` to
`/v1/playstate/{id}/progress` this often (default ~5s if absent). **Push-only** —
the server stores what the client sends and never polls the client. Reporting is
optional for the client; progress reports don't bump `Item.updatedAt`.
`events` advertises the additive server→client event stream (see [Events](#events-server-sent)).
Absent ⇒ `false`: the client falls back to polling.
`passkeys` advertises passwordless **passkey** (WebAuthn) sign-in (see [Passkeys](#passkeys-webauthn)).
Absent ⇒ `false`: no Relying Party is configured; the client hides passkey
affordances and uses password login.
`deviceAuth` advertises the **QR / code device-authorization** grant for TVs (see
[Device authorization](#device-authorization-qr--code-sign-in)). Absent ⇒ `false`:
the client shouldn't offer a "sign in on this TV" QR flow.
`webAuth` advertises the **OAuth-style web authorization** flow (see
[Web authorization](#web-authorization-oauth-style)). Absent ⇒ `false`: the client
shouldn't offer the "sign in on the web" button and should use password, passkey, or
device-code sign-in instead.
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
carries. (The reference server advertises the full list above. It now serves
`chapters` for any item probed by the [media-probe extension](#extensions--admin-only)
— `ffprobe -show_chapters`, since TMDB has no chapter data. The one field it never
fills is `criticRating`: TMDB exposes only an audience score (`vote_average` →
`communityRating`), not a critic aggregate, so a critic rating needs a different
source — see [Item shape](#item-shape). Don't conflate the two: `criticRating` is
**0–100** (Double); `communityRating` is **0–10** (Double).)

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

### `GET /v1/auth/directory` — unauthenticated, **opt-in**

A pre-auth list of pickable profiles, for a "who's watching" sign-in chooser
(the `/user` page renders avatars to tap instead of typing a username). Served
**only** when the admin enables the `signInUserList` setting — otherwise **404**,
so a server never enumerates its accounts before sign-in. Credentials, roles, and
admin status are never included.

**200**
```json
{ "users": [
  { "username": "alice", "displayName": "Alice", "avatarURL": "/v1/auth/directory/u_…/avatar" }
] }
```
`avatarURL` is absent when the user has no avatar (the client shows an initial).
Sorted by display name (case-insensitive). Picking a profile prefills `username`
for `POST /v1/auth/login`; passwordless sign-in still goes through the discoverable
passkey ceremony (`POST /v1/auth/passkeys/authenticate/begin`).

**404** `not_found` — the directory is disabled (`signInUserList` off).

### `GET /v1/auth/directory/{userId}/avatar` — unauthenticated, **opt-in**

The profile picture for a chooser entry, served without a token so the picker can
render it pre-auth. Gated by the same `signInUserList` setting. **404** when the
directory is disabled or the user has no avatar.

### `POST /v1/auth/refresh`

**Body** `{ "refreshToken": "..." }`

Returns a **new** token pair; the presented refresh token is **rotated** (the old
one is immediately invalidated). Same response shape as login.

**401** `unauthorized` — invalid, expired, or already-rotated refresh token.

### `POST /v1/auth/logout`

**Body** `{ "refreshToken": "...", "allDevices": false }`

Revokes the presented refresh token's session. `allDevices: true` revokes every
session on the same device id. **204 No Content** on success (idempotent).

### `GET /v1/auth/sessions` — auth required

The caller's active sign-in sessions (one per device), newest-active first. **200** →
```json
{ "sessions": [ { "id": "ses_…", "deviceId": "phone", "current": true,
                  "createdAt": "…", "lastActiveAt": "…", "expiresAt": "…" } ] }
```
`current` flags the requesting session. Powers the "signed-in devices" list on the
[`/user`](#discovery) page.

### `DELETE /v1/auth/sessions/{sessionId}` — auth required

Sign out one of the caller's **own** devices. **204**; idempotent; scoped to the
caller (a user can only revoke their own sessions). Revoking the current session
signs this device out on its next request.

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
- **`user.avatarURL`** — the `User` object carries an optional `avatarURL`. When
  the user has uploaded a profile picture it is a server-relative path
  (`/v1/users/<id>/avatar?v=…`); otherwise it is omitted. Clients tolerate its
  absence and resolve the path against the server base URL.

A client should use this (not `/v1/info`) to decide which affordances to show
(browse, contribute markers, edit metadata, …).

### `PATCH /v1/auth/me` — auth required

Update the authenticated user's **own** profile. **Body** (only the provided
fields change):
```json
{ "displayName": "Bob B." }
```
`displayName`, when present, must be non-empty (**400** otherwise). Returns the
refreshed `MeResponse` (same shape as `GET /v1/auth/me`).

### `PUT /v1/auth/me/avatar` — auth required

Upload (or replace) the authenticated user's profile picture. The request body is
the **raw image bytes** (not JSON); send `Content-Type: image/png`, `image/jpeg`,
or `image/webp`. The image type is validated from the bytes (the declared
content-type is not trusted) and the size is capped (`avatarMaxBytes` setting,
default 2 MB).

Returns the refreshed `MeResponse`, now with `user.avatarURL` set. **400** if the
bytes are not a supported image or exceed the size cap.

### `DELETE /v1/auth/me/avatar` — auth required

Remove the authenticated user's profile picture. Idempotent. Returns the
refreshed `MeResponse` with `user.avatarURL` omitted.

### `GET /v1/users/{userId}/avatar` — auth required

Stream a user's hosted profile picture (the bytes, with the stored image
`Content-Type`). Any authenticated user may load any user's avatar, so clients can
render other members' pictures. **404** if that user has no avatar.

### `POST /v1/auth/password` — auth required

Change the authenticated user's **own** password. **Body**
`{ "currentPassword": "…", "newPassword": "…" }`. **204** on success; **401** if
the current password is wrong. The presenting session stays valid.

---

## Passkeys (WebAuthn)

Passwordless sign-in with a [WebAuthn](https://www.w3.org/TR/webauthn-2/) passkey
(Touch ID / Face ID, a platform passkey synced via iCloud Keychain / Google
Password Manager, or a hardware security key). Available **only when the server
advertises `capabilities.passkeys == true`** — i.e. an admin has configured a
Relying Party (RP id + origin). When it's `false`, the `/v1/auth/passkeys/*`
routes are absent (**404**) and clients must use password login.

Each ceremony is two calls. The **begin** call returns a server-generated
`challengeId` plus a standard WebAuthn `publicKey` options object; the
**finish** call echoes that `challengeId` together with the authenticator's
response. A `challengeId` is **single-use** and short-lived (≈5 min): the server
stores the issued challenge, validates the response against it, then consumes it.

The `publicKey` payloads and the authenticator `credential` objects are the
**standard W3C WebAuthn JSON shapes** — exactly what `navigator.credentials`
(browser) or `ASAuthorization` (Apple platforms) produces/consumes, with binary
fields base64url-encoded. Build them with your platform's WebAuthn API rather than
by hand; only the Sphynx-specific `challengeId` envelope is documented in detail
below.

Enrollment requires an existing session (you add a passkey while logged in);
signing in with a passkey is public. Passwords remain available as the
bootstrap/fallback credential.

### `POST /v1/auth/passkeys/register/begin` — auth required

Begin enrolling a passkey for the authenticated user. No body.

**200**
```json
{
  "challengeId": "pkc_…",
  "publicKey": {
    "challenge": "<base64url>",
    "rp":   { "id": "media.example.com", "name": "My Library" },
    "user": { "id": "<base64url>", "name": "alice", "displayName": "Alice" },
    "pubKeyCredParams": [ { "type": "public-key", "alg": -7 } ],
    "timeout": 300000,
    "attestation": "none"
  }
}
```
Pass `publicKey` to `navigator.credentials.create({ publicKey })` (or the platform
equivalent).

### `POST /v1/auth/passkeys/register/finish` — auth required

Complete enrollment. **Body**:
```json
{
  "challengeId": "pkc_…",
  "label": "iPhone",
  "credential": { /* RegistrationCredential from the authenticator */ }
}
```
`label` is an optional nickname (defaults to `"Passkey"`). **201** returns the
stored [`PasskeyInfo`](#passkeyinfo). **400** if the attestation can't be verified
or the challenge is invalid/expired.

### `POST /v1/auth/passkeys/authenticate/begin` — unauthenticated

Begin a passwordless sign-in. No body. The options intentionally omit
`allowCredentials`, so the authenticator offers its **discoverable** passkeys for
this RP and the user picks one.

**200**
```json
{
  "challengeId": "pkc_…",
  "publicKey": { "challenge": "<base64url>", "rpId": "media.example.com", "timeout": 60000, "userVerification": "preferred" }
}
```
Pass `publicKey` to `navigator.credentials.get({ publicKey })`.

### `POST /v1/auth/passkeys/authenticate/finish` — unauthenticated

Complete sign-in. **Body**:
```json
{
  "challengeId": "pkc_…",
  "credential": { /* AuthenticationCredential from the authenticator */ }
}
```
On a verified assertion, returns the **same `TokenResponse` as `POST /v1/auth/login`**
(access + refresh tokens, scoped to the `X-Sphynx-Device` device). **401** if the
assertion fails or the credential is unknown; **400** if the challenge is
invalid/expired.

### `GET /v1/auth/passkeys` — auth required

List the authenticated user's passkeys, newest first.

**200**
```json
{ "passkeys": [
  { "id": "pk_…", "label": "iPhone", "createdAt": 1719500000.0, "lastUsedAt": 1719600000.0, "backedUp": true }
] }
```
<a id="passkeyinfo"></a>**`PasskeyInfo`** — `id` (opaque `pk_…`, used in the
management URLs below — *not* the raw WebAuthn credential id), `label` (nickname),
`createdAt`, `lastUsedAt` (nullable), `backedUp` (whether it's a synced
multi-device passkey). Never includes key material.

### `PATCH /v1/auth/passkeys/{id}` — auth required

Rename a passkey. **Body** `{ "label": "…" }` (non-empty). **200** returns the
updated `PasskeyInfo`; **404** if the id isn't one of the caller's passkeys.

### `DELETE /v1/auth/passkeys/{id}` — auth required

Remove a passkey. **204** on success; **404** if the id isn't one of the caller's
passkeys.

> **Configuration.** Passkeys are off until an admin sets the Relying Party in
> **Settings** (`passkeyRelyingPartyID`, optional `passkeyRelyingPartyName` and
> `passkeyRelyingPartyOrigin`; see [Admin settings](#admin-server-specific-not-part-of-the-wire-protocol)).
> The RP id is the registrable domain the server is reached at (no scheme/port,
> e.g. `media.example.com`); the origin defaults to `https://<rpId>`. These must
> match the client's origin or every ceremony fails — a constraint of WebAuthn,
> not Sphynx.

---

## Device authorization (QR / code sign-in)

Passwordless sign-in for **TVs and other limited-input clients** — an RFC 8628-style
device-authorization grant. The device shows a QR (and a short code); the user
approves it on a second device where they're already signed in (typically with a
**passkey**); the device polls and receives the same `TokenResponse` as any login.
Advertised via `capabilities.deviceAuth`.

```
 ┌── TV ──┐                         ┌── phone (signed in) ──┐
 │ start  │──┐                      │                       │
 │  poll  │  │  authorization_      │   scan QR / enter code│
 │  poll  │  │   pending …          │   approve ────────────┼──► device/approve
 │  poll  │◄─┘  → TokenResponse ◄───┼───────────────────────┘
 └────────┘                         └───────────────────────┘
```

### `POST /v1/auth/device/start` — unauthenticated

The device begins. Send `X-Sphynx-Device` (its install id); optional body
`{ "label": "Living Room TV" }` names it on the approval screen.

**200**
```json
{
  "deviceCode": "…",
  "userCode": "WXYZ-2345",
  "verificationUri": "https://server/link",
  "verificationUriComplete": "https://server/link?code=WXYZ-2345",
  "interval": 5,
  "expiresIn": 600
}
```
The device renders a **QR of `verificationUriComplete`** and shows `userCode` for
manual entry. `deviceCode` is the secret it polls with (never shown to the user).
`interval` is the minimum seconds between polls; the request expires after
`expiresIn`. `verificationUri` is the server's public base URL + `/link` (configured
via the passkey Relying-Party origin, else `http://<host>:<port>`).

### `POST /v1/auth/device/token` — unauthenticated

The device polls with `{ "deviceCode": "…" }`. Until approved, **400** with an error
`code` of `authorization_pending` (keep polling), `expired_token` (start over), or
`invalid_grant` (unknown/already-claimed). Once approved, **200** with a full
[`TokenResponse`](#post-v1authlogin--unauthenticated) — a real session for this
device. The code is **single-use**: a second claim fails.

### `GET /v1/auth/device/pending?code=<userCode>` — auth required

Lets the approval UI confirm *which* device it's authorizing. **200**
`{ "label": "Living Room TV", "expiresIn": 540 }`; **404** if the code is unknown or
expired.

### `POST /v1/auth/device/approve` — auth required

The signed-in user approves a pending device: `{ "userCode": "WXYZ-2345" }` → **204**.
**404** if unknown/expired. The approver authenticated however they like — **a passkey
makes this the "scan, Face ID, done" flow**. The reference server hosts a browser
approval page at **`GET /link`**; a native client may call this endpoint directly
from its own (passkey-authenticated) session.

---

## Web authorization (OAuth-style)

A seamless **same-device web sign-in** for clients that can't add the server's host
to an Associated Domains entitlement — the self-hosted case, where the app can't be
re-signed per server, so platform passkeys and universal-link callbacks aren't
available. It mirrors the OAuth 2.0 authorization-code grant but returns to the app
via a **custom URL scheme** instead of a universal link, so it needs no Associated
Domains and no per-owner app signing. The client drives it with
`ASWebAuthenticationSession` (or the platform equivalent). Advertised via
`capabilities.webAuth`.

```
 ┌──────── app ────────┐                    ┌──── hosted login page ────┐
 │ open web/start  ────┼───────────────────►│  username + password      │
 │  (ASWebAuth…)       │                     │  authorize ──► mint code  │
 │ capture redirect ◄──┼── scheme://?code ◄──┼── redirect                │
 │ web/token (+verifier)──► TokenResponse    └───────────────────────────┘
 └─────────────────────┘
```

**PKCE is recommended.** Before starting, the client generates a high-entropy
`code_verifier` and sends its challenge (`code_challenge` =
BASE64URL(SHA256(verifier)) with `code_challenge_method=S256`). The code can then
only be redeemed by the client that holds the verifier, which matters because any
app could register the same custom scheme. `plain` is accepted but discouraged; the
non-PKCE flow works but is not recommended.

**`state`** is an opaque value the client generates and must verify on return
(it's echoed back unchanged) to tie the redirect to the request it started.

### `GET /v1/auth/web/start` — unauthenticated

The client opens this URL in a web-authentication session. The server renders its
normal login page; on a successful sign-in the page redirects to
`redirect_uri?code=<authCode>&state=<state>`.

**Query params**

| param | required | notes |
|---|---|---|
| `redirect_uri` | yes | Where the code is delivered. Must pass the server's allowlist (see below); a bad target renders an error page (**400**), not a login form. |
| `state` | recommended | Opaque; echoed back on the redirect. |
| `code_challenge` | recommended | PKCE challenge. |
| `code_challenge_method` | with challenge | `S256` (recommended) or `plain`. Defaults to `plain` if a challenge is sent without it. |

The page submits credentials to `POST /v1/auth/web/authorize`
`{ username, password, redirectUri, state?, codeChallenge?, codeChallengeMethod? }`,
which (on success) returns `{ "redirectTo": "<redirect_uri>?code=…&state=…" }` and
the page navigates there. The browser never receives a session token — only the
short, single-use `code`.

### `POST /v1/auth/web/token` — unauthenticated

The client redeems the code for a session. Honors `X-Sphynx-Device` for session
scoping, like the other auth routes (the session is scoped to the **exchanging
client's** device, not the browser's).

**Body** `{ "code": "<authCode>", "codeVerifier": "<verifier>" }` — `codeVerifier`
is required when the flow used PKCE; omit it otherwise.

**200** — a full [`TokenResponse`](#post-v1authlogin--unauthenticated) (same shape as
`/v1/auth/login`).

**400** with an error `code` of:
- `invalid_grant` — unknown, expired, or already-used code, or PKCE verification
  failed. The code is **single-use** (consumed on first exchange) and short-lived
  (**~60s** TTL).

### `redirect_uri` allowlisting

To prevent open redirects, `redirect_uri` is validated server-side:

- With an **allowlist configured** (the `webAuthRedirectAllowlist` setting — a
  newline/comma-separated list of exact URIs or scheme prefixes such as
  `ocelot://auth`), the redirect must equal, or begin with, a listed entry.
- With **no allowlist** (the default), app **custom schemes are accepted** (a
  deep link can't be an open redirect to an arbitrary web origin) while `http(s)`
  targets are **rejected** — an operator must allowlist a web origin to permit it.
  This makes the flow work for a native app out of the box while keeping web
  redirects locked down. PKCE is what binds the code to the legitimate client.

The setting is runtime-tunable via the admin API/GUI (`PATCH /v1/admin/settings`,
field `webAuthRedirectAllowlist`); the `SPHYNX_WEB_REDIRECT_ALLOWLIST` env var only
seeds it on first run.

> Device authorization (above) remains the fallback for **tvOS / input-limited**
> clients that can't present a web view.

---

## Browse

### `GET /v1/libraries` — auth required

The top-level collections a user can browse.

**200**
```json
{ "libraries": [ { "id": "lib_…", "title": "Movies", "kind": "movies" } ] }
```
`kind` is an open string enum (`movies`, `tvShows`, `homeVideos`, `musicVideos`,
`music`, `audiobooks`, `boxSets`, `collection`, `other`, …); clients map unknown
kinds to a default. `music`/`audiobooks` are protocol-modelled but **not produced by
the reference server** — see [Music & audiobooks](#music--audiobooks).

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
| `year` | — | Top level only: keep items of this release year |
| `unwatched` | — | `true` ⇒ drop items the caller has marked watched |

The supported `sort` keys and filter params are advertised in
[`capabilities.browse`](#discovery) (`{ "sorts": [...], "filters": [...] }`), so a
client builds its sort/filter UI from the contract instead of guessing. Items fold
the caller's per-user state: `resumePosition`, `watched`, `playCount`, `isFavorite`,
`lastPlayedAt` (see [Item shape](#item-shape)). `sort`/`genre`/`year` apply to a
library's top level; children of an item (seasons/episodes) keep their natural order.

**200**
```json
{ "items": [ { "id": "it_…", "type": "movie", "title": "…", "year": 2008 } ],
  "nextCursor": "b2Zmc2V0OjUw",
  "totalCount": 947,
  "pageSize": 50 }
```
An absent `nextCursor` means the end of the list. `totalCount` is the **structural**
total under this parent matching `genre`/`year` — the full set the cursor paginates,
so a client can show "1–50 of 947". It does **not** account for the per-user
`unwatched` post-filter (which is applied per page). `pageSize` echoes the effective
limit the server applied after its own clamping. Both are present on `/v1/items`;
the home feeds omit them.

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

#### How clients should implement extras

The contract is deliberately narrow: **the server classifies, the client presents.**
The server guarantees two things — every extra carries an extras `type` (`trailer` /
`featurette` / `deletedScene` / `behindTheScenes`), and every extra hangs off its
title via `parentId`. It does **not** dictate layout. How extras are surfaced is
entirely a client decision; the same catalog can be rendered three different ways by
three different clients without any server change.

To consume them:

1. Browse a title's children with `GET /v1/items?parent=<movieId|seriesId>`. The
   response mixes the title's structural children (a show's `season` rows) with its
   extras (`trailer` / `featurette` / `deletedScene` / `behindTheScenes` rows).
2. **Partition by `type`.** Pull the four extras types out of the listing and group
   them by `type` — that grouping is the basis for every presentation below. Treat
   any `type` you don't recognize as a generic extra (the set is open and may grow);
   never assume the list is exhaustive.
3. Play an extra exactly like any leaf item — `GET /v1/resolve/<id>` returns its
   direct URL. Extras carry no TMDB id and only the metadata parsed from their
   filename (`title`, `container`), so render them as simple clips, not rich tiles.

Presentation is open — common, equally-valid patterns a client may choose:

- **A "Bonus / Extras" shelf** on the title's detail screen, optionally sub-grouped
  into "Trailers", "Deleted Scenes", "Featurettes", "Behind the Scenes" by `type`.
  This is the most common layout and the recommended default.
- **A pseudo-season per category.** A client may present each extras `type` as if it
  were a season of the show — e.g. a "Deleted Scenes" row or a "Featurettes" row
  shown next to *Season 1*, *Season 2*, … — by synthesizing those groupings client-side
  from the `type` partition. Note this is a **client-side rendering choice only**: the
  server never emits a `season`-typed container for extras, and the extras' real
  `parentId` is the title, not a season. (A genuine `season` with `seasonIndex: 0` —
  *Specials* — is different: those are real aired episodes the server enriches from
  TMDB, not bonus clips. Don't conflate the two.)
- **A dedicated "Extras" library/view.** A client may instead collect extras across
  titles into their own top-level section. Build it by walking each title's children
  and bucketing the extras client-side; the server exposes no separate extras library
  or endpoint, so this view is composed entirely on the client.

In short: rely on `type` + `parentId`; choose whatever of the above (or another
layout) fits your UI. The server will not change shape underneath you.

### Collections / box sets

When a movie belongs to a TMDB collection, the server creates (or reuses, deduped
by collection id) a `collection`-typed item in that movie's library and links the
movie to it via `collectionId`/`collectionTitle` **and** the generic `parentId`. The
collection then appears at the library's top level; its members are browsed with the
existing `GET /v1/items?parent=<collectionId>`. No new endpoint — a collection is
just another container.

**Collections library.** A library of kind `collection` holds no items of its own —
it's a **cross-library view**. Browsing it with `GET /v1/items?parent=<collectionLibraryId>`
aggregates every box-set tile across the server (movie and series collections alike),
newest first, paginated like any top level. The aggregate is scoped to the libraries
the caller may read, so a box set whose titles live in an off-limits library never
surfaces there. Each tile still opens to its members via `?parent=<collectionId>` as
usual. Enable it like the other server libraries (one per kind).

**Manual collections.** Collections can also be curated **by hand**, in any library
and for **series** as well as movies (TMDB has no collection data for TV, so series
box sets are always manual). A manual collection is the same `collection`-typed item,
just with no `tmdbId`; its members are linked exactly like auto-discovered ones, so it
groups, browses, and obeys the threshold identically. Curated via the
`/v1/admin/collections` endpoints (see *Admin → collections*), gated by the
`collections.edit` permission so curation can be delegated independently of metadata
editing. Collection tiles are never enriched/identified on their own.

**Grouping threshold.** Whether a collection actually surfaces as a box-set tile is
governed **server-side** by the owning library's `collectionThreshold` (set via the
admin API; see *Admin → libraries*). A collection appears at the top level only when
it has at least `collectionThreshold` present members; below that, the tile is hidden
and its member movies/series are listed individually at the top level instead. The
default is `2` (so a single owned title isn't shown as a one-item box set); set it to
`1` to group any non-empty collection. Raising it ungroups small box sets with no
re-indexing — the `collectionId`/`parentId` links are untouched, so the collection is
still directly browsable via `?parent=<collectionId>`. Clients do nothing here: they
render whatever the top-level browse returns. The threshold is **not** carried on the
wire `Library` object — grouping is resolved before items are projected. The same
grouping applies to the **Recently Added** home row (`GET /v1/home/recent`).

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

## Music & audiobooks

> **The reference server does not implement music or audiobooks** — it has no
> audio identification/enrichment (TMDB is film/TV only), so it never produces these
> item types and won't advertise their fields in `capabilities.fields`. The
> **protocol**, however, fully models them, so another Sphynx-compatible server can
> serve an audio library without any wire changes. This section is that contract.

Audio reuses the same primitives as everything else — libraries, the parent/child
tree (`parentId` + `?parent=`), `resolve`, playstate, per-user state — with audio
types and a few ordering fields.

**Libraries.** `Library.kind` gains `music` and `audiobooks` (distinct from the
existing `musicVideos`, which is video).

**Hierarchy** (mirrors series → season → episode), nested via `parentId`:

| Domain | Tree | `Item.type` |
|---|---|---|
| Music | artist → album → track | `artist` / `album` / `track` |
| Audiobooks | audiobook → chapter | `audiobook` / `chapter` |

**Item fields for audio** (all optional; a server sets what applies):

- `artistName`, `albumTitle` — denormalized parent names so a track tile renders
  without extra fetches (the audio analogue of `seriesTitle`). For an **audiobook**,
  map author → `artistName`, book → `albumTitle`, chapter № → `trackNumber`.
- `trackNumber` — 1-based track/chapter number within its album/audiobook.
- `discNumber` — 1-based disc for a multi-disc album (absent ⇒ single disc).
- `runtime` (seconds), `images`, `genres`, `communityRating`, `cast` (performers),
  `extra` (anything beyond the canonical set — BPM, ISRC, narrator, …) all apply
  unchanged.

**Lossless / hi-res audio.** A client learns a track's quality from the described
streams on `resolve` — `MediaStream` carries the audio detail:

```json
"tracks": { "streams": [
  { "index": 0, "kind": "audio", "codec": "flac",
    "sampleRate": 96000, "bitDepth": 24, "channels": 2, "bitRate": 4600000 }
]}
```

- `codec` + `bitDepth` + `sampleRate` is what marks a stream **lossless / hi-res** —
  e.g. `flac`/`alac` at `bitDepth: 24`, `sampleRate: 96000` renders as "FLAC 24/96".
  A lossy stream (`aac`/`mp3`) sets `bitRate` and omits `bitDepth`.
- When a title exists in multiple qualities (FLAC **and** MP3), expose them as
  [versions](#multi-version--editions): each `MediaVersion.label` names the quality
  ("FLAC 24/96", "MP3 320"), and `resolve?version=<id>` picks one — exactly the
  movie 4K/1080p mechanism, reused for audio.

A field-rich audio server populates these from a tag/probe pass (e.g. an
`ffprobe`-style extension, the same shape the media-probe extension already uses for
video streams).

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
  never re-delivers boundary items. **`since` is EXCLUSIVE** of the prior call's
  `until` instant, and items sharing an exact change-timestamp are ordered by item
  id — so a same-instant change is never double-delivered nor dropped.

---

## Search — optional

Search is an **optional** capability. A server advertises whether it implements
server-side search via `capabilities.search`; the **reference server sets it to
`false`** and does **not** expose `/v1/search`. When `search` is `false` the
endpoint is absent (a call returns **404**), and the client searches its **own**
synced catalogue — which is encouraged (see the
[guide](https://reckloon.github.io/Sphynx-Media/#search) for client-side strategies,
including Ocelot's on-device LLM search).

The protocol standardizes only the **shape** so that any server which *does* offer
search is interchangeable:

### `GET /v1/search?q=<query>` — auth required *(only when `capabilities.search`)*

Query parameters: `q` (the query, **required**), `type` (optional `ItemType`
filter, e.g. `movie`), `limit`, `cursor` (opaque, from a prior `nextCursor`).

**200** — a `SearchResponse`, shaped like [`/v1/items`](#browse) so the client
reuses the same rendering:
```json
{ "items": [ /* Item, most-relevant first */ ], "nextCursor": "offset:20", "query": "blade" }
```
- `items` — matching items, server-ranked. `nextCursor` — absent at end of results.
  `query` — the query echoed back (optional).
- How matching/ranking is done is entirely the server's choice; the protocol
  constrains only the request params and the response shape.

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

A non-authoritative `PUT` is **last-writer-wins**: there is **no version/ETag
precondition**, so two clients that refresh the same stale markers simply overwrite
each other — the most recent contribution wins. Only authoritative markers are
protected (by the 409 above).

Contributed markers also appear in the `/resolve` descriptor's `markers`.

---

## Resolve

### `GET /v1/resolve/{itemId}` — auth required

The late-bound handoff: turns an item into a direct, playable location. Called at
play time, never cached from browse.

**Query:** `version=<id>` *(optional)* — when an item has multiple
[versions/editions](#multi-version--editions), play a specific one. Absent ⇒ the
item's **default** (first/highest-quality) version. An unknown id is **404**
`not_found` — never a silent fallback, so a client that asked for the 4K never gets
handed the 1080p.

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
  A server **SHOULD always emit `terminal` explicitly**; the built-in `http` and
  `local` drivers always emit `terminal: true`. The absent/false fallback above
  remains defined for servers that don't set it, but **relying on absence is
  discouraged** (it has caused real client bugs).
- `ttl` (time-to-live, seconds) — *optional.* When the source returns a time-bounded link (e.g. a signed
  CDN URL), how many seconds it stays valid; the server passes the driver's value
  straight through and never persists it. The built-in `http`/`local` drivers
  return plain, non-expiring URLs, so `ttl` is absent. Absent = no expiry.
- `tracks` — *optional.* Track selection hints plus, once the media has been probed,
  the full per-track detail:
  - `preferredAudio` / `preferredSubtitle` / `copyableAudio` — source-relative
    **indices** (the always-available, cheap hint). `copyableAudio` is defined in
    the protocol but **not populated by the reference server** today; clients
    tolerate its absence.
  - `streams` — described in-container streams, each
    `{ "index", "kind", "codec", "language", "title", "channels", "isDefault", "isForced" }`
    (`kind` is `audio` | `subtitle` | `video` | …). Lets a client render an
    "Audio: English 5.1 / Subtitles: Spanish" picker without demuxing the file.
  - `externalSubtitles` — sidecar subtitle files beside the media,
    `{ "url", "language", "format" }`.

  `streams`/`externalSubtitles` are **absent until the item has been probed** — the
  built-in resolve path doesn't probe. Populate them by enabling the
  [media-probe extension](#extensions--admin-only) and probing the item; the result
  is cached on the item and folded in here on subsequent resolves.
- `candidates` — *optional.* Ranked fallback locations: if `url` fails, try these in
  order (`{ "url", "headers", "priority" }`, lower `priority` first). The reference
  server populates them from the title's **[other versions](#multi-version--editions)**
  — so a client can fall back to another quality/edition — and advertises
  `capabilities.candidates: true`. Absent for a single-file item. Any
  driver-supplied true mirrors (same file, alternate hosts) lead the list.
- `markers` — optional.
  The descriptor **omits the `markers` field entirely when none are stored** —
  mirroring the **404** from the dedicated `GET …/markers`, so the "no markers yet"
  signal is preserved on both paths.

**404** `not_found` (no such item) / `no_media_source` (item's source unavailable).

#### Multi-version / editions

When one title is backed by **more than one file** — 4K + 1080p, Director's Cut +
Theatrical — the server collapses them into a **single item** (grouped by title +
year) carrying a `versions` array instead of duplicate tiles:

```json
"versions": [
  { "id": "v_…", "label": "4K · HDR10 · Remux", "resolution": "4K",
    "dynamicRange": "HDR10", "container": "mkv", "size": 60129542144 },
  { "id": "v_…", "label": "Director's Cut · 1080p", "resolution": "1080p",
    "edition": "Director's Cut", "container": "mkv" }
]
```

- The array is **best-first** — `versions[0]` is the default a plain `resolve`
  returns. Each `id` is opaque and stable across re-scans (cache a user's choice).
- `versions` is **present only when there's a real choice** (≥2 files); a single-file
  item omits it and resolves by id as usual.
- `label` is a ready-to-show string; `resolution` / `edition` / `dynamicRange` /
  `size` are the structured parts (any may be absent) if a client wants to build its
  own label or sort the picker.
- A client shows a version picker and plays one via `GET /v1/resolve/<id>?version=<vid>`.

The reference server detects versions from filenames (`2160p`/`4K`, `1080p`,
`HDR10`/`DV`, `Director's Cut`, `Extended`, `Remux`, …); a field-rich server may
populate them from a probe instead.

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
misfire (the playhead never advanced past startup) can't clobber a good position —
and nothing below applies.

A **non-failed** stop is resolved against the item's `runtime` (per user):

| Where it stopped | Effect |
|---|---|
| **last 5%** (`position ≥ 95%` of runtime) | marked **watched**, resume **cleared** (drops out of Continue Watching), play **counted** — the "scrobble at the end" behavior (Jellyfin PlayedItems / Plex). |
| **first 5%** (`position ≤ 5%`) | marked **unwatched**, resume **cleared**, **not** counted as a play — a false start is discarded. |
| in between | resume point **stored**, play **counted** (the ordinary partial-watch case). |

If the item has no known `runtime`, every non-failed stop is treated as a partial
watch (store resume, count the play).

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

### `DELETE /v1/playstate`
**Reset the caller's entire watch history (cross-device).** Clears **all** stored
resume positions **and** per-item state (watched flag, play count, last-played) for
the authenticated user across every device — a clean slate. Only ever affects the
caller's own rows; idempotent. **200** →
```json
{ "cleared": 12 }
```
where `cleared` is the number of history rows removed (resume + per-item-state).

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

**Server-side next-up rule:** the server emits a next-up episode only when the
latest **played** episode is marked `watched == true`. That decision — whether the
next-up row exists at all — is the server's, not the client's.

The server stores and exposes the data (per-user position + `updatedAt`, ordered by
recency), and **the client owns presentation policy** — display, sort, and hide
decisions. It has each item's runtime, so it decides what to *show*, but **not**
whether the next-up row exists (that is fixed by the `watched == true` rule above).
A client that wants raw timestamps for its own logic can read them via
`GET /v1/playstate?items=…` (each entry carries `updatedAt`).

### `GET /v1/home/recent` — auth required

**Recently Added**: all top-level items (movies, series, and `collection`/box-set
tiles) newest first, per-user state folded in. Cursor-paginated; `detail` selects
skeleton/full. Same `ItemsResponse` shape.

Collection grouping is honored here exactly as in the per-library browse: a
collection whose present-member count is below its owning library's
`collectionThreshold` is hidden and its member movies/series surface individually
instead (see *Collections / box sets*). So a small (sub-threshold) box set never
appears as a one-item tile in Recently Added — it shows the same effective top
level a user gets when browsing that library.

### `GET /v1/home/favorites` — auth required

The caller's favourited items, most-recently-played first. Cursor-paginated; same
`ItemsResponse` shape.

## Per-user state

### `PUT /v1/items/{itemId}/state` — auth required

Set the caller's state for an item (row-scoped to the subject). **Body** (any
subset) `{ "watched": true, "isFavorite": true, "rating": 8.5 }` → **200** with the
item, the new state folded in. The returned item is a **skeleton** projection
(no `genres`/enrichment — it will read as `genres: null`), so a client should
merge only the per-user fields back into its cached record, not treat the
response as a fresh detail fetch. `403` if the caller can't read the item's library.
Play count and last-played are tracked server-side from playback (a non-failed
`POST /v1/playstate/{id}/stop` bumps them); `watched` / `isFavorite` / `rating` are
explicit here.

- **`watched: true`** — also **clears the caller's resume** for the item (same effect
  as `DELETE /v1/playstate/{id}`), so `resumePosition` reads back 0 and the item drops
  out of `GET /v1/home/continue`. Mark-watched implies finished, matching Jellyfin
  (PlayedItems) and Plex (scrobble).
- **`rating`** — the caller's own rating on a **0–10** scale (a 5-star UI sends
  stars ×2), folded back as `Item.userRating`. `0` clears it (absent ⇒ unrated, not
  zero); out of range ⇒ **400**. Distinct from the crowd's `communityRating` and the
  press's `criticRating`.

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

**Extending the stream.** `type` is an **open discriminator** and unknown `type`s and
fields are ignorable, so the event set grows without any wire-version bump or new
capability: a server adds a new event by emitting another `type` (and/or new fields),
and existing clients simply skip what they don't recognise. Two rules keep additions
safe: (1) every frame carries a stable `type` + `ts`, with nil fields omitted; and
(2) the event stays a **nudge** — small payload, re-fetch the authoritative endpoint —
so a client that doesn't yet handle it loses nothing. The only per-event decision is
**audience**: scope it to the subject for personal data, or to library-readers for
shared data, so delivery stays fail-closed like the REST surface. `capabilities.events`
remains a single boolean ("is the stream available?") — it intentionally does **not**
enumerate types, because clients never depend on a specific event existing.

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
  "refreshTokenTTL": 2592000, "enrichmentTTL": 7776000, "metadataLanguage": "en-US",
  "markersAccess": "readwrite", "markersStaleAfter": 604800,
  "playstateRetention": 31536000, "maintenanceInterval": 86400, "avatarMaxBytes": 2000000,
  "signInUserList": false,
  "passkeyRelyingPartyID": "", "passkeyRelyingPartyName": "", "passkeyRelyingPartyOrigin": "" }
```

`metadataLanguage` is the TMDB language tag (`en-US`, `ru-RU`, …) used during
enrichment. Titles, overviews, and episode names are normalised to it, so the
**display title is the canonical name in your language regardless of how the
source named the file** — a `Бэтмен` release shows as `Batman` under `en-US`. A
manually-edited title 🔒 is never overwritten. Applies on the next scan/refresh.

### `PATCH /v1/admin/settings`

Update any subset of the runtime settings. **Body** e.g.
`{ "serverName": "My Library", "markersAccess": "read", "metadataLanguage": "ru-RU" }`
→ **200** with the full updated settings. Persisted; applies on the next restart.
**400** if `markersAccess` isn't `none`/`read`/`readwrite`. Startup/secret values
(host, port, DB path, admin bootstrap) remain environment variables.

`signInUserList` (default `false`) turns on the pre-auth profile chooser
([`GET /v1/auth/directory`](#get-v1authdirectory--unauthenticated-opt-in)). It
exposes the account list — display names + avatars — before sign-in, so it is
opt-in. Seeds once from `SPHYNX_SIGN_IN_USER_LIST`. Applies on the next restart.

**Passkeys** ([WebAuthn](#passkeys-webauthn)) are configured here too:
`passkeyRelyingPartyID` is the registrable domain the server is reached at — a bare
host, **no scheme/port/path** (e.g. `media.example.com`); a non-empty value turns
on `capabilities.passkeys`. `passkeyRelyingPartyName` is the display name shown by
the authenticator (defaults to `serverName`). `passkeyRelyingPartyOrigin` is the
expected client origin **with scheme** (e.g. `https://media.example.com`; defaults
to `https://<passkeyRelyingPartyID>`). **400** if the RP id contains a scheme/port
or the origin omits one. These must match the client's origin or every ceremony
fails (a WebAuthn constraint). Applies on the next restart.

### `GET /v1/admin/tmdb` · `PATCH /v1/admin/tmdb`

The **TMDB v3 API key** — core metadata config (identification + enrichment depend
on it), set in the GUI instead of (or in addition to) the environment.

- **`GET`** → `{ "configured", "keyHint", "appliesOnRestart" }`. The key is **never**
  returned — only whether one is set and a short hint (e.g. `…1b87`).
- **`PATCH`** `{ "apiKey" }` → stores the key (seeded once from `SPHYNX_TMDB_API_KEY`,
  DB-authoritative thereafter). Takes effect on the next server restart.

### `POST /v1/admin/libraries`

**Body** `{ "title": "Movies", "kind": "movies" }` (`kind` defaults to `other`).
**200** → `{ "id": "lib_…", "title": "Movies", "kind": "movies", "collectionThreshold": 2 }`.
New libraries start at `collectionThreshold: 2`.

### `GET /v1/admin/libraries`

List all libraries. **200** → `{ "libraries": [ { "id": "lib_…", "title": "…", "kind": "…", "collectionThreshold": 2 }, … ] }`.

### `PATCH /v1/admin/libraries/{libraryId}`

Update a library. **Body** (any subset) `{ "title": "…", "kind": "…", "collectionThreshold": 2 }`
→ **200** with the updated library. `collectionThreshold` is the minimum number of
present members a collection needs to surface as a box-set tile at this library's top
level (see *Collections / box sets*); it is clamped to `>= 0`. The default is `2`;
set it to `1` to group any non-empty collection.

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
never pass through the server.

> **The `local` driver does not serve files — it is for testing a library on the
> same machine only.** Sphynx is metadata-only: `resolve` hands the client a
> *location* and never streams bytes (see [Resolve](#resolve)). A plain media file
> under a `local` source resolves to a **`file://` path**, which is reachable only
> by a player running on the server host itself. To serve a local media folder to
> other devices, run a file-serving service over it — a Samba/SMB share, a WebDAV
> server, or any HTTP file server — and use the matching **`smb`** / **`webdav`** /
> **`http`** driver, so `resolve` returns a network-reachable URL that the file
> server (not Sphynx) actually serves. (`local` is still useful with `.strm` files,
> which resolve to whatever URL they contain.)

A single library can be fed by **any number of sources, of any mix of drivers** —
each source just routes its items to a `libraryId` (or per-category via
`libraryMap`), and nothing requires those to be distinct. Point several sources at
the same library to merge them onto one shelf. See the
[guide → Source drivers](https://reckloon.github.io/Sphynx-Media/#ext-drivers) for
the full driver list and how to add a backend.

For a **`torbox`** source (the [TorBox](https://torbox.app) debrid cloud), set
`driver` to `torbox` and put your API key in `secrets.apiKey`. Listing reads your
*ready* torrents, usenet, and web downloads (`mylist`); playback mints a
short-lived direct CDN link (`requestdl`) — there are no `.strm` files, no mount,
and no second database. The catalog is the index, refreshed on the source's own
`refreshInterval` like any other driver.

```json
{ "label": "TorBox", "driver": "torbox", "libraryMap": { "movie": "lib_films", "tv": "lib_shows" },
  "config":  { "categories": "torrents,usenet,webdl", "linkTTL": "3600" },
  "secrets": { "apiKey": "•••" } }
```

Optional `config`: **`categories`** (comma list, subset of
`torrents,usenet,webdl`; default all three), **`linkTTL`** (seconds a minted link
is treated as valid before the client re-resolves; default `3600`), and
**`baseURL`** (API root override; default `https://api.torbox.app/v1/api`).

> **Rate limits.** Every TorBox endpoint allows **300 requests/min per API
> token**. This driver stays well under it: a scan costs one `mylist` call per
> enabled category (≤ 3, paginated only past 1 000 items), and a playback costs
> one `requestdl`. It deliberately does **not** call TorBox's metadata-search
> endpoint (the heavily-throttled, 429-prone one) — Sphynx does its own TMDB
> enrichment. No minimum refresh interval is imposed, keeping parity with the
> other drivers; the shared fetcher still backs off and retries on 429/5xx.

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

### `POST /v1/admin/sources/{sourceId}/scan` — `catalog.scan`

Index one source: fetch its manifest, diff against the catalog, apply
adds/updates/removes. **200** →
`{ "sourceId": "src_…", "scanned": 12, "added": 3, "updated": 1, "removed": 0, "enriched": 3 }`
(`enriched` is the count identified+enriched during the scan; `0` when TMDB isn't configured).
Gated by `catalog.scan` (held globally or scoped to a library the source feeds).

### `POST /v1/admin/libraries/{libraryId}/scan` — `catalog.scan`

Re-scan every source feeding one library (a **per-library refresh**). **200** →
`{ "sources": [ <scan summary>, … ] }`. Gated by `catalog.scan` for that library
(or globally). The admin **Refresh** button per library and a delegated scanner both
use this.

### `POST /v1/admin/scan` — `catalog.scan` (unscoped)

Scan every source. **200** → `{ "sources": [ <scan summary>, … ] }`. Requires the
**unscoped** `catalog.scan` grant (a per-library scope can't authorize this).

### Permissions

Authorization is a **single admin** (the bootstrap account, which holds every
permission implicitly and is the only admin) plus an **open per-user permission
set** the admin grants. Permissions are string keys, stored uniformly and
forward-compatible — unknown keys are tolerated. Well-known keys:

| Key | Grants | Gates |
|---|---|---|
| `library.read` | Browse libraries + resolve/play their items | `/v1/libraries`, `/v1/items`, `/v1/resolve`, `/v1/home/*`, `/v1/playstate/*`, item state |
| `metadata.markers.write` | Contribute intro/credit markers | `PUT /v1/items/{id}/markers` |
| `metadata.images.write` | Contribute artwork *(reserved — no wire endpoint yet; see note below)* | — |
| `metadata.edit` | Read/edit item metadata, lock fields, **re-identify / re-enrich**, and **re-map** a title (move library / re-parent / set type & season-episode) | `GET`/`PATCH /v1/admin/items*`, `POST /v1/admin/items/{id}/identity`, `POST /v1/admin/items/{id}/enrich` |
| `collections.edit` | Create **manual collections** (box sets) and add/remove movies or series, rename, or delete them | `GET`/`POST`/`PATCH`/`DELETE /v1/admin/collections*` |
| `catalog.scan` | Trigger a re-scan/refresh of a source or library (not its config/credentials) | `POST /v1/admin/sources/{id}/scan`, `POST /v1/admin/libraries/{id}/scan`, `POST /v1/admin/scan` |

A key may be **scoped to one library or one item** with a `:<id>` suffix, e.g.
`library.read:lib_abc` grants read for that library only, and `metadata.edit:it_123`
grants editing of a single title. A user may hold the global key and any number of
scoped keys; a gated action passes if the caller holds the global key **or** the key
scoped to the relevant library **or** (where applicable) the relevant item. The
admin always passes. `POST /v1/admin/scan` (whole catalog) needs the **unscoped**
`catalog.scan` — a per-library scope can't authorize a full-catalog scan.

**Admin role vs. permissions.** Most `/v1/admin/*` endpoints (settings, source
config/credentials, libraries CRUD, users, diagnostics) require the **admin role** —
there is exactly one admin (the bootstrap account). The exceptions are delegable to
non-admins via permissions: **item correction** (`metadata.edit`, incl. re-identify,
re-enrich, and re-mapping placement), **collection curation** (`collections.edit`),
and **scanning** (`catalog.scan`). A user who holds `metadata.edit` gets a **Library
correction** panel on the [`/user`](#discovery) page that mirrors the admin tools
(browse/search, "needs metadata" filter, edit + lock, re-identify, re-enrich, and
re-map); a user who holds `collections.edit` gets a **Collections** panel on the same
page (and admins get a **Collections** tab). Re-mapping that moves an item across
libraries needs `metadata.edit` on **both** the current and destination library.

**Permission denied is a clean `403`.** A gated action the caller may not perform
returns **`403` `forbidden`** (the error envelope). Clients should disable/hide the
affordance up front from `GET /v1/auth/me`, surface a clear "you don't have
permission" message on a `403`, and treat it as **terminal and non-retryable**
(distinct from `401` re-auth and `5xx`/timeout retries) — never a silently dead
button.

The permission set is replaced wholesale via
[`PUT /v1/admin/users/{userId}/permissions`](#put-v1adminusersuseridpermissions)
— the admin UI's permission editor reads the current array, toggles global and
per-library grants, and writes the full array back.

### `GET /v1/admin/permissions`

The permission vocabulary for the admin editor (so the UI is data-driven, not
hardcoded). **200** →
```json
{ "permissions": [
    { "key": "library.read", "label": "Browse & play",
      "description": "Browse libraries and resolve/play their items.",
      "scopable": true, "reserved": false } ],
  "libraries": [ { "id": "lib_…", "title": "Movies" } ] }
```
`scopable` keys may be granted per-library (`key:<libraryId>`) for any of the
listed `libraries`; `reserved` keys are accepted and stored but not yet enforced.

> **Image contribution is not yet wire-defined.** There is no image-write endpoint
> in the protocol (no `PUT …/images`), and `images` is only ever advertised
> `read`. The `metadata.images.write` permission and any `images: readwrite`
> advertisement are **reserved for a future endpoint**. Today the only
> client-contributable metadata is **markers**, via
> `PUT /v1/items/{id}/markers`.

### `GET /v1/admin/users`

List all accounts. **200** → `{ "users": [ { "id": "u_…", "username": "bob",
"displayName": "Bob", "avatarURL": "/v1/users/u_…/avatar?v=…", "isAdmin": false,
"permissions": ["library.read"] }, … ] }`. `avatarURL` is omitted when the user
has no profile picture. The admin's `permissions` reflects the full implicit set.

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

### `PUT /v1/admin/users/{userId}/password`

Admin reset of another user's password — **no current password required**. **Body**
`{ "newPassword": "…" }` → **204**. Revokes that user's existing sessions, so they
must sign in again. Cannot target the admin account (**403**; the admin changes its
own via `POST /v1/auth/password`).

### `DELETE /v1/admin/users/{userId}`

Delete a user and revoke all their sessions + per-user state. **204** on success.
The admin account cannot be deleted (**403**).

### `GET /v1/admin/items?parent=<id>` — `metadata.edit`

Browse the catalog as a **raw file hierarchy** for the correction UI: the direct
children of `parent`, where `parent` is a **library id** (→ its top level) or an
**item id** (→ that container's children). **200** → `{ "items": [ <Item>, … ] }`
(full projection, so each carries `type`, `images`, `childCount`).

Unlike the player-facing [`GET /v1/items`](#get-v1items--auth-required), this applies
**no collection grouping** — a collection appears as its own openable row and its
member movies appear individually, a 1-to-1 reflection of the indexed source tree.
It reads the catalog only (no driver/CDN traffic). Gated by `metadata.edit` for the
resolved library (admins always pass), so a non-admin editor can use it — this is
what powers the **Library correction** section of the `/user` page as well as the
admin **Items** tab. `limit` defaults to 250 (max 500).

Two optional filters search the **whole catalog** instead of one parent's children
(so `parent` becomes optional when either is given), spanning every library the
caller can edit:

- `search=<text>` — case-insensitive title substring match.
- `needsAttention=true` — only items still missing metadata (unenriched), excluding
  the extra kinds that never enrich (`trailer`/`featurette`/`deletedScene`/`behindTheScenes`).

They combine. Example: `GET /v1/admin/items?needsAttention=true` lists everything
that still needs identifying/enriching across all libraries; `?search=matrix` finds
every title containing "matrix". This drives the search box and **Needs metadata**
filter in the admin **Items** tab.

### `GET /v1/admin/items/{itemId}` — `metadata.edit`

Read one item with its current **lock state**, for the correction UI. **200**
→ `{ "item": { … }, "lockedFields": ["title", "overview"] }`. Gated by
`metadata.edit` for the item's library (admins always pass). The wire `Item` itself
carries no lock info, so this is how a UI knows which fields are pinned.

### `PATCH /v1/admin/items/{itemId}` — `metadata.edit`

Edit an item's metadata and **lock** each edited field against auto-refresh.
Gated by the `metadata.edit` [permission](#permissions) (honoring per-library
scoping), not the admin role — so a non-admin editor can be granted it.

Every field is optional; each metadata field **present is written and locked**. A
locked field survives every scan, TTL refresh, and forced enrich, so manual edits
stick.
**Body**
```jsonc
{ "title": "…", "overview": "…", "year": 1999, "runtime": 8160,
  "genres": ["…"], "communityRating": 8.2, "officialRating": "PG-13",
  "images": { "primary": "https://…", "backdrop": "https://…", "thumb": "https://…" },
  "placeholder": "https://…",          // custom low-res placeholder (image URL)

  // Structural re-mapping (correction) — fix an item's PLACEMENT, not its metadata:
  "libraryId": "lib_…",                 // move to another library (→ top-level)
  "parentId": "it_…",                   // nest under a series/season (→ derives linkage)
  "seasonIndex": 1, "episodeIndex": 3,  // override the TV position
  "type": "episode",                    // override the item type

  "unlock": ["overview"],               // remove specific locks (re-enable refresh)
  "unlockAll": false }                  // or clear every lock
```
Here `placeholder` is a **bare image-URL string** — a convenience the server
stores and re-serves as the `{ "url": … }` one-of. (The read [Item shape](#item-shape)
keeps `placeholder` as the one-of object; only this admin-edit body takes a bare
string.)

**Re-mapping** corrects where an item lives, for things that landed in the wrong
place or never identified. The server keeps the tree consistent: setting
`parentId` makes the item **nested** (its `libraryId` is cleared and `seriesId` /
`seriesTitle` / `seasonIndex` are derived from the new parent); setting `libraryId`
makes it **top-level** (its parent and series linkage are cleared). Because moving
across libraries changes who can see the item, a re-map that changes `libraryId`
or `parentId` requires `metadata.edit` on **both** the item's current library **and**
the destination (the admin role bypasses this). Unknown `type` or a missing
destination returns **400**; lacking edit on either side returns **403**.

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

### Collections — `collections.edit`

Curate **manual collections** (box sets) — see *Collections / box sets*. All four
endpoints are gated by `collections.edit`, held globally or scoped to the target
library (`collections.edit:lib_…`); admins always pass. A collection here is the same
`collection`-typed container browsed via `GET /v1/items?parent=<id>`, so once it
reaches its library's `collectionThreshold` it groups like any other.

#### `GET /v1/admin/collections?library=<libraryId>`

List a library's collections with their members. **200** →
```json
{ "collections": [
  { "id": "it_…", "title": "The Wormhole Saga", "libraryId": "lib_…",
    "memberCount": 2, "members": [ <Item>, … ] }
] }
```

#### `GET /v1/admin/collections/candidates?library=<libraryId>&search=<text>`

The library's top-level movies/series available to add (already-nested items are
excluded). Optional case-insensitive `search`. **200** → `{ "items": [ <Item>, … ] }`.

#### `POST /v1/admin/collections`

Create a collection, optionally seeding members. **Body**
`{ "libraryId": "lib_…", "title": "The Wormhole Saga", "itemIds": ["it_…", …] }`
(`itemIds` optional). Only top-level items of that same library are linked. **200** →
the created collection (same shape as a `collections` list entry).

#### `PATCH /v1/admin/collections/{collectionId}`

Rename and/or add/remove members in one call. **Body** (any subset)
`{ "title": "…", "addItems": ["it_…"], "removeItems": ["it_…"] }`. A rename keeps
members' denormalized `collectionTitle` in sync. **200** → the updated collection.

#### `DELETE /v1/admin/collections/{collectionId}`

Delete the collection tile, **orphaning** its members back to the library's top level
(the movies/series are kept; only the grouping is removed). **204** on success.

### Diagnostics — all `GET`, admin-only

These power the web admin's activity dashboard, log viewer, and database browser.
They are server-specific (not part of the wire protocol).

- **`GET /v1/admin/status`** → an activity snapshot (current parse/enrich activity
  and recent counters).
- **`GET /v1/admin/overview`** → catalog coverage for the always-visible dashboard
  panel: items **in source** (from the last scan) vs **indexed** (in the DB) vs
  **enriched**, both as overall totals and broken down per library, per source, and
  per content category (`byType`):
  ```json
  { "inSource": 120, "indexed": 118, "enriched": 90,
    "libraries": [ { "id": "lib_…", "title": "Movies", "kind": "movies",
                     "indexed": 60, "enriched": 55 } ],
    "sources":   [ { "id": "src_…", "label": "NAS", "driver": "smb",
                     "libraryId": "lib_…", "lastScannedAt": 1.7e9,
                     "inSource": 60, "lastScanAt": "…", "indexed": 58, "enriched": 50 } ],
    "byType":    [ { "type": "movie", "indexed": 60, "enriched": 55 },
                   { "type": "episode", "indexed": 50, "enriched": 35 },
                   { "type": "trailer", "indexed": 8, "enriched": 0 } ] }
  ```
  `inSource` / `lastScanAt` reflect the most recent scan this process has observed
  (omitted for a source not scanned since startup). `byType` groups every item by
  its `type` — `collection` / `movie` / `series` / `season` / `episode` and the
  extras kinds (`trailer`, `featurette`, `deletedScene`, `behindTheScenes`) — in a
  stable display order (containers → leaf media → extras). It is **exhaustive**:
  the per-type `indexed`/`enriched` counts sum to the catalog totals, which makes
  the enriched gap self-explanatory (extras index but never enrich, so a category
  like `trailer` is `0`-enriched by design, not a failure).
- **`GET /v1/admin/logs?after=<seq>&limit=<n>&level=<level>`** → recent diagnostics
  log lines: `{ "lines": [ … ], "latestSeq": <n> }`. `after` pages by sequence
  (default-ish `limit` 200, max 1000); `level` filters by log level.
- **`GET /v1/admin/db/tables`** → `{ "tables": [ { "name": "item", "rowCount": 42 } ] }`
  for the user tables.
- **`GET /v1/admin/db/query?table=<name>&limit=<n>&offset=<n>`** → a read-only page of
  one table: `{ "table", "columns", "rows", "total", "limit", "offset", "redactedColumns" }`.
  The table name is whitelisted against the real schema (no SQL injection) and
  secret columns (credentials) are redacted. `limit` max 200. Optional search
  filters — applied only when the table has the matching column, with bound
  parameters: **`tmdbId=<id>`** (exact match on the `tmdbId` column) and
  **`name=<text>`** (case-insensitive substring of the `title` column); both narrow
  `total` and the returned rows.

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
  `{ "itemId", "probedURL", "prober", "formatName", "durationSeconds", "streams": [ { "index", "kind", "codec", "language", "title", "channels", "isDefault", "isForced" } ], "externalSubtitles": [ { "url", "language", "format" } ], "chapters": [ { "start", "title" } ] }`.
  Returns **400** when the extension is disabled or `ffprobe` isn't available.
  The result is **cached on the item**, so [`GET /v1/resolve/{id}`](#resolve) then
  serves the streams + external subtitles as its `tracks`, and the item's full
  detail carries the embedded `chapters` — all without re-probing. (TMDB has no
  chapter data; `ffprobe -show_chapters` is the only source.)

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
  "resumePosition": 1342.5, "watched": true, "playCount": 3, "isFavorite": true,
  "userRating": 9.0, "lastPlayedAt": "2026-06-27T12:00:00Z",
  "versions": [ { "id": "v_…", "label": "4K · HDR10 · Remux", "resolution": "4K" } ],
  "updatedAt": "2026-06-27T12:00:00Z",
  "extra": { "anything": [1, 2, 3] }
}
```

The example above shows the **full protocol shape** — every field is optional and
omitted when empty. The **reference server** currently populates the TMDB-derived
fields (overview, year, runtime, genres, `communityRating`, `officialRating`, cast
— including **TV** series/episodes — directors/writers, studios, countries, tagline,
status, premiereDate/endDate, `externalIds.imdb`, `sortTitle`, `tags`, `trailers`,
images incl. `logo`/`banner`) plus `parentId`/`collectionId` and per-user state.
`officialRating` is the content certification (e.g. "PG-13" / "TV-MA"), taken from
the US entry of TMDB's `release_dates` (movies) / `content_ratings` (TV).
`chapters` are filled for any item probed by the **media-probe extension**
(`ffprobe -show_chapters` — TMDB carries no chapters). The one field it never fills
is `criticRating` (a **0–100** review-aggregator score, distinct from the 0–10
audience `communityRating`): TMDB has no critic data, so it needs a different
source — typically an **OMDb-backed extension** keyed by the `externalIds.imdb`
the server already stores (OMDb returns Rotten Tomatoes / Metacritic). The
[guide](https://reckloon.github.io/Sphynx-Media/#ext-criticrating) walks through
adding it; the reference server ships only the documented seam. Until then it
rides in `extra`, and clients render fine without it.
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

Every wire field defined in the protocol is now implemented by the reference
server — including ranked `candidates` in the `/resolve` descriptor
(`capabilities.candidates: true`), built from a title's other versions.

(**Search** is defined-but-unimplemented here, but it's a deliberate
non-goal rather than a to-do — see [Search — optional](#search--optional). And
`criticRating` is left for a critic-source extension — see [Item shape](#item-shape).)

All six source drivers now both resolve **and** list: `local`, `http`
(JSON manifest), `webdav` (`PROPFIND` over the built-in HTTP client), `smb` (via
`smbclient`), `ftp` (via `curl`), and `torbox` (the TorBox debrid API). SMB/FTP
listing needs `smbclient`/`curl` on the server's `PATH`; resolve/playback work
without them. Configure sources in the
web admin's **Libraries → Storage sources** (one connection form per driver) or via
`POST /v1/admin/sources`.
