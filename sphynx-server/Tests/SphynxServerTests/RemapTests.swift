import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Correction re-mapping: moving an item between libraries / re-parenting it under
/// a series or season, with edit-on-BOTH-libraries permission gating.
@Suite("Correction re-mapping (parent / library)")
struct RemapTests {
    private func login(_ client: any TestClientProtocol, _ user: String = "admin", _ pass: String = "test-password") async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    private func makeLibrary(_ client: any TestClientProtocol, _ admin: String, kind: String) async throws -> LibraryResponse {
        try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateLibraryRequest(kind: kind))
        ) { try $0.decoded() }
    }

    private func makeItem(_ client: any TestClientProtocol, _ admin: String,
                          type: String, title: String, libraryId: String?, parentId: String? = nil) async throws -> Item {
        try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateItemRequest(type: type, title: title, sourceId: nil,
                sourceKey: "stub://\(title)", container: "mkv", tmdbId: nil,
                libraryId: libraryId, parentId: parentId, year: nil, extra: nil))
        ) { try $0.decoded() }
    }

    private func createUser(_ client: any TestClientProtocol, _ admin: String, _ username: String, _ permissions: [String]) async throws -> AdminUserResponse {
        try await client.execute(
            uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateUserRequest(username: username, password: "pw", displayName: nil, isAdmin: nil, permissions: permissions))
        ) { #expect($0.status == .ok); return try $0.decoded() }
    }

    @Test("re-parenting under a series derives the series linkage")
    func reparentDerivesSeries() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client)
            let tv = try await makeLibrary(client, admin, kind: "tvShows")
            let series = try await makeItem(client, admin, type: "series", title: "Severance", libraryId: tv.id)
            // A loose, unidentified episode sitting at the library top level.
            let ep = try await makeItem(client, admin, type: "episode", title: "Orientation", libraryId: tv.id)

            let moved: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(ep.id)", method: .patch, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(EditItemRequest(parentId: series.id))
            ) { #expect($0.status == .ok); return try $0.decoded() }

            #expect(moved.item.parentId == series.id)
            #expect(moved.item.seriesId == series.id)
            #expect(moved.item.seriesTitle == "Severance")
        }
    }

    @Test("moving an item to another library makes it top-level (clears parent + series linkage)")
    func moveLibraryClearsParent() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client)
            let tv = try await makeLibrary(client, admin, kind: "tvShows")
            let movies = try await makeLibrary(client, admin, kind: "movies")
            let series = try await makeItem(client, admin, type: "series", title: "Show", libraryId: tv.id)
            let nested = try await makeItem(client, admin, type: "episode", title: "Pilot", libraryId: nil, parentId: series.id)

            let moved: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(nested.id)", method: .patch, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(EditItemRequest(libraryId: movies.id, type: "movie"))
            ) { #expect($0.status == .ok); return try $0.decoded() }

            #expect(moved.item.parentId == nil)   // became top-level
            #expect(moved.item.seriesId == nil)    // linkage cleared
            #expect(moved.item.type.rawValue == "movie")
        }
    }

    @Test("moving across libraries needs metadata.edit on BOTH source and destination")
    func moveNeedsEditOnBoth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client)
            let movies = try await makeLibrary(client, admin, kind: "movies")
            let tv = try await makeLibrary(client, admin, kind: "tvShows")
            let item = try await makeItem(client, admin, type: "movie", title: "Wanderer", libraryId: movies.id)

            // Bob may edit Movies (source) but NOT TV (destination).
            let bob = try await createUser(client, admin, "bob", ["metadata.edit:\(movies.id)"])
            let bobToken = try await login(client, "bob", "pw")

            try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(EditItemRequest(libraryId: tv.id))
            ) { #expect($0.status == .forbidden) }   // no edit on the destination

            // Grant edit on TV too → the move is now allowed.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["metadata.edit:\(movies.id)", "metadata.edit:\(tv.id)"]))
            ) { #expect($0.status == .ok) }

            try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(EditItemRequest(libraryId: tv.id))
            ) { #expect($0.status == .ok) }
        }
    }
}
