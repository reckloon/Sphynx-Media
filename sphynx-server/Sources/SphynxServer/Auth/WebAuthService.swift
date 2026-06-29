import Crypto
import Foundation
import GRDB
import SphynxProtocol

/// OAuth-style **web authorization** grant — a seamless same-device web sign-in for
/// clients that can't claim the server's host in an Associated Domains entitlement
/// (the self-hosted case: the app can't be re-signed per server). The client opens
/// the hosted login page in an `ASWebAuthenticationSession`; on success the page
/// redirects to the app's custom URL scheme with a single-use authorization `code`;
/// the client exchanges the code (bound to its PKCE verifier) for the same session
/// a normal login would mint.
///
/// Secrets: the client never sees a session token in the browser — only the short,
/// single-use `code` (we store just its SHA-256 hash). PKCE binds the exchange to
/// the client that started the flow.
struct WebAuthService: Sendable {
    let db: AppDatabase
    let auth: AuthService
    /// Allowed `redirect_uri` targets. Each entry matches a redirect that equals it
    /// or begins with it (so a scheme prefix like `ocelot://` permits any path under
    /// it). When empty, the default policy applies (see `isAllowed`).
    let redirectAllowlist: [String]
    /// Seconds an authorization code stays valid before the client must restart.
    var ttl: Double = 60

    /// Whether `redirect_uri` is an acceptable target.
    ///
    /// - If an allowlist is configured, the redirect must match one of its entries
    ///   (exact, or a prefix such as a `scheme://` entry).
    /// - If no allowlist is configured, **app custom schemes are accepted** (they
    ///   can't be open redirects to arbitrary web origins) while `http(s)` targets
    ///   are rejected — an operator must allowlist a web origin explicitly. PKCE is
    ///   the binding that stops a different app from usefully claiming the code.
    func isAllowed(redirectUri uri: String) -> Bool {
        guard !uri.isEmpty, let scheme = URLComponents(string: uri)?.scheme?.lowercased() else {
            return false
        }
        if !redirectAllowlist.isEmpty {
            return redirectAllowlist.contains { uri == $0 || uri.hasPrefix($0) }
        }
        return scheme != "http" && scheme != "https"
    }

    /// Mint an authorization code for an already-verified user and build the redirect
    /// the browser should navigate to (`redirect_uri?code=…&state=…`). Caller must
    /// have validated `redirectUri` via `isAllowed` first.
    func issueCode(
        userId: String,
        redirectUri: String,
        state: String?,
        codeChallenge: String?,
        codeChallengeMethod: String?
    ) async throws -> String {
        // Validate the PKCE method up front so a malformed request fails before a
        // code is minted. Absent challenge ⇒ non-PKCE flow (allowed, discouraged).
        if codeChallenge != nil {
            let method = codeChallengeMethod ?? "plain"
            guard method == "S256" || method == "plain" else {
                throw SphynxError.badRequest("Unsupported code_challenge_method '\(method)'")
            }
        }
        let code = Tokens.newToken()
        let now = Date().timeIntervalSince1970
        let record = WebAuthRecord(
            id: Tokens.newID("wa_"),
            codeHash: Tokens.hash(code),
            userId: userId,
            redirectUri: redirectUri,
            state: state,
            codeChallenge: codeChallenge,
            codeChallengeMethod: codeChallenge == nil ? nil : (codeChallengeMethod ?? "plain"),
            createdAt: now,
            expiresAt: now + ttl)
        try await db.writer.write { db in try record.insert(db) }
        return Self.buildRedirect(redirectUri: redirectUri, code: code, state: state)
    }

    /// Redeem a code for a session. Single-use (the row is consumed on lookup),
    /// time-bounded, and — when the flow used PKCE — bound to the client's verifier.
    /// The session is scoped to `deviceId` (the exchanging client's `X-Sphynx-Device`).
    func exchange(code: String, codeVerifier: String?, deviceId: String) async throws -> TokenResponse {
        let now = Date().timeIntervalSince1970
        // Consume the code on lookup so it can't be replayed, whatever the outcome.
        let record = try await db.writer.write { db -> WebAuthRecord? in
            let row = try WebAuthRecord.filter(Column("codeHash") == Tokens.hash(code)).fetchOne(db)
            if let row { _ = try WebAuthRecord.filter(Column("id") == row.id).deleteAll(db) }
            return row
        }
        guard let record else {
            throw Self.error("invalid_grant", "Unknown or already-used authorization code")
        }
        guard record.expiresAt > now else {
            throw Self.error("invalid_grant", "The authorization code has expired; start over")
        }
        try Self.verifyPKCE(record: record, codeVerifier: codeVerifier)
        return try await auth.issueSession(forUserId: record.userId, deviceId: deviceId)
    }

    // MARK: Helpers

    /// Append `code` (and `state`, if any) to the redirect URI as query parameters,
    /// preserving any the URI already carries.
    static func buildRedirect(redirectUri: String, code: String, state: String?) -> String {
        let sep = redirectUri.contains("?") ? "&" : "?"
        var query = "code=" + percentEncode(code)
        if let state { query += "&state=" + percentEncode(state) }
        return redirectUri + sep + query
    }

    /// Verify the PKCE binding (no-op when the flow didn't use PKCE).
    static func verifyPKCE(record: WebAuthRecord, codeVerifier: String?) throws {
        guard let challenge = record.codeChallenge else { return }
        guard let verifier = codeVerifier, !verifier.isEmpty else {
            throw error("invalid_grant", "This code requires a code_verifier (PKCE)")
        }
        let ok: Bool
        switch record.codeChallengeMethod ?? "plain" {
        case "S256":
            let digest = SHA256.hash(data: Data(verifier.utf8))
            ok = Data(digest).base64URLEncodedString() == challenge
        default:  // "plain"
            ok = verifier == challenge
        }
        guard ok else { throw error("invalid_grant", "PKCE verification failed") }
    }

    /// Percent-encode a value for use in a URL query component.
    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
    }

    /// 400 with an OAuth-style code in the envelope (`invalid_grant`, `invalid_request`).
    private static func error(_ code: String, _ message: String) -> SphynxError {
        SphynxError(status: .badRequest, code: .unknown(code), message: message)
    }
}
