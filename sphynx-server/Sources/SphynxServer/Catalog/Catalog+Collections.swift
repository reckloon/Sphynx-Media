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
}
