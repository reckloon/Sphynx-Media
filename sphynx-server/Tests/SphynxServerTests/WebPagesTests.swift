import Foundation
import Hummingbird
import HummingbirdTesting
import Testing
@testable import SphynxServer

/// The two unauthenticated HTML shells: the admin console and the end-user
/// self-service page.
@Suite("Web pages serve")
struct WebPagesTests {

    @Test("GET /admin serves the admin HTML shell")
    func adminPage() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/admin", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/html") == true)
                let body = String(buffer: response.body)
                #expect(body.contains("Sphynx"))
                #expect(body.contains("data-tab=\"items\""))   // redesigned tabs present
            }
        }
    }

    @Test("GET /user serves the self-service HTML shell")
    func userPage() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/user", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType]?.contains("text/html") == true)
                let body = String(buffer: response.body)
                #expect(body.contains("My account"))
                #expect(body.contains("Reset watch history"))
            }
        }
    }
}
