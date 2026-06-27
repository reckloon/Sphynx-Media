import Foundation

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

/// Batch resume read for `GET /v1/playstate?items=<id,id,…>` (§7), keyed by
/// item id. Items with no stored state are simply absent.
public struct PlaystateBatchResponse: Codable, Hashable, Sendable {
    public var states: [String: PlaystateResponse]

    public init(states: [String: PlaystateResponse]) {
        self.states = states
    }
}
