import Foundation
import SphynxProtocol

/// The v1 reference driver: media reachable over plain HTTP(S).
///
/// - `list()` enumerates entries from the source's JSON **manifest** (metadata,
///   not media bytes).
/// - `resolve()` hands back the direct URL (joining the source's base URL when
///   the item key is relative) plus the source's required request headers. It
///   marks the descriptor `preResolved` — a direct, fetchable location the client
///   streams itself. No media bytes ever pass through the server.
struct HTTPDriver: SourceDriver {
    let id: String
    /// Optional base URL for relative item keys; nil means keys are absolute.
    let baseURL: String?
    /// Headers the client must send when fetching (also used to fetch the manifest).
    let headers: [String: String]
    /// Validity window for the descriptor; nil = no expiry (a plain URL).
    let ttl: Double?
    /// URL of the JSON manifest listing entries; nil means nothing to enumerate.
    let manifestURL: String?
    let fetcher: any HTTPFetching

    func list() async throws -> [SourceEntry] {
        guard let manifestURL else { return [] }
        let data = try await fetcher.getData(url: manifestURL, headers: headers)
        let manifest: SourceManifest
        do {
            manifest = try JSONDecoder().decode(SourceManifest.self, from: data)
        } catch {
            throw SphynxError.badRequest("Malformed source manifest: \(error)")
        }
        return manifest.items.map {
            SourceEntry(
                key: $0.key, title: $0.title, type: $0.type, container: $0.container,
                year: $0.year, size: $0.size,
                seriesTitle: $0.seriesTitle, season: $0.season, episode: $0.episode
            )
        }
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let url = Self.directURL(key: request.key, baseURL: baseURL)
        return ResolvedLocation(
            url: url,
            headers: headers,
            container: request.container,
            ttl: ttl,
            preResolved: true,
            candidates: nil
        )
    }

    /// Absolute keys pass through; relative keys join onto the base URL.
    static func directURL(key: String, baseURL: String?) -> String {
        if key.hasPrefix("http://") || key.hasPrefix("https://") {
            return key
        }
        guard let baseURL, !baseURL.isEmpty else { return key }
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let trimmedKey = key.hasPrefix("/") ? String(key.dropFirst()) : key
        return "\(trimmedBase)/\(trimmedKey)"
    }
}

/// The JSON manifest an HTTP source is listed from. A deliberately simple,
/// documented shape: a list of entries the indexer turns into catalog items.
struct SourceManifest: Codable, Sendable {
    var items: [ManifestEntry]
}

struct ManifestEntry: Codable, Sendable {
    /// Key the driver resolves into a direct URL (relative to the source base, or absolute).
    var key: String
    var title: String?
    var type: String?
    var container: String?
    var year: Int?
    var size: Int?
    // Optional TV hints; episodes are otherwise detected from the key (S01E02…).
    var seriesTitle: String?
    var season: Int?
    var episode: Int?
}

/// Builds a concrete driver for a source record. The one place that knows the
/// mapping from driver-kind strings to driver types.
struct DriverFactory: Sendable {
    let fetcher: any HTTPFetching

    init(fetcher: any HTTPFetching = URLSessionFetcher()) {
        self.fetcher = fetcher
    }

    func makeDriver(for source: SourceRecord) throws -> any SourceDriver {
        switch source.driver {
        case "http", "https":
            return HTTPDriver(
                id: source.id,
                baseURL: source.baseURL,
                headers: source.headers(),
                ttl: nil,
                manifestURL: source.manifestURL,
                fetcher: fetcher
            )
        case "local":
            // The local root is configured via the source's `baseURL` field.
            guard let root = source.baseURL, !root.isEmpty else {
                throw SphynxError.badRequest("A 'local' source needs a root path (set baseURL)")
            }
            return LocalDriver(id: source.id, root: root)
        default:
            throw SphynxError.noMediaSource("Unsupported source driver '\(source.driver)'")
        }
    }

    /// Driver for self-contained items whose key is an absolute URL (no source).
    func inlineHTTPDriver() -> HTTPDriver {
        HTTPDriver(id: "inline", baseURL: nil, headers: [:], ttl: nil, manifestURL: nil, fetcher: fetcher)
    }
}
