# Passkeys — implementation guide

How to turn on and implement **passkey (WebAuthn) sign-in** for Sphynx, from both
sides of the wire. This is the practical, method-by-method companion to the exact
request/response shapes in [API.md → Passkeys](API.md#passkeys-webauthn).

A **passkey** is a public/private key pair bound to your server's domain and
unlocked by the device (Face ID, Touch ID, Windows Hello, a security key). The
private key never leaves the authenticator and never touches Sphynx — the server
only ever stores a public key. There is no shared secret to phish, leak, or
reuse, which is why passkeys are the recommended way to sign in (passwords stay
available as a fallback).

---

## 1. Server setup (the operator)

Passkeys are **off until you tell the server its own identity**, because the
WebAuthn ceremonies only work when the server's *Relying Party (RP)* matches the
origin the client actually reaches it at — and only the operator knows that
domain. Until it's set, `GET /v1/info` reports `capabilities.passkeys: false` and
the `/v1/auth/passkeys/*` routes return `404`.

Set these in **/admin → Settings** (or seed them once via environment variables —
after first boot, Settings is the source of truth):

| Setting | Env seed | What it is |
|---|---|---|
| Relying Party **id** | `SPHYNX_PASSKEY_RP_ID` | The **registrable domain**, no scheme or port — e.g. `media.example.com`. This is what binds a passkey to your server. |
| Relying Party **name** | `SPHYNX_PASSKEY_RP_NAME` | Human label the authenticator shows during enrollment. Defaults to the server name. |
| Expected **origin** | `SPHYNX_PASSKEY_ORIGIN` | The full origin **with scheme**, e.g. `https://media.example.com`. Defaults to `https://<RP id>`. |

Three rules that cause 90% of "it won't verify" problems:

1. **The RP id must be a registrable suffix of the origin host.** `media.example.com`
   works for an origin of `https://media.example.com`; `example.com` also works
   (parent domain). `app.media.example.com` does **not** match an RP id of
   `media.other.com`.
2. **Passkeys require a secure context.** Browsers only expose WebAuthn over
   **HTTPS** (or `http://localhost` for local development). For real use, put the
   server behind a reverse proxy with TLS — see the
   [guide → Install](https://reckloon.github.io/Sphynx-Media/#install).
3. **The origin must be exact.** Scheme, host, and (non-default) port all have to
   match what the client sends. `https://media.example.com` ≠
   `https://media.example.com:8443`.

> The RP origin doubles as the server's **public base URL** for the
> [QR / device-code TV sign-in](API.md#device-authorization-qr--code-sign-in):
> setting it is what makes the TV's QR scannable from a phone instead of pointing
> at `localhost`. So configuring passkeys also "fixes" TV login for free.

---

## 2. The ceremony model

Every passkey operation is a two-call **ceremony**. Sphynx issues a challenge on
`begin`, the authenticator signs it, and you return the result on `finish`. A
server-issued **`challengeId`** correlates the two calls — echo it back verbatim.

```
register/begin   → { challengeId, publicKey: <CreationOptions> }   (auth required)
   …authenticator creates a credential…
register/finish  ← { challengeId, label?, credential }   → 201 PasskeyInfo

authenticate/begin  → { challengeId, publicKey: <RequestOptions> }   (public)
   …authenticator signs the challenge…
authenticate/finish ← { challengeId, credential }   → TokenResponse (same as login)
```

- **Enrollment is secured**: you add a passkey *while signed in* (password or an
  existing passkey), so the new key is attached to a known account.
- **Authentication is public**: `authenticate/begin` returns options with **no
  `allowCredentials` list**, so the authenticator offers its **discoverable**
  passkeys for this RP and the user simply picks one — there's no "type your
  username" step.
- The `publicKey` object and the `credential` you send back are the **standard W3C
  WebAuthn JSON shapes** (binary fields base64url-encoded). Don't hand-build them —
  feed them to your platform's WebAuthn API, which does the encoding.

Manage enrolled keys with `GET /v1/auth/passkeys` (list), `PATCH
/v1/auth/passkeys/{id}` (rename), and `DELETE /v1/auth/passkeys/{id}` (remove).

---

## 3. Implementation methods, by client

The wire is identical across platforms; only the local API that talks to the
authenticator differs. Pick the one for your client.

### A. Web / browser — `navigator.credentials`

The reference `/user` page does exactly this. The browser's WebAuthn API consumes
Sphynx's `publicKey` object almost directly; the one chore is base64url ⇆
`ArrayBuffer` conversion for the binary fields (`challenge`, `user.id`,
`credential.rawId`, and the attestation/assertion buffers). A small helper library
(e.g. `@simplewebauthn/browser`'s `startRegistration` / `startAuthentication`)
handles that for you.

```js
// Enroll (user is already signed in; send the bearer token).
const begin = await fetch('/v1/auth/passkeys/register/begin', {
  method: 'POST', headers: { Authorization: `Bearer ${accessToken}` },
}).then(r => r.json());

const credential = await startRegistration(begin.publicKey); // base64url handled
await fetch('/v1/auth/passkeys/register/finish', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${accessToken}` },
  body: JSON.stringify({ challengeId: begin.challengeId, label: 'My laptop', credential }),
});

// Sign in (no token, no username).
const ab = await fetch('/v1/auth/passkeys/authenticate/begin', { method: 'POST' }).then(r => r.json());
const assertion = await startAuthentication(ab.publicKey);
const tokens = await fetch('/v1/auth/passkeys/authenticate/finish', {
  method: 'POST', headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ challengeId: ab.challengeId, credential: assertion }),
}).then(r => r.json()); // → { accessToken, refreshToken, … }
```

If you skip the helper and call `navigator.credentials.create({ publicKey })` /
`.get({ publicKey })` yourself, remember to base64url-decode the incoming binary
fields first and base64url-encode the response before posting it.

### B. Apple platforms (iOS / iPadOS / macOS / tvOS) — `AuthenticationServices`

Use `ASAuthorizationPlatformPublicKeyCredentialProvider` (platform passkeys, synced
through iCloud Keychain) and/or `…SecurityKeyPublicKeyCredentialProvider` (hardware
keys).

- **Register:** parse `publicKey` from `register/begin`, create the provider with
  `relyingPartyIdentifier:` = the RP **id**, build a
  `…CredentialRegistrationRequest(challenge:name:userID:)`, run it through
  `ASAuthorizationController`, then map the resulting
  `ASAuthorizationPlatformPublicKeyCredentialRegistration` into the `credential`
  JSON and POST `register/finish`.
- **Authenticate:** parse `authenticate/begin`, make a
  `…CredentialAssertionRequest(challenge:)` (no credential list → the system shows
  the account picker), and map the assertion back for `authenticate/finish`.
- **tvOS:** the TV usually can't show a passkey sheet, so prefer the
  [device-code flow](API.md#device-authorization-qr--code-sign-in) — the TV shows a
  QR, and the **phone** completes the passkey there. "Scan → Face ID → signed in."

> ⚠️ **Associated Domains is mandatory for platform passkeys — not an optional
> "zero-tap" extra.** `ASAuthorizationPlatformPublicKeyCredentialProvider` only runs
> when the app's **Associated Domains** entitlement lists the server's host as
> `webcredentials:<host>` (e.g. `webcredentials:media.example.com`). Without it the
> ceremony fails with a domain-association error — the entitlement is what makes the
> platform ceremony work at all. Since that entitlement is baked into the shipped
> binary, a **single-tenant / first-party build** (one app, one known server domain)
> can use platform passkeys, but a **general-purpose client that connects to
> arbitrary self-hosted servers cannot** pre-declare unknown domains.
>
> This is why **Ocelot** — which connects to any self-hosted Sphynx server — signs
> in on Apple platforms via **`ASWebAuthenticationSession`** (a browser-delegated
> `/user` sign-in that the server's own RP origin satisfies, no app entitlement
> needed) plus password login, and only exercises the platform-passkey ceremony
> above when the server's host happens to be an associated domain of that particular
> build. Hardware security keys (`…SecurityKeyPublicKeyCredentialProvider`) need no
> entitlement and stay available as the entitlement-free fallback.

### C. Android — Credential Manager

Use Jetpack **`androidx.credentials`** (`CredentialManager`). Pass the
`publicKey` object from `begin` as the request JSON to
`CreatePublicKeyCredentialRequest` (register) or
`GetCredentialRequest` with `GetPublicKeyCredentialOption` (authenticate); hand the
returned response JSON straight back as `credential`. Android wants the RP verified
via a **Digital Asset Links** file (`/.well-known/assetlinks.json`) served from
your origin.

### D. Hardware security keys & cross-device

No extra code: roaming authenticators (YubiKey, etc.) and **cross-device sign-in**
(scan a QR with a phone to use *its* passkey on a desktop browser — "hybrid"
transport) are handled by the platform WebAuthn APIs above. They all resolve to the
same `authenticate/begin` → `finish` pair on the wire.

---

## 4. Testing & troubleshooting

- **`capabilities.passkeys` is `false` / routes 404** — no RP id is set. Configure
  it in Settings.
- **Local development** — `http://localhost` is a permitted secure context. Set RP
  id `localhost` and origin `http://localhost:9410` to test without TLS.
- **"Operation not allowed" / verification fails** — almost always an **RP-id or
  origin mismatch** (rule 1 and 3 above) or a non-secure context (rule 2). Check
  what origin the client actually used versus `SPHYNX_PASSKEY_ORIGIN`.
- **Enroll succeeds but login shows no passkey** — the passkey wasn't created as
  *discoverable* (a resident key). Sphynx's authentication ceremony relies on
  discoverable credentials (no `allowCredentials`); request a resident key at
  registration.
- **A user lost their device** — they sign in with their password (still enabled)
  and remove the stale key with `DELETE /v1/auth/passkeys/{id}`, then enroll a new
  one. Admins can also reset the user's password from the Users tab.

---

See also: [API.md → Passkeys](API.md#passkeys-webauthn) for the precise field
list, [API.md → Device authorization](API.md#device-authorization-qr--code-sign-in)
for the TV/QR flow, and the
[guide](https://reckloon.github.io/Sphynx-Media/#api-passkeys) for the narrative
walkthrough.
