import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("TV: identify + hierarchy + browse")
struct TVFlowTests {
    private let baseURL = "https://cdn.example/tv"
    private let manifestURL = "stub://tv"

    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Severance.S01E01.mkv", "container": "mkv" },
            { "key": "Severance.S01E02.mkv", "container": "mkv" }
        ] }
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
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 2, posterPath: "/s1.jpg")],
                cast: [
                    TMDBCastMember(id: 1, name: "Adam Scott", character: "Mark S.", profilePath: "/adam.jpg"),
                    TMDBCastMember(id: 2, name: "Britt Lower", character: "Helly R.", profilePath: "/britt.jpg"),
                ]
            )],
            seasonDetailsByID: [95396: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "First season.", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "Good News About Hell", overview: "Mark is promoted.", stillPath: "/e1.jpg", airDate: "2022-02-18", runtimeMinutes: 57,
                                guestStars: [TMDBCastMember(id: 9, name: "Christopher Walken", character: "Burt G.", profilePath: "/walken.jpg")]),
                    TMDBEpisode(episodeNumber: 2, name: "Half Loop", overview: "Helly resists.", stillPath: "/e2.jpg", airDate: "2022-02-18", runtimeMinutes: 49),
                ]
            )]]
        )
    }

    @Test("scan builds series → season → episode, browsable as a tree")
    func scanBuildsTree() async throws {
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

            // Scan: 2 episode entries → 2 episodes added (series/season are byproducts).
            let summary: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(summary.scanned == 2)
            #expect(summary.added == 2)

            // Top level of the library → one series, enriched.
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(top.items.count == 1)
            let series = try #require(top.items.first)
            #expect(series.type == .series)
            #expect(series.title == "Severance")
            #expect(series.tmdbId == "95396")
            #expect(series.childCount == 1)  // one season
            #expect(series.images?.primary == "https://image.tmdb.org/t/p/w500/sev.jpg")

            // Series → one season.
            let seasons: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(series.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(seasons.items.count == 1)
            let season = try #require(seasons.items.first)
            #expect(season.type == .season)
            #expect(season.seasonIndex == 1)
            #expect(season.childCount == 2)  // two episodes
            #expect(season.images?.primary == "https://image.tmdb.org/t/p/w500/s1.jpg")
            // Seasons inherit the show's wide art (horizontal image).
            #expect(season.images?.backdrop == "https://image.tmdb.org/t/p/w1280/bd.jpg")

            // Season → two episodes (skeleton): ordered, with tile fields.
            let episodes: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(season.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(episodes.items.map(\.episodeIndex) == [1, 2])
            let ep1 = try #require(episodes.items.first)
            #expect(ep1.type == .episode)
            #expect(ep1.title == "Good News About Hell")
            #expect(ep1.seriesId == series.id)
            #expect(ep1.seriesTitle == "Severance")
            #expect(ep1.seasonIndex == 1)
            #expect(ep1.images?.primary == "https://image.tmdb.org/t/p/w780/e1.jpg")  // still (landscape)
            #expect(ep1.images?.backdrop == "https://image.tmdb.org/t/p/w1280/bd.jpg")  // show backdrop

            // Full detail carries the episode enrichment.
            let ep1Full: Item = try await client.execute(
                uri: "/v1/items/\(ep1.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(ep1Full.overview == "Mark is promoted.")
            #expect(ep1Full.runtime == 3420)  // 57 minutes → seconds
            // People are populated: the episode carries its guest stars…
            #expect(ep1Full.cast?.count == 1)
            #expect(ep1Full.cast?.first?.name == "Christopher Walken")
            #expect(ep1Full.cast?.first?.role == "Burt G.")
            #expect(ep1Full.cast?.first?.imageURL == "https://image.tmdb.org/t/p/w185/walken.jpg")

            // …and the series carries its regulars (people were missing before).
            let seriesFull: Item = try await client.execute(
                uri: "/v1/items/\(series.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(seriesFull.cast?.count == 2)
            #expect(seriesFull.cast?.first?.name == "Adam Scott")
            #expect(seriesFull.cast?.first?.role == "Mark S.")
            #expect(seriesFull.cast?.first?.imageURL == "https://image.tmdb.org/t/p/w185/adam.jpg")

            // An episode resolves to its direct URL; a container does not.
            let descriptor: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(ep1.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(descriptor.url == "\(baseURL)/Severance.S01E01.mkv")

            try await client.execute(
                uri: "/v1/resolve/\(series.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .notFound) }  // series is a container, not playable
        }
    }

    @Test("re-scanning TV is idempotent (no duplicate series/seasons)")
    func rescanIdempotent() async throws {
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

            _ = try await client.execute(uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }
            let second: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(second.added == 0)
            #expect(second.removed == 0)

            // Still exactly one series at top level.
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(top.items.count == 1)
        }
    }
}
