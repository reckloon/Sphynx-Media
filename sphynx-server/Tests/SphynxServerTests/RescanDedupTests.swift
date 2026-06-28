import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Regression: re-scanning a source must reuse the synthetic series/season
/// container rows, not recreate them. The trap was a library-scoped dedup lookup
/// (`libraryId = ''`) that never matches the NULL `libraryId` stored when a source
/// is unmapped — so every re-scan spawned a fresh series + season subtree, and an
/// auto-refreshing source multiplied containers without bound (episodes/movies were
/// spared because they dedup on their stable `sourceKey`).
@Suite("Re-scan dedup: containers are reused, not duplicated")
struct RescanDedupTests {
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
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 2, posterPath: "/s1.jpg")]
            )],
            seasonDetailsByID: [95396: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "First season.", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "E1", overview: "Mark is promoted.", stillPath: "/e1.jpg", airDate: "2022-02-18", runtimeMinutes: 57),
                    TMDBEpisode(episodeNumber: 2, name: "E2", overview: "Helly resists.", stillPath: "/e2.jpg", airDate: "2022-02-18", runtimeMinutes: 49),
                ]
            )]]
        )
    }

    private func count(_ overview: OverviewResponse, _ type: String) -> Int {
        overview.byType.first { $0.type == type }?.indexed ?? 0
    }

    @Test("an unmapped source scanned twice keeps one series + one season")
    func rescanDoesNotDuplicateContainers() async throws {
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

            // An UNMAPPED source: no libraryId, no libraryMap. Containers it creates
            // get a NULL libraryId — the exact condition that defeated the old
            // library-scoped dedup lookup.
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL, headers: nil, libraryId: nil, manifestURL: manifestURL))
            ) { try $0.decoded() }

            func scan() async throws {
                _ = try await client.execute(
                    uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
                ) { $0 }
            }
            func overview() async throws -> OverviewResponse {
                try await client.execute(
                    uri: "/v1/admin/overview", method: .get, headers: jsonHeaders(bearer: token)
                ) { try $0.decoded() }
            }

            try await scan()
            let first = try await overview()
            #expect(count(first, "series") == 1)
            #expect(count(first, "season") == 1)
            #expect(count(first, "episode") == 2)

            // Re-scan the identical manifest. Before the fix this doubled the
            // series + season rows (episodes stayed put, deduped by sourceKey).
            try await scan()
            let second = try await overview()
            #expect(count(second, "series") == 1)
            #expect(count(second, "season") == 1)
            #expect(count(second, "episode") == 2)
        }
    }

    // A show whose parsed folder name differs from TMDB's canonical name: the
    // file parses to "Tedd Lasso", but identification maps it to "Ted Lasso", and
    // enrichment rewrites the display `title` accordingly. The indexer keeps
    // passing the parsed name on every re-scan, so dedup MUST key on the stable
    // parsed `seriesTitle`, not the rewritten `title` — otherwise each re-scan
    // misses the enriched row and spawns a duplicate series + season.
    private var rewriteManifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Tedd Lasso.S01E01.mkv", "container": "mkv" },
            { "key": "Tedd Lasso.S01E02.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }

    private var rewriteTMDB: StubTMDBClient {
        StubTMDBClient(
            // Searched by the parsed name ("tedd lasso"), but the canonical name is "Ted Lasso".
            tvSearchResults: ["tedd lasso": [TMDBTVSearchResult(id: 97546, name: "Ted Lasso", year: 2020, popularity: 80)]],
            tvDetailsByID: [97546: TMDBTVDetails(
                id: 97546, name: "Ted Lasso",
                overview: "An American football coach is hired to manage an English soccer team.",
                year: 2020, genres: ["Comedy"], voteAverage: 8.4,
                posterPath: "/ted.jpg", backdropPath: "/bd.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 2, posterPath: "/s1.jpg")]
            )],
            seasonDetailsByID: [97546: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "First season.", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "Pilot", overview: "Ted arrives.", stillPath: "/e1.jpg", airDate: "2020-08-14", runtimeMinutes: 30),
                    TMDBEpisode(episodeNumber: 2, name: "Biscuits", overview: "Biscuits.", stillPath: "/e2.jpg", airDate: "2020-08-14", runtimeMinutes: 30),
                ]
            )]]
        )
    }

    @Test("re-scan dedups even when enrichment rewrites the display title")
    func rescanSurvivesTitleRewrite() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: rewriteManifestJSON]),
            tmdbClient: rewriteTMDB
        )
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL, headers: nil, libraryId: nil, manifestURL: manifestURL))
            ) { try $0.decoded() }

            func scan() async throws {
                _ = try await client.execute(
                    uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
                ) { $0 }
            }
            func overview() async throws -> OverviewResponse {
                try await client.execute(
                    uri: "/v1/admin/overview", method: .get, headers: jsonHeaders(bearer: token)
                ) { try $0.decoded() }
            }

            try await scan()
            let first = try await overview()
            #expect(count(first, "series") == 1)   // enrichment renamed it to "Ted Lasso"
            #expect(count(first, "season") == 1)

            // Re-scan: the parser still yields "Tedd Lasso"; the stored row now reads
            // title "Ted Lasso". Dedup on the parsed `seriesTitle` keeps it at one.
            try await scan()
            let second = try await overview()
            #expect(count(second, "series") == 1)
            #expect(count(second, "season") == 1)
            #expect(count(second, "episode") == 2)
        }
    }
}
