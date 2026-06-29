import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// An HTTP fetcher whose manifest can change between scans, so a test can drop items
/// from a source and re-scan. An actor so it's safely mutable across the async scan.
private actor MutableFetcher: HTTPFetching {
    private var responses: [String: Data]
    init(_ responses: [String: Data]) { self.responses = responses }
    func set(_ url: String, _ data: Data) { responses[url] = data }
    func getData(url: String, headers: [String: String]) async throws -> Data {
        guard let data = responses[url] else { throw SphynxError.notFound("No stub for '\(url)'") }
        return data
    }
}

/// A scan must not leave orphaned container shells behind: when a series' episodes all
/// vanish from the source, the now-empty season and series are pruned (the same cleanup
/// that heals duplicate container shells left by a past overlapping scan).
@Suite("Scan prunes empty containers")
struct PruneContainersTests {
    private let manifestURL = "stub://prune"

    private func token(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("an emptied series' season + series containers are removed on re-scan")
    func prunesEmptyContainers() async throws {
        let full = Data("""
        { "items": [
            { "key": "Severance/Severance.S01E01.mkv", "container": "mkv" },
            { "key": "Severance/Severance.S01E02.mkv", "container": "mkv" }
        ] }
        """.utf8)
        let fetcher = MutableFetcher([manifestURL: full])
        let app = try await buildApplication(
            configuration: testConfiguration(), httpFetcher: fetcher)
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client))
            let lib: String = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: admin,
                body: try jsonBody(CreateLibraryRequest(title: "TV", kind: "tvShows"))
            ) { try $0.decoded(LibraryResponse.self).id }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: admin,
                body: try jsonBody(CreateSourceRequest(label: "TV", driver: "http", baseURL: "https://cdn/tv",
                    headers: nil, libraryId: lib, manifestURL: manifestURL))
            ) { try $0.decoded() }
            func scan() async throws {
                _ = try await client.execute(uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: admin) { $0 }
            }
            func children(_ parent: String) async throws -> [Item] {
                try await client.execute(uri: "/v1/items?parent=\(parent)", method: .get, headers: admin) {
                    try $0.decoded(ItemsResponse.self).items
                }
            }

            // First scan builds the series → season → 2 episodes tree.
            try await scan()
            let series = try #require(try await children(lib).first { $0.type == .series })
            let season = try #require(try await children(series.id).first { $0.type == .season })
            #expect(try await children(season.id).count == 2)

            // The source loses both episodes; a re-scan removes them AND the now-empty
            // season + series — no orphaned container shells left behind.
            await fetcher.set(manifestURL, Data(#"{ "items": [] }"#.utf8))
            try await scan()
            #expect(try await children(lib).isEmpty)
            // The containers are actually deleted, not just hidden.
            try await client.execute(uri: "/v1/admin/items/\(series.id)", method: .get, headers: admin) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/admin/items/\(season.id)", method: .get, headers: admin) { #expect($0.status == .notFound) }
        }
    }
}
