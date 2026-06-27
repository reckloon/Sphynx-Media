import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Manual-edit persistence (field locks)")
struct ManualEditTests {
    private let manifestURL = "stub://movies"
    private let baseURL = "https://cdn.example/movies"

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
                id: 603, title: "The Matrix",
                overview: "A hacker learns the truth about his reality.",
                year: 1999, runtimeMinutes: 136,
                genres: ["Action", "Science Fiction"],
                voteAverage: 8.2,
                posterPath: "/poster.jpg", backdropPath: "/back.jpg",
                cast: [TMDBCastMember(id: 6384, name: "Keanu Reeves", character: "Neo", profilePath: "/keanu.jpg")]
            )]
        )
    }

    private func login(_ client: any TestClientProtocol, _ user: String = "admin", _ pass: String = "test-password") async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("edited fields are locked and survive a forced re-enrich; unlock re-enables refresh")
    func lockedFieldsSurviveEnrich() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token = try await login(client)

            // Manual item, pinned to The Matrix → enriches with TMDB metadata.
            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Unknown Film", sourceId: nil,
                    sourceKey: "https://cdn.example/x.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }
            let pinned: Item = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "603", type: "movie"))
            ) { try $0.decoded() }
            #expect(pinned.overview == "A hacker learns the truth about his reality.")

            // Admin edits overview + genres → those fields lock.
            let edited: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(created.id)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(EditItemRequest(overview: "My own synopsis.", genres: ["Custom"]))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(edited.lockedFields == ["genres", "overview"])
            #expect(edited.item.overview == "My own synopsis.")

            // Forced re-enrich must NOT clobber the locked fields, but refreshes others.
            let reEnriched: Item = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/enrich", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reEnriched.overview == "My own synopsis.")   // locked → preserved
            #expect(reEnriched.genres == ["Custom"])             // locked → preserved
            #expect(reEnriched.communityRating == 8.2)           // unlocked → refreshed
            #expect(reEnriched.runtime == 8160)                  // unlocked → refreshed

            // Unlock overview → next enrich repopulates it from TMDB.
            let unlocked: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(created.id)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(EditItemRequest(unlock: ["overview"]))
            ) { try $0.decoded() }
            #expect(unlocked.lockedFields == ["genres"])

            let refreshed: Item = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/enrich", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(refreshed.overview == "A hacker learns the truth about his reality.")  // back to TMDB
            #expect(refreshed.genres == ["Custom"])  // still locked
        }
    }

    @Test("a locked title survives a source re-scan")
    func lockedTitleSurvivesRescan() async throws {
        let app = try await buildApplication(
            configuration: testConfiguration(),
            httpFetcher: StubFetcher([manifestURL: manifestJSON]),
            tmdbClient: stubTMDB
        )
        try await app.test(.router) { client in
            let token = try await login(client)
            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            let source: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "CDN", driver: "http", baseURL: baseURL,
                    headers: nil, libraryId: library.id, manifestURL: manifestURL))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }

            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(library.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let item = try #require(page.items.first)
            #expect(item.title == "The Matrix")

            // Rename it (locks the title).
            _ = try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(EditItemRequest(title: "The Matrix (Director's Pick)"))
            ) { #expect($0.status == .ok); return try $0.decoded(AdminItemResponse.self) }

            // Re-scan: the manifest still says "The Matrix", but the lock holds.
            _ = try await client.execute(
                uri: "/v1/admin/sources/\(source.id)/scan", method: .post, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded(IndexSummary.self) }

            let after: Item = try await client.execute(
                uri: "/v1/items/\(item.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(after.title == "The Matrix (Director's Pick)")
        }
    }

    @Test("editing requires the metadata.edit permission")
    func editRequiresPermission() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client)
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Z", sourceId: nil,
                    sourceKey: "https://cdn/z.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            // A user with only library.read cannot edit.
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil,
                    isAdmin: nil, permissions: ["library.read"]))
            ) { try $0.decoded() }
            let bobToken = try await login(client, "bob", "pw")
            try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(EditItemRequest(title: "Hacked"))
            ) { #expect($0.status == .forbidden) }

            // Grant metadata.edit → the edit succeeds.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read", "metadata.edit"]))
            ) { #expect($0.status == .ok) }
            let edited: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(EditItemRequest(title: "Curated Title"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(edited.item.title == "Curated Title")
            #expect(edited.lockedFields == ["title"])
        }
    }
}
