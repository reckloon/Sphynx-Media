import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Extensible markers (recap/intro/credits/preview + custom)")
struct MarkerTypesTests {
    private func login(_ client: any TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    private func makeItem(_ client: any TestClientProtocol, _ token: String) async throws -> Item {
        try await client.execute(
            uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
            body: try jsonBody(CreateItemRequest(type: "episode", title: "Ep", sourceId: nil,
                sourceKey: "https://cdn/ep.mkv", container: "mkv", tmdbId: nil,
                libraryId: nil, parentId: nil, year: nil, extra: nil))
        ) { try $0.decoded() }
    }

    @Test("all four well-known segment types round-trip")
    func fourSegments() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let token = try await login(client)
            let item = try await makeItem(client, token)

            let markers = Markers(
                recap: Marker(start: 0, end: 30),
                intro: Marker(start: 30, end: 90),
                credits: Marker(start: 2600),
                preview: Marker(start: 2640, end: 2700)
            )
            let written: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(MarkerContribution(markers: markers, source: "admin"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(written.markers.recap == Marker(start: 0, end: 30))
            #expect(written.markers.preview == Marker(start: 2640, end: 2700))

            // Read back: all four present.
            let read: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(read.markers.recap?.end == 30)
            #expect(read.markers.intro?.start == 30)
            #expect(read.markers.credits?.start == 2600)
            #expect(read.markers.preview?.start == 2640)
            #expect(read.markers.segments.count == 4)
        }
    }

    @Test("a custom (unknown) segment type is stored and served verbatim")
    func customSegment() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let token = try await login(client)
            let item = try await makeItem(client, token)

            let markers = Markers(segments: [
                "intro": Marker(start: 10, end: 40),
                "sponsor": Marker(start: 120, end: 150),  // not a well-known type
            ])
            _ = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .put, headers: jsonHeaders(bearer: token),
                body: try jsonBody(MarkerContribution(markers: markers))
            ) { #expect($0.status == .ok); return try $0.decoded(MarkersInfo.self) }

            let read: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(item.id)/markers", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(read.markers[.intro]?.end == 40)
            #expect(read.markers.segments["sponsor"] == Marker(start: 120, end: 150))
        }
    }
}
