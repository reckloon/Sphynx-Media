import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Collections / box sets + metadata fills (M8)")
struct CollectionsTests {
    private let manifestURL = "stub://movies"
    private let baseURL = "https://cdn.example/movies"

    // Two invented (non-copyrighted) films that share a collection.
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Glass.Horizon.2021.mkv", "title": "Glass Horizon", "type": "movie", "container": "mkv", "year": 2021 },
            { "key": "Glass.Horizon.Reckoning.2023.mkv", "title": "Glass Horizon Reckoning", "type": "movie", "container": "mkv", "year": 2023 }
        ] }
        """.utf8)
    }

    /// Both films belong to TMDB collection 9001 "The Glass Horizon Saga".
    private var stubTMDB: StubTMDBClient {
        let saga = TMDBCollection(id: 9001, name: "The Glass Horizon Saga",
                                  posterPath: "/saga.jpg", backdropPath: "/sagaback.jpg")
        return StubTMDBClient(
            searchResults: [
                "glass horizon": [TMDBSearchResult(id: 7001, title: "Glass Horizon", year: 2021, popularity: 90)],
                "glass horizon reckoning": [TMDBSearchResult(id: 7002, title: "Glass Horizon Reckoning", year: 2023, popularity: 85)],
            ],
            details: [
                7001: TMDBMovieDetails(
                    id: 7001, title: "Glass Horizon", overview: "An origin.", year: 2021,
                    runtimeMinutes: 120, genres: ["Adventure"], voteAverage: 7.5,
                    posterPath: "/gh1.jpg", backdropPath: "/gh1b.jpg", cast: [],
                    collection: saga,
                    logoPath: "/gh1logo.png", bannerPath: "/gh1banner.jpg",
                    trailers: ["https://www.youtube.com/watch?v=abc123"],
                    tags: ["heist", "near future"]
                ),
                7002: TMDBMovieDetails(
                    id: 7002, title: "Glass Horizon Reckoning", overview: "A sequel.", year: 2023,
                    runtimeMinutes: 130, genres: ["Adventure"], voteAverage: 7.8,
                    posterPath: "/gh2.jpg", backdropPath: "/gh2b.jpg", cast: [],
                    collection: saga
                ),
            ]
        )
    }

    private func loginCreateScan(
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ libraryId: String) async throws -> Void
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

            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }

            try await body(client, token, library.id)
        }
    }

    @Test("enriching a movie creates + links its collection; members list via items?parent=")
    func collectionCreatedAndBrowsable() async throws {
        try await loginCreateScan { client, token, libraryId in
            // The library's top level now shows ONE collection (both movies nested under it).
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let collection = try #require(top.items.first { $0.type == .collection })
            #expect(collection.title == "The Glass Horizon Saga")
            #expect(collection.tmdbId == "9001")
            #expect(collection.images?.primary == "https://image.tmdb.org/t/p/w500/saga.jpg")
            // Both movies have left the top level (now nested under the collection).
            #expect(top.items.filter { $0.type == .movie }.isEmpty)

            // Browsing the collection lists both member movies.
            let members: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(collection.id)&detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(members.items.count == 2)
            #expect(Set(members.items.map(\.title)) == ["Glass Horizon", "Glass Horizon Reckoning"])
            for member in members.items {
                #expect(member.collectionId == collection.id)
                #expect(member.collectionTitle == "The Glass Horizon Saga")
                #expect(member.parentId == collection.id)
            }
        }
    }

    @Test("collectionThreshold ungroups a small box set; its members surface at top level")
    func collectionThresholdUngroupsSmallSets() async throws {
        try await loginCreateScan { client, token, libraryId in
            // New libraries default to a threshold of 2.
            let libs: AdminLibrariesResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(libs.libraries.first { $0.id == libraryId }?.collectionThreshold == 2)

            // At the default (2), the 2-member saga still groups into one tile.
            let grouped: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(grouped.items.contains { $0.type == .collection })
            #expect(grouped.items.filter { $0.type == .movie }.isEmpty)

            // Raise the bar above this saga's size: a collection now needs 3 present
            // members to group, so the 2-member saga ungroups.
            _ = try await client.execute(
                uri: "/v1/admin/libraries/\(libraryId)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(UpdateLibraryRequest(title: nil, kind: nil, collectionThreshold: 3))
            ) { try $0.decoded(LibraryResponse.self) }

            let ungrouped: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            // The collection tile is hidden; both member movies appear at top level.
            #expect(ungrouped.items.filter { $0.type == .collection }.isEmpty)
            #expect(Set(ungrouped.items.filter { $0.type == .movie }.map(\.title))
                == ["Glass Horizon", "Glass Horizon Reckoning"])
            // The membership links are untouched — the collection is still browsable directly.
            #expect(ungrouped.items.allSatisfy { $0.collectionId == nil ? true : $0.collectionTitle == "The Glass Horizon Saga" })
        }
    }

    @Test("Recently Added honors collectionThreshold, just like the library view")
    func recentlyAddedHonorsThreshold() async throws {
        try await loginCreateScan { client, token, libraryId in
            // Default threshold 2 → the 2-member saga groups. "Recently Added" shows
            // the box-set tile, not the individual movies (matching browse).
            let grouped: ItemsResponse = try await client.execute(
                uri: "/v1/home/recent", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(grouped.items.contains { $0.type == .collection })
            #expect(grouped.items.filter { $0.type == .movie }.isEmpty)

            // Raise the bar above this saga's size → it ungroups, and its members now
            // surface individually in Recently Added (no stale one-item tile).
            _ = try await client.execute(
                uri: "/v1/admin/libraries/\(libraryId)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(UpdateLibraryRequest(title: nil, kind: nil, collectionThreshold: 3))
            ) { try $0.decoded(LibraryResponse.self) }

            let ungrouped: ItemsResponse = try await client.execute(
                uri: "/v1/home/recent", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(ungrouped.items.filter { $0.type == .collection }.isEmpty)
            #expect(Set(ungrouped.items.filter { $0.type == .movie }.map(\.title))
                == ["Glass Horizon", "Glass Horizon Reckoning"])
        }
    }

    @Test("metadata fills: logo, banner, trailers, tags, sortTitle on detail=full")
    func metadataFillsProject() async throws {
        try await loginCreateScan { client, token, libraryId in
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let collection = try #require(top.items.first { $0.type == .collection })

            let members: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(collection.id)&detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let first = try #require(members.items.first { $0.title == "Glass Horizon" })

            #expect(first.images?.logo == "https://image.tmdb.org/t/p/w500/gh1logo.png")
            #expect(first.images?.banner == "https://image.tmdb.org/t/p/w1280/gh1banner.jpg")
            #expect(first.trailers == ["https://www.youtube.com/watch?v=abc123"])
            #expect(first.tags == ["heist", "near future"])
            // "Glass Horizon" has no leading article → no sortTitle.
            #expect(first.sortTitle == nil)
        }
    }

    @Test("sortTitle drops a leading English article")
    func sortTitleDropsArticle() {
        #expect(Enricher.sortTitle(from: "The Glass Horizon") == "Glass Horizon")
        #expect(Enricher.sortTitle(from: "A Quiet Signal") == "Quiet Signal")
        #expect(Enricher.sortTitle(from: "An Open Door") == "Open Door")
        #expect(Enricher.sortTitle(from: "Glass Horizon") == nil)
        #expect(Enricher.sortTitle(from: "Theatre") == nil)  // not an article
    }

    @Test("skeleton omits trailers/tags/sortTitle but keeps collectionId + logo/banner images")
    func skeletonGatesFullFields() async throws {
        try await loginCreateScan { client, token, libraryId in
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let collection = try #require(top.items.first { $0.type == .collection })

            let members: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(collection.id)&detail=skeleton", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let first = try #require(members.items.first { $0.title == "Glass Horizon" })
            // Collection membership is structural → present even on skeleton.
            #expect(first.collectionId == collection.id)
            // Tile-level artwork (incl. logo/banner) is present on skeleton.
            #expect(first.images?.logo == "https://image.tmdb.org/t/p/w500/gh1logo.png")
            // Full-only enrichment is absent.
            #expect(first.trailers == nil)
            #expect(first.tags == nil)
            #expect(first.sortTitle == nil)
        }
    }
}
