import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Authorization: single admin + per-user permissions")
struct PermissionsFlowTests {

    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    private func createUser(
        _ client: any TestClientProtocol, admin: String,
        username: String, password: String, permissions: [String]?
    ) async throws -> AdminUserResponse {
        try await client.execute(
            uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateUserRequest(username: username, password: password,
                                                 displayName: nil, isAdmin: nil, permissions: permissions))
        ) { #expect($0.status == .ok); return try $0.decoded() }
    }

    /// Create an item **inside a library** — items with no owning library are
    /// admin-only (fail-closed), so a non-admin gated by `library.read` needs the
    /// item to live in a library for the grant to apply.
    private func createItem(_ client: any TestClientProtocol, admin: String, title: String) async throws -> Item {
        let library: LibraryResponse = try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateLibraryRequest(title: "Lib \(title)", kind: "movies"))
        ) { try $0.decoded() }
        return try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                sourceKey: "https://cdn/\(title).mkv", container: "mkv", tmdbId: nil,
                libraryId: library.id, parentId: nil, year: nil, extra: nil))
        ) { try $0.decoded() }
    }

    @Test("created users are never admin and default to library.read")
    func newUsersAreNonAdminWithBrowse() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")

            // Even asking for admin yields a non-admin account.
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: nil)
            #expect(bob.isAdmin == false)
            #expect(bob.permissions == ["library.read"])  // sensible default

            // /auth/me reflects the effective permissions.
            let bobToken = try await login(client, "bob", "pw")
            let me: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(me.permissions.contains("library.read"))
            #expect(me.permissions.contains("metadata.markers.write") == false)
        }
    }

    @Test("the admin cannot be deleted; other users can")
    func adminProtected() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let users: AdminUsersResponse = try await client.execute(
                uri: "/v1/admin/users", method: .get, headers: jsonHeaders(bearer: admin)
            ) { try $0.decoded() }
            let adminId = users.users.first(where: { $0.isAdmin })!.id

            // Deleting the admin is forbidden.
            try await client.execute(
                uri: "/v1/admin/users/\(adminId)", method: .delete, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .forbidden) }

            // A normal user can be created and deleted; their token then dies.
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: nil)
            let bobToken = try await login(client, "bob", "pw")
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)", method: .delete, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .noContent) }
            try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("library.read gates browse + resolve; admin grants it")
    func libraryReadGatesBrowse() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let item = try await createItem(client, admin: admin, title: "Gattaca")

            // A user with NO permissions cannot browse or resolve.
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: [])
            let bobToken = try await login(client, "bob", "pw")
            try await client.execute(
                uri: "/v1/items/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .forbidden) }
            try await client.execute(
                uri: "/v1/resolve/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .forbidden) }

            // Admin grants library.read → browse + resolve now work.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read"]))
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/items/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/resolve/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("marker writes require the metadata.markers.write permission")
    func perUserMarkerWrite() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let item = try await createItem(client, admin: admin, title: "X")

            // Bob can browse but not contribute markers yet.
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: nil)
            let bobToken = try await login(client, "bob", "pw")

            let beforeMe: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(beforeMe.metadata["markers"] == .read)

            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2))))
            ) { #expect($0.status == .forbidden) }

            // Admin grants the markers-write permission (keeping browse).
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read", "metadata.markers.write"]))
            ) { #expect($0.status == .ok) }

            let afterMe: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(afterMe.metadata["markers"] == .readWrite)
            #expect(afterMe.permissions.contains("metadata.markers.write"))

            let written: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 10, end: 20)), source: "theintrodb"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(written.authoritative == false)
        }
    }

    @Test("marker writes honor per-library scoping (like metadata.edit)")
    func markerWriteIsLibraryScoped() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            // Item lives in library A; B is an unrelated library.
            let libA: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateLibraryRequest(title: "A", kind: "movies"))) { try $0.decoded() }
            let libB: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateLibraryRequest(title: "B", kind: "movies"))) { try $0.decoded() }
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Heat", sourceId: nil,
                    sourceKey: "https://cdn/heat.mkv", container: "mkv", tmdbId: nil,
                    libraryId: libA.id, parentId: nil, year: nil, extra: nil))) { try $0.decoded() }

            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: nil)
            let bobToken = try await login(client, "bob", "pw")
            let contribution = try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2)), source: "x"))

            // Grant markers-write scoped to the WRONG library (B), read on A.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read:\(libA.id)", "metadata.markers.write:\(libB.id)"]))) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken), body: contribution
            ) { #expect($0.status == .forbidden) }   // grant is for B, item is in A

            // Re-scope the grant to A → now allowed.
            try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/permissions", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read:\(libA.id)", "metadata.markers.write:\(libA.id)"]))) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken), body: contribution
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("playstate is gated on the item's owning library (like browse/resolve)")
    func playstateLibraryScoped() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let libA: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateLibraryRequest(title: "A", kind: "movies"))) { try $0.decoded() }
            let libB: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateLibraryRequest(title: "B", kind: "movies"))) { try $0.decoded() }
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Heat", sourceId: nil,
                    sourceKey: "https://cdn/heat.mkv", container: "mkv", tmdbId: nil,
                    libraryId: libA.id, parentId: nil, year: nil, extra: nil))) { try $0.decoded() }

            // Bob can read libB only — not the item's library (libA).
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw",
                                           permissions: ["library.read:\(libB.id)"])
            let bobToken = try await login(client, "bob", "pw")
            let start = try jsonBody(PlaystateStartBody(position: 5))

            try await client.execute(uri: "/v1/playstate/\(item.id)/start", method: .post,
                headers: jsonHeaders(bearer: bobToken), body: start) { #expect($0.status == .forbidden) }
            try await client.execute(uri: "/v1/playstate/\(item.id)", method: .get,
                headers: jsonHeaders(bearer: bobToken)) { #expect($0.status == .forbidden) }

            // Grant libA read → playstate now allowed.
            try await client.execute(uri: "/v1/admin/users/\(bob.id)/permissions", method: .put,
                headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read:\(libA.id)"]))) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/playstate/\(item.id)/start", method: .post,
                headers: jsonHeaders(bearer: bobToken), body: start) { #expect($0.status == .noContent) }
        }
    }

    @Test("a user can change their own password")
    func selfPasswordChange() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw", permissions: nil)
            _ = bob
            let bobToken = try await login(client, "bob", "pw")

            // Wrong current password is rejected.
            try await client.execute(
                uri: "/v1/auth/password", method: .post, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(PasswordChangeRequest(currentPassword: "nope", newPassword: "newpw"))
            ) { #expect($0.status == .unauthorized) }

            // Correct current password succeeds; the new password then logs in.
            try await client.execute(
                uri: "/v1/auth/password", method: .post, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(PasswordChangeRequest(currentPassword: "pw", newPassword: "newpw"))
            ) { #expect($0.status == .noContent) }
            _ = try await login(client, "bob", "newpw")
        }
    }

    @Test("a client cannot clobber authoritative (admin) markers")
    func authoritativePrecedence() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let bob = try await createUser(client, admin: admin, username: "bob", password: "pw",
                                           permissions: ["library.read", "metadata.markers.write"])
            _ = bob
            let bobToken = try await login(client, "bob", "pw")
            let item = try await createItem(client, admin: admin, title: "Y")

            // Admin writes authoritative markers.
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 5, end: 9))))
            ) { #expect($0.status == .ok); let i: MarkersInfo = try $0.decoded(); #expect(i.authoritative == true) }

            // Bob (granted, but not admin) may not overwrite them → 409.
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 99, end: 100))))
            ) { #expect($0.status == .conflict) }
        }
    }

    @Test("open `extra` metadata is stored and projected onto the item")
    func extraStoredUniformly() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(
                    type: "movie", title: "The Shawshank Redemption", sourceId: nil,
                    sourceKey: "https://cdn/ssr.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: 1994,
                    extra: ["imdbId": .string("tt0111161"), "spatialAudio": .bool(true)]))
            ) { try $0.decoded() }
            #expect(created.extra?["imdbId"] == .string("tt0111161"))

            let fetched: Item = try await client.execute(
                uri: "/v1/items/\(created.id)?detail=full", method: .get, headers: jsonHeaders(bearer: admin)
            ) { try $0.decoded() }
            #expect(fetched.extra?["imdbId"] == .string("tt0111161"))
            #expect(fetched.extra?["spatialAudio"] == .bool(true))
        }
    }

    @Test("creating a duplicate username is a conflict")
    func duplicateUser() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "admin", password: "x", displayName: nil, isAdmin: nil, permissions: nil))
            ) { #expect($0.status == .conflict) }
        }
    }
}
