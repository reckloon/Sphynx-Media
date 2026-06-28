import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The expanded permission model: `catalog.scan`, per-item `metadata.edit`
/// scoping, and self-service sessions.
@Suite("Delegated permissions + sessions")
struct DelegatedPermissionsTests {

    private func token(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        let t: TokenResponse = try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded() }
        return t.accessToken
    }

    private func makeUser(_ client: any TestClientProtocol, _ admin: HTTPFields,
                          _ name: String, perms: [String]) async throws -> AdminUserResponse {
        try await client.execute(
            uri: "/v1/admin/users", method: .post, headers: admin,
            body: try jsonBody(CreateUserRequest(username: name, password: "pw",
                displayName: nil, isAdmin: nil, permissions: perms))
        ) { try $0.decoded() }
    }

    @Test("catalog.scan gates per-library and per-source scans; scanAll needs the global grant")
    func scanGating() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: admin,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            // Viewer with only library.read cannot scan.
            _ = try await makeUser(client, admin, "viewer", perms: ["library.read"])
            let viewer = jsonHeaders(bearer: try await token(client, "viewer", "pw"))
            try await client.execute(uri: "/v1/admin/libraries/\(lib.id)/scan", method: .post, headers: viewer) {
                #expect($0.status == .forbidden)
            }

            // Scanner scoped to this library can refresh it (no sources ⇒ empty 200)…
            _ = try await makeUser(client, admin, "scanner", perms: ["library.read", "catalog.scan:\(lib.id)"])
            let scanner = jsonHeaders(bearer: try await token(client, "scanner", "pw"))
            try await client.execute(uri: "/v1/admin/libraries/\(lib.id)/scan", method: .post, headers: scanner) {
                #expect($0.status == .ok)
            }
            // …but a per-library scope cannot scan the whole catalog.
            try await client.execute(uri: "/v1/admin/scan", method: .post, headers: scanner) {
                #expect($0.status == .forbidden)
            }

            // A global catalog.scan grant can scan everything.
            _ = try await makeUser(client, admin, "scanall", perms: ["library.read", "catalog.scan"])
            let scanAll = jsonHeaders(bearer: try await token(client, "scanall", "pw"))
            try await client.execute(uri: "/v1/admin/scan", method: .post, headers: scanAll) {
                #expect($0.status == .ok)
            }
        }
    }

    @Test("metadata.edit can be scoped to a single item")
    func perItemEditScope() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: admin,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            func makeItem(_ title: String) async throws -> Item {
                try await client.execute(uri: "/v1/admin/items", method: .post, headers: admin,
                    body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                        sourceKey: "https://x/\(title).mp4", container: "mp4", tmdbId: nil, libraryId: lib.id))
                ) { try $0.decoded() }
            }
            let a = try await makeItem("A"), b = try await makeItem("B")

            // Grant edit for item A only.
            _ = try await makeUser(client, admin, "fixer", perms: ["library.read", "metadata.edit:\(a.id)"])
            let fixer = jsonHeaders(bearer: try await token(client, "fixer", "pw"))

            // Can read + edit A…
            try await client.execute(uri: "/v1/admin/items/\(a.id)", method: .get, headers: fixer) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/v1/admin/items/\(a.id)", method: .patch, headers: fixer,
                body: try jsonBody(["overview": "fixed"])) { #expect($0.status == .ok) }
            // …but not B.
            try await client.execute(uri: "/v1/admin/items/\(b.id)", method: .patch, headers: fixer,
                body: try jsonBody(["overview": "nope"])) { #expect($0.status == .forbidden) }
        }
    }

    @Test("a user can list and revoke their own sessions")
    func sessionSelfService() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = jsonHeaders(bearer: try await token(client, "admin", "test-password"))
            _ = try await makeUser(client, admin, "bob", perms: ["library.read"])
            // Two logins from two devices.
            let t1: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(device: "phone"),
                body: try jsonBody(LoginRequest(username: "bob", password: "pw"))) { try $0.decoded() }
            try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(device: "laptop"),
                body: try jsonBody(LoginRequest(username: "bob", password: "pw"))) { #expect($0.status == .ok) }

            let auth = jsonHeaders(bearer: t1.accessToken)
            let list: SessionsResponse = try await client.execute(
                uri: "/v1/auth/sessions", method: .get, headers: auth) { response in
                    #expect(response.status == .ok); return try response.decoded()
                }
            #expect(list.sessions.count == 2)
            #expect(list.sessions.contains { $0.current })   // the requesting session is flagged
            let other = try #require(list.sessions.first { !$0.current })

            try await client.execute(uri: "/v1/auth/sessions/\(other.id)", method: .delete, headers: auth) {
                #expect($0.status == .noContent)
            }
            let after: SessionsResponse = try await client.execute(
                uri: "/v1/auth/sessions", method: .get, headers: auth) { try $0.decoded() }
            #expect(after.sessions.count == 1)
        }
    }
}
