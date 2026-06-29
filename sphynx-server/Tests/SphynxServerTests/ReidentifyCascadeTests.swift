import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Re-identifying ("Fix"-ing) a series must cascade onto its seasons and episodes:
/// they carry the show's TMDB id plus a (season, episode) index, so re-pointing the
/// series to a different show has to update that stored id and re-enrich each child —
/// otherwise the series tile is corrected but every episode keeps the old show's
/// metadata.
@Suite("Re-identify a series cascades to its children")
struct ReidentifyCascadeTests {
    private let baseURL = "https://cdn.example/tv"
    private let manifestURL = "stub://cascade"

    private var manifestJSON: Data {
        Data("""
        { "items": [ { "key": "Wrongshow.S01E01.mkv", "container": "mkv" } ] }
        """.utf8)
    }

    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            tvSearchResults: ["wrongshow": [TMDBTVSearchResult(id: 100, name: "Wrong Show", year: 2010, popularity: 50)]],
            tvDetailsByID: [
                100: TMDBTVDetails(id: 100, name: "Wrong Show", overview: "The wrong show.", year: 2010,
                    genres: ["Drama"], voteAverage: 5.0, posterPath: "/w.jpg", backdropPath: "/wbd.jpg",
                    seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 1, posterPath: "/ws1.jpg")]),
                200: TMDBTVDetails(id: 200, name: "Right Show", overview: "The right show.", year: 2015,
                    genres: ["Comedy"], voteAverage: 9.0, posterPath: "/r.jpg", backdropPath: "/rbd.jpg",
                    seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 1, posterPath: "/rs1.jpg")]),
            ],
            seasonDetailsByID: [
                100: [1: TMDBSeasonDetails(seasonNumber: 1, name: "Season 1", overview: "Wrong S1", posterPath: "/ws1.jpg",
                    episodes: [TMDBEpisode(episodeNumber: 1, name: "Wrong E1", overview: "wrong ep", stillPath: "/we1.jpg", airDate: "2010-01-01", runtimeMinutes: 30)])],
                200: [1: TMDBSeasonDetails(seasonNumber: 1, name: "Season 1", overview: "Right S1", posterPath: "/rs1.jpg",
                    episodes: [TMDBEpisode(episodeNumber: 1, name: "Right E1", overview: "right ep", stillPath: "/re1.jpg", airDate: "2015-01-01", runtimeMinutes: 30)])],
            ]
        )
    }

    private func children(_ client: any TestClientProtocol, _ token: String, _ parent: String) async throws -> [Item] {
        try await client.execute(
            uri: "/v1/items?parent=\(parent)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(ItemsResponse.self).items }
    }

    @Test("re-pointing the series updates each episode's id, title and overview")
    func cascade() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }
            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "TV", kind: "tvShows"))
            ) { try $0.decoded() }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL, headers: nil, libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }

            // Initial: series + episode identified against the WRONG show (100).
            let series = try #require(try await children(client, token, library.id).first)
            #expect(series.title == "Wrong Show")
            let season = try #require(try await children(client, token, series.id).first)
            let episode = try #require(try await children(client, token, season.id).first)
            #expect(episode.tmdbId == "100")
            #expect(episode.title == "Wrong E1")

            // Fix the series → point it at the RIGHT show (200).
            let fixed: Item = try await client.execute(
                uri: "/v1/admin/items/\(series.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "200", type: "series"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(fixed.tmdbId == "200")
            #expect(fixed.title == "Right Show")

            // The episode must have followed the series to the new show.
            let updated: Item = try await client.execute(
                uri: "/v1/items/\(episode.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(updated.tmdbId == "200")
            #expect(updated.title == "Right E1")
            #expect(updated.overview == "right ep")
        }
    }
}
