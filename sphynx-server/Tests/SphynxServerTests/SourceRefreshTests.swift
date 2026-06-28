import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Per-source refresh + GUI TMDB key")
struct SourceRefreshTests {

    @Test("dueSources honors refreshInterval + lastScannedAt; markScanned clears it")
    func dueLogic() async throws {
        let catalog = Catalog(db: try AppDatabase.makeInMemory())
        let lib = try await catalog.createLibrary(title: "L", kind: "movies")
        let s = try await catalog.createSource(
            label: "S", driver: "http", baseURL: nil, headers: nil,
            libraryId: lib.id, manifestURL: "stub://x", refreshInterval: 100)
        let now = 1_000_000.0

        // Never scanned → due now.
        #expect(try await catalog.dueSources(now: now).map(\.id) == [s.id])
        try await catalog.markSourceScanned(id: s.id, at: now)
        // Just scanned → not due until the interval elapses.
        #expect(try await catalog.dueSources(now: now + 50).isEmpty)
        #expect(try await catalog.dueSources(now: now + 100).map(\.id) == [s.id])

        // A manual-only source (interval 0) is never due.
        let m = try await catalog.createSource(
            label: "M", driver: "http", baseURL: nil, headers: nil,
            libraryId: lib.id, manifestURL: "stub://y", refreshInterval: 0)
        #expect(try await catalog.dueSources(now: now + 1_000_000).contains { $0.id == m.id } == false)
    }

    @Test("source API round-trips refreshInterval; TMDB key is GUI-configurable + masked")
    func apiRoundTrip() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            // Create a source with a 30-minute refresh (API is seconds).
            let src: SourceResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateSourceRequest(label: "NAS", driver: "local",
                    config: ["rootPath": "/srv/media"], refreshInterval: 1800))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(src.refreshInterval == 1800)

            let list: SourcesResponse = try await client.execute(
                uri: "/v1/admin/sources", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(list.sources.first { $0.id == src.id }?.refreshInterval == 1800)

            // TMDB key: core Settings config (not an extension). Unset → configured
            // false; set → masked hint, configured true; never echoes the key.
            let before: TMDBKeyStatus = try await client.execute(
                uri: "/v1/admin/tmdb", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(before.configured == false)

            let after: TMDBKeyStatus = try await client.execute(
                uri: "/v1/admin/tmdb", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(TMDBKeyUpdate(apiKey: "abcd1234"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(after.configured == true)
            #expect(after.keyHint == "…1234")

            // It is NOT advertised as an extension.
            let exts: ExtensionsResponse = try await client.execute(
                uri: "/v1/admin/extensions", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(exts.extensions.contains { $0.id == "tmdb" } == false)
        }
    }
}
