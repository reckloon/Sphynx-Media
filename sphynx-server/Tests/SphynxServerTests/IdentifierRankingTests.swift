import Foundation
import Testing
@testable import SphynxServer

/// Title-matching heuristics: normalization, token-overlap similarity, and the
/// TV series ranker that picks a TMDB candidate. Regression cover for the
/// "Love.and.Death" → "Stories About Love and Death" mis-match, where the real
/// "Love & Death" lost because `&` was stripped (never canonicalised to "and")
/// and a longer title won on a bare substring `contains`.
@Suite("Identifier ranking")
struct IdentifierRankingTests {

    @Test("normalize canonicalises & to \"and\" and folds diacritics")
    func normalizeAmpersandAndDiacritics() {
        #expect(HeuristicIdentifier.normalize("Love & Death") == "love and death")
        #expect(HeuristicIdentifier.normalize("Love and Death") == "love and death")
        #expect(HeuristicIdentifier.normalize("Pokémon") == "pokemon")
    }

    @Test("titleSimilarity rewards an exact match over a padded superset")
    func similarityPenalisesPadding() {
        let query = HeuristicIdentifier.tokens("Love and Death")
        let exact = HeuristicIdentifier.titleSimilarity(query, HeuristicIdentifier.tokens("Love & Death"))
        let padded = HeuristicIdentifier.titleSimilarity(query, HeuristicIdentifier.tokens("Stories About Love and Death"))
        #expect(exact == 1.0)
        #expect(padded < exact)
        #expect(HeuristicIdentifier.titleSimilarity(query, HeuristicIdentifier.tokens("Breaking Bad")) == 0)
    }

    private func loveAndDeathStub(loveDeathPopularity: Double = 5, decoyPopularity: Double = 80) -> StubTMDBClient {
        StubTMDBClient(tvSearchResults: ["love and death": [
            // The decoy is far more popular — it must still lose on title affinity.
            TMDBTVSearchResult(id: 222, name: "Stories About Love and Death", year: 2014, popularity: decoyPopularity),
            TMDBTVSearchResult(id: 111, name: "Love & Death", year: 2023, popularity: loveDeathPopularity),
        ]])
    }

    @Test("identifySeries picks the exact show over a more-popular padded superset")
    func identifyPrefersExactTitle() async throws {
        let tv = TVEnricher(tmdb: loveAndDeathStub())
        let id = try await tv.identifySeries(title: "Love and Death")
        #expect(id == 111)
    }

    @Test("a matching year confirms the right candidate")
    func identifyUsesYear() async throws {
        let tv = TVEnricher(tmdb: loveAndDeathStub(loveDeathPopularity: 5, decoyPopularity: 999))
        let id = try await tv.identifySeries(title: "Love and Death", year: 2023)
        #expect(id == 111)
    }

    @Test("a popular but unrelated candidate never beats the real title")
    func identifyIgnoresPopularDistractor() async throws {
        let stub = StubTMDBClient(tvSearchResults: ["love and death": [
            TMDBTVSearchResult(id: 900, name: "Breaking Bad", year: 2008, popularity: 999),
            TMDBTVSearchResult(id: 111, name: "Love & Death", year: 2023, popularity: 3),
        ]])
        let tv = TVEnricher(tmdb: stub)
        #expect(try await tv.identifySeries(title: "Love and Death") == 111)
    }

    @Test("no search results leaves the series unidentified")
    func identifyReturnsNilWhenNothingFound() async throws {
        let tv = TVEnricher(tmdb: StubTMDBClient(tvSearchResults: [:]))
        #expect(try await tv.identifySeries(title: "Love and Death") == nil)
    }
}
