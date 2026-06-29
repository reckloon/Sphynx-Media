import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Multi-version / editions")
struct MultiVersionTests {
    private let baseURL = "https://cdn.example.com/movies"
    private let manifestURL = "stub://mv-manifest"
    private let uhdKey = "The Matrix (1999)/The.Matrix.1999.2160p.UHD.BluRay.REMUX.HDR10.mkv"
    private let hdKey = "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.x264.mkv"

    // Two files of the SAME movie (title+year), different quality.
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "\(uhdKey)", "title": "The Matrix", "type": "movie", "container": "mkv", "year": 1999 },
            { "key": "\(hdKey)",  "title": "The Matrix", "type": "movie", "container": "mkv", "year": 1999 }
        ] }
        """.utf8)
    }

    private func withLibrary(
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ libraryId: String, _ sourceId: String) async throws -> Void
    ) async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON])
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
            try await body(client, token, library.id, source.id)
        }
    }

    @Test("two files of one movie collapse into a single item with selectable versions")
    func grouping() async throws {
        try await withLibrary { client, token, libraryId, sourceId in
            // Two files, ONE item added.
            let summary: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(summary.scanned == 2)
            #expect(summary.added == 1)

            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(page.items.count == 1)
            let movie = try #require(page.items.first)
            let versions = try #require(movie.versions)
            #expect(versions.count == 2)
            // Default (first) is the 4K HDR remux; the 1080p is the alternate.
            #expect(versions[0].resolution == "4K")
            #expect(versions[0].label == "4K · HDR10 · Remux")
            #expect(versions[1].resolution == "1080p")

            // A plain resolve plays the default (4K) file.
            let def: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(movie.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(def.url == "\(baseURL)/\(uhdKey)")
            // The descriptor offers the other version as a ranked fallback candidate.
            let candidates = try #require(def.candidates)
            #expect(candidates.contains { $0.url == "\(baseURL)/\(hdKey)" })

            // resolve?version=<1080p id> plays the 1080p file, not the default.
            let hd1080 = try #require(versions.first { $0.resolution == "1080p" })
            let alt: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(movie.id)?version=\(hd1080.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(alt.url == "\(baseURL)/\(hdKey)")

            // An unknown version id is a 404 — never a silent fallback to the default.
            try await client.execute(
                uri: "/v1/resolve/\(movie.id)?version=v_nope", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .notFound) }

            // Re-scan is idempotent: no new item, no churn.
            let rescan: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(sourceId)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(rescan.added == 0)
            #expect(rescan.updated == 0)
            #expect(rescan.removed == 0)
        }
    }
}
