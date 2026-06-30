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

/// A registered WebAuthn passkey. We persist only the public key plus the data
/// needed to verify future assertions — the private key never leaves the user's
/// authenticator. `credentialId` is the authenticator's base64url credential id,
/// the lookup key for a passwordless (discoverable) login.
struct PasskeyCredentialRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "passkey_credential"

    var id: String
    var userId: String
    var credentialId: String
    var publicKey: Data
    var signCount: Int
    var label: String
    var backupEligible: Bool
    var backedUp: Bool
    var createdAt: Double
    var lastUsedAt: Double?

    /// Projection into the protocol's `PasskeyInfo` (never exposes the public key).
    func toProtocol() -> PasskeyInfo {
        PasskeyInfo(
            id: id,
            label: label,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            backedUp: backedUp
        )
    }
}

/// A short-lived, single-use WebAuthn ceremony challenge bridging a begin/finish
/// call pair. `userId` is set for registration (bound to the enrolling user) and
/// nil for a passwordless login (the subject is unknown until the assertion is
/// verified). Consumed on finish; expired rows are swept lazily.
struct PasskeyChallengeRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "passkey_challenge"

    var id: String
    var kind: String
    var userId: String?
    var challenge: Data
    var expiresAt: Double
    var createdAt: Double
}

/// A pending device-authorization request (RFC 8628-style QR/code login). The
/// polling device holds the secret `deviceCode`; we store only its hash. The user
/// approves by the short `userCode`. `userId` is set on approval; the row is
/// deleted once the device claims its tokens (single-use).
struct DeviceAuthRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "device_auth"

    var id: String
    var deviceCodeHash: String
    var userCode: String
    var deviceId: String
    var label: String?
    var userId: String?
    var approved: Bool
    var createdAt: Double
    var expiresAt: Double
}

/// A pending OAuth-style **web authorization** code (the same-device web sign-in,
/// `/v1/auth/web/*`). Minted once the user signs in on the hosted login page and
/// handed to the client at its `redirectUri`. We store only the code's hash; the
/// row is single-use (deleted when the client exchanges it) and short-lived.
/// `codeChallenge`/`codeChallengeMethod` carry the optional PKCE binding; `state`
/// is the client's opaque value, echoed back on the redirect.
struct WebAuthRecord: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "web_auth"

    var id: String
    var codeHash: String
    var userId: String
    var redirectUri: String
    var state: String?
    var codeChallenge: String?
    var codeChallengeMethod: String?
    var createdAt: Double
    var expiresAt: Double
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
    /// The caller's personal rating, 0–10 (nil = unrated).
    var rating: Double? = nil

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
    /// A BlurHash for this person's profile photo, generated lazily by the
    /// low-res-images backfill (`BlurHashBackfillService`) when the extension is in
    /// `blurhash` mode. nil until generated, or when the person has no photo; serving
    /// then falls back to the URL placeholder.
    var blurHash: String?
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
    /// Legacy single-image hash: a BlurHash for the poster placeholder only. Kept as
    /// a read-fallback for the `primary` role; new hashes (all roles) live in
    /// `imageBlurHashesJSON`. nil until generated.
    var placeholderBlurHash: String?
    /// Per-role BlurHashes for **every** image, generated lazily by the low-res-images
    /// backfill (`BlurHashBackfillService`) when the extension is in `blurhash` mode.
    /// A JSON `{role: hash}` map keyed by `primary`/`backdrop`/`thumb`/`logo`/`banner`
    /// — the same role keys as `ItemImages.variants`. nil/absent role ⇒ serving falls
    /// back to the URL placeholder for that role.
    var imageBlurHashesJSON: String?
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

    /// Selectable versions/editions — the same title backed by more than one file
    /// (4K + 1080p, Director's Cut + Theatrical), stored as a JSON `[StoredVersion]`
    /// and projected onto `Item.versions`. `sourceKey` mirrors the first (default)
    /// version. Absent/single ⇒ an ordinary single-file item.
    var versionsJSON: String? = nil

    /// Decoded stored versions (empty if none / malformed), best-first as stored.
    func storedVersions() -> [StoredVersion] {
        guard let versionsJSON, let data = versionsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([StoredVersion].self, from: data)
        else { return [] }
        return list
    }

    /// Versions projected for the wire — only when there's a real choice (≥2), so a
    /// single-file item stays clean (`versions` omitted, resolve by id).
    func versionsList() -> [MediaVersion]? {
        let stored = storedVersions()
        guard stored.count >= 2 else { return nil }
        return stored.map(\.asProtocol)
    }

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
    /// - Parameter placeholderMode: how to emit low-res `placeholder` forms (the
    ///   low-res-images extension's knob): `.url` (tiny image URL, the default),
    ///   `.blurhash` (the generated BlurHash per role, falling back to the URL form
    ///   for any role without a hash yet), or `.off` (omit all placeholders). Every
    ///   image role — and each cast face — carries its own hash once the lazy backfill
    ///   (`BlurHashBackfillService`) has reached it.
    func toProtocol(full: Bool = false, placeholderMode: PlaceholderMode = .url) -> Item {
        // Per-image variants: each role carries its own low-res placeholder and an
        // aspect hint (inferred from the role's orientation), so a client can blur
        // up and lay out each image independently — not just the poster. The URL form
        // is derived here from the stored URLs; the BlurHash form comes from the
        // per-role hashes the backfill caches, keyed by the same role names.
        let landscape = 1.778, portrait = 0.667
        let sources = placeholderSourceURLs()
        var hashes = imageBlurHashes()
        // Never serve a BlurHash for excluded roles (e.g. logos), even if one was
        // generated by an older build — they fall back to the URL form.
        for role in Self.nonBlurHashableRoles { hashes[role] = nil }
        // `primary` keeps the legacy single-hash column as a fallback, so posters
        // hashed before the per-role map existed keep their BlurHash until re-backfilled.
        let posterPlaceholder = placeholderMode.placeholder(
            url: sources["primary"], blurHash: hashes["primary"] ?? placeholderBlurHash)
        var variants: [String: ImageInfo] = [:]
        if let primaryImage {
            variants["primary"] = ImageInfo(
                url: primaryImage, placeholder: posterPlaceholder,
                aspect: type == "episode" ? landscape : portrait)  // episode primary is the landscape still
        }
        if let backdropImage {
            variants["backdrop"] = ImageInfo(
                url: backdropImage, placeholder: placeholderMode.placeholder(url: sources["backdrop"], blurHash: hashes["backdrop"]), aspect: landscape)
        }
        if let thumbImage {
            variants["thumb"] = ImageInfo(
                url: thumbImage, placeholder: placeholderMode.placeholder(url: sources["thumb"], blurHash: hashes["thumb"]), aspect: landscape)
        }
        // TMDB title logos top out at `w500` / `original`; `w500` (500px wide) looks
        // soft on large/retina/TV screens, so serve the full-resolution `original` (a
        // small transparent PNG). Done at serve time so existing items get it too,
        // without a re-enrich.
        let logoFull = logoImage.map { Self.resizeTMDB($0, to: "original") }
        if let logoFull {
            variants["logo"] = ImageInfo(url: logoFull, placeholder: placeholderMode.placeholder(url: sources["logo"], blurHash: hashes["logo"]))
        }
        if let bannerImage {
            variants["banner"] = ImageInfo(url: bannerImage, placeholder: placeholderMode.placeholder(url: sources["banner"], blurHash: hashes["banner"]))
        }
        let images: ItemImages? = variants.isEmpty ? nil
            : ItemImages(primary: primaryImage, backdrop: backdropImage, thumb: thumbImage,
                         logo: logoFull, banner: bannerImage, variants: variants)

        var item = Item(
            id: id,
            type: ItemType(rawValue: type) ?? .unknown(type),
            title: title,
            tmdbId: tmdbId,
            year: year,
            images: images,
            placeholder: posterPlaceholder,
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
        // Selectable versions/editions (only when there's a real choice). Cheap and
        // useful on a tile ("2 versions"), so it's not gated behind `full`.
        item.versions = versionsList()
        if full {
            item.overview = overview
            item.runtime = runtime
            item.genres = decodedGenres()
            item.communityRating = communityRating
            item.officialRating = officialRating
            item.cast = decodedCast(placeholderMode: placeholderMode)
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

    /// Image roles deliberately excluded from BlurHash generation and serving — they
    /// always use the plain URL placeholder form. `logo` is a transparent clearlogo:
    /// hashing flattens its transparency to a dark blob, and it's a PNG the Linux
    /// JPEG decoder can't read anyway, so a hash there is both ugly and platform-
    /// inconsistent. Shared by generation (`BlurHashBackfill`) and projection.
    static let nonBlurHashableRoles: Set<String> = ["logo"]

    /// The tiny source URL each image role's low-res placeholder (and its BlurHash)
    /// is derived from. Generation (`BlurHashBackfillService`) and projection share
    /// this so a stored hash always matches the URL form it falls back to. Only roles
    /// whose image exists are present; keyed by the `ItemImages.variants` role names.
    func placeholderSourceURLs() -> [String: String] {
        var urls: [String: String] = [:]
        // `primary` uses the canonical tiny poster/still URL set during enrichment;
        // fall back to a w92 of the full image if that's somehow absent.
        if let placeholderURL {
            urls["primary"] = placeholderURL
        } else if let primaryImage {
            urls["primary"] = Self.resizeTMDB(primaryImage, to: "w92")
        }
        if let backdropImage { urls["backdrop"] = Self.resizeTMDB(backdropImage, to: "w300") }
        if let thumbImage { urls["thumb"] = Self.resizeTMDB(thumbImage, to: "w300") }
        if let logoImage { urls["logo"] = Self.resizeTMDB(logoImage, to: "w92") }
        if let bannerImage { urls["banner"] = Self.resizeTMDB(bannerImage, to: "w300") }
        return urls
    }

    /// The cached per-role BlurHashes (`{role: hash}`), empty when none generated yet.
    func imageBlurHashes() -> [String: String] {
        guard let imageBlurHashesJSON, let data = imageBlurHashesJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
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

    private func decodedCast(placeholderMode: PlaceholderMode) -> [CastMember]? {
        guard let castJSON, let data = castJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode([StoredCast].self, from: data)
        else { return nil }
        return stored.map {
            // Route each face through the mode like every other image: `off` emits no
            // placeholder, `blurhash` uses the backfilled hash (falling back to the URL
            // form until one exists), `url` uses the tiny URL.
            CastMember(id: $0.id, name: $0.name, role: $0.role, imageURL: $0.imageURL,
                       placeholder: placeholderMode.placeholder(url: $0.placeholderURL, blurHash: $0.blurHash))
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
