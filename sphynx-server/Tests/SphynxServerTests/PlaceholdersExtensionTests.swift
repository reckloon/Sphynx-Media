import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Extensions: low-res images (placeholders)")
struct PlaceholdersExtensionTests {
    private let manifestURL = "stub://movies"
    private let baseURL = "https://cdn.example/movies"
    /// The poster the enricher derives for The Matrix (`/poster.jpg` at w92).
    private let posterURL = "https://image.tmdb.org/t/p/w92/poster.jpg"

    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "The.Matrix.1999.mkv", "title": "The Matrix", "type": "movie", "container": "mkv", "year": 1999 }
        ] }
        """.utf8)
    }

    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: ["the matrix": [TMDBSearchResult(id: 603, title: "The Matrix", year: 1999, popularity: 80)]],
            details: [603: TMDBMovieDetails(
                id: 603, title: "The Matrix", overview: "A hacker learns the truth.",
                year: 1999, runtimeMinutes: 136, genres: ["Action"], voteAverage: 8.2,
                posterPath: "/poster.jpg", backdropPath: "/back.jpg", cast: [])]
        )
    }

    /// The same embedded 16×11 baseline JPEG used by `BlurHashTests`.
    private var sampleJPEG: Data {
        Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAASABIAAD/4QESRXhpZgAATU0AKgAAAAgACQESAAMAAAABAAEAAAEaAAUAAAABAAAAegEbAAUAAAABAAAAggEoAAMAAAABAAIAAAEx" +
            "AAIAAAAhAAAAigEyAAIAAAAUAAAArAFCAAQAAAABAAACAAFDAAQAAAABAAACAIdpAAQAAAABAAAAwAAAAAAAAABIAAAAAQAAAEgAAAABQWRvYmUgUGhvdG9z" +
            "aG9wIDI3LjQgKE1hY2ludG9zaCkAADIwMjY6MDU6MjggMDk6NTQ6MDgAAASQBAACAAAAFAAAAPagAQADAAAAAQABAACgAgAEAAAAAQAAABCgAwAEAAAAAQAA" +
            "AAsAAAAAMjAyNjowNTowNiAxMzoxNDozNwD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgA" +
            "CwAQAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGh" +
            "CCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeo" +
            "qaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIB" +
            "AgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2Rl" +
            "ZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMA" +
            "AgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQ" +
            "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A7Cb4daXaeCLzw/f6jFcRvJBdzXUh3Lp1vGQx" +
            "ZSeBLIPlAyMg45OBXoXgzw/4D8d+P/D/AIi0iyFs1rZG1jucBJriGLIe6nIA3Pg7I889OoHH5y3Pi7xLqHw1020vNQlkhvtXWWdCQBI+HILYAzg9B0HGBXvf" +
            "gzxJrlj4mVLO8eFY7KJFC4GFyTjpWOVZEo0OaUrs7cyzR86sj//Z"
        )!
    }

    // MARK: Mode → placeholder mapping

    @Test("mode resolves the served placeholder form, with blurhash→url fallback")
    func modeMapping() {
        #expect(PlaceholderMode.url.placeholder(url: "u", blurHash: "h") == .url("u"))
        #expect(PlaceholderMode.off.placeholder(url: "u", blurHash: "h") == nil)
        #expect(PlaceholderMode.blurhash.placeholder(url: "u", blurHash: "h") == .blurHash("h"))
        // blurhash mode with no generated hash falls back to the URL form.
        #expect(PlaceholderMode.blurhash.placeholder(url: "u", blurHash: nil) == .url("u"))
        // No URL ⇒ nothing to serve.
        #expect(PlaceholderMode.url.placeholder(url: nil) == nil)
        #expect(PlaceholderMode.off.placeholder(url: nil) == nil)
    }

    // MARK: Registry + config endpoints

    @Test("registry lists the placeholders extension; blurhash is the default mode")
    func registryAndDefault() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            let registry: ExtensionsResponse = try await client.execute(
                uri: "/v1/admin/extensions", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let entry = try #require(registry.extensions.first { $0.id == "placeholders" })
            #expect(entry.kind == "optional")
            #expect(entry.configurable)
            #expect(entry.enabled)  // blurhash/url are "on"; only `off` reads as disabled

            let cfg: PlaceholderConfig = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(cfg.mode == "blurhash")  // the out-of-the-box default
        }
    }

    @Test("config PATCH persists the mode; GET reflects it; invalid mode is 400")
    func updateAndValidate() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            let updated: PlaceholderConfig = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "blurhash"))
            ) { try $0.decoded() }
            #expect(updated.mode == "blurhash")

            let reread: PlaceholderConfig = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reread.mode == "blurhash")

            // Disabled (off) registry entry reads as not enabled.
            _ = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "off"))
            ) { $0 }
            let registry: ExtensionsResponse = try await client.execute(
                uri: "/v1/admin/extensions", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(registry.extensions.first { $0.id == "placeholders" }?.enabled == false)

            try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "nonsense"))
            ) { #expect($0.status == .badRequest) }
        }
    }

    // MARK: End-to-end: generation + live mode switching

    @Test("blurhash mode generates a hash at enrich time; switching mode re-shapes serving live")
    func endToEnd() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON, posterURL: sampleJPEG]),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let token = try await adminToken(client)

            // Turn on blurhash BEFORE scanning, so enrichment generates the hash.
            _ = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "blurhash"))
            ) { $0 }

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

            // blurhash: the served placeholder is a BlurHash string.
            let blurItem = try await firstItem(client, token: token, parent: library.id)
            if case .blurHash(let hash)? = blurItem.placeholder {
                #expect(!hash.isEmpty)
            } else {
                Issue.record("expected a blurHash placeholder, got \(String(describing: blurItem.placeholder))")
            }
            // The poster's per-image variant carries the same hash.
            #expect(blurItem.images?.variants?["primary"]?.placeholder == blurItem.placeholder)

            // Switch to off (no re-enrich): the placeholder disappears immediately.
            _ = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "off"))
            ) { $0 }
            #expect(try await firstItem(client, token: token, parent: library.id).placeholder == nil)

            // Switch to url: the cached URL placeholder is served.
            _ = try await client.execute(
                uri: "/v1/admin/extensions/placeholders", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaceholderConfigUpdate(mode: "url"))
            ) { $0 }
            #expect(try await firstItem(client, token: token, parent: library.id).placeholder == .url(posterURL))
        }
    }

    // MARK: Helpers

    private func firstItem(_ client: some TestClientProtocol, token: String, parent: String) async throws -> Item {
        let response: ItemsResponse = try await client.execute(
            uri: "/v1/items?parent=\(parent)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded() }
        return try #require(response.items.first)
    }

    private func adminToken(_ client: some TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }
}
