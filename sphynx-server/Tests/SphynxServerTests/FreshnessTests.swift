import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Freshness & expiry")
struct FreshnessTests {

    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("a non-authoritative client marker is reported stale past the window")
    func clientMarkerGoesStale() async throws {
        // staleAfter = 0 → any client marker is immediately stale.
        let app = try await buildApplication(configuration: testConfiguration(markersStaleAfter: 0))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            // A normal user with the markers grant (so contributions are NON-authoritative).
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil, isAdmin: false, writeGrants: ["markers"]))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await login(client, "bob", "pw")

            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "X", sourceId: nil, sourceKey: "https://cdn/x.mkv", container: nil, tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            // Bob contributes (non-authoritative).
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2)), source: "theintrodb"))
            ) { #expect($0.status == .ok) }

            // Read → server flags it stale, inviting a refresh.
            let info: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(info.authoritative == false)
            #expect(info.stale == true)
        }
    }

    @Test("authoritative (admin) markers are never reported stale")
    func authoritativeNeverStale() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersStaleAfter: 0))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Y", sourceId: nil, sourceKey: "https://cdn/y.mkv", container: nil, tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2))))
            ) { #expect($0.status == .ok) }

            let info: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .get, headers: jsonHeaders(bearer: admin)
            ) { try $0.decoded() }
            #expect(info.authoritative == true)
            #expect(info.stale == false)  // trusted data isn't flagged for refresh
        }
    }

    @Test("fresh markers (within the window) are not stale")
    func freshNotStale() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersStaleAfter: 100_000))
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil, isAdmin: false, writeGrants: ["markers"]))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await login(client, "bob", "pw")
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Z", sourceId: nil, sourceKey: "https://cdn/z.mkv", container: nil, tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }
            try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: bobToken),
                body: try jsonBody(MarkerContribution(markers: Markers(intro: Marker(start: 1, end: 2))))
            ) { _ in }
            let info: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { try $0.decoded() }
            #expect(info.stale == false)
        }
    }

    @Test("playstate purge removes entries older than the cutoff, keeps newer")
    func playstatePurge() async throws {
        let db = try AppDatabase.makeInMemory()
        let playstate = PlaystateService(db: db)
        try await playstate.progress(userId: "u_1", itemId: "it_1", position: 100)

        // Cutoff in the past → nothing purged.
        let removedNone = try await playstate.purge(before: 1)
        #expect(removedNone == 0)
        #expect(try await playstate.get(userId: "u_1", itemId: "it_1") != nil)

        // Cutoff in the future → the entry is expired and purged.
        let future = Date().timeIntervalSince1970 + 1_000
        let removed = try await playstate.purge(before: future)
        #expect(removed == 1)
        #expect(try await playstate.get(userId: "u_1", itemId: "it_1") == nil)
    }
}
