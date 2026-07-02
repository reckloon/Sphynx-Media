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
            #expect(tokens.refreshExpiresIn == 86_400)
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
            #expect(descriptor.terminal == true)
            #expect(descriptor.container == "mp4")
        }
    }

    @Test("refresh rotates tokens; the old token replays idempotently within the grace window")
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
            #expect(first.refreshExpiresIn == 86_400)
            #expect(second.refreshExpiresIn == 86_400)

            // Replaying the just-rotated-away token inside the grace window is
            // idempotent: same current pair, not a 401 (concurrent race / lost
            // response — the client never got `second`).
            let replayed: TokenResponse = try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: first.refreshToken))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(replayed.accessToken == second.accessToken)
            #expect(replayed.refreshToken == second.refreshToken)

            // The replayed pair really is the live one.
            let third: TokenResponse = try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: replayed.refreshToken))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }

            // A token two generations back is dead — the newer rotation closed
            // its grace window.
            try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: first.refreshToken))
            ) { response in
                #expect(response.status == .unauthorized)
            }
            _ = third
        }
    }

    @Test("grace replay is refused once the session is revoked")
    func graceReplayRefusedAfterLogout() async throws {
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
            ) { try $0.decoded() }

            // Sign the session out, then replay the pre-rotation token while its
            // grace window is still open — revocation must win over grace.
            try await client.execute(
                uri: "/v1/auth/logout", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LogoutRequest(refreshToken: second.refreshToken, allDevices: nil))
            ) { response in
                #expect(response.status == .noContent || response.status == .ok)
            }
            try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: first.refreshToken))
            ) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("token TTL settings apply to the next refresh without a restart")
    func ttlSettingsApplyLive() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }
            #expect(tokens.expiresIn == 3600)

            // Change the TTLs through the runtime settings API…
            try await client.execute(
                uri: "/v1/admin/settings", method: .patch,
                headers: jsonHeaders(bearer: tokens.accessToken),
                body: try jsonBody(["accessTokenTTL": 120.0, "refreshTokenTTL": 7200.0])
            ) { response in
                #expect(response.status == .ok)
            }

            // …and the very next refresh mints tokens with the new lifetimes.
            let refreshed: TokenResponse = try await client.execute(
                uri: "/v1/auth/refresh", method: .post,
                headers: jsonHeaders(),
                body: try jsonBody(RefreshRequest(refreshToken: tokens.refreshToken))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(refreshed.expiresIn == 120)
            #expect(refreshed.refreshExpiresIn == 7200)
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
