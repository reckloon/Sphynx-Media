import Foundation

/// A deletion record for incremental sync (§ changes feed).
///
/// When an item is removed from the catalog, its id is recorded as a tombstone so
/// a client polling `GET /v1/changes` can drop it locally without re-listing the
/// whole library to notice the absence. Only the id and the deletion time are
/// known — the item is gone, so it carries no further metadata and cannot be
/// permission-checked.
public struct Tombstone: Codable, Hashable, Sendable {
    public var id: String
    /// RFC3339 timestamp of when the item was deleted.
    public var deletedAt: String

    public init(id: String, deletedAt: String) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// Response for `GET /v1/changes?since=…` — incremental sync (§ changes feed).
///
/// `changes` are items whose client-rendered data changed after `since`,
/// permission-filtered to libraries the caller can read; `tombstones` are the
/// deletions in the same window (ids only). `until` is the server's clock at the
/// time of the response and becomes the client's next `since`, so repeated polls
/// form a gap-free cursor loop. When `nextCursor` is present the window has more
/// pages — fetch them with the same `since` before advancing to `until`.
public struct ChangesResponse: Codable, Hashable, Sendable {
    public var changes: [Item]
    public var tombstones: [Tombstone]
    /// RFC3339 server clock; the client's next `since`.
    public var until: String
    public var nextCursor: String?

    public init(changes: [Item], tombstones: [Tombstone], until: String, nextCursor: String? = nil) {
        self.changes = changes
        self.tombstones = tombstones
        self.until = until
        self.nextCursor = nextCursor
    }
}
