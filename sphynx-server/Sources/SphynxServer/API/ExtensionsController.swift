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
    var blurHashProgress: BackfillProgress? = nil
    /// Live progress of the media-probe background pass.
    var mediaProbeProgress: BackfillProgress? = nil
    /// "Run now" triggers — kick off a one-off background pass. Absent in tests.
    var runBlurHashNow: (@Sendable () async -> Void)? = nil
    var runMediaProbeNow: (@Sendable () async -> Void)? = nil

    /// Settings keys for the media-probe extension (stored alongside runtime
    /// settings; read live so config changes apply without a restart).
    enum Key {
        static let probeEnabled = "ext.mediaProbe.enabled"
        static let probePath = "ext.mediaProbe.ffprobePath"
        /// Background-probe cadence in seconds (fractional allowed); `<= 0`/unset ⇒
        /// manual-only.
        static let probeInterval = "ext.mediaProbe.intervalSeconds"
    }

    /// Settings key for the low-res-images background cadence (seconds, fractional;
    /// `<= 0` ⇒ manual-only; unset ⇒ the maintenance default).
    static let placeholderIntervalKey = "ext.placeholders.intervalSeconds"

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let ext = group.group("admin").group("extensions")
        ext.get(use: list)
        ext.get("media-probe", use: getProbeConfig)
        ext.patch("media-probe", use: updateProbeConfig)
        ext.get("media-probe/probe", use: probe)
        ext.post("media-probe/run", use: runProbePass)
        ext.get("placeholders", use: getPlaceholderConfig)
        ext.patch("placeholders", use: updatePlaceholderConfig)
        ext.post("placeholders/run", use: runPlaceholderPass)
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
        var updates: [String: String] = [:]
        if let raw = body.mode {
            guard let mode = PlaceholderMode(rawValue: raw) else {
                throw SphynxError.badRequest("mode must be one of: url, blurhash, off")
            }
            updates[PlaceholderMode.settingKey] = mode.rawValue
        }
        if let interval = body.intervalSeconds {
            updates[Self.placeholderIntervalKey] = String(try requireInterval(interval))
        }
        if !updates.isEmpty { try await settings.set(updates) }
        return try await placeholderConfig()
    }

    /// Kick off a one-off BlurHash generation pass immediately (the "Run now"
    /// button). Returns the config with fresh progress; the pass continues in the
    /// background. **400** if generation isn't wired (no TMDB / tests).
    @Sendable
    func runPlaceholderPass(_ request: Request, context: SphynxRequestContext) async throws -> PlaceholderConfig {
        try requireAdmin(context)
        guard let trigger = runBlurHashNow else {
            throw SphynxError.badRequest("BlurHash generation isn't available (configure TMDB first).")
        }
        Task { await trigger() }
        return try await placeholderConfig()
    }

    /// The current placeholder mode + interval plus, in `blurhash` mode, the live
    /// backfill progress that drives the Extensions tab's status indicator.
    private func placeholderConfig() async throws -> PlaceholderConfig {
        let mode = try await PlaceholderMode.current(settings)
        let interval = await settings.interval(forKey: Self.placeholderIntervalKey)
        var hashing: BackfillStatus?
        if mode == .blurhash, let snapshot = await blurHashProgress?.snapshot() {
            hashing = BackfillStatus(snapshot)
        }
        return PlaceholderConfig(mode: mode.rawValue, intervalSeconds: interval, hashing: hashing)
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
        if let interval = body.intervalSeconds {
            updates[Key.probeInterval] = String(try requireInterval(interval))
        }
        if !updates.isEmpty { try await settings.set(updates) }
        return try await probeConfig()
    }

    /// Kick off a one-off background probe pass (the "Run now" button) — probes every
    /// not-yet-probed item. **400** when the extension is disabled, ffprobe is
    /// unavailable, or the pass isn't wired (tests).
    @Sendable
    func runProbePass(_ request: Request, context: SphynxRequestContext) async throws -> MediaProbeConfig {
        try requireAdmin(context)
        let cfg = try await probeConfig()
        guard cfg.enabled else {
            throw SphynxError.badRequest("The media-probe extension is disabled. Enable it in Extensions first.")
        }
        guard cfg.resolvedPath != nil else {
            throw SphynxError.badRequest("ffprobe was not found. Install ffmpeg or set its path in the media-probe extension.")
        }
        guard let trigger = runMediaProbeNow else {
            throw SphynxError.badRequest("The media-probe background pass isn't available.")
        }
        Task { await trigger() }
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
        let enabled = all[Key.probeEnabled] == "true"
        let interval = all[Key.probeInterval].flatMap(Double.init)
        var probing: BackfillStatus?
        if enabled, let snapshot = await mediaProbeProgress?.snapshot() { probing = BackfillStatus(snapshot) }
        return MediaProbeConfig(
            enabled: enabled,
            ffprobePath: configuredPath,
            resolvedPath: resolved,
            available: resolved != nil,
            version: version,
            intervalSeconds: interval,
            probing: probing
        )
    }

    /// Validate a background-pass interval (seconds): non-negative; `0` means
    /// manual-only. Sub-second (fractional) values are allowed.
    private func requireInterval(_ v: Double) throws -> Double {
        guard v >= 0, v.isFinite else { throw SphynxError.badRequest("intervalSeconds must be ≥ 0") }
        return v
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
    /// Background-probe cadence in seconds (fractional allowed); 0/absent ⇒ manual-only.
    var intervalSeconds: Double?
    /// Background-probe progress; present only when the extension is enabled.
    var probing: BackfillStatus?
}

struct MediaProbeConfigUpdate: Codable, Sendable {
    var enabled: Bool?
    var ffprobePath: String?
    var intervalSeconds: Double?
}


struct ProbeQuery: Codable, Sendable {
    var itemId: String?
}

struct PlaceholderConfig: Codable, Sendable, ResponseEncodable {
    /// One of `url` | `blurhash` | `off`.
    var mode: String
    /// Background-generation cadence in seconds (fractional allowed); 0/absent ⇒
    /// manual-only; falls back to the maintenance interval when unset.
    var intervalSeconds: Double?
    /// BlurHash backfill progress; present only in `blurhash` mode.
    var hashing: BackfillStatus?
}

struct PlaceholderConfigUpdate: Codable, Sendable {
    var mode: String?
    var intervalSeconds: Double?
}
