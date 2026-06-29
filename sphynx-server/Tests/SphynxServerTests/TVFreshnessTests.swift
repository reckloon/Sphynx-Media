import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Two TV behaviors: a season/episode's displayed series name follows the
/// **normalized** series title (not the source-language parsed name), and a re-scan
/// of an already-enriched, fresh library makes **no** TMDB calls.
@Suite("TV: child seriesTitle follows normalized title; no re-enrich on fresh re-scan")
struct TVFreshnessTests {
    private let baseURL = "https://cdn/tv"
    private let manifestURL = "stub://tv-fresh"

    // Folder parses to "Tedd Lasso"; TMDB's canonical name is "Ted Lasso".
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Tedd Lasso/S01E01.mkv", "container": "mkv" },
            { "key": "Tedd Lasso/S01E02.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }
    private var tmdb: StubTMDBClient {
        StubTMDBClient(
            tvSearchResults: ["tedd lasso": [TMDBTVSearchResult(id: 97546, name: "Ted Lasso", year: 2020, popularity: 80)]],
            tvDetailsByID: [97546: TMDBTVDetails(
                id: 97546, name: "Ted Lasso", overview: "Coach.", year: 2020, genres: ["Comedy"],
                voteAverage: 8.4, posterPath: "/ted.jpg", backdropPath: "/bd.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 2, posterPath: "/s1.jpg")])],
            seasonDetailsByID: [97546: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "S1.", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "Pilot", overview: "Ted arrives.", stillPath: "/e1.jpg", airDate: "2020-08-14", runtimeMinutes: 30),
                    TMDBEpisode(episodeNumber: 2, name: "Biscuits", overview: "Biscuits.", stillPath: "/e2.jpg", airDate: "2020-08-14", runtimeMinutes: 30),
                ])]]
        )
    }

    @Test("season + episode carry the normalized series title; re-scan enriches nothing")
    func childSeriesTitleAndFreshness() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: tmdb)
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }
            let lib: String = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "TV", kind: "tvShows"))
            ) { try $0.decoded(LibraryResponse.self).id }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: lib, manifestURL: manifestURL))
            ) { try $0.decoded() }
            func scan() async throws -> IndexSummary {
                try await client.execute(uri: "/v1/admin/sources/\(source.id)/scan", method: .post,
                    headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            }
            func children(of parent: String) async throws -> [Item] {
                try await client.execute(uri: "/v1/items?parent=\(parent)", method: .get,
                    headers: jsonHeaders(bearer: token)) { try $0.decoded(ItemsResponse.self).items }
            }

            _ = try await scan()

            // Series renamed to the canonical "Ted Lasso".
            let series = try #require(try await children(of: lib).first)
            #expect(series.title == "Ted Lasso")

            // The SEASON displays the normalized series name — not the parsed "Tedd Lasso".
            let season = try #require(try await children(of: series.id).first)
            #expect(season.type == .season)
            #expect(season.seriesTitle == "Ted Lasso")

            // …and so do the EPISODES.
            let episodes = try await children(of: season.id)
            #expect(episodes.count == 2)
            #expect(episodes.allSatisfy { $0.seriesTitle == "Ted Lasso" })

            // A re-scan of the now-fresh tree enriches nothing and churns nothing —
            // i.e. it makes no TMDB calls against known items.
            let rescan = try await scan()
            #expect(rescan.enriched == 0)
            #expect(rescan.updated == 0)
            #expect(rescan.added == 0)
        }
    }
}
