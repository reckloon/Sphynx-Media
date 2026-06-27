import Foundation

/// Neutral image references for an item (§5.4). All optional.
public struct ItemImages: Codable, Hashable, Sendable {
    /// Poster.
    public var primary: String?
    public var backdrop: String?
    public var thumb: String?

    public init(primary: String? = nil, backdrop: String? = nil, thumb: String? = nil) {
        self.primary = primary
        self.backdrop = backdrop
        self.thumb = thumb
    }
}

/// A cast member (§5.4).
public struct CastMember: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var role: String?
    public var imageURL: String?
    public var placeholder: Placeholder?

    public init(
        id: String,
        name: String,
        role: String? = nil,
        imageURL: String? = nil,
        placeholder: Placeholder? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.imageURL = imageURL
        self.placeholder = placeholder
    }
}

/// A catalog item (§5.4).
///
/// All fields except `id`, `title`, and `type` are optional; a server sends what
/// it has. A `detail=skeleton` item is distinguished by the absence of the
/// enrichment fields (overview, genres, ratings, cast). Synthesised `Codable`
/// omits nil optionals on the wire.
public struct Item: Codable, Hashable, Sendable {
    public var id: String
    public var type: ItemType
    public var title: String

    /// The cross-system join key when present.
    public var tmdbId: String?
    public var overview: String?
    public var year: Int?
    /// Runtime in **seconds**.
    public var runtime: Double?

    public var images: ItemImages?
    public var placeholder: Placeholder?

    // Series/episode positioning (present as applicable).
    public var seriesId: String?
    public var seriesTitle: String?
    public var seasonIndex: Int?
    public var episodeIndex: Int?
    public var childCount: Int?

    // Enrichment (present at detail=full).
    public var genres: [String]?
    public var communityRating: Double?
    public var officialRating: String?
    public var cast: [CastMember]?

    /// Per-user state, folded in when known. Position in **seconds**; absent or 0
    /// means "from start".
    public var resumePosition: Double?

    /// Open, server-defined metadata not covered by the canonical fields above.
    /// A server (or server extension) may attach any additional metadata here; a
    /// client reads the keys it understands and ignores the rest. Omitted when
    /// empty. The canonical fields remain the neutral contract — `extra` is the
    /// escape hatch that makes "serve whatever you want" literally true.
    public var extra: [String: JSONValue]?

    public init(
        id: String,
        type: ItemType,
        title: String,
        tmdbId: String? = nil,
        overview: String? = nil,
        year: Int? = nil,
        runtime: Double? = nil,
        images: ItemImages? = nil,
        placeholder: Placeholder? = nil,
        seriesId: String? = nil,
        seriesTitle: String? = nil,
        seasonIndex: Int? = nil,
        episodeIndex: Int? = nil,
        childCount: Int? = nil,
        genres: [String]? = nil,
        communityRating: Double? = nil,
        officialRating: String? = nil,
        cast: [CastMember]? = nil,
        resumePosition: Double? = nil,
        extra: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.tmdbId = tmdbId
        self.overview = overview
        self.year = year
        self.runtime = runtime
        self.images = images
        self.placeholder = placeholder
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.seasonIndex = seasonIndex
        self.episodeIndex = episodeIndex
        self.childCount = childCount
        self.genres = genres
        self.communityRating = communityRating
        self.officialRating = officialRating
        self.cast = cast
        self.resumePosition = resumePosition
        self.extra = extra
    }
}
