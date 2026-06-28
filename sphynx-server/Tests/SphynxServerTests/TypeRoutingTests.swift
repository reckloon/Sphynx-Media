import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("One source → fan out by type to libraries")
struct TypeRoutingTests {
    private let baseURL = "https://cdn.example/media"
    private let manifestURL = "stub://mixed"

    // A single folder/manifest holding both a movie and a TV episode.
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "The.Matrix.1999.mkv", "title": "The Matrix", "type": "movie", "year": 1999 },
            { "key": "Severance.S01E01.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }

    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    private func lib(_ client: any TestClientProtocol, _ token: String, _ title: String, _ kind: String) async throws -> String {
        try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(CreateLibraryRequest(title: title, kind: kind))
        ) { try $0.decoded(LibraryResponse.self).id }
    }

    private func top(_ client: any TestClientProtocol, _ token: String, _ libraryId: String) async throws -> [Item] {
        try await client.execute(
            uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(ItemsResponse.self).items }
    }

    private func sources(_ client: any TestClientProtocol, _ token: String) async throws -> [SourceResponse] {
        try await client.execute(
            uri: "/v1/admin/sources", method: .get, headers: jsonHeaders(bearer: token)
        ) { try $0.decoded(SourcesResponse.self).sources }
    }

    @Test("one scan routes the movie and the series to their own libraries")
    func routesByType() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON])
        )
        try await app.test(.router) { client in
            let token = try await login(client)
            let movies = try await lib(client, token, "Movies", "movies")
            let tv = try await lib(client, token, "TV", "tvShows")

            // ONE source over the mixed manifest, routing by type.
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "Media", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: nil, manifestURL: manifestURL,
                    libraryMap: ["movie": movies, "tv": tv]))
            ) { try $0.decoded() }
            #expect(source.libraryMap?["movie"] == movies)

            // A single scan (one driver walk) creates both the movie and the episode.
            let summary: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(summary.added == 2)

            // Movies library has the movie only; TV library has the series only.
            let inMovies = try await top(client, token, movies)
            let inTV = try await top(client, token, tv)
            #expect(inMovies.count == 1)
            #expect(inMovies.first?.type == .movie)
            #expect(inMovies.first?.title == "The Matrix")
            #expect(inTV.count == 1)
            #expect(inTV.first?.type == .series)
            #expect(inTV.first?.title == "Severance")
        }
    }

    @Test("deleting one library unbinds the shared source; deleting the last orphans + removes it")
    func cascadeUnbindsSharedSource() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON])
        )
        try await app.test(.router) { client in
            let token = try await login(client)
            let movies = try await lib(client, token, "Movies", "movies")
            let tv = try await lib(client, token, "TV", "tvShows")
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "Media", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: nil, manifestURL: manifestURL,
                    libraryMap: ["movie": movies, "tv": tv]))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }

            // Delete the TV library → its items go, but the source still feeds Movies.
            try await client.execute(
                uri: "/v1/admin/libraries/\(tv)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }
            let afterTV = try await sources(client, token)
            #expect(afterTV.count == 1)                          // source survived
            #expect(afterTV.first?.libraryMap?["tv"] == nil)     // unbound from TV
            #expect(try await top(client, token, movies).count == 1)  // movie still there

            // Delete the Movies library → source now feeds nothing → it's removed.
            try await client.execute(
                uri: "/v1/admin/libraries/\(movies)", method: .delete, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .noContent) }
            #expect(try await sources(client, token).isEmpty)
        }
    }
}
