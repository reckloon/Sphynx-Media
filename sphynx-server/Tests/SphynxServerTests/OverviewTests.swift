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

            // The by-category breakdown accounts for the same items by type.
            let movies = try #require(overview.byType.first { $0.type == "movie" })
            #expect(movies.indexed == 2)
            #expect(movies.enriched == 0)
            // The breakdown is exhaustive: its indexed counts sum to the total.
            #expect(overview.byType.reduce(0) { $0 + $1.indexed } == overview.indexed)
            #expect(overview.byType.reduce(0) { $0 + $1.enriched } == overview.enriched)
        }
    }

    @Test("byType breakdown separates enriched categories from never-enriched extras")
    func byTypeBreakdown() async throws {
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

            // A movie and a trailer extra nested under it.
            let movie: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Feature", sourceId: nil,
                    sourceKey: "https://example.com/feature.mp4", container: "mp4", tmdbId: nil,
                    libraryId: library.id))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "trailer", title: "Teaser", sourceId: nil,
                    sourceKey: "https://example.com/teaser.mp4", container: "mp4", tmdbId: nil,
                    libraryId: nil, parentId: movie.id))
            ) { response in #expect(response.status == .ok) }

            let overview: OverviewResponse = try await client.execute(
                uri: "/v1/admin/overview", method: .get, headers: auth
            ) { try $0.decoded() }

            // Display order: containers/leaf media before extras.
            let order = overview.byType.map(\.type)
            #expect(order == ["movie", "trailer"])
            #expect(overview.byType.first { $0.type == "trailer" }?.indexed == 1)
        }
    }

    @Test("permission catalog lists capabilities and scopable libraries")
    func permissionCatalog() async throws {
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

            let catalog: PermissionsCatalogResponse = try await client.execute(
                uri: "/v1/admin/permissions", method: .get, headers: auth
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(catalog.permissions.contains { $0.key == "library.read" && $0.scopable })
            #expect(catalog.permissions.contains { $0.key == "metadata.images.write" && $0.reserved })
            #expect(catalog.libraries.contains { $0.id == library.id })
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
