import Foundation

/// Enrichment fields derived from TMDB, ready to apply to an item.
struct EnrichedFields: Sendable {
    var overview: String?
    var year: Int?
    var runtimeSeconds: Double?
    var genres: [String]
    var communityRating: Double?
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
}

/// Given a TMDB id, fetch metadata and map it to the protocol's enrichment
/// fields — overview, runtime, genres, rating, artwork, and a cheap URL-based
/// placeholder (a tiny TMDB image), plus top-billed cast with images.
struct Enricher: Sendable {
    let tmdb: any TMDBClient
    /// How many cast members to keep.
    var castLimit = 15

    /// Map TMDB cast/guest-star members to the persisted form (top `limit`,
    /// images sized like the movie path). Shared by movies, series, and episodes
    /// so people are populated consistently everywhere.
    static func storedCast(_ members: [TMDBCastMember], limit: Int = 15) -> [StoredCast] {
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
            overview: details.overview?.isEmpty == true ? nil : details.overview,
            year: details.year,
            runtimeSeconds: details.runtimeMinutes.map { Double($0) * 60 },
            genres: details.genres,
            communityRating: details.voteAverage,
            primaryImage: TMDBImage.url(details.posterPath, size: "w500"),
            backdropImage: TMDBImage.url(details.backdropPath, size: "w1280"),
            thumbImage: TMDBImage.url(details.posterPath, size: "w342"),
            // Self-describing placeholder: a tiny poster URL (no BlurHash compute).
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
            externalIds: details.imdbId.map { ["imdb": $0] } ?? [:]
        )
    }
}
