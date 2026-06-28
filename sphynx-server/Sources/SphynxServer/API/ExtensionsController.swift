import Foundation
import Hummingbird

/// Hosts the server's **extensions** — optional, self-contained capabilities that
/// live outside the wire protocol, each with its own config and controls. The web
/// admin "Extensions" tab renders one module per entry returned by
/// `GET /v1/admin/extensions`.
///
/// Two extensions today:
/// - `diagnostics` — the always-on activity / database / logs tooling
///   (`DiagnosticsController`); listed here so the UI can present it as a module.
/// - `media-probe` — opt-in `ffprobe` track inspection (this controller owns it).
///
/// All endpoints are admin-only and server-local (`/v1/admin/extensions/*`).
struct ExtensionsController: Sendable {
    let resolver: Resolver
    let settings: SettingsStore

    /// Settings keys for the media-probe extension (stored alongside runtime
    /// settings; read live so config changes apply without a restart).
    enum Key {
        static let probeEnabled = "ext.mediaProbe.enabled"
        static let probePath = "ext.mediaProbe.ffprobePath"
        /// The TMDB v3 API key — configured in the GUI; seeded once from
        /// `SPHYNX_TMDB_API_KEY`. Read at boot to build the enrichment client, so a
        /// change applies on the next restart.
        static let tmdbAPIKey = "ext.tmdb.apiKey"
    }

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let ext = group.group("admin").group("extensions")
        ext.get(use: list)
        ext.get("media-probe", use: getProbeConfig)
        ext.patch("media-probe", use: updateProbeConfig)
        ext.get("media-probe/probe", use: probe)
        ext.get("tmdb", use: getTMDBConfig)
        ext.patch("tmdb", use: updateTMDBConfig)
    }

    // MARK: Registry

    @Sendable
    func list(_ request: Request, context: SphynxRequestContext) async throws -> ExtensionsResponse {
        try requireAdmin(context)
        let cfg = try await probeConfig()
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
                id: "tmdb", name: "Metadata (TMDB)",
                description: "The TMDB API key used to identify and enrich your library (posters, overviews, cast). Set it here instead of an environment variable.",
                kind: "optional", enabled: try await tmdbConfig().configured, available: true, configurable: true),
        ])
    }

    // MARK: TMDB metadata — config

    @Sendable
    func getTMDBConfig(_ request: Request, context: SphynxRequestContext) async throws -> TMDBExtConfig {
        try requireAdmin(context)
        return try await tmdbConfig()
    }

    @Sendable
    func updateTMDBConfig(_ request: Request, context: SphynxRequestContext) async throws -> TMDBExtConfig {
        try requireAdmin(context)
        let body = try await request.decode(as: TMDBExtUpdate.self, context: context)
        if let key = body.apiKey { try await settings.set([Key.tmdbAPIKey: key.trimmingCharacters(in: .whitespaces)]) }
        return try await tmdbConfig()
    }

    /// Masked view of the TMDB key: whether one is set + a short hint, never the
    /// full value.
    private func tmdbConfig() async throws -> TMDBExtConfig {
        let key = (try await settings.all())[Key.tmdbAPIKey] ?? ""
        let hint = key.count >= 4 ? "…" + String(key.suffix(4)) : (key.isEmpty ? nil : "set")
        return TMDBExtConfig(configured: !key.isEmpty, keyHint: hint, appliesOnRestart: true)
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
        return try await prober.probe(url: descriptor.url, headers: descriptor.headers, itemId: itemId)
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

/// Masked TMDB-key view: never returns the full key.
struct TMDBExtConfig: Codable, Sendable, ResponseEncodable {
    var configured: Bool
    /// A short, non-secret hint (e.g. `…1b87`); nil when unset.
    var keyHint: String?
    /// A changed key takes effect on the next server restart.
    var appliesOnRestart: Bool
}

struct TMDBExtUpdate: Codable, Sendable {
    var apiKey: String?
}

struct ProbeQuery: Codable, Sendable {
    var itemId: String?
}
