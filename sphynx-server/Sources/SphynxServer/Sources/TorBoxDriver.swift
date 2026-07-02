import Foundation
import SphynxProtocol

/// TorBox (https://torbox.app) debrid cloud: a user's *ready* torrents, usenet
/// downloads, and web downloads become catalog items, and playback resolves to a
/// short-lived CDN link minted on demand through the TorBox API.
///
/// Modelled on the official `torbox-media-center`, but deliberately stripped down:
/// **no `.strm` files, no local database, no mount.** The Sphynx catalog *is* the
/// index. A source of this kind refreshes on its own `refreshInterval` like every
/// other driver — this driver imposes no floor of its own, so it keeps parity with
/// the rest (see the rate-limit note for why that's safe). As ever, the server
/// moves no bytes: `list()` is a metadata-only walk and `resolve()` only describes
/// *where* the bytes are.
///
/// ## Rate limits
/// Every TorBox endpoint is limited to **300 requests/min per API token** (there
/// is no edge rate limiting). This driver is frugal by construction:
/// - a **scan** costs one `mylist` call per enabled category (≤ 3), and only
///   paginates further for libraries past 1 000 items per category;
/// - a **playback** costs exactly one `requestdl` call.
///
/// Even an aggressive per-source refresh stays far under the ceiling. The
/// separately-throttled *metadata-search* endpoint (where 429s are common) is
/// **not** used — Sphynx does its own TMDB identification/enrichment. The shared
/// `URLSessionFetcher` still backs off and retries on 429/5xx, honouring
/// `Retry-After`, so a brief burst self-heals within the request.
struct TorBoxDriver: SourceDriver {
    let id: String
    /// TorBox API key (account settings → API). Sent as a Bearer header when
    /// listing and as the `token` query param when minting links. The key is a
    /// secret: it is used server-side only and never appears in a resolved URL or
    /// any field returned to a client.
    let apiKey: String
    /// API root, e.g. `https://api.torbox.app/v1/api`. Configurable so a self-host
    /// can point at a proxy/mirror.
    let baseURL: String
    /// Which buckets to index, a subset of `{torrents, usenet, webdl}`.
    let categories: [String]
    /// Seconds a minted CDN link is treated as valid before the client re-resolves.
    /// TorBox opens a link for downloads on roughly an hour's window, so the default
    /// (1 h) keeps links comfortably fresh; lower it if you see expired links.
    let linkTTL: Double
    let fetcher: any HTTPFetching
    /// Fetcher used for `resolve()` only. A playback resolve sits on the client's
    /// critical path — a player typically gives up after ~30–60s — so it must fail
    /// fast with a retryable error rather than ride the patient fetcher's full
    /// backoff ladder (up to ~90s of sleeps), which reads as a dead server (`-1001`)
    /// to the client. `nil` ⇒ use `fetcher` (tests inject one mock for both paths).
    var resolveFetcher: (any HTTPFetching)? = nil

    static let defaultBaseURL = "https://api.torbox.app/v1/api"
    /// The buckets TorBox exposes, in `mylist`/`requestdl` order.
    static let allCategories = ["torrents", "usenet", "webdl"]
    /// `mylist` page size (TorBox's own default) and a safety cap on pages so a
    /// pathological library can't spin forever.
    private static let pageLimit = 1_000
    private static let maxPages = 50

    private var trimmedBase: String {
        baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    }

    private var authHeader: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    // MARK: - Listing

    func list() async throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        for category in categories {
            entries.append(contentsOf: try await listCategory(category))
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    /// One bucket: page through `mylist`, emitting a `SourceEntry` per *ready* media
    /// file. Non-present items (still downloading/queued) and non-media files
    /// (samples, sidecars, archives) are skipped.
    private func listCategory(_ category: String) async throws -> [SourceEntry] {
        var out: [SourceEntry] = []
        var offset = 0

        for _ in 0..<Self.maxPages {
            let url = "\(trimmedBase)/\(category)/mylist?limit=\(Self.pageLimit)&offset=\(offset)"
            let data = try await fetcher.getData(url: url, headers: authHeader)
            let response: TorBoxListResponse
            do {
                response = try Self.decoder.decode(TorBoxListResponse.self, from: data)
            } catch {
                throw SphynxError.badRequest("Malformed TorBox \(category) list: \(error)")
            }

            let items = response.data ?? []
            for item in items {
                // Only items whose bytes are actually present can resolve to a link.
                guard item.downloadPresent ?? item.downloadFinished ?? false,
                      let parentId = item.id else { continue }
                for file in item.files ?? [] {
                    guard let fileId = file.id else { continue }
                    let name = file.shortName ?? Self.lastComponent(file.name) ?? String(fileId)
                    guard let container = LocalDriver.container(for: name),
                          !LocalDriver.isSkippable(name) else { continue }
                    let display = Self.displayPath(itemName: item.name, file: file)
                    var entry = SourceEntry(
                        key: Self.makeKey(category: category, parentId: parentId, fileId: fileId, display: display),
                        container: container, size: file.size)
                    // The key carries an opaque `{parentId}-{fileId}` routing segment
                    // above the real path. The folder-aware parser walks those
                    // ancestors when picking a *series* title, so it would latch onto
                    // the id segment for TV. We sidestep that by classifying the clean
                    // display path here and passing explicit episode hints — the same
                    // contract the HTTP-manifest driver uses. Movies and extras read
                    // only the immediate parent folder, so they parse cleanly from the
                    // key as-is and need no hint.
                    if case let .episode(series, season, episode, episodeTitle, year) = PathParser.parse(display) {
                        entry.type = "episode"
                        entry.seriesTitle = series
                        entry.season = season
                        entry.episode = episode
                        entry.title = episodeTitle
                        entry.year = year
                    }
                    out.append(entry)
                }
            }

            if items.count < Self.pageLimit { break }   // short page → last page
            offset += Self.pageLimit
        }
        return out
    }

    // MARK: - Resolving

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let key = try Self.parseKey(request.key)
        var components = URLComponents(string: "\(trimmedBase)/\(key.category)/requestdl")
        // `requestdl` authenticates by the `token` query param, not the Bearer
        // header. The minted CDN link carries its own signature — the key never
        // leaves the server, so the client gets a tokenless, direct URL.
        components?.queryItems = [
            URLQueryItem(name: "token", value: apiKey),
            URLQueryItem(name: Self.idParam(for: key.category), value: String(key.parentId)),
            URLQueryItem(name: "file_id", value: String(key.fileId)),
        ]
        guard let url = components?.url?.absoluteString else {
            throw SphynxError.badRequest("Could not build TorBox requestdl URL for '\(request.key)'")
        }

        let data = try await (resolveFetcher ?? fetcher).getData(url: url, headers: [:])
        let response: TorBoxLinkResponse
        do {
            response = try Self.decoder.decode(TorBoxLinkResponse.self, from: data)
        } catch {
            throw SphynxError.noMediaSource("Malformed TorBox link response: \(error)")
        }
        guard let link = response.data, !link.isEmpty else {
            let why = response.detail.map { " (\($0))" } ?? ""
            throw SphynxError.noMediaSource("TorBox returned no download link\(why)")
        }
        return ResolvedLocation(
            url: link, headers: [:], container: request.container,
            ttl: linkTTL, terminal: true, candidates: nil)
    }

    // MARK: - Key encoding

    /// `"{category}/{parentId}-{fileId}/{display}"`.
    ///
    /// The opaque id segment (`{parentId}-{fileId}`) sits *above* an always-present
    /// display folder, so the folder-aware `PathParser` keys on the real
    /// release/filename for the title and never mistakes the numeric ids for a
    /// year or a series name. `resolve` reads the ids straight back out of the key —
    /// no second list call.
    static func makeKey(category: String, parentId: Int, fileId: Int, display: String) -> String {
        "\(category)/\(parentId)-\(fileId)/\(display)"
    }

    struct KeyParts: Equatable { var category: String; var parentId: Int; var fileId: Int }

    static func parseKey(_ key: String) throws -> KeyParts {
        let comps = key.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard comps.count >= 2 else { throw SphynxError.badRequest("Malformed TorBox key '\(key)'") }
        let ids = comps[1].split(separator: "-").map(String.init)
        guard ids.count == 2, let parentId = Int(ids[0]), let fileId = Int(ids[1]) else {
            throw SphynxError.badRequest("Malformed TorBox key '\(key)'")
        }
        return KeyParts(category: comps[0], parentId: parentId, fileId: fileId)
    }

    /// A folder-bearing display path for `PathParser`. A multi-file item already
    /// carries folder structure in `file.name`; a single-file item gets a synthetic
    /// folder from the item's release name, so the title is still folder-derived
    /// (the cleanest signal TorBox gives us).
    static func displayPath(itemName: String?, file: TorBoxFile) -> String {
        let name = file.name.map(trimSlashes) ?? ""
        if name.contains("/") { return name }
        let leaf = file.shortName ?? lastComponent(file.name) ?? file.id.map(String.init) ?? "file"
        let release = itemName.map(trimSlashes).flatMap { $0.isEmpty ? nil : $0 } ?? leaf
        // A release name is a single segment; flatten any stray slashes so it
        // can't perturb the key's structure.
        return "\(release.replacingOccurrences(of: "/", with: " "))/\(leaf)"
    }

    /// The `requestdl` id parameter for a bucket (`torrent_id` / `usenet_id` /
    /// `web_id`); torrents is the safe default for an unknown category.
    static func idParam(for category: String) -> String {
        switch category {
        case "usenet": return "usenet_id"
        case "webdl": return "web_id"
        default: return "torrent_id"
        }
    }

    private static func lastComponent(_ path: String?) -> String? {
        guard let path else { return nil }
        return path.split(separator: "/").last.map(String.init)
    }

    private static func trimSlashes(_ s: String) -> String {
        var s = s
        while s.hasPrefix("/") { s.removeFirst() }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Shared decoder: TorBox responses are snake_case.
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Registration

    /// TorBox sources need no non-secret config (the API key is the only required
    /// input, and it's a secret). Optional config: `categories` (comma list, subset
    /// of torrents/usenet/webdl), `baseURL`, `linkTTL` (seconds).
    static let registration = DriverRegistration(kind: "torbox", requiredConfigKeys: []) { context in
        let apiKey = context.secrets["apiKey"] ?? context.secrets["token"] ?? ""
        guard !apiKey.isEmpty else {
            throw SphynxError.badRequest("TorBox source requires an 'apiKey' secret")
        }
        let configured = (context.config["categories"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { allCategories.contains($0) }
        let base = context.config["baseURL"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL
        // Resolve is on the playback critical path: one quick retry, short backoff,
        // then a retryable 429/502 to the client — never a ~90s stall. Only applies
        // when the context carries the real network fetcher; a test mock stays the
        // single fetcher for both paths.
        let quick = (context.fetcher as? URLSessionFetcher).map { patient -> any HTTPFetching in
            var q = patient
            q.maxAttempts = 2
            q.maxBackoff = 3
            return q
        }
        return TorBoxDriver(
            id: context.id,
            apiKey: apiKey,
            baseURL: base,
            categories: configured.isEmpty ? allCategories : configured,
            linkTTL: context.config["linkTTL"].flatMap(Double.init) ?? 3_600,
            fetcher: context.fetcher,
            resolveFetcher: quick)
    }
}

// MARK: - Wire shapes

/// `GET /{category}/mylist` — the user's list of items in a bucket.
struct TorBoxListResponse: Decodable, Sendable {
    var success: Bool?
    var detail: String?
    var data: [TorBoxItem]?
}

/// One torrent / usenet / web download. `downloadPresent` (and the older
/// `downloadFinished`) tell us the bytes are on TorBox and can be linked.
struct TorBoxItem: Decodable, Sendable {
    var id: Int?
    var name: String?
    var downloadPresent: Bool?
    var downloadFinished: Bool?
    var files: [TorBoxFile]?
}

/// One file inside an item. `name` is the full in-item path (may contain folders);
/// `shortName` is just the leaf filename.
struct TorBoxFile: Decodable, Sendable {
    var id: Int?
    var name: String?
    var shortName: String?
    var size: Int?
    var mimetype: String?
}

/// `GET /{category}/requestdl` — `data` is the minted CDN URL string.
struct TorBoxLinkResponse: Decodable, Sendable {
    var success: Bool?
    var detail: String?
    var data: String?
}
