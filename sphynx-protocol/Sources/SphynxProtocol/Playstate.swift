import Foundation

/// `PUT /v1/items/<itemId>/state` body: update the caller's per-user state for an
/// item. Only the provided fields change. `watched` / `isFavorite` are explicit
/// user actions; play count + last-played are tracked server-side from playback.
public struct ItemStateUpdate: Codable, Hashable, Sendable {
    public var watched: Bool?
    public var isFavorite: Bool?

    public init(watched: Bool? = nil, isFavorite: Bool? = nil) {
        self.watched = watched
        self.isFavorite = isFavorite
    }
}

/// `POST /v1/playstate/<itemId>/start` body (§7). Position in **seconds**.
public struct PlaystateStartBody: Codable, Hashable, Sendable {
    public var position: Double

    public init(position: Double) {
        self.position = position
    }
}

/// `POST /v1/playstate/<itemId>/progress` body (§7).
public struct PlaystateProgressBody: Codable, Hashable, Sendable {
    public var position: Double
    public var paused: Bool

    public init(position: Double, paused: Bool = false) {
        self.position = position
        self.paused = paused
    }
}

/// `POST /v1/playstate/<itemId>/stop` body (§7).
///
/// On `failed: true` the server must **not** overwrite a good resume point with a
/// bogus position.
public struct PlaystateStopBody: Codable, Hashable, Sendable {
    public var position: Double
    public var failed: Bool

    public init(position: Double, failed: Bool = false) {
        self.position = position
        self.failed = failed
    }
}

/// `DELETE /v1/playstate/<itemId>` (§7) clears the caller's resume for an item:
/// it deletes their stored row so the item's `resumePosition` reads back as 0 and
/// it drops out of the continue-watching feed. Empty body, **204 No Content** on
/// success, idempotent (deleting when nothing is stored is still 204), and
/// row-scoped to the caller's own state. No request/response type is needed.

/// Resume state for a single item (§7).
public struct PlaystateResponse: Codable, Hashable, Sendable {
    /// Position in **seconds**; 0 means "from start".
    public var position: Double
    /// Wall-clock timestamp of the last update, RFC 3339 / ISO 8601.
    public var updatedAt: String

    public init(position: Double, updatedAt: String) {
        self.position = position
        self.updatedAt = updatedAt
    }
}

/// `DELETE /v1/playstate` resets the caller's **entire** watch history across
/// every device: all stored resume positions are deleted and per-item state
/// (watched flag, play count, last-played) is cleared, so nothing the user has
/// watched lingers. Row-scoped to the caller; idempotent. Returns the number of
/// rows removed.
public struct PlaystateResetResponse: Codable, Hashable, Sendable {
    /// How many history rows were removed (resume + per-item-state rows).
    public var cleared: Int

    public init(cleared: Int) {
        self.cleared = cleared
    }
}

/// Batch resume read for `GET /v1/playstate?items=<id,id,…>` (§7), keyed by
/// item id. Items with no stored state are simply absent.
public struct PlaystateBatchResponse: Codable, Hashable, Sendable {
    public var states: [String: PlaystateResponse]

    public init(states: [String: PlaystateResponse]) {
        self.states = states
    }
}
