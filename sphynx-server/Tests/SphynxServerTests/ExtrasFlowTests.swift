import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Scanning a source whose manifest includes a bonus clip under an extras bucket
/// produces an item of the extras type, nested under its enclosing show/movie via
/// `parentId` and browsable through `GET /v1/items?parent=<parentId>` — rather
/// than the old bug where it landed in the grid as a standalone movie.
@Suite("Extras: bonus content nests under its parent")
struct ExtrasFlowTests {
    private let baseURL = "https://cdn.example/media"
    private let manifestURL = "stub://extras"

    // A show with one real episode plus a behind-the-scenes featurette, and a
    // movie with a trailer. All titles invented (non-copyrighted).
    private var manifestJSON: Data {
        Data("""
        { "items": [
            { "key": "Pinewood Hollow/Season 1/Pinewood Hollow - S01E01.mkv", "container": "mkv" },
            { "key": "Pinewood Hollow/Featurettes/Making of Pinewood.mkv", "container": "mkv" },
            { "key": "Sky Harbor (2020)/Trailers/Teaser.mkv", "container": "mkv" }
        ] }
        """.utf8)
    }

    @Test("scan nests an extra under its show, browsable via parent")
    func extraNestsUnderShow() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: nil
        )
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "Media", kind: "tvShows"))
            ) { try $0.decoded() }

            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "Media", driver: "http", baseURL: baseURL, headers: nil, libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }

            // 3 media entries → 3 items added (series/season containers are byproducts).
            let summary: IndexSummary = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(summary.scanned == 3)
            #expect(summary.added == 3)

            // Top level of the library: the show series and the movie parent — the
            // extras themselves are NOT here (they nest under their parents).
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let topTypes = Set(top.items.map(\.type))
            #expect(topTypes == [.series, .movie])
            // No extras leaked into the top-level grid.
            #expect(!top.items.contains { [.featurette, .trailer, .deletedScene, .behindTheScenes].contains($0.type) })

            let series = try #require(top.items.first { $0.type == .series })
            #expect(series.title == "Pinewood Hollow")

            // Browsing the series surfaces both its season and its featurette.
            let underSeries: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(series.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let featurette = try #require(underSeries.items.first { $0.type == .featurette })
            #expect(featurette.title == "Making of Pinewood")
            #expect(featurette.parentId == series.id)

            // The movie trailer nests under the movie parent.
            let movie = try #require(top.items.first { $0.type == .movie })
            #expect(movie.title == "Sky Harbor")
            let underMovie: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(movie.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let trailer = try #require(underMovie.items.first { $0.type == .trailer })
            #expect(trailer.title == "Teaser")
            #expect(trailer.parentId == movie.id)
        }
    }
}
