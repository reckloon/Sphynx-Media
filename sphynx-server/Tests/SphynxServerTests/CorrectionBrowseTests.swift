import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The raw item-correction browse endpoint (`GET /v1/admin/items`) and the
/// diagnostics DB-browser search filters.
@Suite("Correction browse + DB search")
struct CorrectionBrowseTests {

    private func adminToken(_ client: any TestClientProtocol) async throws -> String {
        let t: TokenResponse = try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded() }
        return t.accessToken
    }

    @Test("raw browse lists a library's top level and an item's children")
    func rawBrowseHierarchy() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            // A standalone movie at top level.
            _ = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Solo", sourceId: nil,
                    sourceKey: "https://x/s.mp4", container: "mp4", tmdbId: nil, libraryId: lib.id))
            ) { #expect($0.status == .ok) }
            // A container with a child (the child must NOT appear at top level).
            let parent: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "series", title: "Show", sourceId: nil,
                    sourceKey: "show-container", container: nil, tmdbId: nil, libraryId: lib.id))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "episode", title: "Ep1", sourceId: nil,
                    sourceKey: "https://x/e1.mp4", container: "mp4", tmdbId: nil,
                    libraryId: nil, parentId: parent.id))
            ) { #expect($0.status == .ok) }

            // Top level = the standalone movie + the container, but not the episode.
            let top: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/items?parent=\(lib.id)", method: .get, headers: auth
            ) { response in #expect(response.status == .ok); return try response.decoded() }
            let titles = Set(top.items.map(\.title))
            #expect(titles.contains("Solo"))
            #expect(titles.contains("Show"))
            #expect(!titles.contains("Ep1"))

            // Descending into the container yields its child.
            let kids: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/items?parent=\(parent.id)", method: .get, headers: auth
            ) { try $0.decoded() }
            #expect(kids.items.map(\.title) == ["Ep1"])
        }
    }

    @Test("raw browse is gated by metadata.edit, not the admin role")
    func rawBrowsePermission() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            // A viewer with only library.read cannot browse for correction.
            let viewer: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: auth,
                body: try jsonBody(CreateUserRequest(username: "viewer", password: "pw",
                    displayName: nil, isAdmin: nil, permissions: ["library.read"]))
            ) { try $0.decoded() }
            let viewerTok: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "viewer", password: "pw"))
            ) { try $0.decoded() }
            try await client.execute(
                uri: "/v1/admin/items?parent=\(lib.id)", method: .get,
                headers: jsonHeaders(bearer: viewerTok.accessToken)
            ) { #expect($0.status == .forbidden) }

            // Granting metadata.edit lets the same user browse.
            _ = try await client.execute(
                uri: "/v1/admin/users/\(viewer.id)/permissions", method: .put, headers: auth,
                body: try jsonBody(SetPermissionsRequest(permissions: ["library.read", "metadata.edit"]))
            ) { #expect($0.status == .ok) }
            let editorTok: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "viewer", password: "pw"))
            ) { try $0.decoded() }
            try await client.execute(
                uri: "/v1/admin/items?parent=\(lib.id)", method: .get,
                headers: jsonHeaders(bearer: editorTok.accessToken)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("admin items search spans libraries; needs-attention excludes extras")
    func searchAndNeedsAttention() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            for (title, tmdb) in [("The Matrix", "603"), ("Matrix Reloaded", "604"), ("Inception", "27205")] {
                _ = try await client.execute(
                    uri: "/v1/admin/items", method: .post, headers: auth,
                    body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                        sourceKey: "https://x/\(tmdb).mp4", container: "mp4", tmdbId: tmdb, libraryId: lib.id))
                ) { #expect($0.status == .ok) }
            }
            // An extra (never enriches) — must be hidden from "needs metadata".
            _ = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: auth,
                body: try jsonBody(CreateItemRequest(type: "deletedScene", title: "Deleted Bit", sourceId: nil,
                    sourceKey: "https://x/del.mp4", container: "mp4", tmdbId: nil, libraryId: lib.id))
            ) { #expect($0.status == .ok) }

            // Catalog-wide title search — no parent needed.
            let found: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/items?search=matrix", method: .get, headers: auth
            ) { #expect($0.status == .ok); return try $0.decoded() }
            let foundTitles = Set(found.items.map(\.title))
            #expect(foundTitles == ["The Matrix", "Matrix Reloaded"])

            // Needs-metadata: the manually-created movies are unenriched, the extra is excluded.
            let needs: AdminItemsResponse = try await client.execute(
                uri: "/v1/admin/items?needsAttention=true", method: .get, headers: auth
            ) { try $0.decoded() }
            let needTitles = Set(needs.items.map(\.title))
            #expect(needTitles.contains("Inception"))
            #expect(needTitles.contains("The Matrix"))
            #expect(!needTitles.contains("Deleted Bit"))
        }
    }

    @Test("DB browser filters by tmdbId and by name")
    func dbSearch() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let auth = jsonHeaders(bearer: try await adminToken(client))
            let lib: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: auth,
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }
            for (title, tmdb) in [("The Matrix", "603"), ("Matrix Reloaded", "604"), ("Inception", "27205")] {
                _ = try await client.execute(
                    uri: "/v1/admin/items", method: .post, headers: auth,
                    body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                        sourceKey: "https://x/\(tmdb).mp4", container: "mp4", tmdbId: tmdb, libraryId: lib.id))
                ) { #expect($0.status == .ok) }
            }

            // Exact tmdbId.
            let byTmdb: DBTableData = try await client.execute(
                uri: "/v1/admin/db/query?table=item&tmdbId=27205", method: .get, headers: auth
            ) { response in #expect(response.status == .ok); return try response.decoded() }
            #expect(byTmdb.total == 1)

            // Case-insensitive name substring.
            let byName: DBTableData = try await client.execute(
                uri: "/v1/admin/db/query?table=item&name=matrix", method: .get, headers: auth
            ) { try $0.decoded() }
            #expect(byName.total == 2)
        }
    }
}
