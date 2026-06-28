import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The dashboard overview endpoint: per-library / per-source catalog coverage
/// (items in source vs in DB, indexed vs enriched).
@Suite("Admin overview / catalog counts")
struct OverviewTests {

    @Test("overview reports indexed counts per library and overall")
    func overviewCounts() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let tokens: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }
            let auth = jsonHeaders(bearer: tokens.accessToken)

            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            // Two items in the library; without TMDB they index but never enrich.
            for n in 1...2 {
                _ = try await client.execute(
                    uri: "/v1/admin/items", method: .post, headers: auth,
                    body: try jsonBody(CreateItemRequest(
                        type: "movie", title: "Film \(n)", sourceId: nil,
                        sourceKey: "https://example.com/\(n).mp4", container: "mp4",
                        tmdbId: nil, libraryId: library.id))
                ) { response in #expect(response.status == .ok) }
            }

            let overview: OverviewResponse = try await client.execute(
                uri: "/v1/admin/overview", method: .get, headers: auth
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(overview.indexed == 2)
            #expect(overview.enriched == 0)
            let lib = try #require(overview.libraries.first { $0.id == library.id })
            #expect(lib.indexed == 2)
            #expect(lib.enriched == 0)
        }
    }

    @Test("overview is admin-only")
    func overviewAdminOnly() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }

            // Create a non-admin user and log in as them.
            _ = try await client.execute(
                uri: "/v1/admin/users", method: .post,
                headers: jsonHeaders(bearer: admin.accessToken),
                body: try jsonBody(CreateUserRequest(
                    username: "viewer", password: "pw", displayName: nil,
                    isAdmin: nil, permissions: nil))
            ) { response in #expect(response.status == .ok) }
            let viewer: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "viewer", password: "pw"))
            ) { try $0.decoded() }

            try await client.execute(
                uri: "/v1/admin/overview", method: .get,
                headers: jsonHeaders(bearer: viewer.accessToken)
            ) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
