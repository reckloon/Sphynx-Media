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
    /// JSON array of metadata fields this user may contribute (admin-granted).
    /// Admins implicitly hold all grants regardless of this value.
    var writeGrantsJSON: String?

    /// Projection into the protocol's `User` (never exposes the hash).
    func toProtocol() -> User {
        User(id: id, displayName: displayName, avatarURL: avatarURL)
    }

    /// The set of metadata fields this user may contribute.
    func writeGrants() -> Set<String> {
        guard let writeGrantsJSON, let data = writeGrantsJSON.data(using: .utf8),
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
    var createdAt: Double

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

/// Per-user resume position, row-scoped to `(userId, itemId)`.
struct PlaystateRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "playstate"

    var userId: String
    var itemId: String
    var position: Double
    var updatedAt: Double
}

/// A cast member as persisted (JSON in `item.castJSON`).
struct StoredCast: Codable, Sendable {
    var id: String
    var name: String
    var role: String?
    var imageURL: String?
    var placeholderURL: String?
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
    var placeholderURL: String?
    var castJSON: String?
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

    /// Projection into the protocol's `Item`.
    ///
    /// `skeleton` carries the fields needed to render a tile (images,
    /// placeholder, year); `full` adds enrichment (overview, genres, ratings,
    /// runtime, cast). A skeleton is distinguished by the absence of enrichment.
    func toProtocol(full: Bool = false) -> Item {
        let images: ItemImages? = (primaryImage != nil || backdropImage != nil || thumbImage != nil)
            ? ItemImages(primary: primaryImage, backdrop: backdropImage, thumb: thumbImage)
            : nil

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
            extra: decodedExtra()
        )
        // Last change to client-rendered data: the max of the per-field change
        // times we track. Playstate lives in its own table and is intentionally
        // excluded, so progress reports don't invalidate client caches.
        if let latest = [updatedAt, enrichedAt, markersUpdatedAt].compactMap({ $0 }).max() {
            item.updatedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: latest))
        }
        if full {
            item.overview = overview
            item.runtime = runtime
            item.genres = decodedGenres()
            item.communityRating = communityRating
            item.officialRating = officialRating
            item.cast = decodedCast()
        }
        return item
    }

    private func decodedGenres() -> [String]? {
        guard let genresJSON, let data = genresJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
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
