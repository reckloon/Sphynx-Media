import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Admin affordances added for the redesigned UI: reading an item's lock state for
/// the correction editor, and resetting another user's password.
@Suite("Admin item read + password reset")
struct AdminItemAndPasswordTests {

    private func adminToken(_ client: any TestClientProtocol) async throws -> String {
        let t: TokenResponse = try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded() }
        return t.accessToken
    }

    @Test("GET /v1/admin/items/:id returns the item with its locked fields")
    func adminGetItemLocks() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Raw", sourceId: nil,
                    sourceKey: "https://x/r.mp4", container: "mp4", tmdbId: nil))
            ) { try $0.decoded() }

            // Initially nothing is locked.
            let before: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .get, headers: auth
            ) { response in #expect(response.status == .ok); return try response.decoded() }
            #expect(before.lockedFields.isEmpty)

            // Editing the overview locks exactly that field.
            _ = try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .patch, headers: auth,
                body: try jsonBody(["overview": "Fixed."])
            ) { #expect($0.status == .ok) }

            let after: AdminItemResponse = try await client.execute(
                uri: "/v1/admin/items/\(item.id)", method: .get, headers: auth
            ) { try $0.decoded() }
            #expect(after.lockedFields == ["overview"])
            #expect(after.item.overview == "Fixed.")
        }
    }

    @Test("admin can reset a user's password; they log in with the new one")
    func adminResetPassword() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let user: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: auth,
                body: try jsonBody(CreateUserRequest(username: "bob", password: "old-pw",
                    displayName: nil, isAdmin: nil, permissions: nil))
            ) { try $0.decoded() }

            try await client.execute(
                uri: "/v1/admin/users/\(user.id)/password", method: .put, headers: auth,
                body: try jsonBody(ResetPasswordRequest(newPassword: "new-pw"))
            ) { #expect($0.status == .noContent) }

            // Old password no longer works; new one does.
            try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "bob", password: "old-pw"))
            ) { #expect($0.status == .unauthorized) }
            try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "bob", password: "new-pw"))
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("admin password cannot be reset via the admin endpoint")
    func adminCannotResetOwn() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let users: AdminUsersResponse = try await client.execute(
                uri: "/v1/admin/users", method: .get, headers: auth
            ) { try $0.decoded() }
            let admin = try #require(users.users.first { $0.isAdmin })
            try await client.execute(
                uri: "/v1/admin/users/\(admin.id)/password", method: .put, headers: auth,
                body: try jsonBody(ResetPasswordRequest(newPassword: "x"))
            ) { #expect($0.status == .forbidden) }
        }
    }
}
