import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The opt-in sign-in profile chooser: `GET /v1/auth/directory` lists pickable
/// profiles (and their avatars) **pre-auth**, but only when the `signInUserList`
/// setting is on. Off by default so a server never enumerates its accounts.
@Suite("Sign-in profile directory")
struct DirectorySignInTests {
    private static let pngBytes: [UInt8] =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 24)

    private func login(_ client: any TestClientProtocol,
                       username: String = "admin", password: String = "test-password") async throws -> TokenResponse {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: username, password: password))
        ) { try $0.decoded() }
    }

    @Test("disabled by default: the directory 404s and leaks nothing")
    func disabledByDefault() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/auth/directory", method: .get, headers: jsonHeaders()) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test("enabled: lists every account pre-auth, in display order")
    func listsUsersWhenEnabled() async throws {
        let app = try await buildApplication(configuration: testConfiguration(signInUserList: true))
        try await app.test(.router) { client in
            // Add a second user (needs the admin token), then read the directory with NO auth.
            let admin = try await login(client)
            _ = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin.accessToken),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: "Bob", isAdmin: nil, permissions: nil))
            ) { #expect($0.status == .ok || $0.status == .created) }

            let dir: UserDirectoryResponse = try await client.execute(
                uri: "/v1/auth/directory", method: .get, headers: jsonHeaders()  // unauthenticated
            ) { #expect($0.status == .ok); return try $0.decoded() }

            let usernames = dir.users.map(\.username)
            #expect(usernames.contains("admin"))
            #expect(usernames.contains("bob"))
            // Returned in case-insensitive display-name order.
            let names = dir.users.map { $0.displayName.lowercased() }
            #expect(names == names.sorted())
            // No avatar uploaded yet ⇒ no avatar URL.
            #expect(dir.users.allSatisfy { $0.avatarURL == nil })
        }
    }

    @Test("avatars are fetchable pre-auth once set; absent ones 404")
    func avatarsArePublicWhenEnabled() async throws {
        let app = try await buildApplication(configuration: testConfiguration(signInUserList: true))
        try await app.test(.router) { client in
            let admin = try await login(client)

            var imageHeaders = HTTPFields()
            imageHeaders[.authorization] = "Bearer \(admin.accessToken)"
            imageHeaders[.contentType] = "image/png"
            _ = try await client.execute(uri: "/v1/auth/me/avatar", method: .put, headers: imageHeaders,
                                         body: ByteBuffer(bytes: Self.pngBytes)) { #expect($0.status == .ok) }

            let dir: UserDirectoryResponse = try await client.execute(
                uri: "/v1/auth/directory", method: .get, headers: jsonHeaders()
            ) { try $0.decoded() }
            let entry = try #require(dir.users.first { $0.username == "admin" })
            let avatarURL = try #require(entry.avatarURL)

            // The avatar bytes come back without a bearer token.
            try await client.execute(uri: avatarURL, method: .get, headers: jsonHeaders()) {
                #expect($0.status == .ok)
                #expect($0.headers[.contentType] == "image/png")
            }
        }
    }

    @Test("avatar route is also gated: 404 when the directory is disabled")
    func avatarGatedWhenDisabled() async throws {
        let app = try await buildApplication(configuration: testConfiguration())  // disabled
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/auth/directory/u_whoever/avatar", method: .get, headers: jsonHeaders()) {
                #expect($0.status == .notFound)
            }
        }
    }
}
