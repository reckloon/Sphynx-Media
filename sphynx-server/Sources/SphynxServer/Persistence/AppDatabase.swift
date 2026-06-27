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

        return migrator
    }
}
