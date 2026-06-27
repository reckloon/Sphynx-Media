import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Per-user permissions + open metadata storage")
struct PermissionsFlowTests {

    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("marker writes are per-user: admin grants, then the user may contribute")
    func perUserGrants() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")

            // Admin creates a normal user with NO write grants.
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: "Bob", isAdmin: false, writeGrants: nil))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(bob.writeGrants.isEmpty)

            let bobToken = try await login(client, "bob", "pw")

            // An item to contribute markers to.
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "X", sourceId: nil, sourceKey: "https://cdn/x.mkv", container: "mkv", tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            // Server supports markers (info), but Bob's effective access is read-only.
            try await client.execute(uri: "/v1/info", method: .get) { response in
                let info: ServerInfo = try response.decoded()
                #expect(info.capabilities.access("markers") == .readWrite)  // server capability
            }
            let beforeMe: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(beforeMe.metadata["markers"] == .read)  // Bob can't write yet

            // Bob's contribution is rejected.
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2))))
            ) { #expect($0.status == .forbidden) }

            // Admin grants Bob the markers write.
            let granted: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users/\(bob.id)/grants", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(SetGrantsRequest(writeGrants: ["markers"]))
            ) { try $0.decoded() }
            #expect(granted.writeGrants == ["markers"])

            // Now /auth/me reflects readwrite and the contribution succeeds.
            let afterMe: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(afterMe.metadata["markers"] == .readWrite)

            let written: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 10, end: 20)), source: "theintrodb"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(written.authoritative == false)  // non-admin → best-effort
        }
    }

    @Test("a client cannot clobber authoritative (admin) markers")
    func authoritativePrecedence() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil, isAdmin: false, writeGrants: ["markers"]))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await login(client, "bob", "pw")

            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Y", sourceId: nil, sourceKey: "https://cdn/y.mkv", container: nil, tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

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

            // Persisted + projected on a fresh read.
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
            // "admin" already exists from bootstrap.
            try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "admin", password: "x", displayName: nil, isAdmin: false, writeGrants: nil))
            ) { #expect($0.status == .conflict) }
        }
    }
}
