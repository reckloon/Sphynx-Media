import Foundation
import GRDB

/// Collection / box-set support (M8). Collections are discovered during movie
/// enrichment (TMDB `belongs_to_collection`), not during the directory scan, so
/// the create/link logic lives here rather than in the indexer.
extension Catalog {
    /// Find an existing `collection`-typed item for a TMDB collection within a
    /// library (dedup key: TMDB collection id + library).
    func collectionItem(libraryId: String, tmdbId: String) async throws -> ItemRecord? {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("libraryId") == libraryId
                    && Column("type") == "collection"
                    && Column("tmdbId") == tmdbId)
                .fetchOne(db)
        }
    }

    /// Find-or-create the `collection` item for a TMDB collection in a library,
    /// refreshing its title/poster when present. The collection is a top-level
    /// item (no `parentId`) with an empty `sourceKey` (never playable on its own).
    /// Returns the collection item's id.
    @discardableResult
    func upsertCollection(
        libraryId: String,
        tmdbCollectionId: Int,
        title: String,
        primaryImage: String?,
        backdropImage: String?,
        placeholderURL: String?
    ) async throws -> ItemRecord {
        let tmdbId = String(tmdbCollectionId)
        if var existing = try await collectionItem(libraryId: libraryId, tmdbId: tmdbId) {
            // Keep the box-set tile current with the latest TMDB data.
            var changed = false
            if existing.title != title { existing.title = title; changed = true }
            if let primaryImage, existing.primaryImage != primaryImage {
                existing.primaryImage = primaryImage
                changed = true
            }
            if let backdropImage, existing.backdropImage != backdropImage {
                // `thumb` is the horizontal card image — track the backdrop, not the poster.
                existing.backdropImage = backdropImage
                existing.thumbImage = backdropImage
                changed = true
            }
            if let placeholderURL, existing.placeholderURL != placeholderURL {
                existing.placeholderURL = placeholderURL; changed = true
            }
            // A collection's displayable metadata (title + art) all comes from TMDB,
            // so it counts as enriched — stamp it (also heals rows created before this).
            if existing.enrichedAt == nil { existing.enrichedAt = Date().timeIntervalSince1970; changed = true }
            if changed {
                existing.updatedAt = Date().timeIntervalSince1970
                let toUpdate = existing
                try await db.writer.write { db in try toUpdate.update(db) }
            }
            return existing
        }

        let now = Date().timeIntervalSince1970
        var record = ItemRecord(
            id: Tokens.newID("it_"),
            type: "collection",
            title: title,
            sourceId: nil,
            sourceKey: "",  // containers carry an empty key — never playable.
            container: nil,
            tmdbId: tmdbId,
            libraryId: libraryId,
            parentId: nil,
            year: nil,
            createdAt: now,
            updatedAt: now,
            primaryImage: primaryImage,
            backdropImage: backdropImage,
            thumbImage: backdropImage,  // horizontal card image, not the poster
            placeholderURL: placeholderURL,
            identityPinned: false
        )
        // Title + art come from TMDB, so the box-set tile is enriched on creation.
        record.enrichedAt = now
        let toInsert = record
        try await db.writer.write { db in try toInsert.insert(db) }
        return record
    }

    // MARK: Manual collections (admin / delegated curation)

    /// Create an empty **manual** collection in a library — a box-set tile with no
    /// TMDB backing, populated by hand via `assignToCollection`. Carries no `tmdbId`
    /// (so it never dedupes against an auto-discovered collection) and an empty
    /// `sourceKey` (containers are never playable). Stamped `enrichedAt` and skipped
    /// by enrichment, so it's never mistaken for an unidentified movie. Governed by
    /// the owning library's `collectionThreshold` exactly like a TMDB collection.
    func createManualCollection(libraryId: String, title: String) async throws -> ItemRecord {
        let now = Date().timeIntervalSince1970
        var record = ItemRecord(
            id: Tokens.newID("it_"),
            type: "collection",
            title: title,
            sourceId: nil,
            sourceKey: "",
            container: nil,
            tmdbId: nil,
            libraryId: libraryId,
            parentId: nil,
            year: nil,
            createdAt: now,
            updatedAt: now,
            primaryImage: nil,
            backdropImage: nil,
            thumbImage: nil,
            placeholderURL: nil,
            identityPinned: false
        )
        record.enrichedAt = now
        let toInsert = record
        try await db.writer.write { db in try toInsert.insert(db) }
        return record
    }

    /// All `collection` tiles in a library (manual or TMDB-discovered), title-ordered.
    func collectionsIn(libraryId: String) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("libraryId") == libraryId && Column("type") == "collection")
                .order(sql: "title COLLATE NOCASE, id")
                .fetchAll(db)
        }
    }

    /// Top-level **groupable** items in a library — the movies and series you can add
    /// to a collection. Excludes collection tiles themselves and anything already
    /// nested (a member carries `parentId`, so it won't reappear as a candidate).
    /// Optional case-insensitive title substring.
    func groupableItems(libraryId: String, search: String?, limit: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            var request = ItemRecord
                .filter(Column("libraryId") == libraryId && Column("parentId") == nil)
                .filter(["movie", "series"].contains(Column("type")))
            if let search, !search.isEmpty {
                request = request.filter(sql: "title LIKE ? COLLATE NOCASE", arguments: ["%\(search)%"])
            }
            return try request
                .order(sql: "title COLLATE NOCASE, id")
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Link top-level items into a collection: set `parentId` + `collectionId`/
    /// `collectionTitle`, mirroring the auto-link an enriched movie gets. Only items
    /// in the **same library** that are currently top-level (or already in this
    /// collection) are linked — seasons/episodes (no `libraryId`) and items in other
    /// libraries are ignored. Returns the number actually linked.
    @discardableResult
    func assignToCollection(_ collection: ItemRecord, itemIds: [String]) async throws -> Int {
        guard !itemIds.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        return try await db.writer.write { db in
            var linked = 0
            for id in itemIds {
                guard id != collection.id,
                      var item = try ItemRecord.filter(Column("id") == id).fetchOne(db),
                      item.libraryId == collection.libraryId,
                      item.parentId == nil || item.parentId == collection.id
                else { continue }
                item.parentId = collection.id
                item.collectionId = collection.id
                item.collectionTitle = collection.title
                item.updatedAt = now
                try item.update(db)
                linked += 1
            }
            return linked
        }
    }

    /// Unlink items from a collection — back to the library's top level. Only clears
    /// items currently parented to this collection. Returns the number removed.
    @discardableResult
    func removeFromCollection(collectionId: String, itemIds: [String]) async throws -> Int {
        guard !itemIds.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        return try await db.writer.write { db in
            var removed = 0
            for id in itemIds {
                guard var item = try ItemRecord.filter(Column("id") == id).fetchOne(db),
                      item.parentId == collectionId
                else { continue }
                item.parentId = nil
                item.collectionId = nil
                item.collectionTitle = nil
                item.updatedAt = now
                try item.update(db)
                removed += 1
            }
            return removed
        }
    }

    /// Delete a collection tile, **orphaning** its members back to the top level
    /// (membership links cleared) rather than deleting the movies/series. Records a
    /// tombstone for the removed tile. Throws `notFound` if it isn't a collection.
    func deleteCollection(id: String) async throws {
        guard let collection = try await item(id: id), collection.type == "collection" else {
            throw SphynxError.notFound("No collection '\(id)'")
        }
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            // Detach members (clear parent + denormalized collection fields).
            for var member in try ItemRecord.filter(Column("parentId") == id).fetchAll(db) {
                member.parentId = nil
                member.collectionId = nil
                member.collectionTitle = nil
                member.updatedAt = now
                try member.update(db)
            }
            if try ItemRecord.deleteOne(db, key: id) {
                try Self.recordTombstones([id], at: now, in: db)
            }
        }
    }
}
