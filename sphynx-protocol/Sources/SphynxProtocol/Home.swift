import Foundation

/// The display shape of the tiles in a shelf, so a client knows how to lay out
/// (and crop) a row without guessing. The server states it; the client honors it.
///
/// Open enum: unknown values decode to `.unknown` rather than throwing.
public enum ShelfAspect: OpenEnum {
    /// Tall poster art (2:3) — e.g. Recently Added, Favorites.
    case portrait
    /// Wide art (16:9), backdrops/episode stills — e.g. Continue Watching.
    case landscape
    /// 1:1 — music/people.
    case square
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "portrait": self = .portrait
        case "landscape": self = .landscape
        case "square": self = .square
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .portrait: "portrait"
        case .landscape: "landscape"
        case .square: "square"
        case .unknown(let value): value
        }
    }
}

/// A well-known home-screen row.
///
/// **Continue Watching is unified.** There is deliberately **no** `nextUp` kind:
/// the next unwatched episode of a show you're partway through is merged *into*
/// `continueWatching` alongside in-progress movies and episodes, as a single
/// recency-ordered row. A client renders one "Continue Watching" / "Up Next" row,
/// never two. This is a fixed contract, not a server default — clients must not
/// expect a separate Next Up feed to ever appear.
///
/// Open enum: unknown values decode to `.unknown` rather than throwing.
public enum ShelfKind: OpenEnum {
    /// In-progress items **plus** next-up episodes, merged, most-recent first.
    case continueWatching
    /// Newest items added to the library, poster-first.
    case recentlyAdded
    /// The user's favorites.
    case favorites
    /// Top items carrying a particular genre (e.g. "Action"). The genre is named
    /// by the shelf's `title` and encoded in its `id` as `genre:<Name>`.
    case genre
    /// Top items released in a particular decade (e.g. the 1980s). The decade's
    /// start year is encoded in the shelf's `id` as `decade:<startYear>`.
    case releaseDecade
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "continueWatching": self = .continueWatching
        case "recentlyAdded": self = .recentlyAdded
        case "favorites": self = .favorites
        case "genre": self = .genre
        case "releaseDecade": self = .releaseDecade
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .continueWatching: "continueWatching"
        case .recentlyAdded: "recentlyAdded"
        case .favorites: "favorites"
        case .genre: "genre"
        case .releaseDecade: "releaseDecade"
        case .unknown(let value): value
        }
    }
}

/// A typed home-screen row: a titled, ordered set of items the client renders as
/// one shelf. `kind` identifies the row and `aspect` tells the client the tile
/// shape, so which rows are landscape is contract rather than convention.
public struct Shelf: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Open enum: clients map unknown kinds to a neutral default.
    public var kind: ShelfKind
    /// The tile shape this row is meant to be displayed at.
    public var aspect: ShelfAspect
    public var items: [Item]

    public init(id: String, title: String, kind: ShelfKind, aspect: ShelfAspect, items: [Item]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.aspect = aspect
        self.items = items
    }
}

/// Response for `GET /v1/home` — the ordered shelves that make up a user's home
/// screen. Empty shelves are omitted, so a fresh account may return fewer rows.
public struct HomeResponse: Codable, Hashable, Sendable {
    public var shelves: [Shelf]

    public init(shelves: [Shelf]) {
        self.shelves = shelves
    }
}
