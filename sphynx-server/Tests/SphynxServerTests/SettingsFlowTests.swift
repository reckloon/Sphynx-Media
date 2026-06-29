import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Persisted settings (configure via API, not env)")
struct SettingsFlowTests {
    private func login(_ client: any TestClientProtocol, _ user: String = "admin", _ pass: String = "test-password") async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("settings are seeded from config on first run and editable, persisting")
    func seedAndUpdate() async throws {
        let app = try await buildApplication(configuration: testConfiguration(markersAccess: "readwrite"))
        try await app.test(.router) { client in
            let token = try await login(client)

            // First run seeded the store from the (env/default-derived) config.
            let seeded: SettingsResponse = try await client.execute(
                uri: "/v1/admin/settings", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(seeded.serverName == "Test Library")
            #expect(seeded.markersAccess == "readwrite")
            #expect(seeded.enrichmentTTL == 604_800)

            // Edit a subset.
            let updated: SettingsResponse = try await client.execute(
                uri: "/v1/admin/settings", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(UpdateSettingsRequest(serverName: "Will's Library", enrichmentTTL: 1234, markersAccess: "read"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(updated.serverName == "Will's Library")
            #expect(updated.markersAccess == "read")
            #expect(updated.enrichmentTTL == 1234)
            #expect(updated.serverID == "srv_test")  // untouched key unchanged

            // Persisted: a fresh GET reflects the edits.
            let reread: SettingsResponse = try await client.execute(
                uri: "/v1/admin/settings", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reread.serverName == "Will's Library")
            #expect(reread.markersAccess == "read")
        }
    }

    @Test("the web settings page is served at /admin")
    func webPageServed() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/admin", method: .get) { response in
                #expect(response.status == .ok)
                let body = String(buffer: response.body)
                #expect(body.contains("<!DOCTYPE html>"))
                #expect(body.contains("Libraries"))            // tab present
                #expect(body.contains("Sources"))              // tab present
                #expect(body.contains("Users &amp; permissions")) // users tab
                #expect(body.contains("/v1/admin/settings"))   // settings API
                #expect(body.contains("/v1/admin/sources"))    // sources API
                #expect(body.contains("/v1/admin/users"))      // users API
                #expect(body.contains("libraryMap"))           // maps movie+tv libraries
            }
        }
    }

    @Test("invalid markersAccess is rejected; non-admins can't read settings")
    func validationAndAccess() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client)

            try await client.execute(
                uri: "/v1/admin/settings", method: .patch, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(UpdateSettingsRequest(markersAccess: "bogus"))
            ) { #expect($0.status == .badRequest) }

            // A normal user can't touch settings.
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil, isAdmin: nil, permissions: nil))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await login(client, "bob", "pw")
            try await client.execute(
                uri: "/v1/admin/settings", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .forbidden) }
        }
    }
}
