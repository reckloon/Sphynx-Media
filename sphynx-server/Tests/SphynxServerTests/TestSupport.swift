import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import SphynxServer

/// A configuration backed by an in-memory database, for isolated tests.
func testConfiguration(
    adminPassword: String = "test-password",
    markersAccess: String = "readwrite",
    markersStaleAfter: Double = 604_800
) -> ServerConfiguration {
    ServerConfiguration(
        hostname: "127.0.0.1",
        port: 0,
        serverName: "Test Library",
        serverID: "srv_test",
        version: "1.0",
        databasePath: ":memory:",
        adminUsername: "admin",
        adminPassword: adminPassword,
        accessTokenTTL: 3600,
        refreshTokenTTL: 86_400,
        tmdbAPIKey: "",
        enrichmentTTL: 604_800,
        markersAccess: markersAccess,
        markersStaleAfter: markersStaleAfter,
        playstateRetention: 31_536_000,
        maintenanceInterval: 0  // background pass off in tests
    )
}

/// JSON request body as a ByteBuffer.
func jsonBody(_ value: some Encodable) throws -> ByteBuffer {
    ByteBuffer(bytes: try JSONEncoder().encode(value))
}

/// JSON headers, optionally bearer-authenticated.
func jsonHeaders(bearer: String? = nil, device: String? = nil) -> HTTPFields {
    var headers = HTTPFields()
    headers[.contentType] = "application/json"
    if let bearer { headers[.authorization] = "Bearer \(bearer)" }
    if let device, let name = HTTPField.Name("X-Sphynx-Device") { headers[name] = device }
    return headers
}

extension TestResponse {
    /// Decode the response body as a protocol/JSON type.
    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: self.body)
    }
}

/// A non-network HTTP fetcher for tests: serves canned bodies keyed by URL.
struct StubFetcher: HTTPFetching {
    let responses: [String: Data]

    init(_ responses: [String: Data]) { self.responses = responses }

    func getData(url: String, headers: [String: String]) async throws -> Data {
        guard let data = responses[url] else {
            throw SphynxError.notFound("No stubbed response for '\(url)'")
        }
        return data
    }
}

/// A non-network TMDB client for tests. Searches are keyed by lowercased title.
struct StubTMDBClient: TMDBClient {
    var searchResults: [String: [TMDBSearchResult]] = [:]
    var details: [Int: TMDBMovieDetails] = [:]
    // TV stubs
    var tvSearchResults: [String: [TMDBTVSearchResult]] = [:]
    var tvDetailsByID: [Int: TMDBTVDetails] = [:]
    var seasonDetailsByID: [Int: [Int: TMDBSeasonDetails]] = [:]  // tvId → season → details

    func searchMovie(title: String, year: Int?) async throws -> [TMDBSearchResult] {
        searchResults[title.lowercased()] ?? []
    }

    func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        guard let details = details[id] else {
            throw SphynxError.notFound("No stubbed TMDB details for \(id)")
        }
        return details
    }

    func searchTV(title: String) async throws -> [TMDBTVSearchResult] {
        tvSearchResults[title.lowercased()] ?? []
    }

    func tvDetails(id: Int) async throws -> TMDBTVDetails {
        guard let details = tvDetailsByID[id] else {
            throw SphynxError.notFound("No stubbed TMDB TV details for \(id)")
        }
        return details
    }

    func seasonDetails(tvId: Int, season: Int) async throws -> TMDBSeasonDetails {
        guard let details = seasonDetailsByID[tvId]?[season] else {
            throw SphynxError.notFound("No stubbed TMDB season \(tvId)/\(season)")
        }
        return details
    }
}
