import Foundation
import GRDB
import Logging
import SphynxProtocol

/// Accounts, sessions, and tokens (§3, §9 of the server doc).
///
/// - Access tokens are short-lived; refresh tokens are long-lived and **rotate**
///   on every use (the old one is invalidated).
/// - Sessions are **device-scoped**, so one device can be revoked alone.
/// - Per-user data is row-scoped to the token subject.
/// A public, credential-free profile entry for the sign-in chooser.
struct DirectoryUser: Sendable {
    let id: String
    let username: String
    let displayName: String
    let hasAvatar: Bool
}

struct AuthService: Sendable {
    let db: AppDatabase
    let hasher: PasswordHasher
    let accessTokenTTL: Double
    let refreshTokenTTL: Double
    /// On-disk store for server-hosted profile pictures.
    let avatars: AvatarStore

    // MARK: Bootstrap

    /// Create the admin account on first run, when no users exist yet.
    ///
    /// There is **no default password**: if none was provided, a strong random one
    /// is generated and printed to the log exactly once, so a fresh server is never
    /// reachable with a known credential.
    func bootstrapAdminIfNeeded(username: String, password: String, logger: Logger) async throws {
        let userCount = try await db.writer.read { db in try UserRecord.fetchCount(db) }
        guard userCount == 0 else { return }

        let generated = password.isEmpty
        let effectivePassword = generated ? Tokens.newToken() : password
        let hash = try await hasher.hash(effectivePassword)
        let user = UserRecord(
            id: Tokens.newID("u_"),
            username: username,
            displayName: username,
            avatarURL: nil,
            passwordHash: hash,
            isAdmin: true,
            createdAt: Date().timeIntervalSince1970
        )
        // Re-check the count inside the same write transaction so the
        // check-and-insert is atomic and can never create a second admin.
        let inserted = try await db.writer.write { db -> Bool in
            guard try UserRecord.fetchCount(db) == 0 else { return false }
            try user.insert(db)
            return true
        }
        guard inserted else { return }
        if generated {
            logger.warning("""
            No SPHYNX_ADMIN_PASSWORD set — generated a random password for admin account '\(username)':

                \(effectivePassword)

            Save it now; it is shown only once. Set SPHYNX_ADMIN_PASSWORD to choose your own, \
            or change it later via POST /v1/auth/password.
            """)
        } else {
            logger.warning("Bootstrapped admin account '\(username)' from SPHYNX_ADMIN_PASSWORD.")
        }
    }

    // MARK: Login / refresh / logout

    func login(username: String, password: String, deviceId: String) async throws -> TokenResponse {
        let user = try await db.writer.read { db in
            try UserRecord.filter(Column("username") == username).fetchOne(db)
        }
        // Same error for unknown user and wrong password (no user enumeration).
        guard let user else { throw SphynxError.unauthorized("Invalid username or password") }
        guard await hasher.verify(password: password, encodedHash: user.passwordHash) else {
            throw SphynxError.unauthorized("Invalid username or password")
        }
        return try await issueSession(for: user, deviceId: deviceId)
    }

    /// A minimal public profile listing for the sign-in chooser: every account's
    /// id, username, display name, and whether it has an avatar — and nothing else
    /// (no credentials, permissions, or admin flag). Sorted for a stable display
    /// order. The caller decides whether exposing this pre-auth is allowed.
    func directory() async throws -> [DirectoryUser] {
        let users = try await db.writer.read { db in try UserRecord.fetchAll(db) }
        return users
            .map { DirectoryUser(id: $0.id, username: $0.username, displayName: $0.displayName, hasAvatar: $0.avatarURL != nil) }
            .sorted { ($0.displayName.lowercased(), $0.username) < ($1.displayName.lowercased(), $1.username) }
    }

    /// Rotate a refresh token: validate it, issue a brand-new pair, invalidate
    /// the presented refresh token.
    func refresh(refreshToken: String, deviceId: String) async throws -> TokenResponse {
        let presentedHash = Tokens.hash(refreshToken)
        let now = Date().timeIntervalSince1970
        let accessTTL = accessTokenTTL, refreshTTL = refreshTokenTTL

        let result: TokenResponse? = try await db.writer.write { db in
            guard var session = try SessionRecord.filter(Column("refreshTokenHash") == presentedHash).fetchOne(db),
                  !session.revoked,
                  session.refreshExpiresAt > now,
                  let user = try UserRecord.filter(Column("id") == session.userId).fetchOne(db)
            else {
                return nil
            }

            let access = Tokens.newToken()
            let newRefresh = Tokens.newToken()
            session.accessTokenHash = Tokens.hash(access)
            session.accessExpiresAt = now + accessTTL
            session.refreshTokenHash = Tokens.hash(newRefresh)
            session.refreshExpiresAt = now + refreshTTL
            if !deviceId.isEmpty { session.deviceId = deviceId }
            session.updatedAt = now
            try session.update(db)

            return TokenResponse(accessToken: access, refreshToken: newRefresh, expiresIn: accessTTL, refreshExpiresIn: refreshTTL, user: user.toProtocol())
        }

        guard let result else { throw SphynxError.unauthorized("Invalid or expired refresh token") }
        return result
    }

    /// Revoke the presented refresh token's session, or every session on its
    /// device when `allDevices` is set.
    func logout(refreshToken: String, allDevices: Bool) async throws {
        let presentedHash = Tokens.hash(refreshToken)
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            guard let session = try SessionRecord.filter(Column("refreshTokenHash") == presentedHash).fetchOne(db) else {
                return  // nothing to do; don't leak whether it existed
            }
            if allDevices {
                try SessionRecord
                    .filter(Column("deviceId") == session.deviceId)
                    .updateAll(db, Column("revoked").set(to: true), Column("updatedAt").set(to: now))
            } else {
                var s = session
                s.revoked = true
                s.updatedAt = now
                try s.update(db)
            }
        }
    }

    // MARK: Authentication (per-request)

    /// Resolve an access token to its subject, or nil if missing/expired/revoked.
    func authenticate(accessToken: String) async throws -> AuthIdentity? {
        let presentedHash = Tokens.hash(accessToken)
        let now = Date().timeIntervalSince1970
        return try await db.writer.read { db in
            guard let session = try SessionRecord.filter(Column("accessTokenHash") == presentedHash).fetchOne(db),
                  !session.revoked,
                  session.accessExpiresAt > now,
                  let user = try UserRecord.filter(Column("id") == session.userId).fetchOne(db)
            else {
                return nil
            }
            return AuthIdentity(
                userId: user.id,
                isAdmin: user.isAdmin,
                displayName: user.displayName,
                avatarURL: user.avatarURL,
                sessionId: session.id,
                permissions: user.permissions()
            )
        }
    }

    // MARK: User management (admin)

    /// Create a **non-admin** user. There is exactly one admin (the bootstrap
    /// account), so this never creates another — any caller-supplied admin flag
    /// is ignored by design. Throws `conflict` if the username is taken.
    func createUser(
        username: String,
        password: String,
        displayName: String?,
        permissions: [String]
    ) async throws -> UserRecord {
        let existing = try await db.writer.read { db in
            try UserRecord.filter(Column("username") == username).fetchOne(db)
        }
        guard existing == nil else { throw SphynxError.conflict("Username '\(username)' is taken") }

        let hash = try await hasher.hash(password)
        let permissionsJSON = String(data: try JSONEncoder().encode(permissions), encoding: .utf8)
        let user = UserRecord(
            id: Tokens.newID("u_"),
            username: username,
            displayName: displayName ?? username,
            avatarURL: nil,
            passwordHash: hash,
            isAdmin: false,
            createdAt: Date().timeIntervalSince1970,
            permissionsJSON: permissionsJSON
        )
        try await db.writer.write { db in try user.insert(db) }
        return user
    }

    /// List all accounts (admin first, then by creation time).
    func listUsers() async throws -> [UserRecord] {
        try await db.writer.read { db in
            try UserRecord.order(Column("isAdmin").desc, Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    /// Replace a user's permission set. Returns the updated record. The admin
    /// holds everything implicitly, so its permissions cannot be set.
    func setPermissions(userId: String, permissions: [String]) async throws -> UserRecord {
        let permissionsJSON = String(data: try JSONEncoder().encode(permissions), encoding: .utf8)
        let result: Result<UserRecord, SphynxError>? = try await db.writer.write { db in
            guard var user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else { return nil }
            if user.isAdmin {
                return .failure(SphynxError.badRequest("The admin holds all permissions implicitly"))
            }
            user.permissionsJSON = permissionsJSON
            try user.update(db)
            return .success(user)
        }
        guard let result else { throw SphynxError.notFound("No user '\(userId)'") }
        return try result.get()
    }

    /// Delete a user and revoke all their sessions + per-user state. The admin
    /// cannot be deleted.
    func deleteUser(userId: String) async throws {
        let outcome: SphynxError? = try await db.writer.write { db in
            guard let user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else {
                return SphynxError.notFound("No user '\(userId)'")
            }
            if user.isAdmin {
                return SphynxError.forbidden("The admin account cannot be deleted")
            }
            try SessionRecord.filter(Column("userId") == userId).deleteAll(db)
            try PlaystateRecord.filter(Column("userId") == userId).deleteAll(db)
            // Also purge per-item state (watched/favorite/play-count) so a deleted
            // account leaves nothing behind.
            try UserStateRecord.filter(Column("userId") == userId).deleteAll(db)
            try UserRecord.deleteOne(db, key: userId)
            return nil
        }
        if outcome == nil { avatars.delete(userId: userId) }
        if let outcome { throw outcome }
    }

    /// Admin reset of another user's password — no current password required.
    /// Cannot target the admin account (it changes its own via `changePassword`).
    func adminSetPassword(userId: String, newPassword: String) async throws {
        guard !newPassword.isEmpty else { throw SphynxError.badRequest("newPassword is required") }
        let user = try await db.writer.read { db in
            try UserRecord.filter(Column("id") == userId).fetchOne(db)
        }
        guard let user else { throw SphynxError.notFound("No user '\(userId)'") }
        guard !user.isAdmin else {
            throw SphynxError.forbidden("Use the self-service password change for the admin account")
        }
        let hash = try await hasher.hash(newPassword)
        try await db.writer.write { db in
            _ = try UserRecord.filter(Column("id") == userId)
                .updateAll(db, Column("passwordHash").set(to: hash))
            // Force re-login on the user's other devices after an admin reset.
            try SessionRecord.filter(Column("userId") == userId)
                .updateAll(db, Column("revoked").set(to: true))
        }
    }

    /// Change a user's own password after verifying the current one. Revokes
    /// other sessions is left to the caller; the presenting session stays valid.
    func changePassword(userId: String, currentPassword: String, newPassword: String) async throws {
        guard !newPassword.isEmpty else { throw SphynxError.badRequest("newPassword is required") }
        let user = try await db.writer.read { db in
            try UserRecord.filter(Column("id") == userId).fetchOne(db)
        }
        guard let user else { throw SphynxError.notFound("No user '\(userId)'") }
        guard await hasher.verify(password: currentPassword, encodedHash: user.passwordHash) else {
            throw SphynxError.unauthorized("Current password is incorrect")
        }
        let hash = try await hasher.hash(newPassword)
        try await db.writer.write { db in
            _ = try UserRecord.filter(Column("id") == userId)
                .updateAll(db, Column("passwordHash").set(to: hash))
        }
    }

    // MARK: Self-service sessions (own devices)

    /// The caller's active (non-revoked, unexpired) sessions, newest-active first.
    func listSessions(userId: String, currentSessionId: String) async throws -> [SessionInfo] {
        let now = Date().timeIntervalSince1970
        let records = try await db.writer.read { db in
            try SessionRecord
                .filter(Column("userId") == userId && Column("revoked") == false && Column("refreshExpiresAt") > now)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }
        return records.map { r in
            SessionInfo(
                id: r.id, deviceId: r.deviceId, current: r.id == currentSessionId,
                createdAt: Self.iso8601(r.createdAt),
                lastActiveAt: Self.iso8601(r.updatedAt),
                expiresAt: Self.iso8601(r.refreshExpiresAt))
        }
    }

    /// Revoke one of the caller's own sessions (sign out a single device). Scoped
    /// to the user, so a user can only revoke their own. Silent if it doesn't
    /// exist (don't leak whether a session id is valid).
    func revokeSession(userId: String, sessionId: String) async throws {
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            _ = try SessionRecord
                .filter(Column("id") == sessionId && Column("userId") == userId)
                .updateAll(db, Column("revoked").set(to: true), Column("updatedAt").set(to: now))
        }
    }

    private static func iso8601(_ epoch: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: Self-service profile

    /// Update a user's own profile. Only non-nil fields change. A provided
    /// `displayName` must be non-empty. Returns the updated record.
    func updateProfile(userId: String, displayName: String?) async throws -> UserRecord {
        if let displayName, displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SphynxError.badRequest("displayName must not be empty")
        }
        let result: UserRecord? = try await db.writer.write { db in
            guard var user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else { return nil }
            if let displayName { user.displayName = displayName }
            try user.update(db)
            return user
        }
        guard let result else { throw SphynxError.notFound("No user '\(userId)'") }
        return result
    }

    /// Store an uploaded avatar image for a user and point `avatarURL` at the
    /// server-hosted file. The bytes are validated (real image, size cap) by
    /// `AvatarStore`. A cache-busting `?v=` is appended so clients refetch when the
    /// image changes even though the path is stable. Returns the updated record.
    func setAvatar(userId: String, data: Data) async throws -> UserRecord {
        try avatars.write(userId: userId, data: data)
        let url = "/v1/users/\(userId)/avatar?v=\(Int(Date().timeIntervalSince1970))"
        let result: UserRecord? = try await db.writer.write { db in
            guard var user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else { return nil }
            user.avatarURL = url
            try user.update(db)
            return user
        }
        guard let result else { throw SphynxError.notFound("No user '\(userId)'") }
        return result
    }

    /// Remove a user's avatar (file + `avatarURL`). Idempotent.
    func clearAvatar(userId: String) async throws -> UserRecord {
        avatars.delete(userId: userId)
        let result: UserRecord? = try await db.writer.write { db in
            guard var user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else { return nil }
            user.avatarURL = nil
            try user.update(db)
            return user
        }
        guard let result else { throw SphynxError.notFound("No user '\(userId)'") }
        return result
    }

    /// Issue a fresh session for an already-authenticated subject — the entry
    /// point for passwordless (passkey) login, where the WebAuthn assertion has
    /// already established *who* the user is. Mirrors the tail of `login`.
    func issueSession(forUserId userId: String, deviceId: String) async throws -> TokenResponse {
        let user = try await db.writer.read { db in
            try UserRecord.filter(Column("id") == userId).fetchOne(db)
        }
        guard let user else { throw SphynxError.unauthorized("Account no longer exists") }
        return try await issueSession(for: user, deviceId: deviceId)
    }

    // MARK: Helpers

    private func issueSession(for user: UserRecord, deviceId: String) async throws -> TokenResponse {
        let now = Date().timeIntervalSince1970
        let access = Tokens.newToken()
        let refresh = Tokens.newToken()
        let session = SessionRecord(
            id: Tokens.newID("ses_"),
            userId: user.id,
            deviceId: deviceId.isEmpty ? "default" : deviceId,
            accessTokenHash: Tokens.hash(access),
            accessExpiresAt: now + accessTokenTTL,
            refreshTokenHash: Tokens.hash(refresh),
            refreshExpiresAt: now + refreshTokenTTL,
            revoked: false,
            createdAt: now,
            updatedAt: now
        )
        try await db.writer.write { db in try session.insert(db) }
        return TokenResponse(accessToken: access, refreshToken: refresh, expiresIn: accessTokenTTL, refreshExpiresIn: refreshTokenTTL, user: user.toProtocol())
    }
}
