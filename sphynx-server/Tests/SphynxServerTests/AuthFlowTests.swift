import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// A reliable public direct MP4 — the "one hardcoded known media URL" for the
/// Milestone 2 login → resolve → play path.
private let knownMediaURL = "https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4"

@Suite("Auth + Resolve (login → resolve → play)")
struct AuthFlowTests {

    @Test("full path: login, create item, resolve to the direct URL")
    func fullPath() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            // 1. Login as the bootstrapped admin.
            let tokens: TokenResponse = try await client.execute(
                uri: "/v1/auth/login",
                method: .post,
                headers: jsonHeaders(device: "test-device"),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(!tokens.accessToken.isEmpty)
            #expect(!tokens.refreshToken.isEmpty)
            #expect(tokens.expiresIn == 3600)
            #expect(tokens.user.displayName == "admin")

            // 2. Manually enter an item pointing at the known media URL.
            let item: Item = try await client.execute(
                uri: "/v1/admin/items",
                method: .post,
                headers: jsonHeaders(bearer: tokens.accessToken),
                body: try jsonBody(CreateItemRequest(
                    type: "movie",
                    title: "Big Buck Bunny",
                    sourceId: nil,
                    sourceKey: knownMediaURL,
                    container: "mp4",
                    tmdbId: nil
                ))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(item.type == .movie)
            #expect(item.title == "Big Buck Bunny")

            // 3. Resolve it to a direct, playable location.
            let descriptor: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(item.id)",
                method: .get,
                headers: jsonHeaders(bearer: tokens.accessToken)
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(descriptor.url == knownMediaURL)
            #expect(descriptor.preResolved == true)
            #expect(descriptor.container == "mp4")
        }
    }

    @Test("refresh rotates tokens and invalidates the old refresh token")
    func refreshRotates() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let first: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }

            let second: TokenResponse = try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: first.refreshToken))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(second.accessToken != first.accessToken)
            #expect(second.refreshToken != first.refreshToken)

            // The old refresh token must no longer work.
            try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: first.refreshToken))
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("protected routes reject missing/invalid tokens with the error envelope")
    func protectedRoutesRejectUnauthed() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            // No token.
            try await client.execute(uri: "/v1/resolve/it_whatever", method: .get) { response in
                #expect(response.status == .unauthorized)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .unauthorized)
            }
            // Garbage token.
            try await client.execute(
                uri: "/v1/admin/items", method: .post,
                headers: jsonHeaders(bearer: "not-a-real-token"),
                body: try jsonBody(CreateItemRequest(type: nil, title: "x", sourceId: nil, sourceKey: "https://x", container: nil, tmdbId: nil))
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("login with bad credentials returns unauthorized")
    func badCredentials() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/login", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "wrong"))
            ) { response in
                #expect(response.status == .unauthorized)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .unauthorized)
            }
        }
    }

    @Test("resolving an unknown item returns not_found")
    func resolveUnknownItem() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }

            try await client.execute(
                uri: "/v1/resolve/it_does_not_exist", method: .get,
                headers: jsonHeaders(bearer: tokens.accessToken)
            ) { response in
                #expect(response.status == .notFound)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .notFound)
            }
        }
    }
}
