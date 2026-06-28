import Foundation

/// A server→client event delivered over the SSE stream (`GET /v1/events`).
///
/// Events are **live-update nudges with a small payload**, never a replacement
/// for the access-controlled REST surface. A client uses them to keep UI fresh
/// without polling — continue-watching, now-playing, watched/favorite sync — and
/// to know *when* to re-fetch (a `library` event says "something changed; re-run
/// your access-controlled browse"). The wire form is one JSON object per SSE
/// `data:` line with a stable `type` discriminator and `ts` (epoch seconds);
/// unknown `type`s and unknown fields are ignorable, so new event kinds and
/// fields are forward-compatible. Nil fields are omitted by the JSON encoder.
struct ServerEvent: Encodable, Sendable, Equatable {
    /// Stable discriminator: `playstate` | `useritemstate` | `markers` |
    /// `library` | `heartbeat`. Open set — clients ignore unknown types.
    let type: String
    let itemId: String?
    let libraryId: String?
    /// Resume position in seconds (playstate).
    let position: Double?
    let watched: Bool?
    let isFavorite: Bool?
    let playCount: Int?
    /// Coarse verb for `library` events: `added` | `removed` | `updated` | `scanned`.
    let action: String?
    let ts: Double

    private init(type: String, itemId: String? = nil, libraryId: String? = nil,
                 position: Double? = nil, watched: Bool? = nil, isFavorite: Bool? = nil,
                 playCount: Int? = nil, action: String? = nil, ts: Double) {
        self.type = type; self.itemId = itemId; self.libraryId = libraryId
        self.position = position; self.watched = watched; self.isFavorite = isFavorite
        self.playCount = playCount; self.action = action; self.ts = ts
    }

    // MARK: Factories (ts injected so call sites stay testable)

    /// Playback position moved for the subject (start / progress / stop).
    static func playstate(itemId: String, position: Double, ts: Double) -> ServerEvent {
        .init(type: "playstate", itemId: itemId, position: position, ts: ts)
    }

    /// The subject's per-item state changed (watched / favorite / play count).
    static func userItemState(itemId: String, watched: Bool, isFavorite: Bool, playCount: Int, ts: Double) -> ServerEvent {
        .init(type: "useritemstate", itemId: itemId, watched: watched, isFavorite: isFavorite, playCount: playCount, ts: ts)
    }

    /// Item-level markers changed (shared across the server's clients).
    static func markers(itemId: String, libraryId: String?, ts: Double) -> ServerEvent {
        .init(type: "markers", itemId: itemId, libraryId: libraryId, ts: ts)
    }

    /// A library's contents changed — a nudge to re-fetch via browse.
    static func library(libraryId: String?, action: String, ts: Double) -> ServerEvent {
        .init(type: "library", libraryId: libraryId, action: action, ts: ts)
    }

    /// Keep-alive tick; rendered as an SSE comment, not a `data:` frame.
    static func heartbeat(ts: Double) -> ServerEvent {
        .init(type: "heartbeat", ts: ts)
    }
}

/// Who a published event reaches. Delivery reuses the subscriber's identity so it
/// honours the same fail-closed access rules as the REST surface.
enum EventAudience: Sendable {
    /// Only the named subject's own connections (own playstate / item state).
    case user(String)
    /// Every connection whose subject `canReadLibrary(_:)` — fail-closed: a nil
    /// library is admin-only, exactly as item reads are.
    case library(String?)
}
