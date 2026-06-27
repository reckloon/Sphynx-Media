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
struct AuthService: Sendable {
    let db: AppDatabase
    let hasher: PasswordHasher
    let accessTokenTTL: Double
    let refreshTokenTTL: Double

    // MARK: Bootstrap

    /// Create the admin account on first run, when no users exist yet.
    func bootstrapAdminIfNeeded(username: String, password: String, logger: Logger) async throws {
        let userCount = try await db.writer.read { db in try UserRecord.fetchCount(db) }
        guard userCount == 0 else { return }

        let hash = try await hasher.hash(password)
        let user = UserRecord(
            id: Tokens.newID("u_"),
            username: username,
            displayName: username,
            avatarURL: nil,
            passwordHash: hash,
            isAdmin: true,
            createdAt: Date().timeIntervalSince1970
        )
        try await db.writer.write { db in try user.insert(db) }
        logger.warning("Bootstrapped admin account '\(username)'. Change its password via SPHYNX_ADMIN_PASSWORD.")
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

            return TokenResponse(accessToken: access, refreshToken: newRefresh, expiresIn: accessTTL, user: user.toProtocol())
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
                writeGrants: user.writeGrants()
            )
        }
    }

    // MARK: User management (admin)

    /// Create a user. Throws `conflict` if the username is taken.
    func createUser(
        username: String,
        password: String,
        displayName: String?,
        isAdmin: Bool,
        writeGrants: [String]
    ) async throws -> UserRecord {
        let existing = try await db.writer.read { db in
            try UserRecord.filter(Column("username") == username).fetchOne(db)
        }
        guard existing == nil else { throw SphynxError.conflict("Username '\(username)' is taken") }

        let hash = try await hasher.hash(password)
        let grantsJSON = String(data: try JSONEncoder().encode(writeGrants), encoding: .utf8)
        let user = UserRecord(
            id: Tokens.newID("u_"),
            username: username,
            displayName: displayName ?? username,
            avatarURL: nil,
            passwordHash: hash,
            isAdmin: isAdmin,
            createdAt: Date().timeIntervalSince1970,
            writeGrantsJSON: grantsJSON
        )
        try await db.writer.write { db in try user.insert(db) }
        return user
    }

    /// Replace a user's metadata write grants. Returns the updated record.
    func setWriteGrants(userId: String, grants: [String]) async throws -> UserRecord {
        let grantsJSON = String(data: try JSONEncoder().encode(grants), encoding: .utf8)
        let updated: UserRecord? = try await db.writer.write { db in
            guard var user = try UserRecord.filter(Column("id") == userId).fetchOne(db) else { return nil }
            user.writeGrantsJSON = grantsJSON
            try user.update(db)
            return user
        }
        guard let updated else { throw SphynxError.notFound("No user '\(userId)'") }
        return updated
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
        return TokenResponse(accessToken: access, refreshToken: refresh, expiresIn: accessTokenTTL, user: user.toProtocol())
    }
}
