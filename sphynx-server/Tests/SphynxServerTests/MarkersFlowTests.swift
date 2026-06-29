import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Bi-directional markers")
struct MarkersFlowTests {

    /// Log in (admin), create an item, return (client, token, itemId).
    private func withItem(
        markersAccess: String = "readwrite",
        _ body: @Sendable @escaping (any TestClientProtocol, _ token: String, _ itemId: String) async throws -> Void
    ) async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: markersAccess))
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(
                    type: "movie", title: "Big Buck Bunny", sourceId: nil,
                    sourceKey: "https://cdn.example/bbb.mp4", container: "mp4",
                    tmdbId: nil, libraryId: nil, parentId: nil, year: 2008))
            ) { try $0.decoded() }

            try await body(client, token, item.id)
        }
    }

    @Test("info advertises the per-field metadata access policy")
    func advertisesAccess() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/info", method: .get) { response in
                let info: ServerInfo = try response.decoded()
                #expect(info.capabilities.access("markers") == .readWrite)
                #expect(info.capabilities.access("images") == .read)
            }
        }
    }

    @Test("contribute markers, read them back, and see them in /resolve")
    func contributeReadResolve() async throws {
        try await withItem { client, token, itemId in
            // No markers yet.
            try await client.execute(uri: "/v1/items/\(itemId)/markers", method: .get,
                headers: jsonHeaders(bearer: token)) { #expect($0.status == .notFound) }

            // Contribute (as admin → authoritative).
            let contribution = MarkerContribution(
                markers: Markers(intro: Marker(start: 75, end: 145), credits: Marker(start: 9120)),
                source: "theintrodb", confidence: 0.95
            )
            let written: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(itemId)/markers", method: .put,
                headers: jsonHeaders(bearer: token), body: try jsonBody(contribution)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(written.markers.intro == Marker(start: 75, end: 145))
            #expect(written.source == "theintrodb")
            #expect(written.authoritative == true)  // admin contribution

            // Read back.
            let read: MarkersInfo = try await client.execute(
                uri: "/v1/items/\(itemId)/markers", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(read.markers.credits == Marker(start: 9120))

            // Surfaced in the resolve descriptor.
            let descriptor: ResolveDescriptor = try await client.execute(
                uri: "/v1/resolve/\(itemId)", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(descriptor.markers?.intro == Marker(start: 75, end: 145))
        }
    }

    @Test("a read-only server rejects contributions with 403")
    func readOnlyRejectsWrite() async throws {
        try await withItem(markersAccess: "read") { client, token, itemId in
            let contribution = MarkerContribution(markers: Markers(intro: Marker(start: 10, end: 20)))
            try await client.execute(
                uri: "/v1/items/\(itemId)/markers", method: .put,
                headers: jsonHeaders(bearer: token), body: try jsonBody(contribution)
            ) { response in
                #expect(response.status == .forbidden)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .forbidden)
            }
        }
    }

    @Test("a markers=none server does not offer markers")
    func noneNotOffered() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "none"))
        try await app.test(.router) { client in
            // Not advertised.
            try await client.execute(uri: "/v1/info", method: .get) { response in
                let info: ServerInfo = try response.decoded()
                #expect(info.capabilities.access("markers") == .none)
            }
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }
            // Read not offered.
            try await client.execute(uri: "/v1/items/x/markers", method: .get,
                headers: jsonHeaders(bearer: token)) { #expect($0.status == .notFound) }
        }
    }

    @Test("markers require authentication")
    func requiresAuth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/items/x/markers", method: .get) { #expect($0.status == .unauthorized) }
        }
    }
}
