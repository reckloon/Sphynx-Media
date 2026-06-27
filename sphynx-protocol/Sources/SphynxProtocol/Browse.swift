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

    public init(items: [Item], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}
