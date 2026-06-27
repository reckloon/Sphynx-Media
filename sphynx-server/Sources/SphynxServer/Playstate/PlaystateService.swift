import Foundation
import GRDB
import SphynxProtocol

/// Per-user resume tracking (§7 / §10). Position is authoritative server-side and
/// strictly row-scoped to the token's subject — a user only ever touches their
/// own rows.
struct PlaystateService: Sendable {
    let db: AppDatabase

    /// Player started: record the initial position.
    func start(userId: String, itemId: String, position: Double) async throws {
        try await upsert(userId: userId, itemId: itemId, position: position)
    }

    /// Periodic progress: update the position.
    func progress(userId: String, itemId: String, position: Double) async throws {
        try await upsert(userId: userId, itemId: itemId, position: position)
    }

    /// Player stopped. On `failed: true` the stored resume point is left
    /// untouched — a misfire (e.g. the playhead never advanced past startup) must
    /// never clobber a good position.
    func stop(userId: String, itemId: String, position: Double, failed: Bool) async throws {
        guard !failed else { return }
        try await upsert(userId: userId, itemId: itemId, position: position)
    }

    /// Read one item's resume state for a user (nil if none stored).
    func get(userId: String, itemId: String) async throws -> PlaystateResponse? {
        let record = try await db.writer.read { db in
            try PlaystateRecord
                .filter(Column("userId") == userId && Column("itemId") == itemId)
                .fetchOne(db)
        }
        return record.map { PlaystateResponse(position: $0.position, updatedAt: Self.iso8601($0.updatedAt)) }
    }

    /// Batch read for several items at once (absent items simply omitted).
    func batch(userId: String, itemIds: [String]) async throws -> [String: PlaystateResponse] {
        guard !itemIds.isEmpty else { return [:] }
        let records = try await db.writer.read { db in
            try PlaystateRecord
                .filter(Column("userId") == userId && itemIds.contains(Column("itemId")))
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.map {
            ($0.itemId, PlaystateResponse(position: $0.position, updatedAt: Self.iso8601($0.updatedAt)))
        })
    }

    /// In-progress entries for a user, most-recently-updated first. Powers the
    /// "continue watching" feed. Returns everything with a stored position > 0 —
    /// the client decides what counts as "finished" and how to present it.
    func recentlyPlayed(userId: String, limit: Int, offset: Int) async throws -> [PlaystateRecord] {
        try await db.writer.read { db in
            try PlaystateRecord
                .filter(Column("userId") == userId && Column("position") > 0)
                .order(Column("updatedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Raw positions for folding `resumePosition` into item responses.
    func positions(userId: String, itemIds: [String]) async throws -> [String: Double] {
        guard !itemIds.isEmpty else { return [:] }
        let records = try await db.writer.read { db in
            try PlaystateRecord
                .filter(Column("userId") == userId && itemIds.contains(Column("itemId")))
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.itemId, $0.position) })
    }

    /// Purge playstate entries last updated before `cutoff` (epoch seconds).
    /// Returns the number removed. Used by the maintenance pass for retention.
    @discardableResult
    func purge(before cutoff: Double) async throws -> Int {
        try await db.writer.write { db in
            try PlaystateRecord.filter(Column("updatedAt") < cutoff).deleteAll(db)
        }
    }

    // MARK: Helpers

    private func upsert(userId: String, itemId: String, position: Double) async throws {
        let record = PlaystateRecord(
            userId: userId, itemId: itemId,
            position: position, updatedAt: Date().timeIntervalSince1970
        )
        // INSERT … ON CONFLICT (userId,itemId) DO UPDATE.
        try await db.writer.write { db in try record.upsert(db) }
    }

    private static func iso8601(_ epoch: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch))
    }
}
