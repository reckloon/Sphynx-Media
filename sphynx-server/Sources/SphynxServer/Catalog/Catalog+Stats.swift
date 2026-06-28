import Foundation
import GRDB

/// Aggregate item counts that power the admin dashboard's activity panel:
/// how many items each library / source holds, and how many of those have been
/// enriched. Computed with grouped `COUNT` queries (no row materialization).
extension Catalog {
    /// Total + enriched item counts for one grouping column.
    struct ItemCounts: Sendable {
        /// Items reconciled into the catalog for this group.
        var total: Int = 0
        /// Of those, the ones with metadata fetched (`enrichedAt` set).
        var enriched: Int = 0
    }

    /// Counts grouped by `libraryId` (rows with a null library are omitted).
    func itemCountsByLibrary() async throws -> [String: ItemCounts] {
        try await counts(groupedBy: "libraryId")
    }

    /// Counts grouped by `sourceId` (rows with a null source are omitted).
    func itemCountsBySource() async throws -> [String: ItemCounts] {
        try await counts(groupedBy: "sourceId")
    }

    /// Catalog-wide totals: every item, and how many are enriched.
    func itemCountsOverall() async throws -> ItemCounts {
        try await db.writer.read { db in
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0
            let enriched = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item WHERE enrichedAt IS NOT NULL") ?? 0
            return ItemCounts(total: total, enriched: enriched)
        }
    }

    /// Shared grouped-count query. `column` is a fixed, code-supplied identifier
    /// (`libraryId` / `sourceId`) — never user input — so it is safe to inline.
    private func counts(groupedBy column: String) async throws -> [String: ItemCounts] {
        try await db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT \(column) AS gid,
                       COUNT(*) AS total,
                       COUNT(enrichedAt) AS enriched
                FROM item
                WHERE \(column) IS NOT NULL
                GROUP BY \(column)
                """)
            var result: [String: ItemCounts] = [:]
            for row in rows {
                guard let gid = row["gid"] as String? else { continue }
                result[gid] = ItemCounts(total: row["total"] as Int? ?? 0,
                                         enriched: row["enriched"] as Int? ?? 0)
            }
            return result
        }
    }
}
