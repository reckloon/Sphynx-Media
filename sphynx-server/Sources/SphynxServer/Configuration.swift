import Foundation

/// Runtime configuration, sourced from environment variables with sensible
/// defaults.
struct ServerConfiguration: Sendable {
    var hostname: String
    var port: Int

    /// Human-facing name reported by `/v1/info`.
    var serverName: String
    /// Stable server identity reported by `/v1/info`.
    var serverID: String
    var version: String

    /// SQLite file path, or ":memory:" for an ephemeral in-memory DB (tests).
    var databasePath: String

    /// Bootstrap admin account, created on first run when no users exist.
    var adminUsername: String
    var adminPassword: String

    /// Access-token lifetime in seconds (short-lived).
    var accessTokenTTL: Double
    /// Refresh-token lifetime in seconds (long-lived, rotating).
    var refreshTokenTTL: Double

    /// TMDB v3 API key. Empty disables identification/enrichment (items stay
    /// skeletons sourced from the manifest).
    var tmdbAPIKey: String
    /// How long server-fetched enrichment (posters, overview, …) stays fresh
    /// before the maintenance pass re-fetches it, in seconds. Default 90 days.
    var enrichmentTTL: Double

    /// Client access to intro/credit markers: "none" | "read" | "readwrite".
    /// Default allows contributions (e.g. a client bridging TheIntroDB).
    var markersAccess: String
    /// Age after which markers are reported `stale: true` so a client refetches
    /// and contributes fresh ones, in seconds. Default 7 days.
    var markersStaleAfter: Double
    /// Retention for per-user playstate; entries untouched for this long are
    /// purged by the maintenance pass, in seconds. Default 365 days.
    var playstateRetention: Double
    /// Maintenance pass interval (re-enrich stale items, purge old playstate), in
    /// seconds. 0 disables the background pass. Default 1 day.
    var maintenanceInterval: Double

    static func fromEnvironment() -> ServerConfiguration {
        let env = ProcessInfo.processInfo.environment
        return ServerConfiguration(
            hostname: env["SPHYNX_HOST"] ?? "0.0.0.0",
            port: env["SPHYNX_PORT"].flatMap(Int.init) ?? 8080,
            serverName: env["SPHYNX_SERVER_NAME"] ?? "Sphynx Reference Server",
            serverID: env["SPHYNX_SERVER_ID"] ?? "srv_reference",
            version: env["SPHYNX_VERSION"] ?? "1.0",
            databasePath: env["SPHYNX_DB_PATH"] ?? "data/sphynx.sqlite",
            adminUsername: env["SPHYNX_ADMIN_USERNAME"] ?? "admin",
            adminPassword: env["SPHYNX_ADMIN_PASSWORD"] ?? "changeme",
            accessTokenTTL: env["SPHYNX_ACCESS_TTL"].flatMap(Double.init) ?? 3600,
            refreshTokenTTL: env["SPHYNX_REFRESH_TTL"].flatMap(Double.init) ?? 2_592_000,
            tmdbAPIKey: env["SPHYNX_TMDB_API_KEY"] ?? "",
            enrichmentTTL: env["SPHYNX_ENRICH_TTL"].flatMap(Double.init) ?? 7_776_000,       // 90 days
            markersAccess: env["SPHYNX_MARKERS_ACCESS"] ?? "readwrite",
            markersStaleAfter: env["SPHYNX_MARKERS_STALE_AFTER"].flatMap(Double.init) ?? 604_800,    // 7 days
            playstateRetention: env["SPHYNX_PLAYSTATE_RETENTION"].flatMap(Double.init) ?? 31_536_000, // 365 days
            maintenanceInterval: env["SPHYNX_MAINTENANCE_INTERVAL"].flatMap(Double.init) ?? 86_400    // 1 day
        )
    }
}
