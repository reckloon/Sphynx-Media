import Foundation

/// Per-image metadata for one role in `ItemImages.variants`: the full URL plus a
/// low-res `placeholder` to blur up from and an `aspect` hint (width ÷ height), so
/// a client knows an image's shape before it loads and can crop/lay out without
/// guessing. Only `url` is required; everything else is best-effort.
public struct ImageInfo: Codable, Hashable, Sendable {
    /// The full-size image URL (the same value as the matching flat role field).
    public var url: String
    /// A low-res stand-in for `url` (the reference server sends the `url` form).
    public var placeholder: Placeholder?
    /// Aspect ratio = width ÷ height. ~0.667 for a portrait poster (2:3), ~1.778
    /// for landscape art (16:9). Absent when the server can't state it.
    public var aspect: Double?
    /// Intrinsic pixel dimensions, when the server knows them (often absent).
    public var width: Int?
    public var height: Int?

    public init(url: String, placeholder: Placeholder? = nil, aspect: Double? = nil, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.placeholder = placeholder
        self.aspect = aspect
        self.width = width
        self.height = height
    }
}

/// Neutral image references for an item (§5.4). All optional — a server sends the
/// forms it has; clients use the ones they recognise. New image roles may be added
/// over time without breaking older clients.
public struct ItemImages: Codable, Hashable, Sendable {
    /// Poster.
    public var primary: String?
    public var backdrop: String?
    public var thumb: String?
    /// Transparent title logo (clearlogo), as used by many clients' detail screens.
    public var logo: String?
    /// Wide banner art.
    public var banner: String?

    /// Per-role rich metadata keyed by role name (`"primary"`, `"backdrop"`,
    /// `"thumb"`, `"logo"`, `"banner"`). **Additive:** the flat role fields above
    /// remain the URL source of truth; `variants` adds the per-image `placeholder`
    /// and `aspect` a client needs to blur up and lay out each image independently
    /// (e.g. a landscape backdrop carrying its own low-res form + 16:9 hint, not
    /// just the poster's). An open map — clients tolerate unknown role keys.
    public var variants: [String: ImageInfo]?

    public init(
        primary: String? = nil,
        backdrop: String? = nil,
        thumb: String? = nil,
        logo: String? = nil,
        banner: String? = nil,
        variants: [String: ImageInfo]? = nil
    ) {
        self.primary = primary
        self.backdrop = backdrop
        self.thumb = thumb
        self.logo = logo
        self.banner = banner
        self.variants = variants
    }
}

/// A chapter / scene marker on an item's timeline (§5.4). Times in **seconds**.
public struct Chapter: Codable, Hashable, Sendable {
    public var start: Double
    public var title: String?
    /// Optional chapter thumbnail image URL.
    public var imageURL: String?

    public init(start: Double, title: String? = nil, imageURL: String? = nil) {
        self.start = start
        self.title = title
        self.imageURL = imageURL
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

    /// The work's original-language title, when it differs from `title`.
    public var originalTitle: String?
    /// A title to sort by (articles dropped, etc.), when the server provides one.
    public var sortTitle: String?
    /// A short marketing tagline.
    public var tagline: String?

    public var images: ItemImages?
    public var placeholder: Placeholder?

    // Series/episode positioning (present as applicable).
    public var seriesId: String?
    public var seriesTitle: String?
    public var seasonIndex: Int?
    public var episodeIndex: Int?
    public var childCount: Int?

    /// Generic parent link. The container this item nests under when it isn't the
    /// TV season/series relationship above — e.g. a bonus/extra under its movie or
    /// show, or a movie under its collection. A client browses an item's children
    /// with `GET /v1/items?parent=<id>`. Absent for top-level items.
    public var parentId: String?
    /// Collection / box-set membership, when the item belongs to one (mirrors
    /// `seriesId`/`seriesTitle`). The collection itself is a `collection`-typed item.
    public var collectionId: String?
    public var collectionTitle: String?

    // Enrichment (present at detail=full).
    public var genres: [String]?
    /// Audience rating, typically 0…10 (e.g. TMDB vote average).
    public var communityRating: Double?
    /// Critic rating, typically 0…100 (e.g. a review-aggregator score).
    public var criticRating: Double?
    /// Content rating / certification, e.g. "PG-13", "TV-MA".
    public var officialRating: String?
    public var cast: [CastMember]?
    /// Director name(s).
    public var directors: [String]?
    /// Writer name(s).
    public var writers: [String]?
    /// Production studios / networks.
    public var studios: [String]?
    /// Production countries (names or ISO codes, as the server has them).
    public var countries: [String]?
    /// Free-form tags / keywords.
    public var tags: [String]?
    /// Trailer URLs (e.g. YouTube links), when known.
    public var trailers: [String]?
    /// Chapter / scene markers along the timeline.
    public var chapters: [Chapter]?
    /// Release / first-air status, e.g. "Released", "Continuing", "Ended".
    public var status: String?
    /// Premiere / first-air date (RFC 3339 date).
    public var premiereDate: String?
    /// End / last-air date for series (RFC 3339 date).
    public var endDate: String?
    /// When this item was added to the library (RFC 3339), for "Recently Added".
    public var dateAdded: String?
    /// Cross-system identifiers beyond `tmdbId`, e.g. `{"imdb":"tt…","tvdb":"…"}`.
    /// An open map: clients read the namespaces they understand.
    public var externalIds: [String: String]?

    /// Per-user state, folded in when known. Position in **seconds**; absent or 0
    /// means "from start".
    ///
    /// **Source-of-truth note:** this is a *convenience snapshot* taken when the item
    /// was projected — it does **not** move `updatedAt` (which deliberately excludes
    /// playstate), so a cached `Item.resumePosition` can be stale. The authoritative
    /// resume value lives in `/v1/playstate`; a client that needs the current
    /// position (e.g. resuming playback) should read `GET /v1/playstate/{itemId}` (or
    /// the batch form) rather than trust a cached item. Use `resumePosition` for
    /// display hints, `/v1/playstate` for the truth.
    public var resumePosition: Double?
    /// Per-user: the user has marked this watched. Absent ⇒ unknown / unwatched.
    public var watched: Bool?
    /// Per-user: how many times the user has played it.
    public var playCount: Int?
    /// Per-user: the user favorited it.
    public var isFavorite: Bool?
    /// Per-user: the caller's own rating on a **0–10** scale (distinct from the
    /// crowd's `communityRating` and the press's `criticRating`). Absent ⇒ unrated.
    public var userRating: Double?
    /// Per-user: when the user last played it (RFC 3339).
    public var lastPlayedAt: String?

    /// Wall-clock RFC 3339 timestamp of the last change to **client-rendered**
    /// data for this item (title, images, enrichment, markers, …) — the max of
    /// the server's per-field change times. A client can diff this single value
    /// to decide "changed since I cached it?" without comparing every field.
    ///
    /// Deliberately **excludes** per-user playstate (`resumePosition`), which
    /// changes far more often and would otherwise invalidate the cache on every
    /// progress report. Absent ⇒ unknown.
    public var updatedAt: String?

    /// Selectable versions/editions of this title — the same logical movie/episode
    /// backed by more than one file (4K + 1080p, Director's Cut + Theatrical). Absent
    /// or a single entry ⇒ resolve the item by id as usual; with multiple, a client
    /// shows a version picker and plays one via `GET /v1/resolve/<id>?version=<vid>`.
    /// The first entry is the server's default (highest quality) — what a plain
    /// `resolve` returns. See `MediaVersion`.
    public var versions: [MediaVersion]?

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
        originalTitle: String? = nil,
        sortTitle: String? = nil,
        tagline: String? = nil,
        images: ItemImages? = nil,
        placeholder: Placeholder? = nil,
        seriesId: String? = nil,
        seriesTitle: String? = nil,
        seasonIndex: Int? = nil,
        episodeIndex: Int? = nil,
        childCount: Int? = nil,
        parentId: String? = nil,
        collectionId: String? = nil,
        collectionTitle: String? = nil,
        genres: [String]? = nil,
        communityRating: Double? = nil,
        criticRating: Double? = nil,
        officialRating: String? = nil,
        cast: [CastMember]? = nil,
        directors: [String]? = nil,
        writers: [String]? = nil,
        studios: [String]? = nil,
        countries: [String]? = nil,
        tags: [String]? = nil,
        trailers: [String]? = nil,
        chapters: [Chapter]? = nil,
        status: String? = nil,
        premiereDate: String? = nil,
        endDate: String? = nil,
        dateAdded: String? = nil,
        externalIds: [String: String]? = nil,
        resumePosition: Double? = nil,
        watched: Bool? = nil,
        playCount: Int? = nil,
        isFavorite: Bool? = nil,
        userRating: Double? = nil,
        lastPlayedAt: String? = nil,
        updatedAt: String? = nil,
        versions: [MediaVersion]? = nil,
        extra: [String: JSONValue]? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.tmdbId = tmdbId
        self.overview = overview
        self.year = year
        self.runtime = runtime
        self.originalTitle = originalTitle
        self.sortTitle = sortTitle
        self.tagline = tagline
        self.images = images
        self.placeholder = placeholder
        self.seriesId = seriesId
        self.seriesTitle = seriesTitle
        self.seasonIndex = seasonIndex
        self.episodeIndex = episodeIndex
        self.childCount = childCount
        self.parentId = parentId
        self.collectionId = collectionId
        self.collectionTitle = collectionTitle
        self.genres = genres
        self.communityRating = communityRating
        self.criticRating = criticRating
        self.officialRating = officialRating
        self.cast = cast
        self.directors = directors
        self.writers = writers
        self.studios = studios
        self.countries = countries
        self.tags = tags
        self.trailers = trailers
        self.chapters = chapters
        self.status = status
        self.premiereDate = premiereDate
        self.endDate = endDate
        self.dateAdded = dateAdded
        self.externalIds = externalIds
        self.resumePosition = resumePosition
        self.watched = watched
        self.playCount = playCount
        self.isFavorite = isFavorite
        self.userRating = userRating
        self.lastPlayedAt = lastPlayedAt
        self.updatedAt = updatedAt
        self.versions = versions
        self.extra = extra
    }
}

/// One selectable version/edition of a title — a single file backing the same
/// logical movie/episode. A client renders these as a version picker and plays one
/// with `GET /v1/resolve/<itemId>?version=<id>`; resolving without `version` plays
/// the item's default (first) version.
public struct MediaVersion: Codable, Hashable, Sendable {
    /// Opaque, stable id — pass back as `?version=`. Don't parse it.
    public var id: String
    /// Human label for the picker, e.g. "4K HDR · Remux", "Director's Cut · 1080p".
    public var label: String
    /// Source container hint (`mkv`, `mp4`, …), when known.
    public var container: String?
    /// Resolution bucket (`4K`, `1080p`, `720p`, …), when detected.
    public var resolution: String?
    /// Edition (`Director's Cut`, `Extended`, `Theatrical`, `IMAX`, …), when detected.
    public var edition: String?
    /// Dynamic range (`HDR10`, `HDR10+`, `DV`), when detected; absent ⇒ SDR/unknown.
    public var dynamicRange: String?
    /// File size in bytes, when the driver reports it.
    public var size: Int?

    public init(
        id: String, label: String, container: String? = nil, resolution: String? = nil,
        edition: String? = nil, dynamicRange: String? = nil, size: Int? = nil
    ) {
        self.id = id
        self.label = label
        self.container = container
        self.resolution = resolution
        self.edition = edition
        self.dynamicRange = dynamicRange
        self.size = size
    }
}
