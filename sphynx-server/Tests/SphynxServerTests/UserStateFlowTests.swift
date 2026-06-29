import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Per-user state, feeds, sort/filter (M5)")
struct UserStateFlowTests {
    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }
    private func library(_ client: any TestClientProtocol, _ token: String, _ kind: String = "movies") async throws -> String {
        try await client.execute(
            uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(CreateLibraryRequest(title: "Lib", kind: kind))
        ) { try $0.decoded(LibraryResponse.self).id }
    }
    private func item(_ client: any TestClientProtocol, _ token: String, _ title: String, _ lib: String, genres: [String]? = nil) async throws -> Item {
        try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(CreateItemRequest(type: "movie", title: title, sourceId: nil,
                sourceKey: "https://cdn/\(title).mkv", container: "mkv", tmdbId: nil,
                libraryId: lib, parentId: nil, year: nil, extra: nil))
        ) { try $0.decoded() }
    }

    @Test("watched + favorite round-trip, fold into items, and a stop bumps play count")
    func stateAndPlayCount() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await login(client)
            let lib = try await library(client, token)
            let m = try await item(client, token, "Heat", lib)

            // Mark watched + favorite.
            let updated: Item = try await client.execute(
                uri: "/v1/items/\(m.id)/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(watched: true, isFavorite: true))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(updated.watched == true)
            #expect(updated.isFavorite == true)

            // Folded into a fresh read.
            let read: Item = try await client.execute(
                uri: "/v1/items/\(m.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(read.isFavorite == true)

            // In the favorites feed.
            let favs: ItemsResponse = try await client.execute(
                uri: "/v1/home/favorites", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(favs.items.contains { $0.id == m.id })

            // A real stop counts as a play.
            try await client.execute(uri: "/v1/playstate/\(m.id)/start", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStartBody(position: 1))) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/v1/playstate/\(m.id)/stop", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateStopBody(position: 100, failed: false))) { #expect($0.status == .noContent) }
            let afterStop: Item = try await client.execute(
                uri: "/v1/items/\(m.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(afterStop.playCount == 1)
        }
    }

    @Test("per-user rating round-trips, folds in, clears at 0, and rejects out-of-range")
    func userRating() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await login(client)
            let lib = try await library(client, token)
            let m = try await item(client, token, "Heat", lib)

            // Set a rating (0–10); it folds into the response.
            let rated: Item = try await client.execute(
                uri: "/v1/items/\(m.id)/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(rating: 8.5))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(rated.userRating == 8.5)

            // Persisted: a fresh read still carries it.
            let read: Item = try await client.execute(
                uri: "/v1/items/\(m.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(read.userRating == 8.5)

            // 0 clears it (absent ⇒ unrated, not 0).
            let cleared: Item = try await client.execute(
                uri: "/v1/items/\(m.id)/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(rating: 0))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(cleared.userRating == nil)

            // Out of range is a 400.
            try await client.execute(
                uri: "/v1/items/\(m.id)/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(rating: 42))
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("recently-added newest-first; sort by name; unwatched filter")
    func feedsAndSort() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await login(client)
            let lib = try await library(client, token)
            let charlie = try await item(client, token, "Charlie", lib)
            _ = try await item(client, token, "Alpha", lib)
            let bravo = try await item(client, token, "Bravo", lib)

            // Recently added: newest first (Bravo was created last).
            let recent: ItemsResponse = try await client.execute(
                uri: "/v1/home/recent", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(recent.items.first?.id == bravo.id)

            // Sort by name ascending.
            let byName: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)&sort=name&order=asc", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(byName.items.map(\.title) == ["Alpha", "Bravo", "Charlie"])

            // Mark Charlie watched, then filter unwatched.
            try await client.execute(
                uri: "/v1/items/\(charlie.id)/state", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(ItemStateUpdate(watched: true, isFavorite: nil))
            ) { #expect($0.status == .ok) }
            let unwatched: ItemsResponse = try await client.execute(
                uri: "/v1/items?parent=\(lib)&unwatched=true", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(unwatched.items.contains { $0.id == charlie.id } == false)
            #expect(unwatched.items.count == 2)
        }
    }

    @Test("/v1/info advertises the playback report interval")
    func reportInterval() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let info: ServerInfo = try await client.execute(uri: "/v1/info", method: .get) { try $0.decoded() }
            #expect(info.capabilities.playstateReportInterval == 5)
        }
    }
}
