import Foundation
import Hummingbird

/// Hosts the server's **extensions** — optional, self-contained capabilities that
/// live outside the wire protocol, each with its own config and controls. The web
/// admin "Extensions" tab renders one module per entry returned by
/// `GET /v1/admin/extensions`.
///
/// Extensions today:
/// - `diagnostics` — the always-on activity / database / logs tooling
///   (`DiagnosticsController`); listed here so the UI can present it as a module.
/// - `media-probe` — opt-in `ffprobe` track inspection (this controller owns it).
/// - `placeholders` — the low-res image `placeholder` mode (`url`/`blurhash`/`off`);
///   see `PlaceholderMode`. BlurHash generation for every image role + cast face
///   happens lazily in `BlurHashBackfillService`; this controller reports its
///   progress via `GET /v1/admin/extensions/placeholders`.
///
/// All endpoints are admin-only and server-local (`/v1/admin/extensions/*`).
struct ExtensionsController: Sendable {
    let catalog: Catalog
    let resolver: Resolver
    let settings: SettingsStore
    /// Live progress of the low-res-images BlurHash backfill, for the status
    /// indicator. Absent in tests / when the backfill service isn't running.
    var blurHashProgress: BlurHashProgress? = nil

    /// Settings keys for the media-probe extension (stored alongside runtime
    /// settings; read live so config changes apply without a restart).
    enum Key {
        static let probeEnabled = "ext.mediaProbe.enabled"
        static let probePath = "ext.mediaProbe.ffprobePath"
    }

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let ext = group.group("admin").group("extensions")
        ext.get(use: list)
        ext.get("media-probe", use: getProbeConfig)
        ext.patch("media-probe", use: updateProbeConfig)
        ext.get("media-probe/probe", use: probe)
        ext.get("placeholders", use: getPlaceholderConfig)
        ext.patch("placeholders", use: updatePlaceholderConfig)
    }

    // MARK: Registry

    @Sendable
    func list(_ request: Request, context: SphynxRequestContext) async throws -> ExtensionsResponse {
        try requireAdmin(context)
        let cfg = try await probeConfig()
        let placeholderMode = try await PlaceholderMode.current(settings)
        return ExtensionsResponse(extensions: [
            ExtensionInfo(
                id: "diagnostics", name: "Diagnostics",
                description: "Live parse/enrich activity, a read-only database browser, and a server log tail.",
                kind: "builtin", enabled: true, available: true, configurable: false),
            ExtensionInfo(
                id: "media-probe", name: "Media probe",
                description: "Inspect a title's audio, subtitle, and video streams (language, codec, channels) with ffmpeg's ffprobe, plus any sidecar subtitle files.",
                kind: "optional", enabled: cfg.enabled, available: cfg.available, configurable: true),
            ExtensionInfo(
                id: "placeholders", name: "Low-res images",
                description: "How tiles blur up before artwork loads: a tiny image URL, a generated BlurHash, or off. BlurHashes are generated for every image (poster, backdrop, still, banner, cast faces) by a lazy background pass. Transparent logos always use the URL form.",
                kind: "optional", enabled: placeholderMode != .off, available: true, configurable: true),
        ])
    }

    // MARK: Low-res images — config

    @Sendable
    func getPlaceholderConfig(_ request: Request, context: SphynxRequestContext) async throws -> PlaceholderConfig {
        try requireAdmin(context)
        return try await placeholderConfig()
    }

    @Sendable
    func updatePlaceholderConfig(_ request: Request, context: SphynxRequestContext) async throws -> PlaceholderConfig {
        try requireAdmin(context)
        let body = try await request.decode(as: PlaceholderConfigUpdate.self, context: context)
        if let raw = body.mode {
            guard let mode = PlaceholderMode(rawValue: raw) else {
                throw SphynxError.badRequest("mode must be one of: url, blurhash, off")
            }
            try await settings.set([PlaceholderMode.settingKey: mode.rawValue])
        }
        return try await placeholderConfig()
    }

    /// The current placeholder mode plus, in `blurhash` mode, the live backfill
    /// progress that drives the Extensions tab's status indicator.
    private func placeholderConfig() async throws -> PlaceholderConfig {
        let mode = try await PlaceholderMode.current(settings)
        var hashing: BlurHashStatus?
        if mode == .blurhash, let snapshot = await blurHashProgress?.snapshot() {
            hashing = BlurHashStatus(
                running: snapshot.running,
                total: snapshot.total,
                done: snapshot.done,
                lastCompletedAt: snapshot.lastCompletedAt.map {
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))
                })
        }
        return PlaceholderConfig(mode: mode.rawValue, hashing: hashing)
    }

    // MARK: Media probe — config

    @Sendable
    func getProbeConfig(_ request: Request, context: SphynxRequestContext) async throws -> MediaProbeConfig {
        try requireAdmin(context)
        return try await probeConfig()
    }

    @Sendable
    func updateProbeConfig(_ request: Request, context: SphynxRequestContext) async throws -> MediaProbeConfig {
        try requireAdmin(context)
        let body = try await request.decode(as: MediaProbeConfigUpdate.self, context: context)
        var updates: [String: String] = [:]
        if let enabled = body.enabled { updates[Key.probeEnabled] = enabled ? "true" : "false" }
        if let path = body.ffprobePath { updates[Key.probePath] = path }
        if !updates.isEmpty { try await settings.set(updates) }
        return try await probeConfig()
    }

    // MARK: Media probe — run

    @Sendable
    func probe(_ request: Request, context: SphynxRequestContext) async throws -> ProbeResult {
        try requireAdmin(context)
        let query = try request.uri.decodeQuery(as: ProbeQuery.self, context: context)
        guard let itemId = query.itemId, !itemId.isEmpty else {
            throw SphynxError.badRequest("query parameter 'itemId' is required")
        }
        let cfg = try await probeConfig()
        guard cfg.enabled else {
            throw SphynxError.badRequest("The media-probe extension is disabled. Enable it in Extensions first.")
        }
        guard let ffprobePath = cfg.resolvedPath else {
            throw SphynxError.badRequest("ffprobe was not found. Install ffmpeg or set its path in the media-probe extension.")
        }
        // Resolve the item to its direct location, exactly as a player would, then
        // probe that (throws notFound / noMediaSource for bad or container items).
        let descriptor = try await resolver.resolve(itemId: itemId)
        let prober = FFprobeProber(ffprobePath: ffprobePath)
        let result = try await prober.probe(url: descriptor.url, headers: descriptor.headers, itemId: itemId)

        // Cache the result on the item so `/v1/resolve` serves rich `tracks`
        // (languages / codecs / channels + sidecar subtitles) and browse serves
        // `chapters`, all without re-probing.
        if var item = try await catalog.item(id: itemId) {
            let stored = StoredProbe(streams: result.streams, externalSubtitles: result.externalSubtitles,
                                     chapters: result.chapters, probedAt: Date().timeIntervalSince1970)
            if let data = try? JSONEncoder().encode(stored) {
                item.probedTracksJSON = String(data: data, encoding: .utf8)
                try await catalog.updateItem(item)
            }
        }
        return result
    }

    // MARK: Helpers

    private func probeConfig() async throws -> MediaProbeConfig {
        let all = try await settings.all()
        let configuredPath = all[Key.probePath] ?? ""
        let resolved = FFprobeProber.locate(configured: configuredPath)
        var version: String?
        if let resolved { version = await FFprobeProber(ffprobePath: resolved).version() }
        return MediaProbeConfig(
            enabled: all[Key.probeEnabled] == "true",
            ffprobePath: configuredPath,
            resolvedPath: resolved,
            available: resolved != nil,
            version: version
        )
    }

    private func requireAdmin(_ context: SphynxRequestContext) throws {
        guard let identity = context.identity else { throw SphynxError.unauthorized("Not authenticated") }
        guard identity.isAdmin else { throw SphynxError.forbidden("Admin role required") }
    }
}

// MARK: - DTOs (server-local)

struct ExtensionInfo: Codable, Sendable {
    var id: String
    var name: String
    var description: String
    /// `builtin` (always on) | `optional` (toggleable).
    var kind: String
    var enabled: Bool
    /// Whether the extension's prerequisites are met (e.g. ffprobe installed).
    var available: Bool
    var configurable: Bool
}

struct ExtensionsResponse: Codable, Sendable, ResponseEncodable {
    var extensions: [ExtensionInfo]
}

struct MediaProbeConfig: Codable, Sendable, ResponseEncodable {
    var enabled: Bool
    /// The admin-configured path (may be empty → auto-discovered).
    var ffprobePath: String
    /// The path actually in use (configured or discovered); nil if none found.
    var resolvedPath: String?
    var available: Bool
    var version: String?
}

struct MediaProbeConfigUpdate: Codable, Sendable {
    var enabled: Bool?
    var ffprobePath: String?
}


struct ProbeQuery: Codable, Sendable {
    var itemId: String?
}

struct PlaceholderConfig: Codable, Sendable, ResponseEncodable {
    /// One of `url` | `blurhash` | `off`.
    var mode: String
    /// BlurHash backfill progress; present only in `blurhash` mode.
    var hashing: BlurHashStatus?
}

/// Progress of the lazy BlurHash backfill, for the Extensions status indicator.
/// `total`/`done` count images (every role + cast face the current/last pass set out
/// to hash); `running` is true while a pass is in flight.
struct BlurHashStatus: Codable, Sendable {
    var running: Bool
    var total: Int
    var done: Int
    /// RFC 3339 time the last pass finished, if one has.
    var lastCompletedAt: String?
}

struct PlaceholderConfigUpdate: Codable, Sendable {
    var mode: String?
}
