import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Indexer + Browse")
struct BrowseFlowTests {
    private let baseURL = "https://download.blender.org/peach/bigbuckbunny_movies"
    private let manifestURL = "stub://movies-manifest"

    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "BigBuckBunny_320x180.mp4", "title": "Big Buck Bunny", "type": "movie", "container": "mp4", "year": 2008 },
            { "key": "BigBuckBunny_640x360.mp4", "title": "Big Buck Bunny (HD)", "type": "movie", "container": "mp4", "year": 2008 },
            { "key": "sintel.mp4", "title": "Sintel", "type": "movie", "container": "mp4", "year": 2010 }
        ] }
        """.utf8)
    }

    /// Build an app whose HTTP fetcher serves the canned manifest (no network),
    /// log in as admin, and return a client + the admin access token.
    private func withScannedLibrary(
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ libraryId: String, _ sourceId: String) async throws -> Void
    ) async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON])
        )
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post,
                headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { #expect($0.status == .ok); return try $0.decoded() }

            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post,
                headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(
                    label: "Blender", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: library.id, manifestURL: manifestURL
                ))
            ) { #expect($0.status == .ok); return try $0.decoded() }

            try await body(client, token, library.id, source.id)
        }
    }

    @Test("scan indexes the manifest; libraries and items then list it")
    func scanThenBrowse() async throws {
        try await withScannedLibrary { client, token, libraryId, sourceId in
            // Scan the source → 3 added.
            let summary: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(sourceId)/scan", method: .post,
                headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(summary.added == 3)
            #expect(summary.removed == 0)

            // Libraries lists our new library.
            let libraries: LibrariesResponse = try await client.execute(
                uri: "/v1/libraries", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(libraries.libraries.contains { $0.id == libraryId && $0.kind == .movies })

            // Items lists the three scanned movies.
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(page.items.count == 3)
            #expect(page.nextCursor == nil)
            #expect(Set(page.items.map(\.title)) == ["Big Buck Bunny", "Big Buck Bunny (HD)", "Sintel"])
            #expect(page.items.allSatisfy { $0.type == .movie })
        }
    }

    @Test("a scanned item resolves to baseURL + key")
    func scannedItemResolves() async throws {
        try await withScannedLibrary { client, token, libraryId, sourceId in
            _ = try await client.execute(uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let sintel = try #require(page.items.first { $0.title == "Sintel" })

            let descriptor: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(sintel.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(descriptor.url == "\(baseURL)/sintel.mp4")
            #expect(descriptor.preResolved == true)
        }
    }

    @Test("cursor pagination walks the full set without overlap")
    func pagination() async throws {
        try await withScannedLibrary { client, token, libraryId, sourceId in
            _ = try await client.execute(uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }

            let first: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)&limit=2", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(first.items.count == 2)
            let cursor = try #require(first.nextCursor)

            let second: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)&limit=2&cursor=\(cursor)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(second.items.count == 1)
            #expect(second.nextCursor == nil)

            // Three distinct items across the two pages, no overlap.
            #expect(Set(first.items.map(\.id)).union(second.items.map(\.id)).count == 3)
        }
    }

    @Test("re-scanning the same manifest is idempotent")
    func rescanIdempotent() async throws {
        try await withScannedLibrary { client, token, _, sourceId in
            _ = try await client.execute(uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }
            let second: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(second.added == 0)
            #expect(second.updated == 0)
            #expect(second.removed == 0)
        }
    }

    @Test("single item fetch returns it; unknown id is not_found")
    func singleItem() async throws {
        try await withScannedLibrary { client, token, libraryId, sourceId in
            _ = try await client.execute(uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)) { $0 }
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let one = page.items[0]

            let fetched: Item = try await client.execute(
                uri: "/v1/items/\(one.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(fetched.id == one.id)

            try await client.execute(
                uri: "/v1/items/it_nope", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .notFound) }
        }
    }

    @Test("browse requires authentication")
    func browseRequiresAuth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/libraries", method: .get) { #expect($0.status == .unauthorized) }
        }
    }
}
