import Foundation

/// The outcome of identifying a raw item against TMDB.
struct Identification: Sendable {
    var tmdbId: Int
    var type: String
    /// 0...1 confidence; lets low-confidence matches be surfaced for review.
    var confidence: Double
}

/// **The load-bearing subsystem.** Turns a raw item (title/year/key) into a
/// confident TMDB id. Kept behind a protocol so the matching strategy can be
/// swapped without touching anything downstream.
protocol Identifier: Sendable {
    func identify(title: String, year: Int?, type: String, sourceKey: String) async throws -> Identification?
}

/// v1 heuristic identifier: search TMDB by title (+ year), then rank candidates
/// by title equality and year agreement, preferring popularity as a tie-break.
/// Movies only for now; other types are left unidentified (skeleton).
struct HeuristicIdentifier: Identifier {
    let tmdb: any TMDBClient

    func identify(title: String, year: Int?, type: String, sourceKey: String) async throws -> Identification? {
        // Only movies are identified in this milestone.
        guard type == "movie" || type == "other" else { return nil }

        // Prefer the clean title we have; fall back to parsing the key.
        let parsed = FilenameParser.parse(sourceKey)
        let queryTitle = title.isEmpty ? parsed.title : title
        let queryYear = year ?? parsed.year
        guard !queryTitle.isEmpty else { return nil }

        let results = try await tmdb.searchMovie(title: queryTitle, year: queryYear)
        guard let best = rank(results, title: queryTitle, year: queryYear) else { return nil }
        return Identification(tmdbId: best.result.id, type: "movie", confidence: best.confidence)
    }

    /// Score each candidate; return the highest, or nil if none.
    private func rank(_ results: [TMDBSearchResult], title: String, year: Int?) -> (result: TMDBSearchResult, confidence: Double)? {
        let normalizedQuery = Self.normalize(title)
        var best: (result: TMDBSearchResult, confidence: Double)?

        for result in results {
            var score = 0.3  // any returned candidate is weak evidence
            let normalizedResult = Self.normalize(result.title)
            if normalizedResult == normalizedQuery {
                score += 0.5
            } else if normalizedResult.contains(normalizedQuery) || normalizedQuery.contains(normalizedResult) {
                score += 0.25
            }
            if let year, let resultYear = result.year, year == resultYear {
                score += 0.2
            }
            score = min(score, 1.0)

            if best == nil || score > best!.confidence
                || (score == best!.confidence && result.popularity > best!.result.popularity) {
                best = (result, score)
            }
        }
        return best
    }

    /// Case/space/punctuation-insensitive title comparison.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }
}
