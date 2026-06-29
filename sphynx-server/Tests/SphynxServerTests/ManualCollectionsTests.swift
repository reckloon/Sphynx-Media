import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Manual collections: admin- and user-curated box sets (no TMDB), governed by the
/// same per-library `collectionThreshold` as auto-discovered collections, and gated
/// by the `collections.edit` permission so curation can be delegated.
@Suite("Manual collections (admin / delegated curation)")
struct ManualCollectionsTests {

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

    @Test("create a series collection; it groups at top level and lists its members")
    func seriesCollectionGroupsLikeMovies() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let lib = try await makeLibrary(client, admin, kind: "tvShows")
            let a = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol", libraryId: lib)
            let b = try await makeItem(client, admin, type: "series", title: "Wormhole Patrol: Next Watch", libraryId: lib)

            // Before grouping, both series sit at the library's top level.
            let before: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(before.items.filter { $0.type == .series }.count == 2)

            // Candidates list both top-level series.
            let cands: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/collections/candidates?library=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(Set(cands.items.map(\.title)) == ["Wormhole Patrol", "Wormhole Patrol: Next Watch"])

            // Create a collection seeded with both series.
            let made: AdminCollection = try await client.execute(
                uri: "/v1/admin/collections", method: .post, headers: admin,
                body: try jsonBody(CreateCollectionRequest(libraryId: lib, title: "The Wormhole Saga", itemIds: [a.id, b.id]))
            ) { try $0.decoded() }
            #expect(made.memberCount == 2)

            // At the default threshold (2) the two series now group into one tile.
            let grouped: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            let tile = try #require(grouped.items.first { $0.type == .collection })
            #expect(tile.title == "The Wormhole Saga")
            #expect(grouped.items.filter { $0.type == .series }.isEmpty)

            // The collection is browsable and its members carry the back-links.
            let members: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(tile.id)&detail=full", method: .get, headers: admin) { try $0.decoded() }
            #expect(Set(members.items.map(\.title)) == ["Wormhole Patrol", "Wormhole Patrol: Next Watch"])
            #expect(members.items.allSatisfy { $0.collectionId == tile.id && $0.collectionTitle == "The Wormhole Saga" })

            // Now that they're nested, neither series is offered as a candidate again.
            let cands2: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/collections/candidates?library=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(cands2.items.isEmpty)
        }
    }

    @Test("a collection-kind library aggregates collections in BOTH the client and admin browsers")
    func collectionLibraryAggregatesInAdminToo() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            // A TV library with two series grouped into a box set…
            let lib = try await makeLibrary(client, admin, kind: "tvShows")
            let a = try await makeItem(client, admin, type: "series", title: "Orbit One", libraryId: lib)
            let b = try await makeItem(client, admin, type: "series", title: "Orbit Two", libraryId: lib)
            let made: AdminCollection = try await client.execute(
                uri: "/v1/admin/collections", method: .post, headers: admin,
                body: try jsonBody(CreateCollectionRequest(libraryId: lib, title: "Orbit Saga", itemIds: [a.id, b.id]))
            ) { try $0.decoded() }

            // …and a separate, physically-empty "Collections" library.
            let colLib = try await makeLibrary(client, admin, kind: "collection")

            // CLIENT view of the collection library: the box set shows (aggregated).
            let clientView: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(colLib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(clientView.items.contains { $0.id == made.id && $0.type == .collection })

            // ADMIN view must match — previously it used a literal libraryId match
            // and came back empty, so the web UI showed an empty Collections library.
            let adminView: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/items?parent=\(colLib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(adminView.items.contains { $0.id == made.id && $0.type == .collection })
            #expect(adminView.items.map(\.title).contains("Orbit Saga"))
        }
    }

    @Test("rename, remove a member, and delete (orphaning members back to top level)")
    func renameRemoveDelete() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let lib = try await makeLibrary(client, admin, kind: "movies")
            let a = try await makeItem(client, admin, type: "movie", title: "Aurora", libraryId: lib)
            let b = try await makeItem(client, admin, type: "movie", title: "Aurora Rising", libraryId: lib)
            let c = try await makeItem(client, admin, type: "movie", title: "Aurora Eclipse", libraryId: lib)

            let made: AdminCollection = try await client.execute(
                uri: "/v1/admin/collections", method: .post, headers: admin,
                body: try jsonBody(CreateCollectionRequest(libraryId: lib, title: "Aurora Trilogy", itemIds: [a.id, b.id, c.id]))
            ) { try $0.decoded() }

            // Rename + drop one member in a single PATCH.
            let updated: AdminCollection = try await client.execute(
                uri: "/v1/admin/collections/\(made.id)", method: .patch, headers: admin,
                body: try jsonBody(UpdateCollectionRequest(title: "Aurora Saga", addItems: nil, removeItems: [c.id]))
            ) { try $0.decoded() }
            #expect(updated.title == "Aurora Saga")
            #expect(updated.memberCount == 2)
            // The rename propagated to the remaining members' denormalized title.
            #expect(updated.members.allSatisfy { $0.collectionTitle == "Aurora Saga" })

            // The removed movie is back at the library's top level (links cleared).
            let top: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            let eclipse = try #require(top.items.first { $0.title == "Aurora Eclipse" })
            #expect(eclipse.type == .movie)
            #expect(eclipse.collectionId == nil)

            // Delete the collection: the tile is gone, both members orphaned back.
            try await client.execute(
                uri: "/v1/admin/collections/\(made.id)", method: .delete, headers: admin) { #expect($0.status == .noContent) }
            let after: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)", method: .get, headers: admin) { try $0.decoded() }
            #expect(after.items.filter { $0.type == .collection }.isEmpty)
            #expect(Set(after.items.filter { $0.type == .movie }.map(\.title))
                == ["Aurora", "Aurora Eclipse", "Aurora Rising"])
            #expect(after.items.allSatisfy { $0.collectionId == nil })
        }
    }

    @Test("collections.edit gates curation; library.read alone is forbidden, a scoped grant passes")
    func collectionsEditGating() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let lib = try await makeLibrary(client, admin, kind: "movies")
            let other = try await makeLibrary(client, admin, kind: "tvShows")

            // A plain viewer cannot list or create collections.
            try await makeUser(client, admin, "viewer", perms: ["library.read"])
            let viewer = jsonHeaders(bearer: try await token(client, "viewer", "pw"))
            try await client.execute(uri: "/v1/admin/collections?library=\(lib)", method: .get, headers: viewer) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/v1/admin/collections", method: .post, headers: viewer,
                body: try jsonBody(CreateCollectionRequest(libraryId: lib, title: "Nope", itemIds: nil))) {
                #expect($0.status == .forbidden)
            }

            // A curator scoped to `lib` can manage it…
            try await makeUser(client, admin, "curator", perms: ["library.read", "collections.edit:\(lib)"])
            let curator = jsonHeaders(bearer: try await token(client, "curator", "pw"))
            let made: AdminCollection = try await client.execute(
                uri: "/v1/admin/collections", method: .post, headers: curator,
                body: try jsonBody(CreateCollectionRequest(libraryId: lib, title: "Curated", itemIds: nil))
            ) { try $0.decoded() }
            #expect(made.title == "Curated")
            try await client.execute(uri: "/v1/admin/collections?library=\(lib)", method: .get, headers: curator) {
                #expect($0.status == .ok)
            }
            // …but the scope doesn't reach another library.
            try await client.execute(uri: "/v1/admin/collections", method: .post, headers: curator,
                body: try jsonBody(CreateCollectionRequest(libraryId: other, title: "Nope", itemIds: nil))) {
                #expect($0.status == .forbidden)
            }
        }
    }
}
