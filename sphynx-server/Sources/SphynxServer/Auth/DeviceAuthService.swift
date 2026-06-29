import Foundation
import GRDB
import Hummingbird
import SphynxProtocol

/// Device authorization grant (RFC 8628-style) — QR/code login for TVs and other
/// limited-input clients. The device starts a request and polls; the user approves
/// it on a second, already-signed-in device (e.g. via a passkey). On approval the
/// poll mints the same session a normal login would.
///
/// Secrets: the device holds `deviceCode` (we store only its SHA-256 hash); the
/// user sees the short `userCode`. Requests are single-use and time-bounded.
struct DeviceAuthService: Sendable {
    let db: AppDatabase
    let auth: AuthService
    /// Public base URL the verification page (`/link`) lives at — what the QR points
    /// to. Must be reachable by the approving device.
    let publicBaseURL: String
    /// Seconds a request stays valid before the device must restart.
    var ttl: Double = 600
    /// Minimum seconds the device should wait between polls.
    var pollInterval: Double = 5

    /// Begin a device-authorization request for the polling device.
    func start(deviceId: String, label: String?) async throws -> DeviceAuthResponse {
        let deviceCode = Tokens.newToken()
        let display = Self.newUserCode()          // shown to the user, e.g. "WXYZ-2345"
        let now = Date().timeIntervalSince1970
        let record = DeviceAuthRecord(
            id: Tokens.newID("da_"),
            deviceCodeHash: Tokens.hash(deviceCode),
            userCode: Self.normalize(display),    // stored normalized for lookup
            deviceId: deviceId.isEmpty ? "default" : deviceId,
            label: label?.isEmpty == true ? nil : label,
            userId: nil, approved: false, createdAt: now, expiresAt: now + ttl)
        try await db.writer.write { db in try record.insert(db) }

        let base = publicBaseURL.hasSuffix("/") ? String(publicBaseURL.dropLast()) : publicBaseURL
        let verifyUri = base + "/link"
        return DeviceAuthResponse(
            deviceCode: deviceCode,
            userCode: display,
            verificationUri: verifyUri,
            verificationUriComplete: verifyUri + "?code=" + display,
            interval: pollInterval,
            expiresIn: ttl)
    }

    /// Approve a pending request by its `userCode`, binding it to the approving user.
    /// Idempotent on an already-approved row.
    func approve(userCode: String, userId: String) async throws {
        let code = Self.normalize(userCode)
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            guard var record = try DeviceAuthRecord.filter(Column("userCode") == code).fetchOne(db) else {
                throw SphynxError.notFound("No pending sign-in for that code")
            }
            guard record.expiresAt > now else {
                _ = try DeviceAuthRecord.filter(Column("id") == record.id).deleteAll(db)
                throw SphynxError.badRequest("That code has expired — start the sign-in again on the device")
            }
            record.userId = userId
            record.approved = true
            try record.update(db)
        }
    }

    /// The pending request for a `userCode`, for the approval page to show "which
    /// device am I approving?". Nil if unknown/expired.
    func pending(userCode: String) async throws -> DeviceAuthRecord? {
        let code = Self.normalize(userCode)
        let now = Date().timeIntervalSince1970
        return try await db.writer.read { db in
            try DeviceAuthRecord
                .filter(Column("userCode") == code && Column("expiresAt") > now)
                .fetchOne(db)
        }
    }

    /// The device polls with its `deviceCode`. Returns tokens once approved;
    /// otherwise throws the RFC-style state as the error envelope's code.
    func poll(deviceCode: String, deviceId: String) async throws -> TokenResponse {
        let now = Date().timeIntervalSince1970
        let record = try await db.writer.read { db in
            try DeviceAuthRecord.filter(Column("deviceCodeHash") == Tokens.hash(deviceCode)).fetchOne(db)
        }
        guard let record else {
            throw Self.error("invalid_grant", "Unknown or already-claimed device code")
        }
        if record.expiresAt <= now {
            try await delete(id: record.id)
            throw Self.error("expired_token", "The sign-in request has expired; start over")
        }
        guard record.approved, let userId = record.userId else {
            // Not yet approved — the device should keep polling.
            throw Self.error("authorization_pending", "Waiting for the user to approve this device", retryable: true)
        }
        // Approved: mint the session and consume the (single-use) request.
        let tokens = try await auth.issueSession(forUserId: userId, deviceId: record.deviceId)
        try await delete(id: record.id)
        return tokens
    }

    private func delete(id: String) async throws {
        try await db.writer.write { db in _ = try DeviceAuthRecord.filter(Column("id") == id).deleteAll(db) }
    }

    /// 400 with an RFC-8628 device-flow code in the envelope (`authorization_pending`,
    /// `expired_token`, `invalid_grant`).
    private static func error(_ code: String, _ message: String, retryable: Bool = false) -> SphynxError {
        SphynxError(status: .badRequest, code: .unknown(code), message: message, retryable: retryable)
    }

    /// Short, human-typable code from an unambiguous alphabet (no 0/O/1/I/L), e.g.
    /// "WXYZ-2345". Display form carries a dash; stored/looked-up form is normalized.
    static func newUserCode() -> String {
        let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    /// Normalize a user-entered code for lookup: uppercase, strip dashes/whitespace.
    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
    }
}
