import Foundation

/// TV identification + enrichment via TMDB, used by the Indexer when it builds
/// the series → season → episode tree. Movies go through `EnrichmentService`;
/// TV is hierarchical and enriched as the tree is created.
struct TVEnricher: Sendable {
    let tmdb: any TMDBClient

    /// Resolve a series title to a TMDB id (best ranked candidate), or nil.
    ///
    /// Candidates are scored by token-overlap title similarity — which rewards
    /// covering the query while penalising titles padded with extra words, so an
    /// exact "Love & Death" beats a longer "…Stories About Love and Death" for the
    /// query "Love and Death" — with a known `year` as a strong confirm/demote
    /// signal and popularity only as a tie-break. As before, the best-ranked of
    /// whatever TMDB returns is accepted (TMDB's search already filters relevance,
    /// and a messy parsed name like `Wrongshow` should still resolve to the one
    /// candidate it returns); the win here is ordering, not rejection.
    func identifySeries(title: String, year: Int? = nil) async throws -> Int? {
        let results = try await tmdb.searchTV(title: title)
        let queryTokens = HeuristicIdentifier.tokens(title)

        var best: (id: Int, score: Double, popularity: Double)?
        for result in results {
            var score = HeuristicIdentifier.titleSimilarity(queryTokens, HeuristicIdentifier.tokens(result.name))
            if let year, let resultYear = result.year {
                let gap = abs(year - resultYear)
                if gap == 0 { score += 0.25 }
                else if gap == 1 { score += 0.1 }
                else if gap >= 3 { score -= 0.2 }
            }
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
            title: details.name.isEmpty ? nil : details.name,
            overview: details.overview?.isEmpty == true ? nil : details.overview,
            year: details.year,
            runtimeSeconds: nil,
            genres: details.genres,
            communityRating: details.voteAverage,
            officialRating: details.officialRating,
            // `thumb` is a smaller LANDSCAPE card image (from the backdrop), not a
            // small poster — so horizontal tiles get a sized image. See API.md.
            primaryImage: TMDBImage.url(details.posterPath, size: "w500"),
            backdropImage: TMDBImage.url(details.backdropPath, size: "w1280"),
            thumbImage: TMDBImage.url(details.backdropPath, size: "w780"),
            placeholderURL: TMDBImage.url(details.posterPath, size: "w92"),
            cast: Enricher.storedCast(details.cast),
            // Title-logo (clearlogo) + wide banner, same as the movie path — so a
            // series' detail screen gets its logo, not just movies.
            logoImage: TMDBImage.url(details.logoPath, size: "original"),   // logos are small PNGs; serve full-res
            bannerImage: TMDBImage.url(details.bannerPath, size: "w1280")
        )
    }

    /// Full season details (poster + episode list), fetched once per season.
    func season(tmdbId: Int, season: Int) async throws -> TMDBSeasonDetails {
        try await tmdb.seasonDetails(tvId: tmdbId, season: season)
    }
}
