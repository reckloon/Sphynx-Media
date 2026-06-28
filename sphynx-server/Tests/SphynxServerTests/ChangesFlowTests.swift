import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Incremental changes feed + tombstones")
struct ChangesFlowTests {

    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    private func createLibrary(_ client: any TestClientProtocol, admin: String, title: String) async throws -> String {
        try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateLibraryRequest(title: title, kind: "movies"))
        ) { #expect($0.status == .ok); return try $0.decoded(LibraryResponse.self).id }
    }

    private func createItem(
        _ client: any TestClientProtocol, admin: String, title: String, libraryId: String
    ) async throws -> Item {
        try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
            body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                sourceKey: "https://cdn/\(title).mkv", container: "mkv", tmdbId: nil,
                libraryId: libraryId, parentId: nil, year: nil, extra: nil))
        ) { #expect($0.status == .ok); return try $0.decoded() }
    }

    private func deleteItem(_ client: any TestClientProtocol, admin: String, id: String) async throws {
        try await client.execute(
            uri: "/v1/admin/items/\(id)", method: .delete, headers: jsonHeaders(bearer: admin)
        ) { #expect($0.status == .ok || $0.status == .noContent) }
    }

    @Test("since=0 returns all items; a since after creation returns nothing new")
    func fullThenIncremental() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let lib = try await createLibrary(client, admin: admin, title: "Movies")
            let a = try await createItem(client, admin: admin, title: "A", libraryId: lib)
            let b = try await createItem(client, admin: admin, title: "B", libraryId: lib)

            // Full sync from 0 sees both items and no tombstones.
            let full: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=0", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(Set(full.changes.map(\.id)) == [a.id, b.id])
            #expect(full.tombstones.isEmpty)
            #expect(!full.until.isEmpty)

            // Polling again with the returned `until` as the next `since` yields
            // nothing new (no changes, no deletions).
            let next: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=\(full.until)", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(next.changes.isEmpty)
            #expect(next.tombstones.isEmpty)
        }
    }

    @Test("deleting an item yields a tombstone; the survivor stays in changes")
    func deletionTombstone() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let lib = try await createLibrary(client, admin: admin, title: "Movies")
            let a = try await createItem(client, admin: admin, title: "A", libraryId: lib)
            let b = try await createItem(client, admin: admin, title: "B", libraryId: lib)

            try await deleteItem(client, admin: admin, id: a.id)

            let resp: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=0", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }

            // The deleted item is a tombstone, the survivor remains in changes.
            #expect(resp.tombstones.map(\.id) == [a.id])
            #expect(!resp.tombstones[0].deletedAt.isEmpty)
            #expect(resp.changes.map(\.id) == [b.id])
        }
    }

    @Test("a paginated window has a fixed `until` ceiling — later changes wait for the next window")
    func stableWindowCeiling() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let lib = try await createLibrary(client, admin: admin, title: "Movies")
            let a = try await createItem(client, admin: admin, title: "A", libraryId: lib)
            let b = try await createItem(client, admin: admin, title: "B", libraryId: lib)

            // Open the window (page 1 of 2 with limit=1) — this fixes `until`.
            let p1: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=0&limit=1", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(p1.changes.count == 1)
            #expect(p1.nextCursor != nil)

            // A new item created AFTER the window opened must NOT leak into it.
            let c = try await createItem(client, admin: admin, title: "C", libraryId: lib)

            // Drain the remaining pages of the SAME window via the cursor.
            var collected = Set(p1.changes.map(\.id))
            var cursor = p1.nextCursor
            var lastUntil = p1.until
            while let cur = cursor {
                let pg: ChangesResponse = try await client.execute(
                    uri: "/v1/changes?since=0&limit=1&cursor=\(cur)", method: .get, headers: jsonHeaders(bearer: admin)
                ) { #expect($0.status == .ok); return try $0.decoded() }
                collected.formUnion(pg.changes.map(\.id))
                lastUntil = pg.until
                cursor = pg.nextCursor
            }
            // The window delivered exactly A and B — never C (it changed after `until`).
            #expect(collected == [a.id, b.id])
            #expect(!collected.contains(c.id))
            #expect(lastUntil == p1.until)   // `until` is stable across the window's pages

            // The next window (since = until) is where C surfaces — no gap, no loss.
            let nextWindow: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=\(p1.until)", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(nextWindow.changes.map(\.id) == [c.id])
        }
    }

    @Test("changes are permission-filtered; tombstones are id-only and not filtered")
    func permissionFiltering() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let libA = try await createLibrary(client, admin: admin, title: "Lib A")
            let libB = try await createLibrary(client, admin: admin, title: "Lib B")
            let inA = try await createItem(client, admin: admin, title: "In A", libraryId: libA)
            let inB = try await createItem(client, admin: admin, title: "In B", libraryId: libB)

            // Bob may read only libA (library-scoped grant).
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw",
                    displayName: nil, isAdmin: nil, permissions: ["library.read:\(libA)"]))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            let bobToken = try await login(client, "bob", "pw")

            // Bob's changes feed sees only the item in libA, never libB's.
            let resp: ChangesResponse = try await client.execute(
                uri: "/v1/changes?since=0", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(resp.changes.map(\.id) == [inA.id])
            #expect(!resp.changes.contains { $0.id == inB.id })
        }
    }
}
