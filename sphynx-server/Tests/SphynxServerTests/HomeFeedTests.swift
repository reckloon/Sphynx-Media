import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The unified home feed (M7 #1): typed shelves with an aspect, and **next-up
/// episodes merged into Continue Watching** — never a separate "Next Up".
@Suite("Home feed: typed shelves + unified continue/next-up")
struct HomeFeedTests {
    private let baseURL = "https://cdn.example/tv"
    private let manifestURL = "stub://home-tv"

    // A three-episode show, so "next up" has somewhere to point.
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Show.S01E01.mkv", "container": "mkv" },
            { "key": "Show.S01E02.mkv", "container": "mkv" },
            { "key": "Show.S01E03.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }

    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            tvSearchResults: ["show": [TMDBTVSearchResult(id: 700, name: "Show", year: 2021, popularity: 50)]],
            tvDetailsByID: [700: TMDBTVDetails(
                id: 700, name: "Show", overview: "A show.", year: 2021,
                genres: ["Drama"], voteAverage: 8.0, posterPath: "/p.jpg", backdropPath: "/bd.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 3, posterPath: "/s1.jpg")]
            )],
            seasonDetailsByID: [700: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "S1", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "One", overview: "1", stillPath: "/e1.jpg", airDate: "2021-01-01", runtimeMinutes: 50),
                    TMDBEpisode(episodeNumber: 2, name: "Two", overview: "2", stillPath: "/e2.jpg", airDate: "2021-01-08", runtimeMinutes: 50),
                    TMDBEpisode(episodeNumber: 3, name: "Three", overview: "3", stillPath: "/e3.jpg", airDate: "2021-01-15", runtimeMinutes: 50),
                ]
            )]]
        )
    }

    /// Scan the show and return (token, [episode ids in order E01,E02,E03]).
    private func setup(_ client: any TestClientProtocol) async throws -> (token: String, episodes: [String]) {
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
            uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(IndexSummary.self) }

        // series → season → episodes (ordered E01,E02,E03)
        let series: ItemsResponse = try await client.execute(
            uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded() }
        let seasons: ItemsResponse = try await client.execute(
            uri: "/v1/items?parent=\(series.items[0].id)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded() }
        let episodes: ItemsResponse = try await client.execute(
            uri: "/v1/items?parent=\(seasons.items[0].id)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded() }
        return (token, episodes.items.map(\.id))
    }

    @Test("watching E1 surfaces E2 as next-up inside Continue Watching")
    func nextUpMergedIntoContinue() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let (token, eps) = try await setup(client)

            // Finish episode 1.
            try await client.execute(
                uri: "/v1/items/\(eps[0])/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(watched: true, isFavorite: nil))
            ) { #expect($0.status == .ok) }

            // Continue Watching now offers episode 2 (next up), not episode 1.
            let cont: ItemsResponse = try await client.execute(
                uri: "/v1/home/continue", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(cont.items.contains { $0.id == eps[1] })
            #expect(cont.items.contains { $0.id == eps[0] } == false)
            // It's a fresh start, not a resume.
            #expect(cont.items.first { $0.id == eps[1] }?.resumePosition ?? 0 == 0)

            // The typed home feed: a landscape Continue Watching shelf carrying it,
            // and crucially NO separate "next up" shelf — they are one row.
            let home: HomeResponse = try await client.execute(
                uri: "/v1/home", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let cw = home.shelves.first { $0.kind == .continueWatching }
            #expect(cw != nil)
            #expect(cw?.aspect == .landscape)
            #expect(cw?.items.contains { $0.id == eps[1] } == true)
            #expect(home.shelves.contains { $0.kind == .unknown("nextUp") } == false)
        }
    }

    @Test("an in-progress episode wins over next-up for the same show")
    func resumeWinsOverNextUp() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let (token, eps) = try await setup(client)

            // Finished E1, but currently partway through E3.
            try await client.execute(
                uri: "/v1/items/\(eps[0])/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(watched: true, isFavorite: nil))
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/playstate/\(eps[2])/start", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStartBody(position: 120))
            ) { #expect($0.status == .noContent) }

            // The show is represented by the in-progress E3 — E2 next-up is suppressed.
            let cont: ItemsResponse = try await client.execute(
                uri: "/v1/home/continue", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(cont.items.contains { $0.id == eps[2] })
            #expect(cont.items.contains { $0.id == eps[1] } == false)
            #expect(cont.items.first { $0.id == eps[2] }?.resumePosition == 120)
        }
    }
}
