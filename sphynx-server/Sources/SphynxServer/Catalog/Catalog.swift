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
        manifestURL: String?
    ) async throws -> SourceRecord {
        let headersJSON: String? = try headers.flatMap { dict in
            String(data: try JSONEncoder().encode(dict), encoding: .utf8)
        }
        let record = SourceRecord(
            id: Tokens.newID("src_"),
            label: label,
            driver: driver,
            baseURL: baseURL,
            headersJSON: headersJSON,
            libraryId: libraryId,
            manifestURL: manifestURL,
            createdAt: Date().timeIntervalSince1970
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
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
            identityPinned: false,
            extraJSON: extraJSON
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    func item(id: String) async throws -> ItemRecord? {
        try await db.writer.read { db in try ItemRecord.filter(Column("id") == id).fetchOne(db) }
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

    /// Children of a parent item (season → episodes, etc.).
    func childItems(parentId: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == parentId)
                .order(Column("createdAt"), Column("id"))
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
