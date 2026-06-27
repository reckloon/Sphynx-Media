import Foundation
import Logging

/// Orchestrates identification + enrichment for items and persists the result.
/// Present only when TMDB is configured; the Indexer and admin endpoints call it.
struct EnrichmentService: Sendable {
    let catalog: Catalog
    let identifier: any Identifier
    let enricher: Enricher
    /// Freshness window — enriched items aren't re-fetched until this elapses.
    let ttl: Double
    let logger: Logger

    /// Identify (if needed) and enrich one item, persisting changes.
    /// Returns true if the item was updated. Best-effort: failures are logged,
    /// not thrown, so one bad item never aborts a scan.
    @discardableResult
    func process(_ item: ItemRecord, force: Bool) async -> Bool {
        let now = Date().timeIntervalSince1970

        // Skip fresh, already-identified items unless forced.
        if !force, let enrichedAt = item.enrichedAt, item.tmdbId != nil, now - enrichedAt < ttl {
            return false
        }

        do {
            var updated = item

            // Resolve the TMDB id: pinned/known, else identify.
            let resolvedId: Int?
            if item.identityPinned, let existing = item.tmdbId, let value = Int(existing) {
                resolvedId = value
            } else if let existing = item.tmdbId, let value = Int(existing), !force {
                resolvedId = value
            } else if let identification = try await identifier.identify(
                title: item.title, year: item.year, type: item.type, sourceKey: item.sourceKey
            ) {
                updated.tmdbId = String(identification.tmdbId)
                updated.type = identification.type
                updated.confidence = identification.confidence
                resolvedId = identification.tmdbId
            } else {
                resolvedId = nil
            }

            guard let resolvedId else {
                // Unidentified — leave as a skeleton; a later forced run can retry.
                return false
            }

            let fields = try await enricher.enrichMovie(tmdbId: resolvedId)
            apply(fields, to: &updated)
            updated.enrichedAt = now
            updated.updatedAt = now
            try await catalog.updateItem(updated)
            return true
        } catch {
            logger.warning("Enrichment failed for item \(item.id): \(error)")
            return false
        }
    }

    /// Enrich every item that needs it (new or stale). Returns the count updated.
    func enrichAll(force: Bool) async throws -> Int {
        var count = 0
        for item in try await catalog.allItems() where await process(item, force: force) {
            count += 1
        }
        return count
    }

    private func apply(_ fields: EnrichedFields, to item: inout ItemRecord) {
        // Manual edits win: never overwrite a field the admin has locked.
        let locked = item.lockedFields()
        if !locked.contains(LockableField.overview) { item.overview = fields.overview }
        if !locked.contains(LockableField.year), let year = fields.year { item.year = year }
        if !locked.contains(LockableField.runtime) { item.runtime = fields.runtimeSeconds }
        if !locked.contains(LockableField.genres) { item.genresJSON = Self.encode(fields.genres) }
        if !locked.contains(LockableField.communityRating) { item.communityRating = fields.communityRating }
        if !locked.contains(LockableField.images) {
            item.primaryImage = fields.primaryImage
            item.backdropImage = fields.backdropImage
            item.thumbImage = fields.thumbImage
        }
        if !locked.contains(LockableField.placeholder) { item.placeholderURL = fields.placeholderURL }
        if !locked.contains(LockableField.cast) { item.castJSON = Self.encode(fields.cast) }

        // Extended metadata (server-owned; projected onto the canonical Item).
        let extended = StoredExtended(
            originalTitle: fields.originalTitle,
            tagline: fields.tagline,
            status: fields.status,
            premiereDate: fields.premiereDate,
            endDate: nil,
            studios: fields.studios.isEmpty ? nil : fields.studios,
            directors: fields.directors.isEmpty ? nil : fields.directors,
            writers: fields.writers.isEmpty ? nil : fields.writers,
            countries: fields.countries.isEmpty ? nil : fields.countries,
            externalIds: fields.externalIds.isEmpty ? nil : fields.externalIds
        )
        item.extendedJSON = extended.isEmpty ? nil : Self.encode(extended)
    }

    private static func encode(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
