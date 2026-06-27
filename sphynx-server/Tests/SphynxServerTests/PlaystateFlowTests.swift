import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Playstate")
struct PlaystateFlowTests {

    /// Log in, create a library + a manual item in it, return (client, token, libraryId, itemId).
    private func withItem(
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ libraryId: String, _ itemId: String) async throws -> Void
    ) async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(
                    type: "movie", title: "Big Buck Bunny", sourceId: nil,
                    sourceKey: "https://cdn.example/bbb.mp4", container: "mp4",
                    tmdbId: nil, libraryId: library.id, parentId: nil, year: 2008))
            ) { try $0.decoded() }

            try await body(client, token, library.id, item.id)
        }
    }

    @Test("info advertises the playstate capability")
    func capabilityAdvertised() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/info", method: .get) { response in
                let info: ServerInfo = try response.decoded()
                #expect(info.capabilities.playstate == true)
            }
        }
    }

    @Test("start → progress → read reflects the latest position")
    func startProgressRead() async throws {
        try await withItem { client, token, _, itemId in
            // No state yet → from start.
            let initial: PlaystateResponse = try await client.execute(
                uri: "/v1/playstate/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(initial.position == 0)

            try await client.execute(
                uri: "/v1/playstate/\(itemId)/start", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStartBody(position: 10))
            ) { #expect($0.status == .noContent) }

            try await client.execute(
                uri: "/v1/playstate/\(itemId)/progress", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateProgressBody(position: 120, paused: false))
            ) { #expect($0.status == .noContent) }

            let state: PlaystateResponse = try await client.execute(
                uri: "/v1/playstate/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(state.position == 120)
            #expect(!state.updatedAt.isEmpty)
        }
    }

    @Test("a failed stop must NOT clobber a good resume point")
    func failedStopPreservesResume() async throws {
        try await withItem { client, token, _, itemId in
            // Establish a good resume point.
            try await client.execute(
                uri: "/v1/playstate/\(itemId)/progress", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateProgressBody(position: 1342.5))
            ) { _ in }

            // A misfire: stop at position 0 with failed=true.
            try await client.execute(
                uri: "/v1/playstate/\(itemId)/stop", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStopBody(position: 0, failed: true))
            ) { #expect($0.status == .noContent) }

            // The good resume point must survive.
            let state: PlaystateResponse = try await client.execute(
                uri: "/v1/playstate/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(state.position == 1342.5)

            // A successful stop does update it.
            try await client.execute(
                uri: "/v1/playstate/\(itemId)/stop", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStopBody(position: 1500, failed: false))
            ) { _ in }
            let after: PlaystateResponse = try await client.execute(
                uri: "/v1/playstate/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(after.position == 1500)
        }
    }

    @Test("resume position is folded into browse items and single-item reads")
    func resumeFoldedIntoItems() async throws {
        try await withItem { client, token, libraryId, itemId in
            try await client.execute(
                uri: "/v1/playstate/\(itemId)/progress", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateProgressBody(position: 777))
            ) { _ in }

            // Browse list.
            let page: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(libraryId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(page.items.first?.resumePosition == 777)

            // Single item.
            let single: Item = try await client.execute(
                uri: "/v1/items/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(single.resumePosition == 777)
        }
    }

    @Test("batch read returns stored states, omitting unknown items")
    func batchRead() async throws {
        try await withItem { client, token, _, itemId in
            try await client.execute(
                uri: "/v1/playstate/\(itemId)/progress", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateProgressBody(position: 55))
            ) { _ in }

            let batch: PlaystateBatchResponse = try await client.execute(
                uri: "/v1/playstate?items=\(itemId),it_missing", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(batch.states[itemId]?.position == 55)
            #expect(batch.states["it_missing"] == nil)
        }
    }

    @Test("continue-watching feed lists in-progress items, most-recent first")
    func continueWatchingFeed() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let library: LibraryResponse = try await client.execute(
                uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateLibraryRequest(title: "Movies", kind: "movies"))
            ) { try $0.decoded() }

            func makeItem(_ title: String) async throws -> String {
                try await client.execute(
                    uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                    body: try jsonBody(CreateItemRequest(
                        type: "movie", title: title, sourceId: nil,
                        sourceKey: "https://cdn/\(title).mp4", container: "mp4",
                        tmdbId: nil, libraryId: library.id, parentId: nil, year: nil))
                ) { try $0.decoded(Item.self).id }
            }
            let a = try await makeItem("A")
            let b = try await makeItem("B")
            let c = try await makeItem("C")  // never played → must not appear

            // Play A first, then B → B is the more recent.
            try await client.execute(uri: "/v1/playstate/\(a)/progress", method: .post,
                headers: jsonHeaders(bearer: token), body: try jsonBody(PlaystateProgressBody(position: 100))) { _ in }
            try await client.execute(uri: "/v1/playstate/\(b)/progress", method: .post,
                headers: jsonHeaders(bearer: token), body: try jsonBody(PlaystateProgressBody(position: 200))) { _ in }

            let feed: ItemsResponse = try await client.execute(
                uri: "/v1/home/continue", method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }

            #expect(feed.items.map(\.id) == [b, a])  // most-recent first
            #expect(feed.items.first?.resumePosition == 200)
            #expect(feed.items.last?.resumePosition == 100)
            #expect(!feed.items.contains { $0.id == c })  // unplayed item absent
        }
    }

    @Test("continue-watching requires authentication")
    func continueRequiresAuth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/home/continue", method: .get) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("playstate requires authentication")
    func requiresAuth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/playstate/it_x", method: .get) { #expect($0.status == .unauthorized) }
        }
    }
}
