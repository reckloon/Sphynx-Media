import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Security regressions")
struct SecurityTests {
    private func login(_ client: any TestClientProtocol, _ user: String, _ pass: String) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: user, password: pass))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }

    @Test("resolve/browse fail closed: a non-admin cannot read an item with no library")
    func unlibrariedItemIsAdminOnly() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let admin = try await login(client, "admin", "test-password")

            // A library-less item (manual entry, self-contained URL).
            let item: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Secret", sourceId: nil,
                    sourceKey: "https://cdn/secret.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            // A normal user, even with the default library.read, must NOT reach it.
            let bob: AdminUserResponse = try await client.execute(
                uri: "/v1/admin/users", method: .post, headers: jsonHeaders(bearer: admin),
                body: try jsonBody(CreateUserRequest(username: "bob", password: "pw", displayName: nil, isAdmin: nil, permissions: nil))
            ) { try $0.decoded() }
            _ = bob
            let bobToken = try await login(client, "bob", "pw")

            try await client.execute(
                uri: "/v1/resolve/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .forbidden) }   // was a credential leak (fail-open)
            try await client.execute(
                uri: "/v1/items/\(item.id)", method: .get, headers: jsonHeaders(bearer: bobToken)
            ) { #expect($0.status == .forbidden) }

            // The admin still resolves it.
            try await client.execute(
                uri: "/v1/resolve/\(item.id)", method: .get, headers: jsonHeaders(bearer: admin)
            ) { #expect($0.status == .ok) }
        }
    }

    @Test("the network fetcher rejects file:// and other non-http schemes")
    func fetcherRejectsFileScheme() async throws {
        let fetcher = URLSessionFetcher()
        await #expect(throws: SphynxError.self) {
            _ = try await fetcher.getData(url: "file:///etc/passwd", headers: [:])
        }
        await #expect(throws: SphynxError.self) {
            _ = try await fetcher.getData(url: "gopher://internal/", headers: [:])
        }
    }

    @Test("the local driver contains resolution within its root (no path traversal)")
    func localDriverPathContainment() async throws {
        let driver = LocalDriver(id: "src_x", root: "/srv/media")
        await #expect(throws: SphynxError.self) {
            _ = try await driver.resolve(ResolveRequest(key: "../../etc/passwd", container: nil))
        }
    }

    @Test("there is no default admin password — an unset one is randomised")
    func noDefaultAdminPassword() async throws {
        // adminPassword "" → bootstrap generates a random password (logged once).
        let app = try await buildApplication(configuration: testConfiguration(adminPassword: ""))
        try await app.test(.router) { client in
            for guess in ["changeme", "", "admin", "password"] {
                try await client.execute(
                    uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                    body: try jsonBody(LoginRequest(username: "admin", password: guess))
                ) { #expect($0.status == .unauthorized) }
            }
        }
    }
}
