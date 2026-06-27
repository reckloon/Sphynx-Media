import Foundation
import GRDB
import SphynxProtocol

/// The queryable item/source store the API reads from: libraries, items, their
/// identity, and parent/child structure. Backed by SQLite (GRDB).
struct Catalog: Sendable {
    let db: AppDatabase

    // MARK: Libraries

    func createLibrary(title: String, kind: String) async throws -> LibraryRecord {
        let record = LibraryRecord(
            id: Tokens.newID("lib_"),
            title: title,
            kind: kind,
            createdAt: Date().timeIntervalSince1970
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    func libraries() async throws -> [LibraryRecord] {
        try await db.writer.read { db in
            try LibraryRecord.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    func library(id: String) async throws -> LibraryRecord? {
        try await db.writer.read { db in try LibraryRecord.filter(Column("id") == id).fetchOne(db) }
    }

    // MARK: Sources

    func createSource(
        label: String,
        driver: String,
        baseURL: String?,
        headers: [String: String]?,
        libraryId: String?,
        manifestURL: String?,
        config: [String: String]? = nil,
        secrets: [String: String]? = nil
    ) async throws -> SourceRecord {
        let record = SourceRecord(
            id: Tokens.newID("src_"),
            label: label,
            driver: driver,
            baseURL: baseURL,
            headersJSON: Self.encodeStringMap(headers),
            libraryId: libraryId,
            manifestURL: manifestURL,
            configJSON: Self.encodeStringMap(config),
            secretsJSON: Self.encodeStringMap(secrets),
            createdAt: Date().timeIntervalSince1970
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    /// Encode a non-empty string map to JSON text (nil when empty/absent).
    private static func encodeStringMap(_ map: [String: String]?) -> String? {
        guard let map, !map.isEmpty else { return nil }
        return (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func source(id: String) async throws -> SourceRecord? {
        try await db.writer.read { db in try SourceRecord.filter(Column("id") == id).fetchOne(db) }
    }

    func sources() async throws -> [SourceRecord] {
        try await db.writer.read { db in try SourceRecord.order(Column("createdAt")).fetchAll(db) }
    }

    // MARK: Items

    func createItem(
        type: String,
        title: String,
        sourceId: String?,
        sourceKey: String,
        container: String?,
        tmdbId: String?,
        libraryId: String? = nil,
        parentId: String? = nil,
        year: Int? = nil,
        seriesId: String? = nil,
        seriesTitle: String? = nil,
        seasonIndex: Int? = nil,
        episodeIndex: Int? = nil,
        extra: [String: JSONValue]? = nil
    ) async throws -> ItemRecord {
        if let sourceId, try await source(id: sourceId) == nil {
            throw SphynxError.badRequest("No source '\(sourceId)'")
        }
        let now = Date().timeIntervalSince1970
        let extraJSON: String? = try extra.flatMap { value in
            value.isEmpty ? nil : String(data: try JSONEncoder().encode(value), encoding: .utf8)
        }
        let record = ItemRecord(
            id: Tokens.newID("it_"),
            type: type,
            title: title,
            sourceId: sourceId,
            sourceKey: sourceKey,
            container: container,
            tmdbId: tmdbId,
            libraryId: libraryId,
            parentId: parentId,
            year: year,
            createdAt: now,
            updatedAt: now,
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            seasonIndex: seasonIndex,
            episodeIndex: episodeIndex,
            identityPinned: false,
            extraJSON: extraJSON
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    /// Find a series container in a library by exact title (for indexer dedup).
    func seriesItem(libraryId: String, title: String) async throws -> ItemRecord? {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("libraryId") == libraryId && Column("type") == "series" && Column("title") == title)
                .fetchOne(db)
        }
    }

    /// Find a season container under a series by its season number.
    func seasonItem(seriesItemId: String, seasonNumber: Int) async throws -> ItemRecord? {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == seriesItemId && Column("type") == "season" && Column("seasonIndex") == seasonNumber)
                .fetchOne(db)
        }
    }

    /// Count an item's direct children (seasons of a series, episodes of a season).
    func countChildren(parentId: String) async throws -> Int {
        try await db.writer.read { db in
            try ItemRecord.filter(Column("parentId") == parentId).fetchCount(db)
        }
    }

    /// Persist a container's child count.
    func setChildCount(itemId: String, count: Int) async throws {
        try await db.writer.write { db in
            _ = try ItemRecord
                .filter(Column("id") == itemId)
                .updateAll(db, Column("childCount").set(to: count))
        }
    }

    func item(id: String) async throws -> ItemRecord? {
        try await db.writer.read { db in try ItemRecord.filter(Column("id") == id).fetchOne(db) }
    }

    /// The library an item belongs to. Seasons/episodes inherit their series'
    /// library, so walk up the parent chain when the item carries no `libraryId`
    /// of its own. Returns nil for an orphaned/self-contained item.
    func owningLibraryId(of item: ItemRecord) async throws -> String? {
        if let libraryId = item.libraryId { return libraryId }
        var current = item
        var hops = 0
        while let parentId = current.parentId, hops < 8 {
            guard let parent = try await self.item(id: parentId) else { return nil }
            if let libraryId = parent.libraryId { return libraryId }
            current = parent
            hops += 1
        }
        return nil
    }

    /// Top-level items of a library (no parent), ordered stably. Fetches
    /// `limit + 1` so the caller can tell whether another page exists.
    func topLevelItems(libraryId: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("libraryId") == libraryId && Column("parentId") == nil)
                .order(Column("createdAt"), Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Children of a parent item, ordered for display: seasons by season number,
    /// episodes by episode number, falling back to insertion order.
    func childItems(parentId: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == parentId)
                .order(Column("seasonIndex"), Column("episodeIndex"), Column("createdAt"), Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    // MARK: Indexer support

    func itemsBySource(sourceId: String) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord.filter(Column("sourceId") == sourceId).fetchAll(db)
        }
    }

    func allItems() async throws -> [ItemRecord] {
        try await db.writer.read { db in try ItemRecord.fetchAll(db) }
    }

    /// Fetch several items by id, keyed by id (missing ids simply absent).
    func items(ids: [String]) async throws -> [String: ItemRecord] {
        guard !ids.isEmpty else { return [:] }
        let records = try await db.writer.read { db in
            try ItemRecord.filter(ids.contains(Column("id"))).fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func updateItem(_ record: ItemRecord) async throws {
        try await db.writer.write { db in try record.update(db) }
    }

    func deleteItem(id: String) async throws {
        try await db.writer.write { db in _ = try ItemRecord.deleteOne(db, key: id) }
    }
}
