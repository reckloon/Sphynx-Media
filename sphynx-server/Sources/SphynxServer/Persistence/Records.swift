import Foundation
import GRDB
import SphynxProtocol

/// A user account. Passwords are stored as encoded bcrypt hashes only.
struct UserRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user"

    var id: String
    var username: String
    var displayName: String
    var avatarURL: String?
    var passwordHash: String
    var isAdmin: Bool
    var createdAt: Double
    /// JSON array of permission keys this user holds (admin-granted). Admins
    /// implicitly hold every permission regardless of this value. Open-ended:
    /// unknown keys are tolerated. See `Permissions`.
    var permissionsJSON: String?

    /// Projection into the protocol's `User` (never exposes the hash).
    func toProtocol() -> User {
        User(id: id, displayName: displayName, avatarURL: avatarURL)
    }

    /// The set of permission keys this user holds.
    func permissions() -> Set<String> {
        guard let permissionsJSON, let data = permissionsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }
}

/// A device-scoped session: one current access token + one rotating refresh
/// token. Only token *hashes* are stored, never the tokens themselves.
struct SessionRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "session"

    var id: String
    var userId: String
    var deviceId: String
    var accessTokenHash: String
    var accessExpiresAt: Double
    var refreshTokenHash: String
    var refreshExpiresAt: Double
    var revoked: Bool
    var createdAt: Double
    var updatedAt: Double
}

/// A top-level browsable collection.
struct LibraryRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "library"

    var id: String
    var title: String
    var kind: String
    var createdAt: Double
    /// Minimum number of present members a collection must have to be shown as a
    /// box-set tile at this library's top level. Below it, the collection is hidden
    /// and its members appear individually. The default of `2` keeps a single owned
    /// movie from collapsing into a one-item box set; set it to `1` to group any
    /// non-empty collection. Server-internal: the grouping is resolved before items
    /// reach the wire, so it isn't on `Library`.
    var collectionThreshold: Int = 2

    func toProtocol() -> Library {
        Library(id: id, title: title, kind: LibraryKind(rawValue: kind) ?? .unknown(kind))
    }
}

/// An admin-configured place media lives, plus how to reach and list it.
struct SourceRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "source"

    var id: String
    var label: String
    /// Driver kind, e.g. "http".
    var driver: String
    var baseURL: String?
    /// JSON-encoded `[String: String]` of headers to send when fetching.
    var headersJSON: String?
    /// Library this source feeds (items it indexes land here).
    var libraryId: String?
    /// URL of a JSON manifest the indexer lists entries from.
    var manifestURL: String?
    /// Driver-specific, non-secret configuration (host, port, share, rootPath, …),
    /// stored as a JSON object of strings.
    var configJSON: String?
    /// Driver credentials (username, password, token, …). NEVER returned by the
    /// API and NEVER written to logs.
    var secretsJSON: String?
    /// Routes this source's items to different libraries by content category
    /// (`{ "movie": lib_x, "tv": lib_y }`). Absent categories fall back to
    /// `libraryId`, so a single-library source behaves as before.
    var libraryMapJSON: String?
    var createdAt: Double
    /// Auto-refresh cadence in **seconds** (0 = manual only); how often the
    /// background loop re-scans this source.
    var refreshInterval: Double = 0
    /// Epoch seconds of the last completed scan (nil = never scanned).
    var lastScannedAt: Double?

    /// Decoded content-category → library id map (empty if none / malformed).
    func libraryMap() -> [String: String] {
        Self.decodeStringMap(libraryMapJSON)
    }

    /// The library an item of the given category (`"movie"` | `"tv"`) routes to:
    /// the per-category mapping if present, else the source's single `libraryId`.
    func libraryId(for category: String) -> String? {
        libraryMap()[category] ?? libraryId
    }

    /// Every library this source feeds (the single `libraryId` plus any mapped).
    func feedsLibraries() -> Set<String> {
        var libs = Set(libraryMap().values)
        if let libraryId { libs.insert(libraryId) }
        return libs
    }

    /// Decoded request headers (empty if none / malformed). For the HTTP driver
    /// these may carry an `Authorization` token, so they're treated as secret —
    /// never echoed by the source API.
    func headers() -> [String: String] {
        Self.decodeStringMap(headersJSON)
    }

    /// Driver-specific, non-secret configuration.
    func config() -> [String: String] {
        Self.decodeStringMap(configJSON)
    }

    /// Driver credentials. Callers must never log or return these.
    func secrets() -> [String: String] {
        Self.decodeStringMap(secretsJSON)
    }

    private static func decodeStringMap(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

/// A persisted runtime configuration value (`setting` table), key → string value.
struct SettingRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setting"

    var key: String
    var value: String
}

/// Per-user item state (watched / favorite / play count / last-played),
/// row-scoped to `(userId, itemId)`.
struct UserStateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "useritemstate"

    var userId: String
    var itemId: String
    var watched: Bool
    var playCount: Int
    var isFavorite: Bool
    var lastPlayedAt: Double?

    /// An empty state for `(userId, itemId)` (nothing recorded yet).
    static func empty(userId: String, itemId: String) -> UserStateRecord {
        UserStateRecord(userId: userId, itemId: itemId, watched: false, playCount: 0, isFavorite: false, lastPlayedAt: nil)
    }
}

/// Per-user resume position, row-scoped to `(userId, itemId)`.
struct PlaystateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playstate"

    var userId: String
    var itemId: String
    var position: Double
    var updatedAt: Double
}

/// A deletion tombstone for the incremental changes feed: one row per removed
/// item id, with the time it was deleted. Re-adding an item clears its tombstone.
struct TombstoneRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tombstone"

    var itemId: String
    var deletedAt: Double

    /// Projection into the protocol's `Tombstone` (RFC3339 deletion time, with
    /// fractional seconds to match the changes feed's `until`/`since` precision).
    func toProtocol() -> Tombstone {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return Tombstone(id: itemId, deletedAt: f.string(from: Date(timeIntervalSince1970: deletedAt)))
    }
}

/// A cast member as persisted (JSON in `item.castJSON`).
struct StoredCast: Codable, Sendable {
    var id: String
    var name: String
    var role: String?
    var imageURL: String?
    var placeholderURL: String?
}

/// A cached media-probe result persisted as one JSON blob (`item.probedTracksJSON`)
/// and folded into the resolve descriptor's `tracks`. Reuses the protocol stream
/// types so the stored shape and the wire shape are one vocabulary.
struct StoredProbe: Codable, Sendable {
    var streams: [MediaStream]
    var externalSubtitles: [ExternalSubtitle]
    /// Embedded container chapters (optional; absent on rows probed before chapter
    /// support, so it decodes as nil rather than throwing).
    var chapters: [Chapter]? = nil
    /// When the probe ran (epoch seconds).
    var probedAt: Double
}

/// Extended TMDB metadata persisted uniformly as one JSON blob (`item.extendedJSON`)
/// and projected onto the canonical `Item` fields. Open by design — new keys can
/// be added without a migration; older rows simply lack them.
struct StoredExtended: Codable, Sendable {
    var originalTitle: String?
    var tagline: String?
    var status: String?
    var premiereDate: String?
    var endDate: String?
    var studios: [String]?
    var directors: [String]?
    var writers: [String]?
    var countries: [String]?
    var externalIds: [String: String]?

    /// Nil when nothing is set (so an empty blob isn't persisted).
    var isEmpty: Bool {
        originalTitle == nil && tagline == nil && status == nil && premiereDate == nil
            && endDate == nil && (studios?.isEmpty ?? true) && (directors?.isEmpty ?? true)
            && (writers?.isEmpty ?? true) && (countries?.isEmpty ?? true)
            && (externalIds?.isEmpty ?? true)
    }
}

/// A catalog item: identity, structure, and TMDB enrichment.
struct ItemRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "item"

    var id: String
    var type: String
    var title: String
    /// Source this item belongs to; nil means `sourceKey` is a self-contained
    /// absolute URL resolvable by the inline HTTP driver.
    var sourceId: String?
    /// The opaque key/path/URL the source's driver resolves into a direct URL.
    var sourceKey: String
    var container: String?
    var tmdbId: String?
    /// Library membership (top-level browse).
    var libraryId: String?
    /// Parent item for hierarchy (series → season → episode); nil = top-level.
    var parentId: String?
    /// Collection / box-set membership (the collection itself is a `collection`-typed
    /// item; movies also carry `parentId == collectionId` so `items?parent=` lists them).
    var collectionId: String?
    var collectionTitle: String?
    var year: Int?
    var createdAt: Double
    var updatedAt: Double

    // TV positioning (denormalised for the client; nil for movies).
    var seriesId: String?
    var seriesTitle: String?
    var seasonIndex: Int?
    var episodeIndex: Int?
    /// Number of direct children (seasons of a series, episodes of a season).
    var childCount: Int?

    // Enrichment (TMDB). Tile-level fields (images/placeholder) appear in both
    // skeleton and full; the rest are full-only.
    var overview: String?
    var genresJSON: String?
    var communityRating: Double?
    var officialRating: String?
    /// Runtime in **seconds**.
    var runtime: Double?
    var primaryImage: String?
    var backdropImage: String?
    var thumbImage: String?
    /// Title-logo (clearlogo) artwork.
    var logoImage: String?
    /// Wide banner artwork.
    var bannerImage: String?
    var placeholderURL: String?
    var castJSON: String?
    /// JSON array of trailer URLs (full-detail).
    var trailersJSON: String?
    /// JSON array of free-form tag/keyword strings (full-detail).
    var tagsJSON: String?
    /// A title to sort by (leading article dropped); full-detail.
    var sortTitle: String?
    /// Identification confidence (0...1).
    var confidence: Double?
    /// When enrichment last succeeded; nil = never enriched.
    var enrichedAt: Double?
    /// Admin pinned the identity — don't auto-re-identify.
    var identityPinned: Bool

    // Intro/credit markers (item-level, shared across clients) + provenance.
    var markersJSON: String?
    var markersSource: String?
    var markersConfidence: Double?
    /// Server-detected / admin-pinned (vs best-effort client contribution).
    var markersAuthoritative: Bool = false
    var markersContributedBy: String?
    var markersUpdatedAt: Double?

    /// Open server-defined metadata, stored uniformly as JSON text and projected
    /// onto `Item.extra`.
    var extraJSON: String?

    /// Field keys an admin has locked against auto-refresh (manual edits), stored
    /// uniformly as JSON text. Enrichment + re-scan skip any field in this set.
    var lockedFieldsJSON: String?

    /// Extended TMDB metadata (tagline, studios, directors, externalIds, …),
    /// stored uniformly as one JSON blob and projected onto the `Item`.
    var extendedJSON: String?

    /// Cached media-probe result (in-container streams + sidecar subtitles, from
    /// the media-probe extension), stored as one JSON blob and folded into the
    /// resolve descriptor's `tracks`. Absent until the item has been probed.
    var probedTracksJSON: String? = nil

    /// Decoded extended metadata (nil if none / malformed).
    func extended() -> StoredExtended? {
        guard let extendedJSON, let data = extendedJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredExtended.self, from: data)
    }

    /// The set of locked field keys (empty if none / malformed).
    func lockedFields() -> Set<String> {
        guard let lockedFieldsJSON, let data = lockedFieldsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    /// Projection into the protocol's `Item`.
    ///
    /// `skeleton` carries the fields needed to render a tile (images,
    /// placeholder, year); `full` adds enrichment (overview, genres, ratings,
    /// runtime, cast). A skeleton is distinguished by the absence of enrichment.
    func toProtocol(full: Bool = false) -> Item {
        // Per-image variants: each role carries its own low-res placeholder and an
        // aspect hint (inferred from the role's orientation), so a client can blur
        // up and lay out each image independently — not just the poster. Derived
        // here from the stored URLs (no extra storage / re-enrich needed).
        let landscape = 1.778, portrait = 0.667
        var variants: [String: ImageInfo] = [:]
        if let primaryImage {
            variants["primary"] = ImageInfo(
                url: primaryImage, placeholder: placeholderURL.map { .url($0) },
                aspect: type == "episode" ? landscape : portrait)  // episode primary is the landscape still
        }
        if let backdropImage {
            variants["backdrop"] = ImageInfo(
                url: backdropImage, placeholder: .url(Self.resizeTMDB(backdropImage, to: "w300")), aspect: landscape)
        }
        if let thumbImage {
            variants["thumb"] = ImageInfo(
                url: thumbImage, placeholder: .url(Self.resizeTMDB(thumbImage, to: "w300")), aspect: landscape)
        }
        if let logoImage {
            variants["logo"] = ImageInfo(url: logoImage, placeholder: .url(Self.resizeTMDB(logoImage, to: "w92")))
        }
        if let bannerImage {
            variants["banner"] = ImageInfo(url: bannerImage, placeholder: .url(Self.resizeTMDB(bannerImage, to: "w300")))
        }
        let images: ItemImages? = variants.isEmpty ? nil
            : ItemImages(primary: primaryImage, backdrop: backdropImage, thumb: thumbImage,
                         logo: logoImage, banner: bannerImage, variants: variants)

        var item = Item(
            id: id,
            type: ItemType(rawValue: type) ?? .unknown(type),
            title: title,
            tmdbId: tmdbId,
            year: year,
            images: images,
            placeholder: placeholderURL.map { .url($0) },
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            seasonIndex: seasonIndex,
            episodeIndex: episodeIndex,
            childCount: childCount,
            parentId: parentId,
            collectionId: collectionId,
            collectionTitle: collectionTitle,
            extra: decodedExtra()
        )
        // Last change to client-rendered data: the max of the per-field change
        // times we track. Playstate lives in its own table and is intentionally
        // excluded, so progress reports don't invalidate client caches.
        if let latest = [updatedAt, enrichedAt, markersUpdatedAt].compactMap({ $0 }).max() {
            item.updatedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: latest))
        }
        // When the item entered the library (tile-level, for "Recently Added").
        item.dateAdded = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: createdAt))
        if full {
            item.overview = overview
            item.runtime = runtime
            item.genres = decodedGenres()
            item.communityRating = communityRating
            item.officialRating = officialRating
            item.cast = decodedCast()
            item.sortTitle = sortTitle
            item.tags = decodedStringList(tagsJSON)
            item.trailers = decodedStringList(trailersJSON)
            // Embedded chapters, when the item has been probed (media-probe ext).
            item.chapters = storedChapters()
            // Extended TMDB metadata (omitted fields stay nil — nothing breaks).
            if let ext = extended() {
                item.originalTitle = ext.originalTitle
                item.tagline = ext.tagline
                item.status = ext.status
                item.premiereDate = ext.premiereDate
                item.endDate = ext.endDate
                item.studios = ext.studios?.isEmpty == false ? ext.studios : nil
                item.directors = ext.directors?.isEmpty == false ? ext.directors : nil
                item.writers = ext.writers?.isEmpty == false ? ext.writers : nil
                item.countries = ext.countries?.isEmpty == false ? ext.countries : nil
                item.externalIds = ext.externalIds?.isEmpty == false ? ext.externalIds : nil
            }
        }
        return item
    }

    private func decodedGenres() -> [String]? {
        guard let genresJSON, let data = genresJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }

    /// Swap the size segment of a TMDB image URL (`…/t/p/<size>/<path>`) to make a
    /// smaller rendition (e.g. a low-res placeholder). Returns the URL unchanged if
    /// it doesn't match the TMDB pattern (so non-TMDB servers degrade gracefully).
    static func resizeTMDB(_ url: String, to size: String) -> String {
        url.replacingOccurrences(
            of: #"/t/p/(w\d+|h\d+|original)/"#, with: "/t/p/\(size)/", options: .regularExpression)
    }

    /// Decode a JSON array of strings (nil/empty → nil so the wire omits it).
    private func decodedStringList(_ json: String?) -> [String]? {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data), !list.isEmpty
        else { return nil }
        return list
    }

    private func decodedCast() -> [CastMember]? {
        guard let castJSON, let data = castJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode([StoredCast].self, from: data)
        else { return nil }
        return stored.map {
            CastMember(id: $0.id, name: $0.name, role: $0.role, imageURL: $0.imageURL,
                       placeholder: $0.placeholderURL.map { .url($0) })
        }
    }

    /// Open server-defined metadata, decoded for `Item.extra`.
    func decodedExtra() -> [String: JSONValue]? {
        guard let extraJSON, let data = extraJSON.data(using: .utf8),
              let value = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// The stored intro/credit markers, if any.
    func storedMarkers() -> Markers? {
        guard let markersJSON, let data = markersJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Markers.self, from: data)
    }

    /// The cached probe result folded into a resolve `Tracks`, if the item has
    /// been probed. Derives the selection hints (`preferredAudio` =
    /// default/first audio; `preferredSubtitle` = forced/default subtitle) from
    /// the stream dispositions, then attaches the full per-stream detail and any
    /// sidecar subtitles. Returns nil when nothing was probed.
    func storedTracks() -> Tracks? {
        guard let probedTracksJSON, let data = probedTracksJSON.data(using: .utf8),
              let probe = try? JSONDecoder().decode(StoredProbe.self, from: data) else { return nil }
        let streams = probe.streams, subs = probe.externalSubtitles
        guard !streams.isEmpty || !subs.isEmpty else { return nil }
        let audio = streams.filter { $0.kind == "audio" }
        let subtitle = streams.filter { $0.kind == "subtitle" }
        let preferredAudio = (audio.first { $0.isDefault == true } ?? audio.first)?.index
        let preferredSubtitle = (subtitle.first { $0.isForced == true }
                                 ?? subtitle.first { $0.isDefault == true })?.index
        return Tracks(
            preferredAudio: preferredAudio,
            preferredSubtitle: preferredSubtitle,
            streams: streams.isEmpty ? nil : streams,
            externalSubtitles: subs.isEmpty ? nil : subs
        )
    }

    /// Embedded chapters from a cached probe, projected onto `Item.chapters`.
    /// `ffprobe` is the only source — TMDB has no chapter data. Nil until probed.
    func storedChapters() -> [Chapter]? {
        guard let probedTracksJSON, let data = probedTracksJSON.data(using: .utf8),
              let probe = try? JSONDecoder().decode(StoredProbe.self, from: data),
              let chapters = probe.chapters, !chapters.isEmpty else { return nil }
        return chapters
    }

    /// Markers + provenance for `GET /v1/items/<id>/markers`.
    ///
    /// `staleAfter` (seconds) flags non-authoritative markers older than the
    /// window as `stale`, inviting a client to refetch + contribute. Authoritative
    /// (server-detected / admin-pinned) markers are never stale.
    func markersInfo(staleAfter: Double, now: Double = Date().timeIntervalSince1970) -> MarkersInfo? {
        guard let markers = storedMarkers() else { return nil }
        let isStale: Bool = {
            guard !markersAuthoritative, let updatedAt = markersUpdatedAt else { return false }
            return (now - updatedAt) > staleAfter
        }()
        return MarkersInfo(
            markers: markers,
            source: markersSource,
            confidence: markersConfidence,
            authoritative: markersAuthoritative,
            updatedAt: markersUpdatedAt.map { ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0)) },
            stale: isStale
        )
    }
}
