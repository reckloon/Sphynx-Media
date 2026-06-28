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
    let catalog: Catalog
    let resolver: Resolver
    let settings: SettingsStore

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
        ])
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

        // Cache the result on the item so `/v1/resolve` can serve rich `tracks`
        // (languages / codecs / channels + sidecar subtitles) without re-probing.
        if var item = try await catalog.item(id: itemId) {
            let stored = StoredProbe(streams: result.streams, externalSubtitles: result.externalSubtitles,
                                     probedAt: Date().timeIntervalSince1970)
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
