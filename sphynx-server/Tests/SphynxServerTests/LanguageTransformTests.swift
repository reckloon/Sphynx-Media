import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The metadata-language transformer: during enrichment the display title is
/// normalised to TMDB's name in the server's declared language, so a
/// foreign-named release (`Бэтмен`) shows in the configured language (`Batman`).
/// A manually-edited title stays locked and is never overwritten.
@Suite("Metadata language transformer")
struct LanguageTransformTests {

    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    // MARK: - TMDB client sends the language parameter

    /// A capturing fetcher that records request URLs and answers with minimal JSON.
    private actor CapturingFetcher: HTTPFetching {
        let body: Data
        private(set) var urls: [String] = []
        init(_ body: Data) { self.body = body }
        func getData(url: String, headers: [String: String]) async throws -> Data {
            urls.append(url)
            return body
        }
    }

    @Test("the TMDB client sends the configured language on detail requests")
    func detailRequestsCarryLanguage() async throws {
        let fetcher = CapturingFetcher(Data(#"{"id":268,"title":"Бэтмен"}"#.utf8))
        let client = TMDBHTTPClient(apiKey: "KEY", language: "ru-RU", fetcher: fetcher)

        let details = try await client.movieDetails(id: 268)
        #expect(details.title == "Бэтмен")   // the language's localized title comes back

        let url = try #require(await fetcher.urls.first)
        #expect(url.contains("/movie/268"))
        #expect(url.contains("language=ru-RU"))
    }

    // MARK: - Enrichment normalises the title (and respects the lock)

    /// TMDB returns the English title for Batman (id 268), whatever the source called it.
    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: ["бэтмен": [TMDBSearchResult(id: 268, title: "Batman", year: 1989, popularity: 60)]],
            details: [268: TMDBMovieDetails(
                id: 268, title: "Batman",
                overview: "The Dark Knight of Gotham City.",
                year: 1989, runtimeMinutes: 126,
                genres: ["Fantasy", "Action"],
                voteAverage: 7.2,
                posterPath: "/batman.jpg", backdropPath: "/gotham.jpg",
                cast: []
            )]
        )
    }

    @Test("a foreign-named item is renamed to the TMDB title during enrichment")
    func foreignTitleNormalised() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)

            // A manual item the source named in Russian.
            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Бэтмен", sourceId: nil,
                    sourceKey: "https://cdn.example/batman.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: 1989, extra: nil))
            ) { try $0.decoded() }
            #expect(created.title == "Бэтмен")

            // Pinning identifies + enriches → the title normalises to TMDB's.
            let pinned: Item = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "268", type: "movie"))
            ) { try $0.decoded() }
            #expect(pinned.title == "Batman")
            #expect(pinned.overview == "The Dark Knight of Gotham City.")
        }
    }

    @Test("a manually-edited title is locked and survives re-enrichment")
    func editedTitleSurvives() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)

            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Бэтмен", sourceId: nil,
                    sourceKey: "https://cdn.example/batman.mkv", container: "mkv", tmdbId: "268",
                    libraryId: nil, parentId: nil, year: 1989, extra: nil))
            ) { try $0.decoded() }

            // Admin renames it → title locks.
            let edited: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(created.id)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(EditItemRequest(title: "Batman (1989 Restoration)"))
            ) { try $0.decoded() }
            #expect(edited.lockedFields.contains("title"))

            // A forced re-enrich must not overwrite the locked title.
            let reEnriched: Item = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/enrich", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reEnriched.title == "Batman (1989 Restoration)")
        }
    }
}
