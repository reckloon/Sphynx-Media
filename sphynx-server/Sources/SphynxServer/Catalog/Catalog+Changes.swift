import Foundation
import GRDB

/// Incremental sync support (§ changes feed): the items changed since a
/// timestamp plus the deletion tombstones in the same window, backing
/// `GET /v1/changes`.
extension Catalog {
    /// SQL for an item's "last client-rendered change" time: the max of the
    /// per-field change times we track. Playstate lives in its own table and is
    /// intentionally excluded (mirrors `ItemRecord.toProtocol`'s `updatedAt`).
    /// `MAX(...)` ignores NULLs and `updatedAt` is `NOT NULL`, so this is never
    /// NULL.
    private static let changeTimeSQL = "MAX(updatedAt, COALESCE(enrichedAt, 0), COALESCE(markersUpdatedAt, 0))"

    /// Items whose client-rendered data changed strictly after `since`, ordered by
    /// that change time then id (a stable, resumable order). Fetches `limit + 1`
    /// so the caller can tell whether another page exists.
    func changedItems(since: Double, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(sql: "\(Self.changeTimeSQL) > ?", arguments: [since])
                .order(sql: "\(Self.changeTimeSQL), id")
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Deletion tombstones recorded strictly after `since`, oldest first.
    func tombstones(since: Double) async throws -> [TombstoneRecord] {
        try await db.writer.read { db in
            try TombstoneRecord
                .filter(Column("deletedAt") > since)
                .order(Column("deletedAt"), Column("itemId"))
                .fetchAll(db)
        }
    }
}
