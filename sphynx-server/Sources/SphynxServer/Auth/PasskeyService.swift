import Foundation
import GRDB
import SphynxProtocol
import WebAuthn

/// WebAuthn / passkey ceremonies (registration + passwordless authentication) and
/// passkey management, layered on top of `AuthService`'s sessions.
///
/// - **Registration** happens while logged in: an authenticated user enrolls a
///   passkey, and we store only its public key + verification metadata. The
///   private key never leaves the user's authenticator.
/// - **Authentication** is passwordless and pre-auth: the server hands out a
///   challenge, the authenticator signs it, and a verified assertion mints a
///   normal device-scoped session — the same token pair `login` returns.
///
/// A ceremony's challenge is persisted between its `begin` and `finish` calls as a
/// short-lived, **single-use** row (deleted on finish, swept when expired), so the
/// flow survives a restart and a presented assertion can be validated against the
/// exact challenge that was issued.
struct PasskeyService: Sendable {
    let db: AppDatabase
    let auth: AuthService
    /// Relying Party configuration (domain id, display name, expected origin).
    let relyingPartyID: String
    let relyingPartyName: String
    let relyingPartyOrigin: String
    /// How long an unfinished ceremony challenge stays valid, in seconds.
    let challengeTTL: Double

    private var manager: WebAuthnManager {
        WebAuthnManager(configuration: .init(
            relyingPartyID: relyingPartyID,
            relyingPartyName: relyingPartyName,
            relyingPartyOrigin: relyingPartyOrigin
        ))
    }

    // MARK: Registration (authenticated)

    /// Begin enrolling a passkey for an already-authenticated user. Returns the
    /// challenge id to echo on finish plus the creation options for the client's
    /// `navigator.credentials.create()` / `ASAuthorization` request.
    func beginRegistration(userId: String) async throws -> (challengeId: String, options: PublicKeyCredentialCreationOptions) {
        let user = try await db.writer.read { db in
            try UserRecord.filter(Column("id") == userId).fetchOne(db)
        }
        guard let user else { throw SphynxError.unauthorized("Account no longer exists") }

        let options = manager.beginRegistration(
            user: PublicKeyCredentialUserEntity(
                // The user handle is opaque and must not carry PII; the account id
                // is already an opaque "u_…" token, so its bytes are a safe handle.
                id: Array(user.id.utf8),
                name: user.username,
                displayName: user.displayName
            )
        )
        let challengeId = try await storeChallenge(kind: "register", userId: userId, challenge: options.challenge)
        return (challengeId, options)
    }

    /// Complete enrollment: verify the attestation against the stored challenge and
    /// persist the new credential. `label` is an optional user-facing nickname.
    func finishRegistration(
        userId: String,
        challengeId: String,
        label: String?,
        credential: RegistrationCredential
    ) async throws -> PasskeyInfo {
        let challenge = try await consumeChallenge(id: challengeId, kind: "register", expectedUserId: userId)

        let result: Credential
        do {
            result = try await manager.finishRegistration(
                challenge: challenge,
                credentialCreationData: credential,
                confirmCredentialIDNotRegisteredYet: { credentialId in
                    let existing = try await db.writer.read { db in
                        try PasskeyCredentialRecord.filter(Column("credentialId") == credentialId).fetchCount(db)
                    }
                    return existing == 0
                }
            )
        } catch let error as SphynxError {
            throw error
        } catch {
            throw SphynxError.badRequest("Passkey registration could not be verified: \(error)")
        }

        let now = Date().timeIntervalSince1970
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PasskeyCredentialRecord(
            id: Tokens.newID("pk_"),
            userId: userId,
            // `Credential.id` comes back as standard base64 from this library;
            // normalise to base64url so it matches an assertion's credential id at
            // login time (and the duplicate check above).
            credentialId: EncodedBase64(result.id).urlEncoded.asString(),
            publicKey: Data(result.publicKey),
            signCount: Int(result.signCount),
            label: (trimmed?.isEmpty == false ? trimmed! : "Passkey"),
            backupEligible: result.backupEligible,
            backedUp: result.isBackedUp,
            createdAt: now,
            lastUsedAt: nil
        )
        try await db.writer.write { db in try record.insert(db) }
        return record.toProtocol()
    }

    // MARK: Authentication (passwordless, pre-auth)

    /// Begin a passwordless login. `allowCredentials` is intentionally omitted so
    /// the authenticator offers its **discoverable** passkeys for this Relying
    /// Party — the user picks one and we identify them from the verified assertion.
    func beginAuthentication() async throws -> (challengeId: String, options: PublicKeyCredentialRequestOptions) {
        let options = manager.beginAuthentication(userVerification: .preferred)
        let challengeId = try await storeChallenge(kind: "authenticate", userId: nil, challenge: options.challenge)
        return (challengeId, options)
    }

    /// Complete a passwordless login: verify the assertion against the stored
    /// challenge and the credential's public key, advance the sign counter, and
    /// mint a device-scoped session for the credential's owner.
    func finishAuthentication(
        challengeId: String,
        credential: AuthenticationCredential,
        deviceId: String
    ) async throws -> TokenResponse {
        let challenge = try await consumeChallenge(id: challengeId, kind: "authenticate", expectedUserId: nil)

        let presentedId = credential.id.asString()
        let record = try await db.writer.read { db in
            try PasskeyCredentialRecord.filter(Column("credentialId") == presentedId).fetchOne(db)
        }
        // Same opaque failure whether the credential is unknown or the assertion is
        // bad, so a passkey can't be probed for existence.
        guard let record else { throw SphynxError.unauthorized("Passkey authentication failed") }

        let verified: VerifiedAuthentication
        do {
            verified = try manager.finishAuthentication(
                credential: credential,
                expectedChallenge: challenge,
                credentialPublicKey: Array(record.publicKey),
                credentialCurrentSignCount: UInt32(record.signCount)
            )
        } catch {
            throw SphynxError.unauthorized("Passkey authentication failed")
        }

        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            _ = try PasskeyCredentialRecord.filter(Column("id") == record.id).updateAll(
                db,
                Column("signCount").set(to: Int(verified.newSignCount)),
                Column("backedUp").set(to: verified.credentialBackedUp),
                Column("lastUsedAt").set(to: now)
            )
        }
        return try await auth.issueSession(forUserId: record.userId, deviceId: deviceId)
    }

    // MARK: Management (authenticated)

    /// List a user's passkeys, newest first.
    func list(userId: String) async throws -> [PasskeyInfo] {
        let records = try await db.writer.read { db in
            try PasskeyCredentialRecord
                .filter(Column("userId") == userId)
                .order(Column("createdAt").desc, Column("id"))
                .fetchAll(db)
        }
        return records.map { $0.toProtocol() }
    }

    /// Rename one of the user's passkeys. Scoped to the owner.
    func rename(userId: String, passkeyId: String, label: String) async throws -> PasskeyInfo {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SphynxError.badRequest("label must not be empty") }
        let result: PasskeyCredentialRecord? = try await db.writer.write { db in
            guard var record = try PasskeyCredentialRecord
                .filter(Column("id") == passkeyId && Column("userId") == userId)
                .fetchOne(db)
            else { return nil }
            record.label = trimmed
            try record.update(db)
            return record
        }
        guard let result else { throw SphynxError.notFound("No passkey '\(passkeyId)'") }
        return result.toProtocol()
    }

    /// Remove one of the user's passkeys. Scoped to the owner.
    func delete(userId: String, passkeyId: String) async throws {
        let deleted = try await db.writer.write { db in
            try PasskeyCredentialRecord
                .filter(Column("id") == passkeyId && Column("userId") == userId)
                .deleteAll(db)
        }
        guard deleted > 0 else { throw SphynxError.notFound("No passkey '\(passkeyId)'") }
    }

    // MARK: Challenge storage

    private func storeChallenge(kind: String, userId: String?, challenge: [UInt8]) async throws -> String {
        let now = Date().timeIntervalSince1970
        let record = PasskeyChallengeRecord(
            id: Tokens.newID("pkc_"),
            kind: kind,
            userId: userId,
            challenge: Data(challenge),
            expiresAt: now + challengeTTL,
            createdAt: now
        )
        try await db.writer.write { db in
            // Opportunistically sweep expired challenges so the table can't grow
            // unbounded from abandoned ceremonies.
            try PasskeyChallengeRecord.filter(Column("expiresAt") < now).deleteAll(db)
            try record.insert(db)
        }
        return record.id
    }

    /// Atomically fetch-and-delete a challenge (single use), enforcing kind, owner,
    /// and expiry. Returns the challenge bytes the assertion must match.
    private func consumeChallenge(id: String, kind: String, expectedUserId: String?) async throws -> [UInt8] {
        let now = Date().timeIntervalSince1970
        let record: PasskeyChallengeRecord? = try await db.writer.write { db in
            guard let record = try PasskeyChallengeRecord.filter(Column("id") == id).fetchOne(db) else {
                return nil
            }
            try PasskeyChallengeRecord.deleteOne(db, key: id)  // single use, always consumed
            return record
        }
        guard let record,
              record.kind == kind,
              record.expiresAt > now,
              record.userId == expectedUserId
        else {
            throw SphynxError.badRequest("Passkey challenge is invalid or expired")
        }
        return Array(record.challenge)
    }
}
