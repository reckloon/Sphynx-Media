import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("GET /v1/info")
struct InfoEndpointTests {
    @Test("returns 200 with identity and decodes as ServerInfo")
    func returnsServerInfo() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/info", method: .get) { response in
                #expect(response.status == .ok)
                let info: ServerInfo = try response.decoded()
                #expect(info.product == "Sphynx")
                #expect(info.serverName == "Test Library")
                #expect(info.id == "srv_test")
                #expect(info.protocols == ["v1"])
                // The additive event stream is advertised so clients can opt in.
                #expect(info.capabilities.events == true)
                #expect(info.capabilities.playstate == true)
                // The server advertises the Item fields it can populate, and the
                // list is honest: it includes what it fills and omits what it
                // doesn't, so clients can flag unsupported features.
                let fields = info.capabilities.fields
                for present in ["title", "overview", "genres", "cast", "images", "parentId",
                                "collectionId", "tags", "trailers", "sortTitle", "resumePosition"] {
                    #expect(fields.contains(present), "should advertise \(present)")
                }
                for absent in ["criticRating", "chapters"] {
                    #expect(!fields.contains(absent), "must not over-claim \(absent)")
                }
            }
        }
    }

    @Test("is unauthenticated (no bearer token required)")
    func isUnauthenticated() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/info", method: .get) { response in
                #expect(response.status == .ok)
            }
        }
    }
}
