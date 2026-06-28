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
        admin.get("logs", use: logs)
        admin.get("db/tables", use: dbTables)
        admin.get("db/query", use: dbQuery)
    }

    @Sendable
    func status(_ request: Request, context: SphynxRequestContext) async throws -> ActivitySnapshot {
        try requireAdmin(context)
        return await diagnostics.snapshot()
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
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\"") ?? 0
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM \"\(table)\" LIMIT ? OFFSET ?",
                arguments: [limit, offset]
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

extension ActivitySnapshot: ResponseEncodable {}
