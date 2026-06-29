import Foundation

/// Enrichment fields derived from TMDB, ready to apply to an item.
struct EnrichedFields: Sendable {
    /// Canonical title in the server's metadata language. Applied as the display
    /// name during enrichment (honoring the `title` lock), so a foreign-named
    /// release is normalised to the declared language. nil → keep the parsed name.
    var title: String? = nil
    var overview: String?
    var year: Int?
    var runtimeSeconds: Double?
    var genres: [String]
    var communityRating: Double?
    /// Content certification (e.g. "PG-13" / "TV-MA"), when TMDB has one.
    var officialRating: String? = nil
    var primaryImage: String?
    var backdropImage: String?
    var thumbImage: String?
    var placeholderURL: String?
    var cast: [StoredCast]
    // Extended metadata (optional; defaulted so the TV path needn't set them).
    var originalTitle: String? = nil
    var tagline: String? = nil
    var status: String? = nil
    var premiereDate: String? = nil
    var studios: [String] = []
    var directors: [String] = []
    var writers: [String] = []
    var countries: [String] = []
    var externalIds: [String: String] = [:]
    // M8 metadata fills (optional; defaulted so the TV path needn't set them).
    var logoImage: String? = nil
    var bannerImage: String? = nil
    var trailers: [String] = []
    var tags: [String] = []
    var sortTitle: String? = nil
    /// Collection / box set this movie belongs to, if any.
    var collection: TMDBCollection? = nil
}

/// Given a TMDB id, fetch metadata and map it to the protocol's enrichment
/// fields — overview, runtime, genres, rating, artwork, and a cheap URL-based
/// placeholder (a tiny TMDB image), plus top-billed cast with images.
struct Enricher: Sendable {
    let tmdb: any TMDBClient
    /// How many cast members to keep.
    var castLimit = 30

    /// Map TMDB cast/guest-star members to the persisted form (top `limit`,
    /// images sized like the movie path). Shared by movies, series, and episodes
    /// so people are populated consistently everywhere. Members without a TMDB photo
    /// are still kept (for a complete credits list); they just carry no image to hash.
    static func storedCast(_ members: [TMDBCastMember], limit: Int = 30) -> [StoredCast] {
        members.prefix(limit).map { member in
            StoredCast(
                id: "pe_\(member.id)",
                name: member.name,
                role: member.character,
                imageURL: TMDBImage.url(member.profilePath, size: "w185"),
                placeholderURL: TMDBImage.url(member.profilePath, size: "w92")
            )
        }
    }

    func enrichMovie(tmdbId: Int) async throws -> EnrichedFields {
        let details = try await tmdb.movieDetails(id: tmdbId)
        return EnrichedFields(
            title: details.title.isEmpty ? nil : details.title,
            overview: details.overview?.isEmpty == true ? nil : details.overview,
            year: details.year,
            runtimeSeconds: details.runtimeMinutes.map { Double($0) * 60 },
            genres: details.genres,
            communityRating: details.voteAverage,
            officialRating: details.officialRating,
            // Image roles (see API.md → Item shape): `primary` is the portrait
            // poster; `backdrop` is large landscape art; `thumb` is a smaller
            // LANDSCAPE card image (NOT a small poster) — derived from the backdrop
            // so horizontal tiles (e.g. Continue Watching) have a sized image.
            primaryImage: TMDBImage.url(details.posterPath, size: "w500"),
            backdropImage: TMDBImage.url(details.backdropPath, size: "w1280"),
            thumbImage: TMDBImage.url(details.backdropPath, size: "w780"),
            // Self-describing placeholder: a tiny poster URL for `primary` (no BlurHash compute).
            placeholderURL: TMDBImage.url(details.posterPath, size: "w92"),
            cast: Self.storedCast(details.cast, limit: castLimit),
            originalTitle: (details.originalTitle == details.title) ? nil : details.originalTitle,
            tagline: details.tagline,
            status: details.status,
            premiereDate: details.releaseDate,
            studios: details.studios,
            directors: details.directors,
            writers: details.writers,
            countries: details.countries,
            externalIds: details.imdbId.map { ["imdb": $0] } ?? [:],
            logoImage: TMDBImage.url(details.logoPath, size: "w500"),
            bannerImage: TMDBImage.url(details.bannerPath, size: "w1280"),
            trailers: details.trailers,
            tags: details.tags,
            sortTitle: Self.sortTitle(from: details.title),
            collection: details.collection
        )
    }

    /// Derive a sort title by dropping a leading English article ("The "/"A "/"An ").
    /// Returns nil when the title has no leading article (so we don't store a
    /// redundant copy of the title).
    static func sortTitle(from title: String) -> String? {
        for article in ["The ", "A ", "An "] where title.hasPrefix(article) {
            let stripped = String(title.dropFirst(article.count)).trimmingCharacters(in: .whitespaces)
            return stripped.isEmpty ? nil : stripped
        }
        return nil
    }
}
