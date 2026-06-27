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
