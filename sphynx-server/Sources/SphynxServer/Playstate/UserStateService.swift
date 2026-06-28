import Foundation
import GRDB
import SphynxProtocol

/// Per-user item state — watched, favorite, play count, last-played — row-scoped
/// to the authenticated subject (a user only ever touches their own rows). Mirrors
/// `PlaystateService`; kept separate so frequent progress reports don't churn this
/// table (play count + last-played update only on a real stop).
struct UserStateService: Sendable {
    let db: AppDatabase

    /// Apply an explicit user action (watched / favorite); only non-nil fields
    /// change. Returns the resulting state.
    @discardableResult
    func update(userId: String, itemId: String, watched: Bool?, isFavorite: Bool?) async throws -> UserStateRecord {
        try await db.writer.write { db in
            var record = try Self.fetch(db, userId: userId, itemId: itemId)
                ?? UserStateRecord.empty(userId: userId, itemId: itemId)
            if let watched { record.watched = watched }
            if let isFavorite { record.isFavorite = isFavorite }
            try record.save(db)
            return record
        }
    }

    /// Record a completed play: bump the play count and last-played time.
    /// Returns the resulting state.
    @discardableResult
    func recordPlay(userId: String, itemId: String, at now: Double = Date().timeIntervalSince1970) async throws -> UserStateRecord {
        try await db.writer.write { db in
            var record = try Self.fetch(db, userId: userId, itemId: itemId)
                ?? UserStateRecord.empty(userId: userId, itemId: itemId)
            record.playCount += 1
            record.lastPlayedAt = now
            try record.save(db)
            return record
        }
    }

    /// The state for one item, or nil if nothing is recorded.
    func get(userId: String, itemId: String) async throws -> UserStateRecord? {
        try await db.writer.read { db in try Self.fetch(db, userId: userId, itemId: itemId) }
    }

    /// States for several items, keyed by item id (missing items simply absent).
    func states(userId: String, itemIds: [String]) async throws -> [String: UserStateRecord] {
        guard !itemIds.isEmpty else { return [:] }
        let records = try await db.writer.read { db in
            try UserStateRecord
                .filter(Column("userId") == userId && itemIds.contains(Column("itemId")))
                .fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.itemId, $0) })
    }

    /// The user's favourited item ids, most-recently-played first. Fetches
    /// `limit + 1` so the caller can tell whether another page exists.
    func favoriteItemIds(userId: String, limit: Int, offset: Int) async throws -> [String] {
        try await db.writer.read { db in
            try UserStateRecord
                .filter(Column("userId") == userId && Column("isFavorite") == true)
                .order(Column("lastPlayedAt").desc, Column("itemId"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
                .map(\.itemId)
        }
    }

    /// All of the user's watched rows (watched == true), each carrying
    /// `lastPlayedAt`. Drives "next up" — the next unwatched episode of a show
    /// you're partway through — which is merged into the Continue Watching row.
    func watchedStates(userId: String) async throws -> [UserStateRecord] {
        try await db.writer.read { db in
            try UserStateRecord
                .filter(Column("userId") == userId && Column("watched") == true)
                .fetchAll(db)
        }
    }

    /// Item ids the user has marked watched (for an "unwatched" filter).
    func watchedItemIds(userId: String) async throws -> Set<String> {
        let ids = try await db.writer.read { db in
            try UserStateRecord
                .filter(Column("userId") == userId && Column("watched") == true)
                .fetchAll(db)
                .map(\.itemId)
        }
        return Set(ids)
    }

    /// Fold a user's state onto an item projection. Only "positive" facts are
    /// attached (watched/favorite when true, play count when > 0), keeping browse
    /// payloads lean; absence reads as unwatched / not-favorite / zero.
    static func fold(_ state: UserStateRecord?, into item: inout Item) {
        guard let state else { return }
        if state.watched { item.watched = true }
        if state.isFavorite { item.isFavorite = true }
        if state.playCount > 0 { item.playCount = state.playCount }
        if let last = state.lastPlayedAt {
            item.lastPlayedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: last))
        }
    }

    private static func fetch(_ db: Database, userId: String, itemId: String) throws -> UserStateRecord? {
        try UserStateRecord
            .filter(Column("userId") == userId && Column("itemId") == itemId)
            .fetchOne(db)
    }
}
