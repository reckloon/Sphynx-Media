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

    /// Items whose client-rendered data changed in the window `(since, until]`,
    /// ordered by that change time then id (a stable, resumable order). Fetches
    /// `limit + 1` so the caller can tell whether another page exists.
    ///
    /// The **`until` ceiling is what makes pagination gap-free**: every page of one
    /// `since` window shares the same `until` (carried in the cursor), so an item
    /// that changes *after* the window opened can't shift into an already-passed
    /// offset and be skipped while `since` advances past it.
    func changedItems(since: Double, until: Double, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(sql: "\(Self.changeTimeSQL) > ? AND \(Self.changeTimeSQL) <= ?", arguments: [since, until])
                .order(sql: "\(Self.changeTimeSQL), id")
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Deletion tombstones recorded in the window `(since, until]`, oldest first.
    func tombstones(since: Double, until: Double) async throws -> [TombstoneRecord] {
        try await db.writer.read { db in
            try TombstoneRecord
                .filter(Column("deletedAt") > since && Column("deletedAt") <= until)
                .order(Column("deletedAt"), Column("itemId"))
                .fetchAll(db)
        }
    }
}
