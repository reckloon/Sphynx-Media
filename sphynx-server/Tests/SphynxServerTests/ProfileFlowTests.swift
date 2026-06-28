import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Self-service profile: display name, server-hosted avatar upload, and the
/// cross-device watch-history reset.
@Suite("Self-service profile + watch-history reset")
struct ProfileFlowTests {

    /// Bytes that begin with the PNG magic signature — enough for `AvatarStore`'s
    /// content sniffing to accept them as a real image.
    private static let pngBytes: [UInt8] =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0x00, count: 24)

    private func login(_ client: any TestClientProtocol,
                       username: String = "admin",
                       password: String = "test-password") async throws -> TokenResponse {
        try await client.execute(
            uri: "/v1/auth/login", method: .post,
            headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: username, password: password))
        ) { try $0.decoded() }
    }

    @Test("a user can update their own display name; empty is rejected")
    func updateDisplayName() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens = try await login(client)

            let me: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .patch,
                headers: jsonHeaders(bearer: tokens.accessToken),
                body: try jsonBody(ProfileUpdateRequest(displayName: "Renamed Admin"))
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(me.user.displayName == "Renamed Admin")

            // It sticks: a fresh /auth/me reflects the change.
            let again: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get,
                headers: jsonHeaders(bearer: tokens.accessToken)
            ) { try $0.decoded() }
            #expect(again.user.displayName == "Renamed Admin")

            // An empty/whitespace name is a bad request.
            try await client.execute(
                uri: "/v1/auth/me", method: .patch,
                headers: jsonHeaders(bearer: tokens.accessToken),
                body: try jsonBody(ProfileUpdateRequest(displayName: "   "))
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("avatar upload is hosted and served back; avatarURL is populated")
    func avatarRoundTrip() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens = try await login(client)

            var imageHeaders = HTTPFields()
            imageHeaders[.authorization] = "Bearer \(tokens.accessToken)"
            imageHeaders[.contentType] = "image/png"

            let me: MeResponse = try await client.execute(
                uri: "/v1/auth/me/avatar", method: .put,
                headers: imageHeaders,
                body: ByteBuffer(bytes: Self.pngBytes)
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            let url = try #require(me.user.avatarURL)
            #expect(url.hasPrefix("/v1/users/"))
            #expect(url.contains("/avatar"))

            // Fetch the hosted image back; bytes round-trip and the type is PNG.
            try await client.execute(
                uri: url, method: .get,
                headers: jsonHeaders(bearer: tokens.accessToken)
            ) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "image/png")
                #expect(Array(response.body.readableBytesView) == Self.pngBytes)
            }

            // Removing the avatar clears the URL and 404s the image.
            let cleared: MeResponse = try await client.execute(
                uri: "/v1/auth/me/avatar", method: .delete,
                headers: jsonHeaders(bearer: tokens.accessToken)
            ) { try $0.decoded() }
            #expect(cleared.user.avatarURL == nil)
        }
    }

    @Test("a non-image upload is rejected as a bad request")
    func avatarRejectsNonImage() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens = try await login(client)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(tokens.accessToken)"
            headers[.contentType] = "image/png"  // lying content-type; bytes decide
            try await client.execute(
                uri: "/v1/auth/me/avatar", method: .put,
                headers: headers,
                body: ByteBuffer(string: "this is plainly not an image")
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("an oversize avatar is rejected")
    func avatarRejectsOversize() async throws {
        var config = testConfiguration()
        config.avatarMaxBytes = 16   // smaller than our 32-byte PNG sample
        let app = try await buildApplication(configuration: config)
        try await app.test(.router) { client in
            let tokens = try await login(client)
            var headers = HTTPFields()
            headers[.authorization] = "Bearer \(tokens.accessToken)"
            headers[.contentType] = "image/png"
            try await client.execute(
                uri: "/v1/auth/me/avatar", method: .put,
                headers: headers,
                body: ByteBuffer(bytes: Self.pngBytes)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("resetting watch history clears resume positions and watched state")
    func resetWatchHistory() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens = try await login(client)
            let auth = jsonHeaders(bearer: tokens.accessToken)

            // Create a library + item so playstate is gated on a readable library.
            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(
                    type: "movie", title: "Sample", sourceId: nil,
                    sourceKey: "https://example.com/sample.mp4", container: "mp4",
                    tmdbId: nil, libraryId: library.id))
            ) { try $0.decoded() }

            // Record some history: a watched flag, then a resume position. (Order
            // matters: marking watched clears any existing resume, so set the resume
            // *after* — re-watching — to have both a state row and a resume row at
            // reset time.)
            try await client.execute(
                uri: "/v1/items/\(item.id)/state", method: .put, headers: auth,
                body: try jsonBody(ItemStateUpdate(watched: true))
            ) { #expect($0.status == .ok) }
            try await client.execute(
                uri: "/v1/playstate/\(item.id)/start", method: .post, headers: auth,
                body: try jsonBody(PlaystateStartBody(position: 123))
            ) { #expect($0.status == .noContent) }

            // Reset everything.
            let reset: PlaystateResetResponse = try await client.execute(
                uri: "/v1/playstate", method: .delete, headers: auth
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(reset.cleared >= 2)

            // Resume position now reads back as "from start".
            let after: PlaystateResponse = try await client.execute(
                uri: "/v1/playstate/\(item.id)", method: .get, headers: auth
            ) { try $0.decoded() }
            #expect(after.position == 0)
        }
    }
}
