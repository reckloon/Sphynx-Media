import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Item.updatedAt (client cache diffing)")
struct UpdatedAtTests {

    @Test("projection uses the max of data-change timestamps")
    func maxOfChangeTimes() {
        var record = ItemRecord(
            id: "it_x", type: "movie", title: "X", sourceKey: "k",
            createdAt: 100, updatedAt: 300, identityPinned: false
        )
        record.enrichedAt = 150
        record.markersUpdatedAt = 200  // max is updatedAt (300)
        let expected = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 300))
        #expect(record.toProtocol().updatedAt == expected)

        // When markers are newest, they win.
        record.markersUpdatedAt = 500
        let expected2 = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 500))
        #expect(record.toProtocol().updatedAt == expected2)
    }

    @Test("present at both detail levels")
    func bothDetailLevels() {
        let record = ItemRecord(
            id: "it_y", type: "movie", title: "Y", sourceKey: "k",
            createdAt: 100, updatedAt: 100, identityPinned: false
        )
        #expect(record.toProtocol(full: false).updatedAt != nil)
        #expect(record.toProtocol(full: true).updatedAt != nil)
    }

    @Test("playstate changes do NOT bump Item.updatedAt")
    func playstateExcluded() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "M", sourceId: nil, sourceKey: "https://cdn/m.mkv", container: nil, tmdbId: nil, libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }
            let before = try #require(item.updatedAt)

            // Report progress (per-user playstate) — must NOT change item.updatedAt.
            try await client.execute(
                uri: "/v1/playstate/\(item.id)/progress", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(PlaystateProgressBody(position: 123, paused: false))
            ) { #expect($0.status == .noContent) }

            let after: Item = try await client.execute(
                uri: "/v1/items/\(item.id)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(after.updatedAt == before)          // cache stays valid
            #expect(after.resumePosition == 123)        // resume still tracked
        }
    }
}
