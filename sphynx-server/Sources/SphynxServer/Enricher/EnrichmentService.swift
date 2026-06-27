import Foundation
import Logging

/// Orchestrates identification + enrichment for items and persists the result.
/// Present only when TMDB is configured; the Indexer and admin endpoints call it.
struct EnrichmentService: Sendable {
    let catalog: Catalog
    let identifier: any Identifier
    let enricher: Enricher
    /// TV identify + enrich (present when TMDB is configured). Movies use
    /// `enricher`; TV (series/season/episode) routes through this.
    let tv: TVEnricher?
    /// Freshness window — enriched items aren't re-fetched until this elapses.
    let ttl: Double
    let logger: Logger

    private static let tvTypes: Set<String> = ["series", "season", "episode"]

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

        // TV items use the TV endpoints, not the movie endpoint.
        if Self.tvTypes.contains(item.type) {
            return await processTV(item, now: now)
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

    /// Enrich a TV item (series / season / episode) via the TV endpoints, honoring
    /// admin field locks. Series resolve their own TMDB id (pinned or searched);
    /// seasons/episodes inherit the series id stored on the row.
    private func processTV(_ item: ItemRecord, now: Double) async -> Bool {
        guard let tv else { return false }  // TV enrichment needs TMDB configured
        do {
            var updated = item
            switch item.type {
            case "series":
                // Resolve the series TMDB id: pinned, else known, else search.
                let resolvedId: Int?
                if item.identityPinned, let id = item.tmdbId.flatMap(Int.init) {
                    resolvedId = id
                } else if let id = item.tmdbId.flatMap(Int.init) {
                    resolvedId = id
                } else {
                    resolvedId = try await tv.identifySeries(title: item.seriesTitle ?? item.title)
                }
                guard let resolvedId else { return false }
                updated.tmdbId = String(resolvedId)
                // Series fields map onto the same EnrichedFields the movie path
                // uses, so the shared `apply` honors locks identically.
                apply(try await tv.seriesFields(tmdbId: resolvedId), to: &updated)

            case "season":
                guard let seriesId = item.tmdbId.flatMap(Int.init), let season = item.seasonIndex else { return false }
                let details = try await tv.season(tmdbId: seriesId, season: season)
                let locked = updated.lockedFields()
                if !locked.contains(LockableField.overview) { updated.overview = details.overview }
                if !locked.contains(LockableField.images) {
                    updated.primaryImage = TMDBImage.url(details.posterPath, size: "w500")
                    updated.thumbImage = TMDBImage.url(details.posterPath, size: "w342")
                }
                if !locked.contains(LockableField.placeholder) {
                    updated.placeholderURL = TMDBImage.url(details.posterPath, size: "w92")
                }

            case "episode":
                guard let seriesId = item.tmdbId.flatMap(Int.init),
                      let season = item.seasonIndex, let episode = item.episodeIndex else { return false }
                let details = try await tv.season(tmdbId: seriesId, season: season)
                guard let meta = details.episodes.first(where: { $0.episodeNumber == episode }) else { return false }
                let locked = updated.lockedFields()
                if !locked.contains(LockableField.overview) { updated.overview = meta.overview }
                if !locked.contains(LockableField.runtime) { updated.runtime = meta.runtimeMinutes.map { Double($0) * 60 } }
                if !locked.contains(LockableField.images) {
                    updated.primaryImage = TMDBImage.url(meta.stillPath, size: "w780")
                    updated.thumbImage = TMDBImage.url(meta.stillPath, size: "w300")
                }
                if !locked.contains(LockableField.placeholder) {
                    updated.placeholderURL = TMDBImage.url(meta.stillPath, size: "w92")
                }

            default:
                return false
            }
            updated.enrichedAt = now
            updated.updatedAt = now
            try await catalog.updateItem(updated)
            return true
        } catch {
            logger.warning("TV enrichment failed for item \(item.id): \(error)")
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
