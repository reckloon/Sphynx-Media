import Foundation
import GRDB

/// The persisted, runtime-tunable configuration keys — the ones an admin sets via
/// the API/GUI instead of an environment variable. Startup-only keys (host, port,
/// database path), the first-run admin bootstrap, and the TMDB key stay in the
/// environment; everything here is stored in the `setting` table.
enum SettingKey: String, CaseIterable, Sendable {
    case serverName
    case serverID
    case accessTokenTTL
    case refreshTokenTTL
    case enrichmentTTL
    case metadataLanguage
    case markersAccess
    case markersStaleAfter
    case playstateRetention
    case maintenanceInterval
    case avatarMaxBytes
    case passkeyRelyingPartyID
    case passkeyRelyingPartyName
    case passkeyRelyingPartyOrigin
    case webAuthRedirectAllowlist
}

/// Reads and writes persisted settings. The database is the source of truth;
/// environment variables only **seed** it on first run.
struct SettingsStore: Sendable {
    let db: AppDatabase

    /// All stored settings as a key → string map.
    func all() async throws -> [String: String] {
        let records = try await db.writer.read { db in try SettingRecord.fetchAll(db) }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.value) })
    }

    /// Upsert the given settings (only the keys provided are touched).
    func set(_ updates: [String: String]) async throws {
        guard !updates.isEmpty else { return }
        try await db.writer.write { db in
            for (key, value) in updates {
                try db.execute(
                    sql: "INSERT INTO setting(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    arguments: [key, value]
                )
            }
        }
    }
}

extension ServerConfiguration {
    /// The runtime-tunable settings projected from this configuration as strings.
    func runtimeSettings() -> [String: String] {
        [
            SettingKey.serverName.rawValue: serverName,
            SettingKey.serverID.rawValue: serverID,
            SettingKey.accessTokenTTL.rawValue: String(accessTokenTTL),
            SettingKey.refreshTokenTTL.rawValue: String(refreshTokenTTL),
            SettingKey.enrichmentTTL.rawValue: String(enrichmentTTL),
            SettingKey.metadataLanguage.rawValue: metadataLanguage,
            SettingKey.markersAccess.rawValue: markersAccess,
            SettingKey.markersStaleAfter.rawValue: String(markersStaleAfter),
            SettingKey.playstateRetention.rawValue: String(playstateRetention),
            SettingKey.maintenanceInterval.rawValue: String(maintenanceInterval),
            SettingKey.avatarMaxBytes.rawValue: String(avatarMaxBytes),
            SettingKey.passkeyRelyingPartyID.rawValue: passkeyRelyingPartyID,
            SettingKey.passkeyRelyingPartyName.rawValue: passkeyRelyingPartyName,
            SettingKey.passkeyRelyingPartyOrigin.rawValue: passkeyRelyingPartyOrigin,
            SettingKey.webAuthRedirectAllowlist.rawValue: webAuthRedirectAllowlist,
        ]
    }

    /// A copy with the runtime keys present in `settings` overlaid (parsed back to
    /// their types). Unknown keys and unparseable values are ignored.
    func applying(_ settings: [String: String]) -> ServerConfiguration {
        var c = self
        if let v = settings[SettingKey.serverName.rawValue] { c.serverName = v }
        if let v = settings[SettingKey.serverID.rawValue] { c.serverID = v }
        if let v = settings[SettingKey.accessTokenTTL.rawValue], let d = Double(v) { c.accessTokenTTL = d }
        if let v = settings[SettingKey.refreshTokenTTL.rawValue], let d = Double(v) { c.refreshTokenTTL = d }
        if let v = settings[SettingKey.enrichmentTTL.rawValue], let d = Double(v) { c.enrichmentTTL = d }
        if let v = settings[SettingKey.metadataLanguage.rawValue], !v.isEmpty { c.metadataLanguage = v }
        if let v = settings[SettingKey.markersAccess.rawValue] { c.markersAccess = v }
        if let v = settings[SettingKey.markersStaleAfter.rawValue], let d = Double(v) { c.markersStaleAfter = d }
        if let v = settings[SettingKey.playstateRetention.rawValue], let d = Double(v) { c.playstateRetention = d }
        if let v = settings[SettingKey.maintenanceInterval.rawValue], let d = Double(v) { c.maintenanceInterval = d }
        if let v = settings[SettingKey.avatarMaxBytes.rawValue], let i = Int(v) { c.avatarMaxBytes = i }
        if let v = settings[SettingKey.passkeyRelyingPartyID.rawValue] { c.passkeyRelyingPartyID = v }
        if let v = settings[SettingKey.passkeyRelyingPartyName.rawValue] { c.passkeyRelyingPartyName = v }
        if let v = settings[SettingKey.passkeyRelyingPartyOrigin.rawValue] { c.passkeyRelyingPartyOrigin = v }
        if let v = settings[SettingKey.webAuthRedirectAllowlist.rawValue] { c.webAuthRedirectAllowlist = v }
        return c
    }

    /// Produce the **effective** configuration: stored settings win; any
    /// runtime key not yet in the store is seeded from this (env/default-derived)
    /// configuration and persisted. After first run the database is authoritative,
    /// so env vars for these keys no longer take effect (configure via the API).
    func resolvingSettings(store: SettingsStore) async throws -> ServerConfiguration {
        let stored = try await store.all()
        let current = runtimeSettings()
        let seeds = current.filter { stored[$0.key] == nil }
        if !seeds.isEmpty { try await store.set(seeds) }
        return applying(stored.merging(seeds) { existing, _ in existing })
    }
}
