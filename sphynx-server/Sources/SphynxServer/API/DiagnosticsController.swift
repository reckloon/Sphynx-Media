import Foundation
import GRDB
import Hummingbird

/// Admin-only diagnostics for the web admin page: live parse/enrich **activity**,
/// a recent-**logs** tail, and a read-only **database browser**. All server-local
/// (not part of the client wire protocol), under `/v1/admin/*`, behind the auth
/// gate + an admin check.
struct DiagnosticsController: Sendable {
    let catalog: Catalog
    let diagnostics: DiagnosticsCenter
    let logStore: LogStore

    /// Columns never returned by the DB browser — password hashes, token hashes,
    /// stored credentials, and request headers (which may carry auth).
    static let redactedColumns: Set<String> = [
        "passwordHash", "accessTokenHash", "refreshTokenHash",
        "secretsJSON", "headersJSON",
    ]
    private static let redactedPlaceholder = "•••"

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let admin = group.group("admin")
        admin.get("status", use: status)
        admin.get("overview", use: overview)
        admin.get("logs", use: logs)
        admin.get("db/tables", use: dbTables)
        admin.get("db/query", use: dbQuery)
    }

    @Sendable
    func status(_ request: Request, context: SphynxRequestContext) async throws -> ActivitySnapshot {
        try requireAdmin(context)
        return await diagnostics.snapshot()
    }

    /// Catalog coverage for the always-visible dashboard panel: per-library and
    /// per-source counts of **items in the source** (from the last scan) vs
    /// **items in the DB** (indexed), and how many of the indexed items are
    /// **enriched**. Polled alongside `/status`.
    @Sendable
    func overview(_ request: Request, context: SphynxRequestContext) async throws -> OverviewResponse {
        try requireAdmin(context)
        let libraries = try await catalog.libraries()
        let sources = try await catalog.sources()
        let libCounts = try await catalog.itemCountsByLibrary()
        let srcCounts = try await catalog.itemCountsBySource()
        let typeCounts = try await catalog.itemCountsByType()
        let overall = try await catalog.itemCountsOverall()

        // Most recent scan per source (recentScans is newest-first).
        let scans = await diagnostics.snapshot().scans
        var lastScan: [String: ScanView] = [:]
        for scan in scans where lastScan[scan.sourceId] == nil { lastScan[scan.sourceId] = scan }

        let libraryViews = libraries.map { lib -> LibraryOverview in
            let c = libCounts[lib.id] ?? .init()
            return LibraryOverview(id: lib.id, title: lib.title, kind: lib.kind,
                                   indexed: c.total, enriched: c.enriched)
        }
        let sourceViews = sources.map { src -> SourceOverview in
            let c = srcCounts[src.id] ?? .init()
            let scan = lastScan[src.id]
            return SourceOverview(id: src.id, label: src.label, driver: src.driver,
                                  libraryId: src.libraryId, lastScannedAt: src.lastScannedAt,
                                  inSource: scan?.scanned, lastScanAt: scan?.at,
                                  indexed: c.total, enriched: c.enriched)
        }
        // Break the catalog down by content category, in a stable display order
        // (containers → leaf media → extras); any unknown type sorts to the end.
        let typeOrder = ["collection", "movie", "series", "season", "episode",
                         "trailer", "featurette", "deletedScene", "behindTheScenes"]
        let typeViews = typeCounts
            .map { TypeOverview(type: $0.key, indexed: $0.value.total, enriched: $0.value.enriched) }
            .sorted { a, b in
                let ia = typeOrder.firstIndex(of: a.type) ?? typeOrder.count
                let ib = typeOrder.firstIndex(of: b.type) ?? typeOrder.count
                return ia != ib ? ia < ib : a.type < b.type
            }

        // Items the sources reported on their last scan. Sum over CURRENT sources
        // only (via sourceViews) — the diagnostics scan history also retains scans
        // from deleted/recreated sources, and counting those double-counts inSource.
        let inSourceTotal = sourceViews.reduce(0) { $0 + ($1.inSource ?? 0) }
        return OverviewResponse(
            inSource: inSourceTotal,
            indexed: overall.total,
            enriched: overall.enriched,
            libraries: libraryViews,
            sources: sourceViews,
            byType: typeViews
        )
    }

    @Sendable
    func logs(_ request: Request, context: SphynxRequestContext) async throws -> LogsResponse {
        try requireAdmin(context)
        let query = try request.uri.decodeQuery(as: LogsQuery.self, context: context)
        let limit = min(max(query.limit ?? 200, 1), 1000)
        let lines = logStore.snapshot(after: query.after, limit: limit)
        let filtered = query.level.flatMap { lvl in lines.filter { $0.level == lvl } } ?? lines
        return LogsResponse(lines: filtered, latestSeq: logStore.latestSeq)
    }

    @Sendable
    func dbTables(_ request: Request, context: SphynxRequestContext) async throws -> DBTablesResponse {
        try requireAdmin(context)
        let tables = try await catalog.db.writer.read { db -> [DBTableInfo] in
            let names = try Self.userTables(db)
            return try names.map { name in
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"") ?? 0
                return DBTableInfo(name: name, rowCount: count)
            }
        }
        return DBTablesResponse(tables: tables)
    }

    @Sendable
    func dbQuery(_ request: Request, context: SphynxRequestContext) async throws -> DBTableData {
        try requireAdmin(context)
        let query = try request.uri.decodeQuery(as: DBQuery.self, context: context)
        guard let table = query.table, !table.isEmpty else {
            throw SphynxError.badRequest("table is required")
        }
        let limit = min(max(query.limit ?? 50, 1), 200)
        let offset = max(query.offset ?? 0, 0)

        return try await catalog.db.writer.read { db -> DBTableData in
            // Whitelist against the real table list — never interpolate an
            // unvalidated name into SQL.
            guard try Self.userTables(db).contains(table) else {
                throw SphynxError.notFound("No table '\(table)'")
            }
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
                .compactMap { $0["name"] as String? }

            // Optional search filters. Each clause is added only when the table has
            // the column (whitelisted against the real schema above) and the values
            // are bound parameters — never interpolated — so this stays injection-safe.
            var clauses: [String] = []
            var filterArgs: [DatabaseValueConvertible] = []
            if let tmdbId = query.tmdbId, !tmdbId.isEmpty, columns.contains("tmdbId") {
                clauses.append("tmdbId = ?"); filterArgs.append(tmdbId)
            }
            if let name = query.name, !name.isEmpty, columns.contains("title") {
                clauses.append("title LIKE ? COLLATE NOCASE"); filterArgs.append("%\(name)%")
            }
            let whereSQL = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")

            let total = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM \"\(table)\"\(whereSQL)",
                arguments: StatementArguments(filterArgs)
            ) ?? 0
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM \"\(table)\"\(whereSQL) LIMIT ? OFFSET ?",
                arguments: StatementArguments(filterArgs + [limit, offset])
            )
            let redacted = columns.filter { Self.redactedColumns.contains($0) }
            let data: [[String?]] = rows.map { row in
                columns.map { col in
                    if Self.redactedColumns.contains(col) { return Self.redactedPlaceholder }
                    return Self.display(row[col] as DatabaseValue)
                }
            }
            return DBTableData(table: table, columns: columns, rows: data,
                               total: total, limit: limit, offset: offset,
                               redactedColumns: redacted)
        }
    }

    // MARK: Helpers

    /// User tables only — excludes SQLite/GRDB internal bookkeeping.
    private static func userTables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table'
              AND name NOT LIKE 'sqlite_%'
              AND name NOT LIKE 'grdb_%'
            ORDER BY name
            """)
    }

    /// Render a stored value as a display string (null → nil; blobs summarized).
    private static func display(_ value: DatabaseValue) -> String? {
        switch value.storage {
        case .null: return nil
        case .int64(let i): return String(i)
        case .double(let d): return String(d)
        case .string(let s): return s
        case .blob(let data): return "‹blob \(data.count) bytes›"
        }
    }

    private func requireAdmin(_ context: SphynxRequestContext) throws {
        guard let identity = context.identity else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        guard identity.isAdmin else {
            throw SphynxError.forbidden("Admin role required")
        }
    }
}

// MARK: - DTOs (server-local)

struct LogsQuery: Codable, Sendable {
    var after: Int?
    var limit: Int?
    var level: String?
}

struct LogsResponse: Codable, Sendable, ResponseEncodable {
    var lines: [LogStore.Line]
    var latestSeq: Int
}

struct DBQuery: Codable, Sendable {
    var table: String?
    var limit: Int?
    var offset: Int?
    /// Optional filters (applied only when the table has the matching column):
    /// `tmdbId` exact-matches the `tmdbId` column; `name` is a case-insensitive
    /// substring match on `title`.
    var tmdbId: String?
    var name: String?
}

struct DBTableInfo: Codable, Sendable {
    var name: String
    var rowCount: Int
}

struct DBTablesResponse: Codable, Sendable, ResponseEncodable {
    var tables: [DBTableInfo]
}

struct DBTableData: Codable, Sendable, ResponseEncodable {
    var table: String
    var columns: [String]
    /// Row-major, aligned to `columns`; a null cell is `null`.
    var rows: [[String?]]
    var total: Int
    var limit: Int
    var offset: Int
    /// Columns whose values were replaced with a placeholder (secrets).
    var redactedColumns: [String]
}

/// One library's catalog coverage for the dashboard panel.
struct LibraryOverview: Codable, Sendable {
    var id: String
    var title: String
    var kind: String
    /// Items reconciled into the catalog for this library.
    var indexed: Int
    /// Of those, how many have fetched metadata.
    var enriched: Int
}

/// One source's catalog coverage for the dashboard panel.
struct SourceOverview: Codable, Sendable {
    var id: String
    var label: String
    var driver: String
    var libraryId: String?
    /// Epoch seconds of the last completed scan (nil = never scanned).
    var lastScannedAt: Double?
    /// Items the driver listed on the most recent scan this process has seen
    /// (nil if it hasn't been scanned since the server started).
    var inSource: Int?
    /// Timestamp of that scan (ISO 8601), if any.
    var lastScanAt: String?
    /// Items from this source currently in the catalog.
    var indexed: Int
    /// Of those, how many have fetched metadata.
    var enriched: Int
}

/// One content category's share of the catalog (grouped by item `type`), so the
/// dashboard can break the indexed/enriched totals down by kind.
struct TypeOverview: Codable, Sendable {
    /// The item type: `collection` / `movie` / `series` / `season` / `episode` or
    /// an extras kind (`trailer`, `featurette`, `deletedScene`, `behindTheScenes`).
    var type: String
    /// Items of this type in the catalog.
    var indexed: Int
    /// Of those, how many have fetched metadata (extras never enrich).
    var enriched: Int
}

/// Catalog coverage snapshot for the always-visible dashboard panel.
struct OverviewResponse: Codable, Sendable, ResponseEncodable {
    /// Items the sources reported on their last scan (scanned sources only).
    var inSource: Int
    /// Items currently in the catalog (indexed).
    var indexed: Int
    /// Of the indexed items, how many are enriched.
    var enriched: Int
    var libraries: [LibraryOverview]
    var sources: [SourceOverview]
    /// Indexed/enriched broken down by content category, in display order.
    var byType: [TypeOverview]
}

extension ActivitySnapshot: ResponseEncodable {}
