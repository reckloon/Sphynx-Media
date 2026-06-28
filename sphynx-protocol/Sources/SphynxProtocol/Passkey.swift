import Foundation

/// Passkey (WebAuthn) support — the **Sphynx-specific** value types around the
/// ceremonies. The ceremony payloads themselves (`PublicKeyCredentialCreationOptions`,
/// the authenticator's `RegistrationCredential` / `AuthenticationCredential`) are
/// the standard W3C WebAuthn JSON shapes a client builds with its platform API
/// (ASAuthorization on Apple platforms, `navigator.credentials` in a browser).
/// They are documented in `docs/API.md` and intentionally **not** modelled here,
/// so this package stays free of a WebAuthn dependency.
///
/// Advertised via `capabilities.passkeys` in `GET /v1/info`. When absent/false the
/// server has no Relying Party configured and the `/v1/auth/passkeys/*` routes
/// reject ceremonies — clients should hide passkey affordances.

/// A registered passkey, as returned by the management endpoints. Never carries
/// key material — only what a client needs to list and manage a user's passkeys.
public struct PasskeyInfo: Codable, Hashable, Sendable {
    /// Opaque, stable server id for this passkey (`pk_…`). Use this in the
    /// management URLs (rename/delete), not the raw WebAuthn credential id.
    public var id: String
    /// User-facing nickname so a person can tell their authenticators apart
    /// (e.g. "iPhone", "YubiKey"). Defaults to a generic label at enrollment.
    public var label: String
    /// When the passkey was enrolled (epoch seconds).
    public var createdAt: Double
    /// When it was last used to sign in (epoch seconds); nil if never used since
    /// enrollment.
    public var lastUsedAt: Double?
    /// Whether the credential is currently backed up / synced (a "multi-device"
    /// passkey, e.g. iCloud Keychain). Informational, for display.
    public var backedUp: Bool

    public init(id: String, label: String, createdAt: Double, lastUsedAt: Double? = nil, backedUp: Bool = false) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.backedUp = backedUp
    }
}

/// Response for `GET /v1/auth/passkeys`: the authenticated user's passkeys,
/// newest first.
public struct PasskeyListResponse: Codable, Hashable, Sendable {
    public var passkeys: [PasskeyInfo]

    public init(passkeys: [PasskeyInfo] = []) {
        self.passkeys = passkeys
    }
}

/// `PATCH /v1/auth/passkeys/{id}` request body: rename a passkey. `label` must be
/// non-empty.
public struct PasskeyRenameRequest: Codable, Hashable, Sendable {
    public var label: String

    public init(label: String) {
        self.label = label
    }
}
