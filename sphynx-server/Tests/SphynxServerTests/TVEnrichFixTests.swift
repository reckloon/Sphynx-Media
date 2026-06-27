import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Milestone 4: admin identity-override + re-enrich must route TV items through
/// the TV endpoints, not the movie endpoint.
@Suite("TV identity override + re-enrich")
struct TVEnrichFixTests {
    private let baseURL = "https://cdn.example/tv"
    private let manifestURL = "stub://tv"

    private var manifestJSON: Data {
        Data("""
        { "items": [ { "key": "Severance.S01E01.mkv", "container": "mkv" } ] }
        """.utf8)
    }

    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            tvSearchResults: ["severance": [TMDBTVSearchResult(id: 95396, name: "Severance", year: 2022, popularity: 90)]],
            tvDetailsByID: [95396: TMDBTVDetails(
                id: 95396, name: "Severance",
                overview: "Mark leads a team whose memories are surgically divided.",
                year: 2022, genres: ["Drama", "Mystery"], voteAverage: 8.4,
                posterPath: "/sev.jpg", backdropPath: "/bd.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 1, posterPath: "/s1.jpg")]
            )],
            seasonDetailsByID: [95396: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "First season.", posterPath: "/s1.jpg",
                episodes: [TMDBEpisode(episodeNumber: 1, name: "E1", overview: "Mark is promoted.", stillPath: "/e1.jpg", airDate: "2022-02-18", runtimeMinutes: 57)]
            )]]
        )
    }

    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("pinning a series to a TMDB id enriches via the TV endpoint")
    func setIdentityOnSeries() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)

            // A bare series container with no identity yet.
            let series: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "series", title: "Severance", sourceId: nil,
                    sourceKey: "series:severance", container: nil, tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }
            #expect(series.overview == nil)

            // Pin it to the show's TMDB id. The fix routes this through TVEnricher;
            // before it, this hit /movie/95396 (unstubbed → no enrichment).
            let pinned: Item = try await client.execute(
                uri: "/v1/admin/items/\(series.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "95396", type: "series"))
            ) { #expect($0.status == .ok); return try $0.decoded() }

            #expect(pinned.tmdbId == "95396")
            #expect(pinned.overview == "Mark leads a team whose memories are surgically divided.")
            #expect(pinned.genres == ["Drama", "Mystery"])
            #expect(pinned.images?.primary == "https://image.tmdb.org/t/p/w500/sev.jpg")
        }
    }

    @Test("force re-enriching an episode uses the season endpoint")
    func reEnrichEpisode() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let token = try await login(client)
            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "TV", kind: "tvShows"))
            ) { try $0.decoded() }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }

            // Walk to the episode.
            let series = try #require(try await client.execute(
                uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(ItemsResponse.self).items.first })
            let season = try #require(try await client.execute(
                uri: "/v1/items?parent=\(series.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(ItemsResponse.self).items.first })
            let episode = try #require(try await client.execute(
                uri: "/v1/items?parent=\(season.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(ItemsResponse.self).items.first })

            // Force re-enrich the episode → TV season endpoint, not /movie.
            let reEnriched: Item = try await client.execute(
                uri: "/v1/admin/items/\(episode.id)/enrich", method: .post, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(reEnriched.overview == "Mark is promoted.")
            #expect(reEnriched.runtime == 3420)  // 57 min → seconds
            #expect(reEnriched.images?.primary == "https://image.tmdb.org/t/p/w780/e1.jpg")
        }
    }
}
