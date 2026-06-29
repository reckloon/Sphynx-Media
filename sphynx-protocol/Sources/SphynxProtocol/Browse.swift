import Foundation

/// A top-level collection a user can browse (§5.1).
public struct Library: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Open enum: clients map unknown kinds to a neutral default.
    public var kind: LibraryKind

    public init(id: String, title: String, kind: LibraryKind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// Response for `GET /v1/libraries`.
public struct LibrariesResponse: Codable, Hashable, Sendable {
    public var libraries: [Library]

    public init(libraries: [Library]) {
        self.libraries = libraries
    }
}

/// Response for `GET /v1/items` — children of a container (§5.2).
///
/// Cursor pagination: an absent `nextCursor` means the end of the list.
public struct ItemsResponse: Codable, Hashable, Sendable {
    public var items: [Item]
    public var nextCursor: String?
    /// Total items under this parent matching the **structural** filters
    /// (`genre`/`year`) — the full set the cursor paginates over — so a client can
    /// show "1–N of `totalCount`". The per-user `unwatched` view-filter is applied
    /// per page and is *not* reflected here. Omitted (nil) by endpoints that don't
    /// compute it (the home feeds).
    public var totalCount: Int?
    /// The effective page size the server applied — the requested `limit` after the
    /// server's own clamping — so a client paginates against the real size rather
    /// than guessing the clamp. Omitted where not applicable.
    public var pageSize: Int?

    public init(items: [Item], nextCursor: String? = nil, totalCount: Int? = nil, pageSize: Int? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.totalCount = totalCount
        self.pageSize = pageSize
    }
}
