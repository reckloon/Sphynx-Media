import Foundation
import SphynxProtocol

/// A short reuse-grace window for rotated refresh tokens.
///
/// Refresh tokens rotate on every use, which makes two real-world client failures
/// fatal without help:
/// - **Concurrent race**: two requests 401 at once, both try to refresh; the loser
///   presents a token the winner just rotated away and gets a 401.
/// - **Lost response**: the server rotates, the response never reaches the client
///   (timeout, dropped connection); the client retries with the old token — which is
///   now dead — and the session is stranded even though nobody did anything wrong.
///
/// After each rotation this remembers, for `ttl` seconds, the *previous* refresh-token
/// hash and the pair that rotation issued. A client presenting the just-rotated-away
/// token inside the window idempotently gets the current pair back instead of a 401.
///
/// In-memory by design: entries live ~a minute, and keeping issued tokens out of the
/// database preserves the hashes-only-at-rest rule (§9). A restart simply forfeits any
/// open windows — the worst case is the pre-existing behavior.
actor RefreshGraceWindow {
    struct Entry {
        let sessionId: String
        let response: TokenResponse
        let expiresAt: Double
    }

    /// Previous refresh-token hash → the pair the rotation that retired it issued.
    private var entries: [String: Entry] = [:]
    private let ttl: Double

    init(ttl: Double = 60) {
        self.ttl = ttl
    }

    /// Record a completed rotation. Any earlier window for the same session closes —
    /// a token two generations back must never resolve, only the immediately-previous one.
    func recordRotation(previousHash: String, sessionId: String, response: TokenResponse, now: Double) {
        entries = entries.filter { $0.value.expiresAt > now && $0.value.sessionId != sessionId }
        entries[previousHash] = Entry(sessionId: sessionId, response: response, expiresAt: now + ttl)
    }

    /// The pair last issued for this previous-token hash, if its window is still open.
    /// The caller must re-validate the session against the database (revocation, expiry,
    /// and that the cached pair is still the session's current one) before returning it.
    func replay(previousHash: String, now: Double) -> Entry? {
        entries = entries.filter { $0.value.expiresAt > now }
        return entries[previousHash]
    }
}
