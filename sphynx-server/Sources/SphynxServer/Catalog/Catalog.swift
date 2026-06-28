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

    /// Update a library's editable fields (only non-nil arguments are applied).
    func updateLibrary(id: String, title: String?, kind: String?) async throws -> LibraryRecord {
        let updated: LibraryRecord? = try await db.writer.write { db in
            guard var lib = try LibraryRecord.filter(Column("id") == id).fetchOne(db) else { return nil }
            if let title, !title.isEmpty { lib.title = title }
            if let kind { lib.kind = kind }
            try lib.update(db)
            return lib
        }
        guard let updated else { throw SphynxError.notFound("No library '\(id)'") }
        return updated
    }

    /// Delete a library and **cascade**: every item it holds (the whole tree), then
    /// unbind it from any source that feeds it — deleting a source only if that
    /// leaves it feeding no library at all (a source that also feeds another
    /// library survives, with this library removed from its routing).
    func deleteLibrary(id: String) async throws {
        let existed: Bool = try await db.writer.write { db in
            guard try LibraryRecord.filter(Column("id") == id).fetchCount(db) > 0 else { return false }
            // Items carry their resolved libraryId, so this removes the whole tree.
            try ItemRecord.filter(Column("libraryId") == id).deleteAll(db)

            for var source in try SourceRecord.fetchAll(db) {
                var changed = false
                if source.libraryId == id { source.libraryId = nil; changed = true }
                let map = source.libraryMap()
                let pruned = map.filter { $0.value != id }
                if pruned.count != map.count {
                    source.libraryMapJSON = pruned.isEmpty ? nil : Self.encodeStringMap(pruned)
                    changed = true
                }
                guard changed else { continue }
                if source.feedsLibraries().isEmpty {
                    try SourceRecord.deleteOne(db, key: source.id)
                } else {
                    try source.update(db)
                }
            }
            _ = try LibraryRecord.deleteOne(db, key: id)
            return true
        }
        guard existed else { throw SphynxError.notFound("No library '\(id)'") }
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
        secrets: [String: String]? = nil,
        libraryMap: [String: String]? = nil
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
            libraryMapJSON: Self.encodeStringMap(libraryMap),
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

    /// Update a source's editable fields (only non-nil arguments are applied).
    /// `config`/`secrets`/`headers` replace the stored maps wholesale when given.
    func updateSource(
        id: String,
        label: String?,
        baseURL: String?,
        headers: [String: String]?,
        manifestURL: String?,
        libraryId: String?,
        config: [String: String]?,
        secrets: [String: String]?,
        libraryMap: [String: String]?
    ) async throws -> SourceRecord {
        let updated: SourceRecord? = try await db.writer.write { db in
            guard var s = try SourceRecord.filter(Column("id") == id).fetchOne(db) else { return nil }
            if let label, !label.isEmpty { s.label = label }
            if let baseURL { s.baseURL = baseURL }
            if let headers { s.headersJSON = Self.encodeStringMap(headers) }
            if let manifestURL { s.manifestURL = manifestURL }
            if let libraryId { s.libraryId = libraryId }
            if let config { s.configJSON = Self.encodeStringMap(config) }
            if let secrets { s.secretsJSON = Self.encodeStringMap(secrets) }
            if let libraryMap { s.libraryMapJSON = Self.encodeStringMap(libraryMap) }
            try s.update(db)
            return s
        }
        guard let updated else { throw SphynxError.notFound("No source '\(id)'") }
        return updated
    }

    /// Delete a source and **cascade**: the items it produced, then any series/
    /// season containers those items leave empty, then the source row.
    func deleteSource(id: String) async throws {
        let items = try await itemsBySource(sourceId: id)
        let parentIds = Set(items.compactMap(\.parentId))
        let existed: Bool = try await db.writer.write { db in
            guard try SourceRecord.filter(Column("id") == id).fetchCount(db) > 0 else { return false }
            try ItemRecord.filter(Column("sourceId") == id).deleteAll(db)
            _ = try SourceRecord.deleteOne(db, key: id)
            return true
        }
        guard existed else { throw SphynxError.notFound("No source '\(id)'") }
        try await pruneEmptyContainers(seeds: parentIds)
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

    /// Delete an item and **cascade**: its whole subtree (a series takes its
    /// seasons + episodes), then prune any container the deletion leaves empty
    /// up the parent chain. Throws `notFound` if the item doesn't exist.
    func deleteItemTree(id: String) async throws {
        guard let item = try await item(id: id) else {
            throw SphynxError.notFound("No item '\(id)'")
        }
        // Collect the subtree (self + descendants) by walking parentId levels.
        var toDelete: [String] = []
        var frontier: [String] = [id]
        while !frontier.isEmpty {
            toDelete.append(contentsOf: frontier)
            let level = frontier
            let children = try await db.writer.read { db in
                try ItemRecord.filter(level.contains(Column("parentId"))).fetchAll(db)
            }
            frontier = children.map(\.id)
        }
        let ids = toDelete
        try await db.writer.write { db in
            _ = try ItemRecord.filter(ids.contains(Column("id"))).deleteAll(db)
        }
        if let parentId = item.parentId {
            try await pruneEmptyContainers(seeds: [parentId])
        }
    }

    /// Remove series/season containers left with no children, bubbling up the
    /// parent chain (deleting a season may empty its series). Containers carry an
    /// empty `sourceKey`, so they're never playable on their own.
    func pruneEmptyContainers(seeds: Set<String>) async throws {
        var frontier = seeds
        while !frontier.isEmpty {
            var next: Set<String> = []
            for containerId in frontier {
                guard let container = try await item(id: containerId),
                      container.type == "series" || container.type == "season"
                else { continue }
                if try await countChildren(parentId: containerId) == 0 {
                    if let parentId = container.parentId { next.insert(parentId) }
                    try await deleteItem(id: containerId)
                }
            }
            frontier = next
        }
    }
}
