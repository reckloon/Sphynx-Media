import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Admin catalog CRUD + cascade (M3)")
struct CatalogCRUDTests {
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
                id: 95396, name: "Severance", overview: "…", year: 2022,
                genres: ["Drama"], voteAverage: 8.4, posterPath: "/sev.jpg", backdropPath: "/bd.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 2, posterPath: "/s1.jpg")]
            )],
            seasonDetailsByID: [95396: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "…", posterPath: "/s1.jpg",
                episodes: [
                    TMDBEpisode(episodeNumber: 1, name: "E1", overview: "…", stillPath: "/e1.jpg", airDate: "2022-02-18", runtimeMinutes: 57),
                    TMDBEpisode(episodeNumber: 2, name: "E2", overview: "…", stillPath: "/e2.jpg", airDate: "2022-02-18", runtimeMinutes: 49),
                ]
            )]]
        )
    }

    /// Logs in, makes a TV library + source, scans it, and runs the body with
    /// (client, token, libraryId, sourceId).
    private func withTree(
        _ body: @Sendable @escaping (any TestClientProtocol, String, String, String) async throws -> Void
    ) async throws {
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
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }
            try await body(client, token, library.id, source.id)
        }
    }

    private func topLevel(_ client: any TestClientProtocol, _ token: String, _ lib: String) async throws -> [Item] {
        try await client.execute(
            uri: "/v1/items?parent=\(lib)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(ItemsResponse.self).items }
    }

    private func children(_ client: any TestClientProtocol, _ token: String, _ parent: String) async throws -> [Item] {
        try await client.execute(
            uri: "/v1/items?parent=\(parent)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(ItemsResponse.self).items }
    }

    @Test("admin can list + update libraries and sources")
    func listAndUpdate() async throws {
        try await withTree { client, token, lib, source in
            // List.
            let libs: AdminLibrariesResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(libs.libraries.contains { $0.id == lib })
            let sources: SourcesResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(sources.sources.contains { $0.id == source })

            // Update the library title.
            let updated: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries/\(lib)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(UpdateLibraryRequest(title: "Shows", kind: nil))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(updated.title == "Shows")

            // Update the source label.
            let src: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources/\(source)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(UpdateSourceRequest(label: "Renamed", baseURL: nil, headers: nil,
                    manifestURL: nil, libraryId: nil, config: nil, secrets: nil))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(src.label == "Renamed")
        }
    }

    @Test("deleting a source cascades its items and prunes empty containers")
    func deleteSourceCascades() async throws {
        try await withTree { client, token, lib, source in
            #expect(try await topLevel(client, token, lib).count == 1)  // the series

            try await client.execute(
                uri: "/v1/admin/sources/\(source)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }

            // Items gone, the series/season containers pruned → library empty.
            #expect(try await topLevel(client, token, lib).isEmpty)
            // Source gone from the list.
            let sources: SourcesResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(sources.sources.isEmpty)
        }
    }

    @Test("deleting a library cascades its items and sources")
    func deleteLibraryCascades() async throws {
        try await withTree { client, token, lib, source in
            try await client.execute(
                uri: "/v1/admin/libraries/\(lib)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }

            let libs: AdminLibrariesResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(libs.libraries.isEmpty)
            let sources: SourcesResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(sources.sources.isEmpty)  // the feeding source went too
        }
    }

    @Test("deleting the last episode prunes its season and series")
    func deleteLeafPrunesAncestors() async throws {
        try await withTree { client, token, lib, _ in
            let series = try #require(try await topLevel(client, token, lib).first)
            let season = try #require(try await children(client, token, series.id).first)
            let episodes = try await children(client, token, season.id)
            #expect(episodes.count == 2)

            // Delete one episode → season keeps the other; tree intact.
            try await client.execute(
                uri: "/v1/admin/items/\(episodes[0].id)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }
            #expect(try await topLevel(client, token, lib).count == 1)
            #expect(try await children(client, token, season.id).count == 1)

            // Delete the last episode → season + series prune away → library empty.
            try await client.execute(
                uri: "/v1/admin/items/\(episodes[1].id)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }
            #expect(try await topLevel(client, token, lib).isEmpty)
        }
    }

    @Test("deleting a series removes its whole subtree")
    func deleteContainerSubtree() async throws {
        try await withTree { client, token, lib, _ in
            let series = try #require(try await topLevel(client, token, lib).first)
            try await client.execute(
                uri: "/v1/admin/items/\(series.id)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }
            #expect(try await topLevel(client, token, lib).isEmpty)
            // The episode is gone too.
            try await client.execute(
                uri: "/v1/items/\(series.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .notFound) }
        }
    }
}
