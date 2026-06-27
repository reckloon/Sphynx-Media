import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Identifier + Enricher (TMDB)")
struct EnrichmentFlowTests {
    private let manifestURL = "stub://movies"
    private let baseURL = "https://cdn.example/movies"

    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "The.Matrix.1999.mkv", "title": "The Matrix", "type": "movie", "container": "mkv", "year": 1999 }
        ] }
        """.utf8)
    }

    /// The Matrix, as TMDB would return it.
    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: ["the matrix": [TMDBSearchResult(id: 603, title: "The Matrix", year: 1999, popularity: 80)]],
            details: [603: TMDBMovieDetails(
                id: 603, title: "The Matrix",
                overview: "A hacker learns the truth about his reality.",
                year: 1999, runtimeMinutes: 136,
                genres: ["Action", "Science Fiction"],
                voteAverage: 8.2,
                posterPath: "/poster.jpg", backdropPath: "/back.jpg",
                cast: [TMDBCastMember(id: 6384, name: "Keanu Reeves", character: "Neo", profilePath: "/keanu.jpg")]
            )]
        )
    }

    private func loginCreateScan(
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ libraryId: String, _ scan: IndexSummary) async throws -> Void
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
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(
                    label: "CDN", driver: "http", baseURL: baseURL, headers: nil,
                    libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }

            let scan: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }

            try await body(client, token, library.id, scan)
        }
    }

    @Test("scan identifies + enriches; full detail carries TMDB metadata")
    func scanEnriches() async throws {
        try await loginCreateScan { client, token, libraryId, scan in
            #expect(scan.added == 1)
            #expect(scan.enriched == 1)

            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let item = try #require(page.items.first)
            #expect(item.tmdbId == "603")

            let full: Item = try await client.execute(
                uri: "/v1/items/\(item.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(full.overview == "A hacker learns the truth about his reality.")
            #expect(full.runtime == 8160)  // 136 minutes → seconds
            #expect(full.genres == ["Action", "Science Fiction"])
            #expect(full.communityRating == 8.2)
            #expect(full.images?.primary == "https://image.tmdb.org/t/p/w500/poster.jpg")
            #expect(full.placeholder == .url("https://image.tmdb.org/t/p/w92/poster.jpg"))
            #expect(full.cast?.first?.name == "Keanu Reeves")
            #expect(full.cast?.first?.role == "Neo")
            #expect(full.cast?.first?.id == "pe_6384")
        }
    }

    @Test("skeleton carries tile fields but omits enrichment")
    func skeletonOmitsEnrichment() async throws {
        try await loginCreateScan { client, token, libraryId, _ in
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)&detail=skeleton", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let item = try #require(page.items.first)
            // Tile fields present…
            #expect(item.images?.primary != nil)
            #expect(item.placeholder == .url("https://image.tmdb.org/t/p/w92/poster.jpg"))
            #expect(item.year == 1999)
            // …enrichment absent.
            #expect(item.overview == nil)
            #expect(item.genres == nil)
            #expect(item.cast == nil)
        }
    }

    @Test("re-scan does not re-enrich fresh items")
    func rescanSkipsFresh() async throws {
        try await loginCreateScan { client, token, _, _ in
            // Find the source again via a second scan-all and check enriched==0.
            let summary: IndexAllSummary = try await client.execute(
                uri: "/v1/admin/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(summary.sources.allSatisfy { $0.enriched == 0 })
        }
    }

    @Test("admin identity override pins a TMDB id and re-enriches")
    func identityOverride() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            // Manually add an item with the wrong title (won't auto-identify).
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(
                    type: "movie", title: "Unknown Film", sourceId: nil,
                    sourceKey: "https://cdn.example/x.mkv", container: "mkv",
                    tmdbId: nil, libraryId: nil, parentId: nil, year: nil))
            ) { try $0.decoded() }
            #expect(item.overview == nil)

            // Pin it to The Matrix.
            let pinned: Item = try await client.execute(
                uri: "/v1/admin/items/\(item.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "603", type: "movie"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(pinned.tmdbId == "603")
            #expect(pinned.overview == "A hacker learns the truth about his reality.")
            #expect(pinned.cast?.first?.name == "Keanu Reeves")
        }
    }

    @Test("enrichment endpoints require TMDB configuration")
    func enrichmentRequiresTMDB() async throws {
        // No tmdbClient injected and no key → enrichment disabled.
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            try await client.execute(
                uri: "/v1/admin/enrich", method: .post, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .badRequest) }
        }
    }
}
