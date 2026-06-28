import Foundation
import GRDB

/// Owns the SQLite connection and schema for the catalog, users, and (later)
/// playstate. WAL mode on disk for concurrent readers; an in-memory variant
/// backs the test suite.
struct AppDatabase: Sendable {
    /// Any GRDB writer: a `DatabasePool` (WAL, on disk) or `DatabaseQueue`
    /// (in-memory, tests). Both are thread-safe and `Sendable`.
    let writer: any DatabaseWriter

    private init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database with WAL journaling (via `DatabasePool`).
    static func makeOnDisk(path: String) throws -> AppDatabase {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        // DatabasePool uses WAL journaling by default.
        let pool = try DatabasePool(path: path, configuration: config)
        return try AppDatabase(pool)
    }

    /// Ephemeral in-memory database (single connection) for tests.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    /// Schema migrations. Append new migrations; never edit a shipped one.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("m1_users_sessions_catalog") { db in
            try db.create(table: "user") { t in
                t.column("id", .text).primaryKey()
                t.column("username", .text).notNull().unique()
                t.column("displayName", .text).notNull()
                t.column("avatarURL", .text)
                t.column("passwordHash", .text).notNull()
                t.column("isAdmin", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "session") { t in
                t.column("id", .text).primaryKey()
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("deviceId", .text).notNull()
                t.column("accessTokenHash", .text).notNull()
                t.column("accessExpiresAt", .double).notNull()
                t.column("refreshTokenHash", .text).notNull()
                t.column("refreshExpiresAt", .double).notNull()
                t.column("revoked", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(indexOn: "session", columns: ["accessTokenHash"])
            try db.create(indexOn: "session", columns: ["refreshTokenHash"])

            try db.create(table: "source") { t in
                t.column("id", .text).primaryKey()
                t.column("label", .text).notNull()
                t.column("driver", .text).notNull()
                t.column("baseURL", .text)
                t.column("headersJSON", .text)
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "item") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("title", .text).notNull()
                t.column("sourceId", .text).references("source", onDelete: .setNull)
                t.column("sourceKey", .text).notNull()
                t.column("container", .text)
                t.column("tmdbId", .text)
                t.column("createdAt", .double).notNull()
            }
        }

        migrator.registerMigration("m2_libraries_and_item_hierarchy") { db in
            try db.create(table: "library") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("createdAt", .double).notNull()
            }

            // A source optionally feeds one library and lists via a manifest URL.
            try db.alter(table: "source") { t in
                t.add(column: "libraryId", .text)
                t.add(column: "manifestURL", .text)
            }

            // Items gain library membership, parent/child links, year, and an
            // updatedAt the indexer touches.
            try db.alter(table: "item") { t in
                t.add(column: "libraryId", .text)
                t.add(column: "parentId", .text)
                t.add(column: "year", .integer)
                t.add(column: "updatedAt", .double).notNull().defaults(to: 0)
            }
            try db.create(indexOn: "item", columns: ["libraryId"])
            try db.create(indexOn: "item", columns: ["parentId"])
            try db.create(indexOn: "item", columns: ["sourceId"])
        }

        migrator.registerMigration("m3_item_enrichment") { db in
            try db.alter(table: "item") { t in
                t.add(column: "overview", .text)
                t.add(column: "genresJSON", .text)
                t.add(column: "communityRating", .double)
                t.add(column: "officialRating", .text)
                t.add(column: "runtime", .double)
                t.add(column: "primaryImage", .text)
                t.add(column: "backdropImage", .text)
                t.add(column: "thumbImage", .text)
                t.add(column: "placeholderURL", .text)
                t.add(column: "castJSON", .text)
                t.add(column: "confidence", .double)
                t.add(column: "enrichedAt", .double)
                t.add(column: "identityPinned", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("m4_playstate") { db in
            try db.create(table: "playstate") { t in
                // Per-user resume, row-scoped to the subject (userId + itemId).
                t.column("userId", .text).notNull()
                t.column("itemId", .text).notNull()
                t.column("position", .double).notNull()
                t.column("updatedAt", .double).notNull()
                t.primaryKey(["userId", "itemId"])
            }
        }

        migrator.registerMigration("m5_item_markers") { db in
            // Intro/credit markers are item-level (shared across a server's
            // clients) and carry provenance. `authoritative` distinguishes
            // server-detected / admin-pinned markers from client contributions.
            try db.alter(table: "item") { t in
                t.add(column: "markersJSON", .text)
                t.add(column: "markersSource", .text)
                t.add(column: "markersConfidence", .double)
                t.add(column: "markersAuthoritative", .boolean).notNull().defaults(to: false)
                t.add(column: "markersContributedBy", .text)
                t.add(column: "markersUpdatedAt", .double)
            }
        }

        migrator.registerMigration("m6_user_write_grants") { db in
            // Per-user metadata write grants (admin-managed), JSON array of field
            // names. Admins implicitly hold all grants.
            try db.alter(table: "user") { t in
                t.add(column: "writeGrantsJSON", .text)
            }
        }

        migrator.registerMigration("m7_item_extra") { db in
            // Open server-defined metadata bag, stored uniformly as JSON text
            // (like genres/cast/markers) and projected onto Item.extra.
            try db.alter(table: "item") { t in
                t.add(column: "extraJSON", .text)
            }
        }

        migrator.registerMigration("m8_item_tv") { db in
            // TV positioning (series → season → episode), denormalised for clients.
            try db.alter(table: "item") { t in
                t.add(column: "seriesId", .text)
                t.add(column: "seriesTitle", .text)
                t.add(column: "seasonIndex", .integer)
                t.add(column: "episodeIndex", .integer)
                t.add(column: "childCount", .integer)
            }
        }

        migrator.registerMigration("m9_source_config_secrets") { db in
            // Generic per-source config + credentials, so non-HTTP drivers (local,
            // webdav, smb, ftp) configure without the HTTP-shaped columns.
            // `configJSON` is driver-specific, non-secret keys (host, port, share,
            // rootPath, …); `secretsJSON` holds credentials that are NEVER returned
            // by the API or written to logs.
            try db.alter(table: "source") { t in
                t.add(column: "configJSON", .text)
                t.add(column: "secretsJSON", .text)
            }
        }

        migrator.registerMigration("m10_user_permissions") { db in
            // Generalize the narrow per-user `writeGrantsJSON` into an open
            // permission set (`permissionsJSON`), stored uniformly as JSON text.
            // The old column is left in place (unused) for simplicity.
            try db.alter(table: "user") { t in
                t.add(column: "permissionsJSON", .text)
            }
            // Backfill existing non-admin users: carry their old write grants
            // forward (markers → metadata.markers.write, images →
            // metadata.images.write) and grant `library.read` so they keep
            // browsing. Admins hold everything implicitly, so they need nothing.
            let rows = try Row.fetchAll(db, sql: "SELECT id, isAdmin, writeGrantsJSON FROM user")
            for row in rows {
                let isAdmin: Bool = row["isAdmin"] ?? false
                if isAdmin { continue }
                var keys: Set<String> = [Permissions.libraryRead]
                if let grantsJSON: String = row["writeGrantsJSON"],
                   let data = grantsJSON.data(using: .utf8),
                   let grants = try? JSONDecoder().decode([String].self, from: data) {
                    for grant in grants {
                        keys.insert(Permissions.writeKeyForField[grant] ?? grant)
                    }
                }
                let json = String(data: try JSONEncoder().encode(keys.sorted()), encoding: .utf8)
                let id: String = row["id"] ?? ""
                try db.execute(sql: "UPDATE user SET permissionsJSON = ? WHERE id = ?",
                               arguments: [json, id])
            }
        }

        migrator.registerMigration("m11_item_locked_fields") { db in
            // Manual-edit persistence: field keys an admin locked against
            // auto-refresh, stored uniformly as JSON text (like genres/extra).
            try db.alter(table: "item") { t in
                t.add(column: "lockedFieldsJSON", .text)
            }
        }

        migrator.registerMigration("m12_item_extended_metadata") { db in
            // Extended TMDB metadata (tagline, studios, directors, externalIds, …),
            // stored uniformly as one JSON blob and projected onto the Item.
            try db.alter(table: "item") { t in
                t.add(column: "extendedJSON", .text)
            }
        }

        migrator.registerMigration("m13_settings") { db in
            // Persisted runtime configuration (server name, TTLs, marker access, …)
            // so the server is configured via the admin API / GUI rather than env
            // vars. Key/value; seeded from env + defaults on first run.
            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("m14_source_library_map") { db in
            // Route a single source's items to different libraries by content type
            // (e.g. movies → a Movies library, TV → a TV library) from ONE scan.
            // JSON `{ "movie": lib_x, "tv": lib_y }`; absent keys fall back to the
            // source's single `libraryId`.
            try db.alter(table: "source") { t in
                t.add(column: "libraryMapJSON", .text)
            }
        }

        migrator.registerMigration("m15_user_item_state") { db in
            // Per-user item state (watched / favorite / play count / last-played),
            // row-scoped to (userId, itemId) like playstate.
            try db.create(table: "useritemstate") { t in
                t.column("userId", .text).notNull()
                t.column("itemId", .text).notNull()
                t.column("watched", .boolean).notNull().defaults(to: false)
                t.column("playCount", .integer).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("lastPlayedAt", .double)
                t.primaryKey(["userId", "itemId"])
            }
        }

        migrator.registerMigration("m16_item_collections_and_metadata") { db in
            // Collection / box-set membership plus M8 metadata fills (logo/banner
            // artwork, trailers, tags, sortTitle), projected onto the canonical Item.
            try db.alter(table: "item") { t in
                t.add(column: "collectionId", .text)
                t.add(column: "collectionTitle", .text)
                t.add(column: "logoImage", .text)
                t.add(column: "bannerImage", .text)
                t.add(column: "trailersJSON", .text)
                t.add(column: "tagsJSON", .text)
                t.add(column: "sortTitle", .text)
            }
        }

        migrator.registerMigration("m17_tombstones") { db in
            // Deletion tombstones for the incremental changes feed: when an item
            // row is removed, its id + deletion time are recorded here so a client
            // polling `GET /v1/changes` can drop it without re-listing the library.
            // Indexed on `deletedAt` for the `since`-windowed query.
            try db.create(table: "tombstone") { t in
                t.primaryKey("itemId", .text)
                t.column("deletedAt", .double).notNull()
            }
            try db.create(indexOn: "tombstone", columns: ["deletedAt"])
        }

        migrator.registerMigration("m18_source_refresh") { db in
            // Per-source auto-refresh: how often to re-scan this source (seconds;
            // 0 = manual only) and when it was last scanned. A background loop
            // re-scans each source when it's due.
            try db.alter(table: "source") { t in
                t.add(column: "refreshInterval", .double).notNull().defaults(to: 0)
                t.add(column: "lastScannedAt", .double)
            }
        }

        migrator.registerMigration("m19_item_probed_tracks") { db in
            // Cached media-probe result (in-container streams + sidecar subtitles),
            // stored uniformly as one JSON blob and folded into the resolve
            // descriptor's `tracks`. Populated by the media-probe extension.
            try db.alter(table: "item") { t in
                t.add(column: "probedTracksJSON", .text)
            }
        }

        migrator.registerMigration("m20_library_collection_threshold") { db in
            // Per-library "group movies into collections" knob: the minimum number
            // of present members a collection needs to surface as a box-set tile.
            // Existing libraries default to 1 (group any non-empty collection — the
            // prior behavior).
            try db.alter(table: "library") { t in
                t.add(column: "collectionThreshold", .integer).notNull().defaults(to: 1)
            }
        }

        migrator.registerMigration("m21_collection_threshold_default_2") { db in
            // Raise the grouping default from 1 to 2 so a library doesn't show a
            // box-set tile for a single owned movie. Only libraries still on the old
            // default (1) are bumped — an admin who deliberately set 1 keeps it.
            // (New libraries get 2 from the record's own default, since GRDB writes
            // the column on insert; this only backfills rows created under m20.)
            try db.execute(sql: "UPDATE library SET collectionThreshold = 2 WHERE collectionThreshold = 1")
        }

        migrator.registerMigration("m22_item_versions") { db in
            // Selectable versions/editions of a movie — the same title backed by more
            // than one file (4K + 1080p, Director's Cut + Theatrical) — stored as one
            // JSON array and projected onto `Item.versions`. The item's own
            // `sourceKey` remains the default (highest-quality) version.
            try db.alter(table: "item") { t in
                t.add(column: "versionsJSON", .text)
            }
        }

        migrator.registerMigration("m23_user_rating") { db in
            // The caller's personal rating (0–10), per (userId, itemId). Distinct
            // from the crowd's communityRating and the press's criticRating.
            try db.alter(table: "useritemstate") { t in
                t.add(column: "rating", .double)
            }
        }

        migrator.registerMigration("m24_passkeys") { db in
            // A registered WebAuthn/passkey credential, owned by a user. We store
            // only the public key (the private key never leaves the authenticator)
            // plus the metadata needed to verify future assertions. `credentialId`
            // is the authenticator's base64url credential id and is the lookup key
            // during a passwordless (discoverable) login, so it's unique + indexed.
            try db.create(table: "passkey_credential") { t in
                t.column("id", .text).primaryKey()
                t.column("userId", .text).notNull()
                    .references("user", onDelete: .cascade)
                t.column("credentialId", .text).notNull().unique()
                t.column("publicKey", .blob).notNull()
                t.column("signCount", .integer).notNull().defaults(to: 0)
                // User-facing nickname so a person can tell their devices apart.
                t.column("label", .text).notNull()
                // Backup eligibility / sync state reported by the authenticator at
                // registration (a synced passkey is "multi-device").
                t.column("backupEligible", .boolean).notNull().defaults(to: false)
                t.column("backedUp", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .double).notNull()
                t.column("lastUsedAt", .double)
            }
            try db.create(indexOn: "passkey_credential", columns: ["userId"])

            // A short-lived, single-use challenge bridging a ceremony's begin and
            // finish calls. For registration it is bound to the enrolling user; for
            // a passwordless login the user is unknown until the assertion is
            // verified, so `userId` is null. Consumed (deleted) on finish; expired
            // rows are swept lazily.
            try db.create(table: "passkey_challenge") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()           // "register" | "authenticate"
                t.column("userId", .text)                   // set for registration only
                t.column("challenge", .blob).notNull()
                t.column("expiresAt", .double).notNull()
                t.column("createdAt", .double).notNull()
            }
            try db.create(indexOn: "passkey_challenge", columns: ["expiresAt"])
        }

        return migrator
    }
}
