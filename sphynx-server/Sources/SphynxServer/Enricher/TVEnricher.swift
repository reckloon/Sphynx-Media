import Foundation

/// TV identification + enrichment via TMDB, used by the Indexer when it builds
/// the series → season → episode tree. Movies go through `EnrichmentService`;
/// TV is hierarchical and enriched as the tree is created.
struct TVEnricher: Sendable {
    let tmdb: any TMDBClient

    /// Resolve a series title to a TMDB id (best ranked candidate), or nil.
    func identifySeries(title: String) async throws -> Int? {
        let results = try await tmdb.searchTV(title: title)
        let query = HeuristicIdentifier.normalize(title)
        var best: (id: Int, score: Double, popularity: Double)?
        for result in results {
            var score = 0.3
            let name = HeuristicIdentifier.normalize(result.name)
            if name == query { score += 0.5 }
            else if name.contains(query) || query.contains(name) { score += 0.25 }
            if best == nil || score > best!.score
                || (score == best!.score && result.popularity > best!.popularity) {
                best = (result.id, score, result.popularity)
            }
        }
        return best?.id
    }

    /// Enrichment fields for a series (poster/backdrop/overview/genres/rating).
    func seriesFields(tmdbId: Int) async throws -> EnrichedFields {
        let details = try await tmdb.tvDetails(id: tmdbId)
        return EnrichedFields(
            overview: details.overview?.isEmpty == true ? nil : details.overview,
            year: details.year,
            runtimeSeconds: nil,
            genres: details.genres,
            communityRating: details.voteAverage,
            // `thumb` is a smaller LANDSCAPE card image (from the backdrop), not a
            // small poster — so horizontal tiles get a sized image. See API.md.
            primaryImage: TMDBImage.url(details.posterPath, size: "w500"),
            backdropImage: TMDBImage.url(details.backdropPath, size: "w1280"),
            thumbImage: TMDBImage.url(details.backdropPath, size: "w780"),
            placeholderURL: TMDBImage.url(details.posterPath, size: "w92"),
            cast: Enricher.storedCast(details.cast)
        )
    }

    /// Full season details (poster + episode list), fetched once per season.
    func season(tmdbId: Int, season: Int) async throws -> TMDBSeasonDetails {
        try await tmdb.seasonDetails(tvId: tmdbId, season: season)
    }
}
