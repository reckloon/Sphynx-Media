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
        let queryTokens = Self.tokens(title)
        var best: (result: TMDBSearchResult, confidence: Double)?

        for result in results {
            // Title affinity dominates: a token-overlap measure that rewards
            // covering the query while penalising candidates padded with extra
            // words, so a longer title that merely *contains* the query no longer
            // outranks an exact match. Year agreement confirms (and a far-off year
            // demotes a same-named remake); popularity only breaks ties.
            var score = 0.3 + 0.6 * Self.titleSimilarity(queryTokens, Self.tokens(result.title))
            if let year, let resultYear = result.year {
                let gap = abs(year - resultYear)
                if gap == 0 { score += 0.2 }
                else if gap >= 3 { score -= 0.15 }
            }
            score = min(max(score, 0.0), 1.0)

            if best == nil || score > best!.confidence
                || (score == best!.confidence && result.popularity > best!.result.popularity) {
                best = (result, score)
            }
        }
        return best
    }

    /// Case/space/punctuation-insensitive title key. Canonicalises `&` to the word
    /// "and" (so the release spelling `Love.and.Death` matches TMDB's `Love & Death`
    /// instead of the `&` vanishing) and folds diacritics (`Pokémon` == `Pokemon`).
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(Character.init)
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// The normalized title split into comparison tokens.
    static func tokens(_ s: String) -> [String] {
        normalize(s).split(separator: " ").map(String.init)
    }

    /// Token-overlap title similarity in `0...1`. Equal token sets score `1`;
    /// otherwise it is `|shared|² / (|query|·|candidate|)`, which rewards covering
    /// the query (recall) *and* penalises candidates padded with extra words
    /// (precision). So for the query "Love and Death", the exact "Love & Death"
    /// (→ `love and death`) scores `1`, while the longer "Stories About Love and
    /// Death" scores only `0.6` and no longer wins on a bare substring match.
    static func titleSimilarity(_ query: [String], _ candidate: [String]) -> Double {
        if query.isEmpty || candidate.isEmpty { return 0 }
        let q = Set(query), c = Set(candidate)
        if q == c { return 1 }
        let shared = Double(q.intersection(c).count)
        return (shared * shared) / Double(q.count * c.count)
    }
}
