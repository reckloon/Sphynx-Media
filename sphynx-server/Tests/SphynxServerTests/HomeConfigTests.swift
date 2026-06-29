import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The configurable home feed: an admin **default** layout of ordered rows
/// (including `genre`/`releaseDecade` kinds) plus a **per-user** override that
/// replaces it and can be reset. Empty rows are omitted.
@Suite("Home config: default layout + per-user genre/decade rows")
struct HomeConfigTests {
    /// Three movies spanning two decades and a few genres, so genre/decade rows
    /// have something to surface.
    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: [:],
            details: [
                603: TMDBMovieDetails(
                    id: 603, title: "The Matrix", overview: "Reality is a lie.",
                    year: 1999, runtimeMinutes: 136,
                    genres: ["Action", "Science Fiction"], voteAverage: 8.2,
                    posterPath: "/m.jpg", backdropPath: "/mb.jpg", cast: [], releaseDate: "1999-03-31"),
                562: TMDBMovieDetails(
                    id: 562, title: "Die Hard", overview: "Yippee-ki-yay.",
                    year: 1988, runtimeMinutes: 132,
                    genres: ["Action", "Thriller"], voteAverage: 7.8,
                    posterPath: "/d.jpg", backdropPath: "/db.jpg", cast: [], releaseDate: "1988-07-15"),
                105: TMDBMovieDetails(
                    id: 105, title: "Back to the Future", overview: "88 mph.",
                    year: 1985, runtimeMinutes: 116,
                    genres: ["Adventure", "Comedy", "Science Fiction"], voteAverage: 8.3,
                    posterPath: "/b.jpg", backdropPath: "/bb.jpg", cast: [], releaseDate: "1985-07-03"),
            ]
        )
    }

    /// Sign in as admin and return the token.
    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    /// Create a top-level movie and pin it to `tmdbId` (which enriches genres/year).
    private func addMovie(_ client: any TestClientProtocol, token: String, tmdbId: String) async throws {
        let created: Item = try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(CreateItemRequest(type: "movie", title: "Unknown", sourceId: nil,
                sourceKey: "https://cdn/\(tmdbId).mkv", container: "mkv", tmdbId: nil,
                libraryId: nil, parentId: nil, year: nil, extra: nil))
        ) { try $0.decoded() }
        _ = try await client.execute(
            uri: "/v1/admin/items/\(created.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(SetIdentityRequest(tmdbId: tmdbId, type: "movie"))
        ) { try $0.decoded(Item.self) }
    }

    private func putLayout(_ client: any TestClientProtocol, _ path: String, token: String, _ shelves: [HomeShelfDTO]) async throws -> HomeConfigResponse {
        try await client.execute(
            uri: path, method: .put, headers: jsonHeaders(bearer: token),
            body: try jsonBody(HomeConfigRequest(shelves: shelves))
        ) { try $0.decoded() }
    }

    private func home(_ client: any TestClientProtocol, token: String) async throws -> HomeResponse {
        try await client.execute(uri: "/v1/home", method: .get, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
    }

    private func dto(_ spec: HomeShelfSpec) -> HomeShelfDTO { HomeShelfDTO(spec) }

    @Test("admin default starts at the built-in layout and drives the feed")
    func builtInDefaultDrivesFeed() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)
            try await addMovie(client, token: token, tmdbId: "603")   // Action / Sci-Fi / 1999
            try await addMovie(client, token: token, tmdbId: "562")   // Action / Thriller / 1988

            // Admin default = built-in until saved.
            let def: HomeConfigResponse = try await client.execute(
                uri: "/v1/admin/home", method: .get, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            #expect(def.customized == false)
            #expect(def.shelves.contains { $0.id == "genre:Action" })

            // The built-in default has an Action genre row → it surfaces both movies.
            let feed = try await home(client, token: token)
            let action = feed.shelves.first { $0.id == "genre:Action" }
            #expect(action?.kind == .genre)
            #expect(action?.items.count == 2)
        }
    }

    @Test("a genre/decade default layout builds the right rows; empty rows are omitted")
    func genreAndDecadeRows() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)
            try await addMovie(client, token: token, tmdbId: "603")   // 1999
            try await addMovie(client, token: token, tmdbId: "562")   // 1988
            try await addMovie(client, token: token, tmdbId: "105")   // 1985

            _ = try await putLayout(client, "/v1/admin/home", token: token, [
                dto(.recentlyAdded),
                dto(.genre("Action")),       // Matrix + Die Hard
                dto(.genre("Horror")),       // nothing → omitted
                dto(.decade(1980)),          // Die Hard + Back to the Future
            ])

            let feed = try await home(client, token: token)
            let ids = feed.shelves.map(\.id)
            #expect(ids.contains("genre:Action"))
            #expect(ids.contains("decade:1980"))
            #expect(ids.contains("recent"))
            #expect(!ids.contains("genre:Horror"))   // empty row omitted

            let decade = feed.shelves.first { $0.id == "decade:1980" }
            #expect(decade?.kind == .releaseDecade)
            #expect(decade?.items.count == 2)        // 1988 + 1985, not the 1999 Matrix
        }
    }

    @Test("a user's saved layout replaces the default, and reset restores it")
    func perUserReplaceAndReset() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)
            try await addMovie(client, token: token, tmdbId: "603")
            try await addMovie(client, token: token, tmdbId: "105")

            // Admin default: just a Sci-Fi row (both movies are Sci-Fi).
            _ = try await putLayout(client, "/v1/admin/home", token: token, [dto(.genre("Science Fiction"))])

            // User override: only a Comedy row (only Back to the Future) — replaces default.
            let saved = try await putLayout(client, "/v1/home/config", token: token, [dto(.genre("Comedy"))])
            #expect(saved.customized == true)

            var feed = try await home(client, token: token)
            #expect(feed.shelves.map(\.id) == ["genre:Comedy"])      // default fully replaced
            #expect(feed.shelves.first?.items.count == 1)

            // Reset → back to the admin default (Sci-Fi).
            let reset: HomeConfigResponse = try await client.execute(
                uri: "/v1/home/config", method: .delete, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            #expect(reset.customized == false)
            feed = try await home(client, token: token)
            #expect(feed.shelves.map(\.id) == ["genre:Science Fiction"])
            #expect(feed.shelves.first?.items.count == 2)
        }
    }

    @Test("see-all endpoints page genre and decade rows; malformed rows are dropped")
    func seeAllAndSanitization() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)
            try await addMovie(client, token: token, tmdbId: "603")   // 1999 Action
            try await addMovie(client, token: token, tmdbId: "562")   // 1988 Action
            try await addMovie(client, token: token, tmdbId: "105")   // 1985

            let action: ItemsResponse = try await client.execute(
                uri: "/v1/home/genre?name=Action", method: .get, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            #expect(action.items.count == 2)

            let eighties: ItemsResponse = try await client.execute(
                uri: "/v1/home/decade?start=1980", method: .get, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            #expect(eighties.items.count == 2)

            // Genres list is populated from the catalog.
            let genres: GenresResponse = try await client.execute(
                uri: "/v1/home/genres", method: .get, headers: jsonHeaders(bearer: token)) { try $0.decoded() }
            #expect(genres.genres.contains("Action"))

            // A genre row with no genre value is malformed → dropped on save.
            let resp = try await putLayout(client, "/v1/admin/home", token: token, [
                HomeShelfDTO(HomeShelfSpec(id: "bad", kind: "genre", title: "Bad")),   // no genre
                dto(.genre("Action")),
            ])
            #expect(resp.shelves.map(\.id) == ["genre:Action"])
        }
    }
}
