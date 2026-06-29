import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// `GET /v1/people/{personId}/items` — the inverse of an item's cast list.
///
/// The shared cast member is TMDB person id 700 → cast id `pe_700` ("Rosa Vance"),
/// who appears in two movies and one series (all invented, non-copyrighted). A
/// distractor person (`pe_701`) appears only in one movie, so we can assert the
/// lookup is keyed exactly on the cast id (no substring/false matches).
@Suite("People: filmography (inverse cast)")
struct PeopleFlowTests {
    private let baseURL = "https://cdn.example/media"
    private let manifestURL = "stub://media"

    // Two movies + one series, each as a manifest entry the indexer can identify.
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Tidewater.Echoes.2019.mkv", "title": "Tidewater Echoes", "type": "movie", "container": "mkv", "year": 2019 },
            { "key": "The.Glass.Orchard.2023.mkv", "title": "The Glass Orchard", "type": "movie", "container": "mkv", "year": 2023 },
            { "key": "Northwind.Hollow.S01E01.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }

    private var rosa: TMDBCastMember {
        TMDBCastMember(id: 700, name: "Rosa Vance", character: "Captain Wren", profilePath: "/rosa.jpg")
    }

    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: [
                "tidewater echoes": [TMDBSearchResult(id: 5001, title: "Tidewater Echoes", year: 2019, popularity: 50)],
                "the glass orchard": [TMDBSearchResult(id: 5002, title: "The Glass Orchard", year: 2023, popularity: 60)],
            ],
            details: [
                // Older movie (2019-05-01).
                5001: TMDBMovieDetails(
                    id: 5001, title: "Tidewater Echoes",
                    overview: "A diver returns to a flooded town.",
                    year: 2019, runtimeMinutes: 110, genres: ["Drama"], voteAverage: 7.1,
                    posterPath: "/tide.jpg", backdropPath: "/tideb.jpg",
                    cast: [
                        rosa,
                        TMDBCastMember(id: 701, name: "Idris Calloway", character: "Mayor", profilePath: "/idris.jpg"),
                    ],
                    releaseDate: "2019-05-01"),
                // Newer movie (2023-09-15).
                5002: TMDBMovieDetails(
                    id: 5002, title: "The Glass Orchard",
                    overview: "A glassblower inherits a haunted greenhouse.",
                    year: 2023, runtimeMinutes: 98, genres: ["Mystery"], voteAverage: 6.8,
                    posterPath: "/glass.jpg", backdropPath: "/glassb.jpg",
                    cast: [rosa],
                    releaseDate: "2023-09-15"),
            ],
            tvSearchResults: [
                "northwind hollow": [TMDBTVSearchResult(id: 6001, name: "Northwind Hollow", year: 2021, popularity: 70)],
            ],
            tvDetailsByID: [6001: TMDBTVDetails(
                id: 6001, name: "Northwind Hollow",
                overview: "A sheriff polices a town that forgets.",
                year: 2021, genres: ["Mystery"], voteAverage: 7.9,
                posterPath: "/nw.jpg", backdropPath: "/nwb.jpg",
                seasons: [TMDBSeasonSummary(seasonNumber: 1, name: "Season 1", episodeCount: 1, posterPath: "/nws1.jpg")],
                cast: [rosa]
            )],
            seasonDetailsByID: [6001: [1: TMDBSeasonDetails(
                seasonNumber: 1, name: "Season 1", overview: "First season.", posterPath: "/nws1.jpg",
                episodes: [TMDBEpisode(episodeNumber: 1, name: "Pilot", overview: "It begins.", stillPath: "/e1.jpg", airDate: "2021-03-03", runtimeMinutes: 50)]
            )]]
        )
    }

    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    /// Build an app, log in as admin, create a library + source, scan (which
    /// identifies + enriches, populating `castJSON`), then run `body`.
    private func scanned(
        _ body: @Sendable @escaping (any TestClientProtocol, _ admin: String, _ libraryId: String) async throws -> Void
    ) async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let admin = try await self.login(client, "admin", "test-password")
            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateLibraryRequest(title: "Media", kind: "movies"))
            ) { try $0.decoded() }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateSourceRequest(
                    label: "CDN", driver: "http", baseURL: self.baseURL, headers: nil,
                    libraryId: library.id, manifestURL: self.manifestURL))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: admin)
            ) { try $0.decoded(IndexSummary.self) }
            try await body(client, admin, library.id)
        }
    }

    @Test("filmography returns the distinct credited items, newest-first")
    func filmographyNewestFirst() async throws {
        try await scanned { client, admin, _ in
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/people/pe_700/items", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }

            // Two movies + one series, all distinct.
            #expect(page.items.count == 3)
            #expect(Set(page.items.map(\.id)).count == 3)

            // Newest-first by premiere date: Glass Orchard (2023-09-15) →
            // Northwind Hollow (2021) → Tidewater Echoes (2019-05-01).
            #expect(page.items.map(\.title) == ["The Glass Orchard", "Northwind Hollow", "Tidewater Echoes"])

            // The series is included (cast lives on the series container).
            #expect(page.items.contains { $0.type == .series && $0.title == "Northwind Hollow" })

            // Tile fields are present (normal item projection).
            let first = try #require(page.items.first)
            #expect(first.images?.primary == "https://image.tmdb.org/t/p/w500/glass.jpg")
        }
    }

    @Test("a person credited on only one item returns just that item")
    func singleCredit() async throws {
        try await scanned { client, admin, _ in
            // pe_701 (Idris Calloway) is only in Tidewater Echoes.
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/people/pe_701/items", method: .get, headers: jsonHeaders(bearer: admin)
            ) { try $0.decoded() }
            #expect(page.items.count == 1)
            #expect(page.items.first?.title == "Tidewater Echoes")
        }
    }

    @Test("a well-formed person id with no credits returns an empty 200")
    func unknownPersonIsEmpty() async throws {
        try await scanned { client, admin, _ in
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/people/pe_999999/items", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(page.items.isEmpty)
            #expect(page.nextCursor == nil)
        }
    }

    @Test("a malformed person id (not pe_…) is a 404")
    func malformedPersonIs404() async throws {
        try await scanned { client, admin, _ in
            try await client.execute(
                uri: "/v1/people/it_123/items", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("items in a library the caller can't read are excluded")
    func excludesUnreadableLibraries() async throws {
        try await scanned { client, admin, _ in
            // Bob holds no permissions → cannot read the (only) library.
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw",
                                                     displayName: nil, isAdmin: nil, permissions: []))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await self.login(client, "bob", "pw")

            let page: ItemsResponse = try await client.execute(
                uri: "/v1/people/pe_700/items", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            // Everything is filtered out — Bob can read nothing.
            #expect(page.items.isEmpty)

            // Admin grants library.read → the items reappear.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read"]))
            ) { #expect($0.status == .ok) }
            let granted: ItemsResponse = try await client.execute(
                uri: "/v1/people/pe_700/items", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(granted.items.count == 3)
        }
    }
}
