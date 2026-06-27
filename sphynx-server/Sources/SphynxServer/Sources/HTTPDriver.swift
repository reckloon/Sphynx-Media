import Foundation
import SphynxProtocol

/// The v1 reference driver: media reachable over plain HTTP(S).
///
/// - `list()` enumerates entries from the source's JSON **manifest** (metadata,
///   not media bytes).
/// - `resolve()` hands back the direct URL (joining the source's base URL when
///   the item key is relative) plus the source's required request headers. It
///   marks the descriptor `terminal` — the driver's final, fetchable location the
///   client streams itself. No media bytes ever pass through the server.
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
            terminal: true,
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

extension HTTPDriver {
    /// Reachable over plain HTTP(S). `baseURL`/`manifestURL` come from `config`
    /// (falling back to the legacy columns); request headers act as the secret
    /// and are never echoed by the API.
    static let registration = DriverRegistration(kind: "http", requiredConfigKeys: []) { context in
        HTTPDriver(
            id: context.id,
            baseURL: context.config["baseURL"] ?? context.baseURL,
            headers: context.headers,
            ttl: nil,
            manifestURL: context.config["manifestURL"] ?? context.manifestURL,
            fetcher: context.fetcher
        )
    }
}
