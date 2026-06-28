import Foundation
import Hummingbird
import SphynxProtocol
import WebAuthn

/// Passkey (WebAuthn) ceremonies + management. Mounted only when a Relying Party
/// is configured (`capabilities.passkeys == true`); otherwise the routes are
/// absent, matching the protocol's "absent ⇒ unsupported" rule.
///
/// Route groups:
/// - **Public** (no bearer): `/v1/auth/passkeys/authenticate/{begin,finish}` —
///   passwordless login. `finish` returns the same `TokenResponse` as password
///   login.
/// - **Secured** (bearer required): `/v1/auth/passkeys/register/{begin,finish}`
///   (enroll a passkey for the logged-in user) plus list / rename / delete.
struct PasskeyController: Sendable {
    let passkeys: PasskeyService

    /// Public routes: passwordless authentication.
    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.post("auth/passkeys/authenticate/begin", use: authenticateBegin)
        group.post("auth/passkeys/authenticate/finish", use: authenticateFinish)
    }

    /// Secured routes: enrollment + management for the authenticated user.
    func addSecuredRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("auth/passkeys", use: list)
        group.post("auth/passkeys/register/begin", use: registerBegin)
        group.post("auth/passkeys/register/finish", use: registerFinish)
        group.patch("auth/passkeys/:passkeyId", use: rename)
        group.delete("auth/passkeys/:passkeyId", use: delete)
    }

    // MARK: Registration (secured)

    @Sendable
    func registerBegin(_ request: Request, context: SphynxRequestContext) async throws -> PasskeyRegistrationBeginResponse {
        let identity = try context.requireIdentity()
        let (challengeId, options) = try await passkeys.beginRegistration(userId: identity.userId)
        return PasskeyRegistrationBeginResponse(challengeId: challengeId, publicKey: options)
    }

    @Sendable
    func registerFinish(_ request: Request, context: SphynxRequestContext) async throws -> EditedResponse<PasskeyInfo> {
        let identity = try context.requireIdentity()
        let body = try await request.decode(as: PasskeyRegistrationFinishRequest.self, context: context)
        let info = try await passkeys.finishRegistration(
            userId: identity.userId,
            challengeId: body.challengeId,
            label: body.label,
            credential: body.credential
        )
        return EditedResponse(status: .created, response: info)
    }

    // MARK: Authentication (public)

    @Sendable
    func authenticateBegin(_ request: Request, context: SphynxRequestContext) async throws -> PasskeyAuthenticationBeginResponse {
        let (challengeId, options) = try await passkeys.beginAuthentication()
        return PasskeyAuthenticationBeginResponse(challengeId: challengeId, publicKey: options)
    }

    @Sendable
    func authenticateFinish(_ request: Request, context: SphynxRequestContext) async throws -> TokenResponse {
        let body = try await request.decode(as: PasskeyAuthenticationFinishRequest.self, context: context)
        return try await passkeys.finishAuthentication(
            challengeId: body.challengeId,
            credential: body.credential,
            deviceId: request.sphynxDeviceID
        )
    }

    // MARK: Management (secured)

    @Sendable
    func list(_ request: Request, context: SphynxRequestContext) async throws -> PasskeyListResponse {
        let identity = try context.requireIdentity()
        return PasskeyListResponse(passkeys: try await passkeys.list(userId: identity.userId))
    }

    @Sendable
    func rename(_ request: Request, context: SphynxRequestContext) async throws -> PasskeyInfo {
        let identity = try context.requireIdentity()
        guard let passkeyId = context.parameters.get("passkeyId") else {
            throw SphynxError.badRequest("Missing passkey id")
        }
        let body = try await request.decode(as: PasskeyRenameRequest.self, context: context)
        return try await passkeys.rename(userId: identity.userId, passkeyId: passkeyId, label: body.label)
    }

    @Sendable
    func delete(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let identity = try context.requireIdentity()
        guard let passkeyId = context.parameters.get("passkeyId") else {
            throw SphynxError.badRequest("Missing passkey id")
        }
        try await passkeys.delete(userId: identity.userId, passkeyId: passkeyId)
        return Response(status: .noContent)
    }
}

// MARK: - Ceremony wire DTOs
//
// These envelopes carry the standard W3C WebAuthn ceremony payloads (the
// `publicKey` options and the authenticator's credential responses), which come
// from the WebAuthn package and therefore live here in the server rather than in
// the Foundation-only protocol package. Their JSON shape is the client contract,
// documented in `docs/API.md`. The Sphynx-specific `challengeId` correlates a
// ceremony's begin and finish calls.

/// `POST /v1/auth/passkeys/register/begin` response.
struct PasskeyRegistrationBeginResponse: ResponseEncodable, Sendable {
    /// Echo this on `register/finish` to bind the assertion to its challenge.
    let challengeId: String
    /// Standard `PublicKeyCredentialCreationOptions` for `navigator.credentials.create()`.
    let publicKey: PublicKeyCredentialCreationOptions
}

/// `POST /v1/auth/passkeys/register/finish` request body.
struct PasskeyRegistrationFinishRequest: Decodable, Sendable {
    let challengeId: String
    /// Optional user-facing nickname for the new passkey.
    let label: String?
    /// The authenticator's `RegistrationCredential` (from `navigator.credentials.create()`).
    let credential: RegistrationCredential
}

/// `POST /v1/auth/passkeys/authenticate/begin` response.
struct PasskeyAuthenticationBeginResponse: ResponseEncodable, Sendable {
    /// Echo this on `authenticate/finish`.
    let challengeId: String
    /// Standard `PublicKeyCredentialRequestOptions` for `navigator.credentials.get()`.
    let publicKey: PublicKeyCredentialRequestOptions
}

/// `POST /v1/auth/passkeys/authenticate/finish` request body.
struct PasskeyAuthenticationFinishRequest: Decodable, Sendable {
    let challengeId: String
    /// The authenticator's `AuthenticationCredential` (from `navigator.credentials.get()`).
    let credential: AuthenticationCredential
}
