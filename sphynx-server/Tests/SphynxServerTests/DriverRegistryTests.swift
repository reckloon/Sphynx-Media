import Foundation
import Testing
@testable import SphynxServer

/// The driver framework: registry lookup, required-config validation, and that
/// each driver resolves to a scheme-appropriate, client-fetchable URL. Lean —
/// one case per behaviour that matters for adding backends.
@Suite("Driver registry")
struct DriverRegistryTests {
    private func source(driver: String, config: [String: String] = [:], secrets: [String: String] = [:], baseURL: String? = nil) -> SourceRecord {
        SourceRecord(
            id: "src_test", label: "t", driver: driver, baseURL: baseURL, headersJSON: nil,
            libraryId: nil, manifestURL: nil,
            configJSON: config.isEmpty ? nil : String(data: try! JSONEncoder().encode(config), encoding: .utf8),
            secretsJSON: secrets.isEmpty ? nil : String(data: try! JSONEncoder().encode(secrets), encoding: .utf8),
            createdAt: 0
        )
    }

    @Test("an unknown driver kind is rejected")
    func unknownKind() {
        let factory = DriverFactory(fetcher: StubFetcher([:]))
        #expect(throws: SphynxError.self) {
            _ = try factory.makeDriver(for: source(driver: "nope"))
        }
    }

    @Test("missing required config is reported clearly")
    func missingRequiredConfig() {
        let factory = DriverFactory(fetcher: StubFetcher([:]))
        // webdav requires baseURL; smb requires host + share.
        #expect(throws: SphynxError.self) {
            _ = try factory.makeDriver(for: source(driver: "webdav"))
        }
        #expect(throws: SphynxError.self) {
            _ = try factory.makeDriver(for: source(driver: "smb", config: ["host": "nas"]))  // share missing
        }
    }

    @Test("local reads its root from config.rootPath")
    func localFromConfig() throws {
        let factory = DriverFactory(fetcher: StubFetcher([:]))
        let driver = try factory.makeDriver(for: source(driver: "local", config: ["rootPath": "/media"]))
        let local = try #require(driver as? LocalDriver)
        #expect(local.root == "/media")
    }

    @Test("webdav resolves to https with a Basic auth header from secrets")
    func webdavResolve() async throws {
        let factory = DriverFactory(fetcher: StubFetcher([:]))
        let driver = try factory.makeDriver(for: source(
            driver: "webdav",
            config: ["baseURL": "https://dav.example/remote.php/dav"],
            secrets: ["username": "alice", "password": "s3cret"]
        ))
        let location = try await driver.resolve(ResolveRequest(key: "Movies/Film.mkv", container: "mkv"))
        #expect(location.url == "https://dav.example/remote.php/dav/Movies/Film.mkv")
        let expected = "Basic " + Data("alice:s3cret".utf8).base64EncodedString()
        #expect(location.headers["Authorization"] == expected)
    }

    @Test("smb and ftp resolve to their native schemes")
    func smbAndFtpResolve() async throws {
        let factory = DriverFactory(fetcher: StubFetcher([:]))

        let smb = try factory.makeDriver(for: source(driver: "smb", config: ["host": "nas", "share": "media"]))
        let smbLoc = try await smb.resolve(ResolveRequest(key: "Shows/ep.mkv", container: "mkv"))
        #expect(smbLoc.url == "smb://nas/media/Shows/ep.mkv")

        let ftp = try factory.makeDriver(for: source(driver: "ftp", config: ["host": "ftp.example", "port": "2121"]))
        let ftpLoc = try await ftp.resolve(ResolveRequest(key: "movie.mp4", container: "mp4"))
        #expect(ftpLoc.url == "ftp://ftp.example:2121/movie.mp4")
    }

    @Test("the source API response never carries secrets")
    func responseOmitsSecrets() throws {
        let record = source(driver: "webdav", config: ["baseURL": "https://dav.example"],
                            secrets: ["username": "alice", "password": "s3cret"])
        let json = String(data: try JSONEncoder().encode(SourceResponse(from: record)), encoding: .utf8) ?? ""
        #expect(json.contains("dav.example"))            // non-secret config echoed
        #expect(!json.contains("s3cret"))               // credential value never leaks
        #expect(!json.lowercased().contains("password"))
    }

    @Test("scaffold drivers refuse to list (clear, not a crash)")
    func scaffoldListingNotImplemented() async throws {
        let factory = DriverFactory(fetcher: StubFetcher([:]))
        for src in [source(driver: "webdav", config: ["baseURL": "https://x"]),
                    source(driver: "smb", config: ["host": "h", "share": "s"]),
                    source(driver: "ftp", config: ["host": "h"])] {
            let driver = try factory.makeDriver(for: src)
            await #expect(throws: SphynxError.self) { _ = try await driver.list() }
        }
    }
}
