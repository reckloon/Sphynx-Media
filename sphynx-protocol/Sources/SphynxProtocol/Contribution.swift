import Foundation

/// A client (or server extension) contributing intro/credit markers for an item.
///
/// Markers are item-level and shared across all of a server's clients (cached
/// server-side), so a marker contributed once benefits everyone. Used as the body
/// of `PUT /v1/items/<id>/markers` when the server advertises
/// `capabilities.metadata["markers"] == "readwrite"`.
///
/// `source` records provenance (e.g. "theintrodb", "user", a detector name);
/// `confidence` is an optional 0…1 hint.
public struct MarkerContribution: Codable, Hashable, Sendable {
    public var markers: Markers
    public var source: String?
    public var confidence: Double?

    public init(markers: Markers, source: String? = nil, confidence: Double? = nil) {
        self.markers = markers
        self.source = source
        self.confidence = confidence
    }
}

/// Markers plus their provenance, returned by `GET /v1/items/<id>/markers`.
///
/// `authoritative` distinguishes server-detected / admin-pinned markers from
/// best-effort client contributions, so a client can decide how much to trust
/// them (and a server can refuse to let a client overwrite authoritative data).
public struct MarkersInfo: Codable, Hashable, Sendable {
    public var markers: Markers
    public var source: String?
    public var confidence: Double?
    public var authoritative: Bool?
    /// Wall-clock RFC 3339 timestamp of the last update.
    public var updatedAt: String?
    /// The server considers these markers stale (older than its freshness window)
    /// and invites a fresh client contribution. A client that has a data source
    /// (e.g. TheIntroDB) should re-fetch and `PUT` updated markers. Authoritative
    /// markers are never marked stale. Absent ⇒ not stale / unknown.
    public var stale: Bool?

    public init(
        markers: Markers,
        source: String? = nil,
        confidence: Double? = nil,
        authoritative: Bool? = nil,
        updatedAt: String? = nil,
        stale: Bool? = nil
    ) {
        self.markers = markers
        self.source = source
        self.confidence = confidence
        self.authoritative = authoritative
        self.updatedAt = updatedAt
        self.stale = stale
    }
}
