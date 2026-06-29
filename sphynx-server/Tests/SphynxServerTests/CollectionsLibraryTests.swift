import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The `collection`-kind library is a cross-library *view*: it holds no items of
/// its own, but browsing it aggregates every box-set tile from the content
/// libraries (where the tiles actually live, alongside their movies/series).
/// Aggregation is scoped to the libraries the caller may read.
@Suite("Collections library (cross-library box-set view)")
struct CollectionsLibraryTests {

    private func token(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        let t: TokenResponse = try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded() }
        return t.accessToken
    }

    private func makeUser(_ client: any TestClientProtocol, _ admin: HTTPFields,
                          _ name: String, perms: [String]) async throws {
        _ = try await client.execute(
            uri: "/v1/admin/users", method: .post, headers: admin,
            body: try jsonBody(CreateUserRequest(username: name, password: "pw",
                displayName: nil, isAdmin: nil, permissions: perms))
        ) { $0 }
    }

    private func makeLibrary(_ client: any TestClientProtocol, _ admin: HTTPFields, kind: String) async throws -> String {
        let lib: LibraryResponse = try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: admin,
            body: try jsonBody(CreateLibraryRequest(title: nil, kind: kind))
        ) { try $0.decoded() }
        return lib.id
    }

    private func makeItem(_ client: any TestClientProtocol, _ admin: HTTPFields,
                          type: String, title: String, libraryId: String) async throws -> Item {
        try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: admin,
            body: try jsonBody(CreateItemRequest(type: type, title: title, sourceId: nil,
                sourceKey: "https://x/\(title).mp4", container: "mp4", tmdbId: nil, libraryId: libraryId))
        ) { try $0.decoded() }
    }

    @discardableResult
    private func makeCollection(_ client: any TestClientProtocol, _ admin: HTTPFields,
                                libraryId: String, title: String, itemIds: [String]) async throws -> AdminCollection {
        try await client.execute(
            uri: "/v1/admin/collections", method: .post, headers: admin,
            body: try jsonBody(CreateCollectionRequest(libraryId: libraryId, title: title, itemIds: itemIds))
        ) { try $0.decoded() }
    }

    @Test("browsing a collection-kind library aggregates every box-set tile across libraries")
    func aggregatesAllCollections() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let movies = try await makeLibrary(client, admin, kind: "movies")
            let shows = try await makeLibrary(client, admin, kind: "tvShows")
            let collLib = try await makeLibrary(client, admin, kind: "collection")

            // A box set in the movies library…
            let m1 = try await makeItem(client, admin, type: "movie", title: "Aurora", libraryId: movies)
            let m2 = try await makeItem(client, admin, type: "movie", title: "Aurora Rising", libraryId: movies)
            try await makeCollection(client, admin, libraryId: movies, title: "Aurora Saga", itemIds: [m1.id, m2.id])

            // …and one in the TV library.
            let s1 = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol", libraryId: shows)
            let s2 = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol: Next Watch", libraryId: shows)
            try await makeCollection(client, admin, libraryId: shows, title: "Wormhole Saga", itemIds: [s1.id, s2.id])

            // The collection library holds no items of its own, yet browsing it
            // surfaces both box-set tiles — and only collection tiles.
            let agg: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(collLib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(agg.items.allSatisfy { $0.type == .collection })
            #expect(Set(agg.items.map(\.title)) == ["Aurora Saga", "Wormhole Saga"])
            #expect(agg.totalCount == 2)

            // Each tile opens to its own members, wherever they live.
            let tile = try #require(agg.items.first { $0.title == "Aurora Saga" })
            let members: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(tile.id)", method: .get, headers: admin) { try $0.decoded() }
            #expect(Set(members.items.map(\.title)) == ["Aurora", "Aurora Rising"])
        }
    }

    @Test("the aggregate only surfaces box sets from libraries the caller may read")
    func aggregateRespectsReadScope() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let movies = try await makeLibrary(client, admin, kind: "movies")
            let shows = try await makeLibrary(client, admin, kind: "tvShows")
            let collLib = try await makeLibrary(client, admin, kind: "collection")

            let m1 = try await makeItem(client, admin, type: "movie", title: "Aurora", libraryId: movies)
            let m2 = try await makeItem(client, admin, type: "movie", title: "Aurora Rising", libraryId: movies)
            try await makeCollection(client, admin, libraryId: movies, title: "Aurora Saga", itemIds: [m1.id, m2.id])

            let s1 = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol", libraryId: shows)
            let s2 = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol: Next Watch", libraryId: shows)
            try await makeCollection(client, admin, libraryId: shows, title: "Wormhole Saga", itemIds: [s1.id, s2.id])

            // A viewer who may read the collection library and movies, but not TV.
            try await makeUser(client, admin, "viewer",
                perms: ["library.read:\(collLib)", "library.read:\(movies)"])
            let viewer = jsonHeaders(bearer: try await token(client, "viewer", "pw"))

            let agg: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(collLib)", method: .get, headers: viewer) { try $0.decoded() }
            // Only the movies box set surfaces; the TV one is filtered out.
            #expect(Set(agg.items.map(\.title)) == ["Aurora Saga"])
            #expect(agg.totalCount == 1)
        }
    }
}
